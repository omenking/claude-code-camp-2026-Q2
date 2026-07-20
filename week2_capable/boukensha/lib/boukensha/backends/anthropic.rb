require_relative "base"

# https://platform.claude.com/docs/en/api/beta/messages/create
module Boukensha
  module Backends
    class Anthropic < Base
      BASE_URL = "https://api.anthropic.com/v1/messages"
      MODELS = {
        # thinking, but not adapative must set budget_tokens
        # does not support effort flag
        "claude-haiku-4-5" => {
          context_window: 200_000,
          cost_per_million: { input: 1.0, output: 5.0 },
          usage_unit: :tokens
        },
        "claude-haiku-4-5-20251001" => {
          context_window: 200_000,
          cost_per_million: { input: 1.0, output: 5.0 },
          usage_unit: :tokens
        },
        # supports adapative thinking and effort flag
        # non-adpative thinking is deprecated for sonnet 
        "claude-sonnet-4-6" => {
          context_window: 1_000_000,
          cost_per_million: { input: 3.0, output: 15.0 },
          usage_unit: :tokens
        },
        # supports adapative thinking and effort flag
        # non-adaptive thinking is deprecated for opus
        "claude-opus-4-8" => {
          context_window: 1_000_000,
          cost_per_million: { input: 5.0, output: 25.0 },
          usage_unit: :tokens
        }
      }.freeze

      def initialize(api_key:, model:)
        @api_key = api_key
        configure_model(model)
      end

      def to_messages(messages)
        messages.map do |msg|
          case msg.role
          when :tool_result
            {
              role: "user",
              content: [{
                type: "tool_result",
                tool_use_id: msg.tool_use_id,
                content: msg.content
              }]
            }
          when :assistant
            { role: "assistant", content: assistant_content(msg.content) }
          else
            { role: msg.role.to_s, content: msg.content }
          end
        end
      end

      def to_tools(tools)
        tools.values.map do |tool|
          {
            name: tool.name,
            description: tool.description,
            input_schema: {
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
          system: context.system,
          max_tokens: max_output_tokens,
          tools: tools.nil? ? to_tools(context.tools) : tools,
          messages: to_messages(context.messages)
        }
      end

      def headers
        {
          "Content-Type"      => "application/json",
          "x-api-key"         => @api_key,
          "anthropic-version" => "2023-06-01"
        }
      end

      def url
        BASE_URL
      end

      # Normalizes an Anthropic Messages API response into the common shape
      # (see Backends::Base for the full content-block contract). Anthropic's
      # native thinking/redacted_thinking blocks are mapped to "reasoning"
      # blocks, preserving the signature so they can be echoed back unchanged
      # (the API rejects modified thinking blocks when continuing on the same
      # model).
      def parse_response(response)
        stop_reason = response["stop_reason"] == "tool_use" ? "tool_use" : "end_turn"
        content     = (response["content"] || []).map { |block| normalize_block(block) }
        { stop_reason: stop_reason, content: content }
      end

      private

      def normalize_block(block)
        case block["type"]
        when "thinking"
          { "type" => "reasoning", "text" => block["thinking"].to_s, "signature" => block["signature"] }
        when "redacted_thinking"
          { "type" => "reasoning", "text" => "", "redacted" => true, "signature" => block["data"] }
        else
          block
        end
      end

      # Rebuilds Anthropic assistant content from normalized blocks (the inverse
      # of parse_response). Text-only turns are stored as a bare String and pass
      # through unchanged; "reasoning" blocks are re-emitted as native
      # thinking/redacted_thinking blocks so signatures round-trip intact.
      def assistant_content(content)
        return content if content.is_a?(String)

        content.map { |block| denormalize_block(block) }
      end

      def denormalize_block(block)
        return block unless block["type"] == "reasoning"

        if block["redacted"]
          { "type" => "redacted_thinking", "data" => block["signature"] }
        else
          { "type" => "thinking", "thinking" => block["text"].to_s, "signature" => block["signature"] }
        end
      end
    end
  end
end