module Boukensha
  class Agent
    # Default iteration ceiling. The *enforced* value comes from the
    # max_iterations: constructor arg (sourced from Config at the run/repl path),
    # which falls back to this constant. 0 (or nil) disables the ceiling.
    MAX_ITERATIONS = 25

    # The wind-down call is deliberately short and cheap.
    WRAP_UP_OUTPUT_TOKENS = 400
    WRAP_UP_DIRECTIVE = <<~MSG.strip
      You have reached your action limit for this turn. Do not call any more tools.
      Briefly summarize what you accomplished, what is still unfinished, and the
      single next action you would take.
    MSG

    def initialize(context:, registry:, builder:, client:,
                   task_settings: nil, max_iterations: nil, max_output_tokens: nil)
      @context           = context
      @registry          = registry
      @builder           = builder
      @client            = client
      @max_iterations    = resolve_max_iterations(task_settings, max_iterations)
      @max_output_tokens = resolve_max_output_tokens(task_settings, max_output_tokens)
      @iteration         = 0
    end

    def run
      loop do
        # Limits are *trigger thresholds*, not hard caps: once we reach one we
        # stop starting new work iterations and make exactly one terminal
        # wind-down call instead of raising.
        return wrap_up("max_iterations") if iteration_limit_reached?

        @iteration += 1
        puts "[iteration #{@iteration}/#{@max_iterations}]"

        response = @client.call(**call_opts)
        parsed   = @builder.parse_response(response)

        if parsed[:stop_reason] == "tool_use"
          handle_tool_calls(parsed[:content])
        else
          return extract_text(parsed[:content])
        end
      end
    end

    private

    def resolve_max_iterations(task_settings, explicit)
      return explicit.to_i unless explicit.nil?
      return @context.task.max_iterations(task_settings) if task_settings && @context.task.respond_to?(:max_iterations)

      MAX_ITERATIONS
    end

    def resolve_max_output_tokens(task_settings, explicit)
      return explicit unless explicit.nil?
      return @context.task.max_output_tokens(task_settings) if task_settings && @context.task.respond_to?(:max_output_tokens)

      nil
    end

    def iteration_limit_reached?
      @max_iterations.positive? && @iteration >= @max_iterations
    end

    # Per-call options shared by every model round-trip of the turn.
    def call_opts
      @max_output_tokens ? { max_output_tokens: @max_output_tokens } : {}
    end

    # One final, tools-disabled model call so the agent ends the turn in
    # character rather than aborting. Runs *outside* the counted loop: it never
    # re-checks the limits (so it cannot re-trigger) and does not increment
    # @iteration. Falls back to a deterministic message if the call fails.
    def wrap_up(reason)
      @context.add_message(:user, WRAP_UP_DIRECTIVE)
      response = @client.call(tools: [], max_output_tokens: WRAP_UP_OUTPUT_TOKENS)
      text     = extract_text(@builder.parse_response(response)[:content])
      text.strip.empty? ? fallback_message(reason) : text
    rescue ApiError
      fallback_message(reason)
    end

    def fallback_message(reason)
      "I reached my #{@max_iterations}-action limit for this turn before finishing " \
      "(#{reason}). Ask me to continue and I'll pick up from here."
    end

    def extract_text(content)
      content.select { |b| b["type"] == "text" }.map { |b| b["text"] }.join
    end

    def handle_tool_calls(content)
      @context.add_message(:assistant, content)

      content.select { |b| b["type"] == "tool_use" }.each do |block|
        name   = block["name"]
        args   = block["input"]
        use_id = block["id"]

        puts "  tool call → #{name}(#{args})"
        result = @registry.dispatch(name, args)
        puts "  tool result → #{result.to_s[0..60]}"

        @context.add_message(:tool_result, result.to_s, tool_use_id: use_id)
      end
    end
  end # Agent
end
