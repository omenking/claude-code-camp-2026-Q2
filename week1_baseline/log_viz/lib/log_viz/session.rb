require "json"

module LogViz
  # Parses a Boukensha session .jsonl log into an ordered list of entries
  # suitable for rendering as a human-readable transcript.
  class Session
    Entry = Struct.new(:type, :text, :usage, :turn, :iteration,
                       :tool_name, :tool_args, :tool_result, :tool_ok, :tool_error,
                       :stop_reason, :reason, :iterations, :tokens, :before, :dropped,
                       :running_turn_tokens, :redacted,
                       :task, :provider, :model, :input_tokens, :output_tokens,
                       :cost_usd, :usage_unit, :usage_level,
                       keyword_init: true)

    # One sample per `response`, in order. Drives the in-transcript chips (§2.3)
    # and the trend sparkline (§2.4).
    UsagePoint = Struct.new(:turn, :iteration, :input, :output,
                            :cache_read, :cache_creation, :running, :at,
                            :task, :provider, :model, :cost_usd,
                            :usage_unit, :usage_level,
                            keyword_init: true)

    # Per-MTok input/output rates. Cache reads bill at ~0.1x input, cache
    # writes at ~1.25x input. Unknown models return nil cost (rendered as —).
    MODEL_PRICES = {
      "claude-fable-5"    => { input: 10.0, output: 50.0 },
      "claude-opus-4-8"   => { input: 5.0,  output: 25.0 },
      "claude-opus-4-7"   => { input: 5.0,  output: 25.0 },
      "claude-opus-4-6"   => { input: 5.0,  output: 25.0 },
      "claude-sonnet-4-6" => { input: 3.0,  output: 15.0 },
      "claude-haiku-4-5"  => { input: 1.0,  output: 5.0 },
    }.freeze

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

      File.foreach(@path) do |line|
        line = line.strip
        next if line.empty?

        event = JSON.parse(line)

        case event["phase"]
        when "session_start"
          @started_at = event["at"]
          @snapshot   = event           # carries the limits/model denominators
        when "turn"
          current_turn = event["n"]
          pending_user = true
          running_turn = 0
        when "iteration"
          current_iteration = event["n"]
        when "prompt"
          next unless pending_user

          message = event["messages"]&.last
          if message && message["role"] == "user"
            @entries << Entry.new(type: :user, text: extract_text(message["content"]),
                                   turn: current_turn, iteration: current_iteration)
          end
          pending_user = false
        when "compaction"
          @entries << Entry.new(type: :compaction, before: event["before"],
                                 dropped: event["dropped"],
                                 turn: current_turn, iteration: current_iteration)
        when "reasoning"
          @entries << Entry.new(type: :reasoning, text: event["text"],
                                 redacted: event["redacted"],
                                 turn: current_turn, iteration: current_iteration)
        when "plan"
          @entries << Entry.new(type: :plan, text: event["text"],
                                 turn: current_turn, iteration: current_iteration)
        when "response"
          usage = event["usage"]
          if usage
            input  = event["input_tokens"] || usage["input_tokens"]
            output = event["output_tokens"] || usage["output_tokens"]
            input  = input.to_i
            output = output.to_i
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
          @entries << Entry.new(type: :assistant, text: event["text"], usage: usage,
                                 stop_reason: event["stop_reason"],
                                 running_turn_tokens: running_turn,
                                 task: event["task"], provider: event["provider"],
                                 model: event["model"], input_tokens: event["input_tokens"],
                                 output_tokens: event["output_tokens"],
                                 cost_usd: numeric(event["cost_usd"]),
                                 usage_unit: event["usage_unit"],
                                 usage_level: event["usage_level"],
                                 turn: current_turn, iteration: current_iteration)
        when "tool_call"
          pending_calls << { name: event["name"], args: event["args"] }
        when "tool_result"
          call = pending_calls.shift || {}
          @entries << Entry.new(type: :tool, tool_name: event["name"] || call[:name], tool_args: call[:args],
                                 tool_result: event["result"], tool_ok: event.fetch("ok", true),
                                 tool_error: event["error"],
                                 turn: current_turn, iteration: current_iteration)
        when "turn_end"
          @entries << Entry.new(type: :turn_end, reason: event["reason"],
                                 iterations: event["iterations"], tokens: event["tokens"],
                                 turn: current_turn, iteration: current_iteration)
        end
      end
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
    def task_names = @usage_series.map(&:task).compact.uniq

    def model_summary
      labels = @usage_series.map { |p| model_label(p.provider, p.model) }.compact.uniq
      labels = [model_label(provider, model)].compact if labels.empty?
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

    # ---- per-turn rollup (§2.2) -----------------------------------------
    # One row per turn, built from turn_end events. Falls back to a single
    # synthetic row for older logs that predate turn_end.
    def turns
      rows = turn_ends.map do |e|
        { n: e.turn, iterations: e.iterations, tokens: e.tokens.to_i, reason: e.reason }
      end
      return rows unless rows.empty?

      [{ n: entries.map(&:turn).max.to_i, iterations: iteration_count,
         tokens: @total_input_tokens + @total_output_tokens, reason: end_reason }]
    end

    def limit_reason?(reason) = !reason.nil? && reason != "completed"

    # Worst turn by token spend — the one closest to (or over) the cap.
    def largest_turn      = turns.max_by { |t| t[:tokens] }
    def busiest_turn      = turns.max_by { |t| t[:iterations].to_i }
    def any_limit_tripped? = turns.any? { |t| limit_reason?(t[:reason]) }
    def turn_count_real    = turns.length

    # ---- cost estimate (§2.1) -------------------------------------------
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
        key = [p.task || "unknown", p.provider || provider || "unknown", p.model || model || "unknown"]
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
      rows.values.sort_by { |row| [-row[:cost], row[:task], row[:provider], row[:model]] }
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

    private

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

      [provider, model].compact.join(" / ")
    end

    def point_cost(point)
      return point.cost_usd unless point.cost_usd.nil?

      rates = MODEL_PRICES[point.model || model]
      return nil unless rates

      input_rate  = rates[:input] / 1_000_000.0
      output_rate = rates[:output] / 1_000_000.0
      point.input * input_rate +
        point.output * output_rate +
        point.cache_read * input_rate * 0.1 +
        point.cache_creation * input_rate * 1.25
    end
  end
end
