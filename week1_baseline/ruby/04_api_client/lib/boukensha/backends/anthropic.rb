require_relative "base"

module Boukensha
  module Backends
    class Anthropic < Base
      BASE_URL = "https://api.anthropic.com/v1/messages"
      MODELS = {
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
        "claude-sonnet-4-6" => {
          context_window: 1_000_000,
          cost_per_million: { input: 3.0, output: 15.0 },
          usage_unit: :tokens
        },
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

      def to_payload(context, max_output_tokens: 1024)
        {
          model: @model,
          system: context.system,
          max_tokens: max_output_tokens,
          tools: to_tools(context.tools),
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
    end
  end
end
