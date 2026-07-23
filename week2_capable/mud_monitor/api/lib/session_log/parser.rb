require "json"
require "time"

module SessionLog
  # Parses a Boukensha session .jsonl log into an ordered list of entries
  # suitable for rendering as a human-readable transcript.
  # Port of week1_baseline/log_viz/lib/log_viz/session.rb.
  class Parser
    Entry = Struct.new(:seq, :type, :text, :usage, :turn, :iteration, :at, :mono_ms,
                       :dt_ms, :duration_ms,
                       :tool_name, :tool_args, :tool_result, :tool_ok, :tool_error,
                       :stop_reason, :reason, :iterations, :tokens, :before, :dropped,
                       :running_turn_tokens, :redacted, :raw,
                       :task, :depth, :task_name, :max_iterations,
                       :provider, :model, :input_tokens, :output_tokens,
                       :cost_usd, :usage_unit, :usage_level,
                       :request_seq, :message_count,
                       keyword_init: true)

    # One sample per `response`, in order. Drives the cost breakdown and the
    # trend sparkline.
    UsagePoint = Struct.new(:turn, :iteration, :input, :output,
                            :cache_read, :cache_creation, :running, :at,
                            :task, :provider, :model, :cost_usd,
                            :usage_unit, :usage_level,
                            keyword_init: true)

    attr_reader :id, :path, :started_at, :entries,
                :total_input_tokens, :total_output_tokens, :snapshot,
                :usage_series, :peak_input_tokens

    def self.load(path)
      new(path).tap(&:parse!)
    end

    def initialize(path)
      @path                = path
      @id                  = File.basename(path, ".jsonl")
      @entries             = []
      @started_at          = nil
      @total_input_tokens  = 0
      @total_output_tokens = 0
      @snapshot            = {}
      @usage_series        = []
      @peak_input_tokens   = 0
    end

    def parse!
      current_turn      = 0
      current_iteration = 0
      pending_user      = true
      pending_calls     = []
      running_turn      = 0   # cumulative input+output within the current turn
      seq               = 0
      turn_started      = nil # {at:, mono_ms:} of the current "turn" event
      open_tasks        = [] # task_start events awaiting their task_end
      request_ordinal   = 0   # 1-based index among request events → sidebar checkpoint seq

      File.foreach(@path) do |line|
        line = line.strip
        next if line.empty?

        event = begin
          JSON.parse(line)
        rescue JSON::ParserError
          next # truncated final line of a log still being written
        end

        case event["phase"]
        when "session_start"
          @started_at = event["at"]
          @snapshot   = event           # carries the limits/model denominators
        when "turn"
          current_turn = event["n"]
          pending_user = true
          running_turn = 0
          turn_started = { at: event["at"], mono_ms: event["mono_ms"] }
        when "iteration"
          current_iteration = event["n"]
        when "request"
          # The full request payload (system + tool schemas + wire messages) is
          # far too large to render inline — it belongs in the messages sidebar
          # (SessionLog::MessageTimeline). Here we emit only a compact marker so
          # the transcript can place a button at the exact point the call was
          # made; `request_seq` maps 1:1 to the sidebar checkpoint to open.
          request_ordinal += 1
          @entries << seq_entry(seq += 1, event, type: :request,
                                 request_seq: request_ordinal,
                                 message_count: event["message_count"],
                                 turn: current_turn, iteration: current_iteration)
        when "prompt"
          next unless pending_user

          message = event["messages"]&.last
          if message && message["role"] == "user"
            @entries << seq_entry(seq += 1, event, type: :user, text: extract_text(message["content"]),
                                   turn: current_turn, iteration: current_iteration)
          end
          pending_user = false
        when "compaction"
          @entries << seq_entry(seq += 1, event, type: :compaction, before: event["before"],
                                 dropped: event["dropped"],
                                 turn: current_turn, iteration: current_iteration)
        when "clear"
          @entries << seq_entry(seq += 1, event, type: :clear, before: event["before"],
                                 dropped: event["dropped"] || event["before"],
                                 turn: current_turn, iteration: current_iteration)
        when "reasoning"
          @entries << seq_entry(seq += 1, event, type: :reasoning, text: event["text"],
                                 redacted: event["redacted"],
                                 turn: current_turn, iteration: current_iteration)
        when "plan"
          @entries << seq_entry(seq += 1, event, type: :plan, text: event["text"],
                                 turn: current_turn, iteration: current_iteration)
        when "response"
          usage = event["usage"]
          if usage
            input  = (event["input_tokens"] || usage["input_tokens"]).to_i
            output = (event["output_tokens"] || usage["output_tokens"]).to_i
            @total_input_tokens  += input
            @total_output_tokens += output
            running_turn         += input + output
            @peak_input_tokens    = input if input > @peak_input_tokens
            @usage_series << UsagePoint.new(
              turn: current_turn, iteration: current_iteration,
              input: input, output: output,
              cache_read: usage["cache_read_input_tokens"].to_i,
              cache_creation: usage["cache_creation_input_tokens"].to_i,
              running: running_turn, at: event["at"],
              task: event["task"], provider: event["provider"], model: event["model"],
              cost_usd: numeric(event["cost_usd"]),
              usage_unit: event["usage_unit"], usage_level: event["usage_level"])
          end
          entry = seq_entry(seq += 1, event, type: :assistant, text: event["text"], usage: usage,
                            stop_reason: event["stop_reason"],
                            running_turn_tokens: running_turn,
                            provider: event["provider"],
                            model: event["model"], input_tokens: event["input_tokens"],
                            output_tokens: event["output_tokens"],
                            cost_usd: numeric(event["cost_usd"]),
                            usage_unit: event["usage_unit"],
                            usage_level: event["usage_level"],
                            turn: current_turn, iteration: current_iteration)
          # §4.4: model latency is measured from the previous iteration/tool_result
          # to this response — which, in the ordered entries list, is simply the
          # previous entry (no Entry is emitted for "iteration" or a skipped
          # "prompt"), so it is exactly dt_ms.
          entry.duration_ms = entry.dt_ms
          @entries << entry
        when "tool_call"
          pending_calls << { name: event["name"], args: event["args"], at: event["at"],
                             mono_ms: event["mono_ms"], depth: event["depth"].to_i }
        when "tool_result"
          call = take_pending_call(pending_calls, event) || {}
          @entries << seq_entry(seq += 1, event, type: :tool, tool_name: event["name"] || call[:name],
                                 tool_args: call[:args],
                                 tool_result: event["result"], tool_ok: event.fetch("ok", true),
                                 tool_error: event["error"],
                                 duration_ms: elapsed_ms(call[:mono_ms], call[:at], event["mono_ms"], event["at"]),
                                 turn: current_turn, iteration: current_iteration)
        when "task_start"
          # A delegated sub-run opening inside this session (plan Amendment A).
          # Its own limits/model ride on this event — the parent's session_start
          # snapshot describes the parent, not the subagent.
          open_tasks << { at: event["at"], mono_ms: event["mono_ms"] }
          @entries << seq_entry(seq += 1, event, type: :task_start,
                                 task_name: event["task_name"],
                                 model: event["model"], provider: event["provider"],
                                 max_iterations: event["max_iterations"],
                                 turn: current_turn, iteration: current_iteration)
        when "task_end"
          opened   = open_tasks.pop || {}
          @entries << seq_entry(seq += 1, event, type: :task_end,
                                 task_name: event["task_name"],
                                 duration_ms: elapsed_ms(opened[:mono_ms], opened[:at],
                                                          event["mono_ms"], event["at"]),
                                 turn: current_turn, iteration: current_iteration)
        when "turn_end"
          duration = turn_started && elapsed_ms(turn_started[:mono_ms], turn_started[:at],
                                                 event["mono_ms"], event["at"])
          @entries << seq_entry(seq += 1, event, type: :turn_end, reason: event["reason"],
                                 iterations: event["iterations"], tokens: event["tokens"],
                                 duration_ms: duration,
                                 turn: current_turn, iteration: current_iteration)
        else
          @entries << seq_entry(seq += 1, event, type: :unknown, raw: event,
                                 turn: current_turn, iteration: current_iteration)
        end
      end

      @unclosed_tasks = open_tasks.size
    end

    # "monotonic" once every logged event carries `mono_ms` (§4.1); "wallclock"
    # for ms-resolution `at` from before that upgrade landed but after logger
    # timestamps gained sub-second digits; "wallclock_coarse" for the original
    # whole-second `at` — durations under 1s on those are unknowable, not zero.
    def timing_source
      return "monotonic" if @snapshot["mono_ms"] || entries.any?(&:mono_ms)
      return "wallclock" if @started_at.to_s.include?(".") || entries.any? { |e| e.at.to_s.include?(".") }

      "wallclock_coarse"
    end

    def turn_count
      entries.map(&:turn).max.to_i + 1
    end

    def iteration_count
      entries.map(&:iteration).max.to_i
    end

    # ---- denominators sourced from the session_start snapshot ------------
    def iteration_max   = @snapshot["max_iterations"]
    def max_turn_tokens = @snapshot["max_turn_tokens"]
    def context_window  = @snapshot["context_window"]
    def model           = @snapshot["model"]
    def provider        = @snapshot["provider"]
    def response_models = @usage_series.map(&:model).compact.uniq
    def response_providers = @usage_series.map(&:provider).compact.uniq

    # ---- task roster (plan Amendment A) ----------------------------------
    # The root task is whatever depth 0 was doing; the roster is every task that
    # ran in this file. A session that IS a sub-run (a standalone room_inspector,
    # or one of the orphaned files written before Amendment A) is a valid session
    # whose root task is `room_inspector` — nothing here assumes "player".
    def root_task
      entries.find { |e| e.depth.to_i.zero? && e.task }&.task
    end

    def task_roster = entries.map(&:task).compact.uniq
    def sub_runs    = entries.count { |e| e.type == :task_start }

    # A sub-run whose task_end never arrived — the process died mid-delegation.
    # The group is closed at EOF for rendering; this is how the UI knows not to
    # present that closing as a fact.
    def unclosed_tasks = @unclosed_tasks.to_i

    def model_summary
      labels = @usage_series.map { |p| model_label(p.provider, p.model) }.compact.uniq
      labels = [ model_label(provider, model) ].compact if labels.empty?
      labels.length <= 2 ? labels.join(", ") : "#{labels.length} models"
    end

    # ---- per-turn outcomes ----------------------------------------------
    def turn_ends   = entries.select { |e| e.type == :turn_end }
    def end_reason  = turn_ends.last&.reason
    def stopped?    = !end_reason.nil? && end_reason != "completed"

    # Iterations/tokens of the final turn (falls back to whole-session figures
    # for older logs that predate turn_end).
    def last_iterations = turn_ends.last&.iterations || iteration_count
    def turn_tokens     = turn_ends.last&.tokens || (@total_input_tokens + @total_output_tokens)

    # ---- per-turn rollup --------------------------------------------------
    # One row per turn, built from turn_end events. Falls back to a single
    # synthetic row for older logs that predate turn_end.
    def turns
      rows = turn_ends.map do |e|
        { n: e.turn, iterations: e.iterations, tokens: e.tokens.to_i, reason: e.reason,
          started_at: nil, ended_at: e.at, duration_ms: nil }
      end
      return rows unless rows.empty?

      [ { n: entries.map(&:turn).max.to_i, iterations: iteration_count,
         tokens: @total_input_tokens + @total_output_tokens, reason: end_reason,
         started_at: nil, ended_at: nil, duration_ms: nil } ]
    end

    def limit_reason?(reason) = !reason.nil? && reason != "completed"

    # Worst turn by token spend — the one closest to (or over) the cap.
    def largest_turn      = turns.max_by { |t| t[:tokens] }
    def busiest_turn      = turns.max_by { |t| t[:iterations].to_i }
    def any_limit_tripped? = turns.any? { |t| limit_reason?(t[:reason]) }
    def turn_count_real    = turns.length

    # ---- cost estimate ----------------------------------------------------
    # Prefer logger-emitted per-response cost. Older logs fall back to local
    # model rates; nil means no trustworthy cost is available.
    def estimated_cost
      costs = @usage_series.map { |p| point_cost(p) }.compact
      return nil if costs.empty?

      costs.sum
    end

    def cost_breakdown
      rows = {}
      @usage_series.each do |p|
        key = [ p.task || "unknown", p.provider || provider || "unknown", p.model || model || "unknown" ]
        row = rows[key] ||= {
          task: key[0], provider: key[1], model: key[2],
          calls: 0, input: 0, output: 0, cost: 0.0, cost_known: true
        }
        row[:calls] += 1
        row[:input] += p.input.to_i
        row[:output] += p.output.to_i
        cost = point_cost(p)
        if cost
          row[:cost] += cost
        else
          row[:cost_known] = false
        end
      end
      rows.values.sort_by { |row| [ -row[:cost], row[:task], row[:provider], row[:model] ] }
    end

    def task
      entries.find { |e| e.type == :user }&.text
    end

    def final_response
      entries.reverse.find do |e|
        e.type == :assistant &&
          e.stop_reason != "tool_use" &&
          !e.text.to_s.start_with?("(tool use")
      end&.text
    end

    def ended_at
      entries.last&.at
    end

    def tool_calls_count
      entries.count { |e| e.type == :tool }
    end

    private

    # Pair a tool_result with the tool_call that opened it.
    #
    # Plain FIFO breaks as soon as a delegating tool is in flight: the player's
    # `inspect_room` call is still pending while the sub-run's own calls open and
    # close inside it, so the first result to arrive is the INNER one and a
    # `shift` hands it the outer call's timestamp. Matching on name+depth (most
    # recent first, since nesting is strictly LIFO) pairs both correctly, and the
    # name-only fallback keeps pre-Amendment-A logs, which carry no depth,
    # behaving as before.
    def take_pending_call(pending, event)
      name  = event["name"]
      depth = event["depth"].to_i
      index = pending.rindex { |c| c[:name] == name && c[:depth] == depth } ||
              pending.rindex { |c| c[:name] == name }
      return nil if index.nil?

      pending.delete_at(index)
    end

    # `task`/`depth` are stamped here, from the record, for EVERY entry type —
    # the logger stamps them in its own write path for the same reason (plan
    # §A.3.1): a field a call site can forget is a field that goes dead. Logs
    # written before Amendment A carry neither; they read as one unlabelled root
    # task at depth 0, which is what they were.
    def seq_entry(seq, event, **attrs)
      ts = ts_ms(event)
      dt = (ts && @last_ts_ms) ? (ts - @last_ts_ms).round : nil
      @last_ts_ms = ts if ts

      Entry.new(seq: seq, at: event["at"], mono_ms: event["mono_ms"], dt_ms: dt,
                task: event["task"], depth: event["depth"].to_i, **attrs)
    end

    # Prefers the monotonic clock (immune to NTP steps / DST); falls back to
    # wall-clock for logs predating §4.1.
    def ts_ms(event)
      return event["mono_ms"].to_f if event["mono_ms"]
      return nil unless event["at"]

      Time.parse(event["at"]).to_f * 1000
    rescue ArgumentError, TypeError
      nil
    end

    def elapsed_ms(mono1, at1, mono2, at2)
      return (mono2 - mono1).round if mono1 && mono2

      return nil unless at1 && at2

      ((Time.parse(at2) - Time.parse(at1)) * 1000).round
    rescue ArgumentError, TypeError
      nil
    end

    def extract_text(content)
      case content
      when String
        content
      when Array
        content.map do |block|
          case block["type"]
          when "text"        then block["text"]
          when "tool_use"    then "[tool_use: #{block["name"]}]"
          when "tool_result" then "[tool_result]"
          else block.to_s
          end
        end.join("\n")
      else
        content.to_s
      end
    end

    def numeric(value)
      return nil if value.nil?

      Float(value)
    rescue ArgumentError, TypeError
      nil
    end

    def model_label(provider, model)
      return nil if provider.nil? && model.nil?

      [ provider, model ].compact.join(" / ")
    end

    def point_cost(point)
      Pricing.cost_for(point, fallback_model: model)
    end
  end
end
