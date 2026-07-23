require "json"
require "fileutils"
require "securerandom"
require "time"
require "digest"

module Boukensha
  class Logger
    DEFAULT_SESSION_DIR = "sessions".freeze

    attr_reader :session_id, :path

    DEFAULT_TASK = "player".freeze

    def initialize(session_id: nil, dir: nil, log: nil, snapshot: {}, task: DEFAULT_TASK)
      @session_id = session_id || generate_session_id
      @path       = log || File.join(dir || default_dir, "#{@session_id}.jsonl")
      @task_stack = [ task.to_s ]

      FileUtils.mkdir_p(File.dirname(@path))
      @log_io = File.open(@path, "a")
      write_log({ phase: "session_start" }.merge(snapshot))
    end

    # Bracket a delegated sub-run so its events land in THIS file, labelled with
    # the task that produced them. Without this, every delegation minted a fresh
    # logger and therefore a fresh session file, leaving neither file a complete
    # account of the turn and nothing on disk linking them (plan Amendment A).
    #
    # Reentrant: the stack keeps nesting honest if a subagent ever delegates
    # further, and `ensure` guarantees a raise inside the sub-run still closes
    # the group rather than mislabelling everything that follows.
    def task(name, snapshot: {})
      @task_stack.push(name.to_s)
      write_log({ phase: "task_start", task_name: name.to_s }.merge(snapshot))
      yield
    ensure
      write_log(phase: "task_end", task_name: name.to_s)
      @task_stack.pop
    end

    # The task currently on top of the stack — what the agent is doing *now*.
    def current_task
      @task_stack.last
    end

    def turn(n:)
      write_log(phase: "turn", n: n)
    end

    def iteration(n:, max:)
      write_log(phase: "iteration", n: n, max: max)
    end

    def limit_reached(kind:, n:, max:)
      write_log(phase: "limit_reached", kind: kind, n: n, max: max)
    end

    def turn_end(reason:, iterations:, tokens: nil)
      write_log(phase: "turn_end", reason: reason, iterations: iterations, tokens: tokens)
    end

    def prompt(messages:, tools:, context_window:)
      write_log(
        phase:          "prompt",
        message_count:  messages.size,
        messages:       messages.map { |m| serialize_message(m) },
        tool_count:     tools.size,
        tools:          tools.keys,
        context_window: context_window
      )
    end

    # The *definitive* record of what the model was handed: the exact request
    # body built by the backend (`to_api_payload`) — system prompt, full tool
    # schemas, and messages in provider wire format — logged at the moment of
    # invocation. This is distinct from `prompt`, which logs a reconstruction of
    # Context#messages (role + content) that omits the system prompt, the tool
    # schemas, and the wire transform (tool_result → user block, reasoning
    # denormalization, …). `prompt` drives the transcript; `request` is "what the
    # agent actually received".
    #
    # `system` and `tools` are effectively constant across a turn's iterations,
    # so they are logged in full only when they change from the previous request;
    # otherwise a `*_unchanged` flag stands in and the reader carries the last
    # value forward. `messages` — the part that actually grows — is always logged
    # in full.
    def request(payload:)
      payload = stringify(payload)
      messages = payload["messages"] || []

      event = {
        phase:         "request",
        model:         payload["model"],
        max_tokens:    payload["max_tokens"],
        message_count: messages.size,
        messages:      messages
      }

      merge_system!(event, payload["system"])
      merge_tools!(event, payload["tools"] || [])

      write_log(event)
    end

    def compaction(before:, dropped:, context_window:)
      write_log(phase: "compaction", before: before, dropped: dropped, context_window: context_window)
    end

    # A `/clear` wiped the conversation history. `before` is the message count at
    # the moment of the wipe (all of which were dropped) — the next `prompt`
    # snapshot starts the history over from empty. Distinct from `compaction`,
    # which only trims a prefix; a clear drops everything.
    def clear(before:)
      write_log(phase: "clear", before: before, dropped: before)
    end

    def tool_call(name:, args:)
      write_log(phase: "tool_call", name: name, args: args)
    end

    def tool_result(name:, result:, ok: true, error: nil)
      write_log(phase: "tool_result", name: name, result: result.to_s, ok: ok, error: error)
    end

    # `task` is deliberately NOT a parameter here: write_log stamps it on every
    # event from the task stack, so no call site can forget it (and none can
    # disagree with another — two sources of truth for one field is how the old
    # `task:` argument ended up nil at every call site and dead in every log).
    def response(text:, usage: nil, stop_reason: nil, backend: nil)
      write_log(
        {
          phase: "response",
          text: text.to_s.strip,
          usage: usage,
          stop_reason: stop_reason
        }.merge(execution_metadata(backend: backend, usage: usage))
      )
    end

    def reasoning(text:, redacted: false)
      write_log(phase: "reasoning", text: text.to_s, redacted: redacted)
    end

    def plan(text:)
      write_log(phase: "plan", text: text.to_s.strip)
    end

    def raw(data:)
      return unless Boukensha.debug?

      write_log(phase: "raw", data: data)
    end

    def subscribe(&block)
      @subscribers ||= []
      @subscribers << block
    end

    def close
      @log_io&.close
    end

    private

    def default_dir
      File.join(Boukensha.config.dir, DEFAULT_SESSION_DIR)
    end

    def write_log(event)
      now = Time.now
      @log_io.puts JSON.generate(event.merge(
        session_id: @session_id,
        task:       @task_stack.last,
        depth:      @task_stack.size - 1,
        at:         now.iso8601(3),
        mono_ms:    (Process.clock_gettime(Process::CLOCK_MONOTONIC) * 1000).round
      ))
      @log_io.flush
      @subscribers&.each { |s| s.call(event) }
    end

    def generate_session_id
      "#{Time.now.utc.strftime("%Y%m%dT%H%M%SZ")}-#{SecureRandom.hex(4)}"
    end

    def serialize_message(msg)
      { role: msg.role, content: msg.content }
    end

    # JSON-round-trip a symbol-keyed payload into the string-keyed shape it will
    # have on disk, so dedup comparisons below see the same thing the reader will.
    def stringify(payload)
      JSON.parse(JSON.generate(payload))
    end

    # Log the system prompt in full only when it changed since the last request;
    # otherwise mark it unchanged and let the reader carry the last value forward.
    def merge_system!(event, system)
      if system == @last_system && defined?(@last_system)
        event[:system_unchanged] = true
      else
        event[:system]  = system
        @last_system    = system
      end
    end

    # Same treatment for the tool schemas, keyed on a content hash so a large
    # unchanged toolset isn't re-serialized on every iteration.
    def merge_tools!(event, tools)
      sig = Digest::SHA256.hexdigest(JSON.generate(tools))
      if sig == @last_tools_sig
        event[:tools_unchanged] = true
        event[:tool_count]      = @last_tool_count
      else
        event[:tools]        = tools
        event[:tool_count]   = tools.size
        @last_tools_sig      = sig
        @last_tool_count     = tools.size
      end
    end

    def execution_metadata(backend:, usage:)
      return {} unless backend || usage

      tokens = usage_tokens(usage)
      metadata = {
        provider: provider_name(backend),
        model: backend&.model,
        usage_unit: backend&.respond_to?(:usage_unit) ? backend.usage_unit : nil,
        usage_level: backend&.respond_to?(:usage_level) ? backend.usage_level : nil,
        input_tokens: tokens[:input],
        output_tokens: tokens[:output],
        cost_usd: estimate_cost(backend, tokens)
      }
      metadata.compact
    end

    def provider_name(backend)
      return nil unless backend

      backend.class.name.split("::").last.gsub(/([a-z\d])([A-Z])/, '\1_\2').downcase
    end

    def usage_tokens(usage)
      usage ||= {}
      {
        input: first_integer(usage, "input_tokens", "prompt_tokens", "promptTokenCount", "prompt_eval_count"),
        output: first_integer(usage, "output_tokens", "completion_tokens", "candidatesTokenCount", "eval_count")
      }
    end

    def first_integer(hash, *keys)
      keys.each do |key|
        value = hash[key] || hash[key.to_sym]
        return Integer(value) unless value.nil?
      end
      nil
    rescue ArgumentError, TypeError
      nil
    end

    def estimate_cost(backend, tokens)
      return nil unless backend&.respond_to?(:estimate_cost)
      return nil unless tokens[:input] && tokens[:output]

      backend.estimate_cost(input_tokens: tokens[:input], output_tokens: tokens[:output])
    end
  end
end
