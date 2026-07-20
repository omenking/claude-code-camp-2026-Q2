require "json"
require_relative "base"

module Boukensha
  module Backends
    # https://platform.openai.com/docs/api-reference/responses
    #
    # gpt-5.x rejects `reasoning_effort` + tools on /v1/chat/completions ("Please
    # use /v1/responses"), so this backend targets the Responses API instead of
    # chat completions. That changes more than the URL: messages become `input`
    # items, the system prompt becomes a top-level `instructions` string, tool
    # defs are flat (no `function:` wrapper), and tool results round-trip via
    # `function_call_output` items matched by `call_id` rather than a
    # `{role: "tool"}` message.
    class OpenAI < Base
      BASE_URL = "https://api.openai.com/v1/responses"
      MODELS = {
        "gpt-5.5" => {
          context_window: 1_000_000,
          cost_per_million: { input: 5.0, output: 30.0 },
          usage_unit: :tokens
        },
        "gpt-5.4-mini" => {
          context_window: 400_000,
          cost_per_million: { input: 0.75, output: 4.5 },
          usage_unit: :tokens
        },
        "gpt-5.4-nano" => {
          context_window: 400_000,
          cost_per_million: { input: 0.2, output: 1.25 },
          usage_unit: :tokens
        }
      }.freeze

      def initialize(api_key:, model:)
        @api_key = api_key
        configure_model(model)
      end

      def to_input(messages)
        messages.flat_map do |msg|
          case msg.role
          when :tool_result
            [{ type: "function_call_output", call_id: msg.tool_use_id, output: msg.content.to_s }]
          when :assistant
            assistant_items(msg.content)
          else
            [{ role: msg.role.to_s, content: msg.content }]
          end
        end
      end

      def to_tools(tools)
        tools.values.map do |tool|
          {
            type: "function",
            name: tool.name,
            description: tool.description,
            parameters: {
              type: "object",
              properties: tool.parameters,
              required: tool.parameters.keys.map(&:to_s)
            }
          }
        end
      end

      def to_payload(context, max_output_tokens: 1024, tools: nil)
        {
          model: @model,
          instructions: context.system,
          input: to_input(context.messages),
          tools: tools.nil? ? to_tools(context.tools) : tools,
          max_output_tokens: max_output_tokens,
          reasoning: { effort: "none" }
        }
      end

      def headers
        {
          "Content-Type"  => "application/json",
          "Authorization" => "Bearer #{@api_key}"
        }
      end

      def url
        BASE_URL
      end

      # Normalizes a Responses API `output[]` array into the common shape:
      #   { stop_reason: "tool_use" | "end_turn", content: [ {"type"=>...} ] }
      def parse_response(response)
        function_calls = []
        content = (response["output"] || []).filter_map do |item|
          case item["type"]
          when "reasoning"
            text = (item["summary"] || []).map { |s| s["text"] }.join
            { "type" => "reasoning", "text" => text }
          when "message"
            text = (item["content"] || []).select { |c| c["type"] == "output_text" }.map { |c| c["text"] }.join
            { "type" => "text", "text" => text } unless text.empty?
          when "function_call"
            function_calls << item
            nil
          end
        end

        function_calls.each do |fc|
          content << {
            "type"  => "tool_use",
            "id"    => fc["call_id"],
            "name"  => fc["name"],
            "input" => JSON.parse(fc["arguments"] || "{}")
          }
        end

        { stop_reason: function_calls.empty? ? "end_turn" : "tool_use", content: content }
      end

      private

      # Rebuilds Responses input items from normalized content blocks (the
      # inverse of parse_response). Reasoning blocks are dropped — gpt-5.x
      # doesn't need them echoed back when reasoning effort is "none".
      def assistant_items(content)
        blocks = content.is_a?(String) ? [{ "type" => "text", "text" => content }] : content

        text = blocks.select { |b| b["type"] == "text" }.map { |b| b["text"] }.join
        items = text.empty? ? [] : [{ role: "assistant", content: text }]

        blocks.select { |b| b["type"] == "tool_use" }.each do |b|
          items << {
            type: "function_call",
            call_id: b["id"],
            name: b["name"],
            arguments: b["input"].to_json
          }
        end
        items
      end
    end
  end
end
