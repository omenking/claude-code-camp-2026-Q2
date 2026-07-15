require "json"
require "fileutils"
require "securerandom"
require "time"

module Boukensha
  class Logger
    DEFAULT_SESSION_DIR = "sessions".freeze

    attr_reader :session_id, :path

    def initialize(session_id: nil, dir: nil, log: nil, snapshot: {})
      @session_id = session_id || generate_session_id
      @path       = log || File.join(dir || default_dir, "#{@session_id}.jsonl")

      FileUtils.mkdir_p(File.dirname(@path))
      @log_io = File.open(@path, "a")
      write_log({ phase: "session_start" }.merge(snapshot))
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

    def prompt(messages:, tools:)
      write_log(
        phase:         "prompt",
        message_count: messages.size,
        messages:      messages.map { |m| serialize_message(m) },
        tool_count:    tools.size,
        tools:         tools.keys
      )
    end

    def tool_call(name:, args:)
      write_log(phase: "tool_call", name: name, args: args)
    end

    def tool_result(name:, result:, ok: true, error: nil)
      write_log(phase: "tool_result", name: name, result: result.to_s, ok: ok, error: error)
    end

    def response(text:, usage: nil, stop_reason: nil, task: nil, backend: nil)
      write_log(
        {
          phase: "response",
          text: text.to_s.strip,
          usage: usage,
          stop_reason: stop_reason
        }.merge(execution_metadata(task: task, backend: backend, usage: usage))
      )
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
      @log_io.puts JSON.generate(event.merge(session_id: @session_id, at: Time.now.iso8601))
      @log_io.flush
      @subscribers&.each { |s| s.call(event) }
    end

    def generate_session_id
      "#{Time.now.utc.strftime("%Y%m%dT%H%M%SZ")}-#{SecureRandom.hex(4)}"
    end

    def serialize_message(msg)
      { role: msg.role, content: msg.content }
    end

    def execution_metadata(task:, backend:, usage:)
      return {} unless task || backend || usage

      tokens = usage_tokens(usage)
      metadata = {
        task: task_name(task),
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

    def task_name(task)
      task&.respond_to?(:task_name) ? task.task_name : task&.to_s
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
