require_relative "base"

module Boukensha
  module Backends
    class OllamaCloud < Base
      BASE_URL = "https://ollama.com"
      MODELS = {
        "gemma4:31b-cloud" => {
          context_window: 256_000,
          cost_per_million: { input: nil, output: nil },
          usage_unit: :ollama_cloud_usage,
          usage_level: :medium
        },
        "minimax-m3:cloud" => {
          context_window: 512_000,
          advertised_context_window: 1_000_000,
          cost_per_million: { input: nil, output: nil },
          usage_unit: :ollama_cloud_usage,
          usage_level: :high
        },
        "kimi-k2.5:cloud" => {
          context_window: 256_000,
          cost_per_million: { input: nil, output: nil },
          usage_unit: :ollama_cloud_usage,
          usage_level: :high
        }
      }.freeze

      def initialize(api_key:, model:)
        @api_key = api_key
        configure_model(model)
      end

      def to_messages(system, messages)
        system_message = [{ role: "system", content: system }]
        conversation   = messages.map do |msg|
          case msg.role
          when :tool_result
            { role: "tool", tool_name: msg.tool_use_id, content: msg.content }
          else
            { role: msg.role.to_s, content: msg.content }
          end
        end
        system_message + conversation
      end

      def to_tools(tools)
        tools.values.map do |tool|
          {
            type: "function",
            function: {
              name: tool.name,
              description: tool.description,
              parameters: {
                type: "object",
                properties: tool.parameters,
                required: tool.parameters.keys.map(&:to_s)
              }
            }
          }
        end
      end

      def to_payload(context, max_output_tokens: 1024)
        {
          model: @model,
          stream: false,
          messages: to_messages(context.system, context.messages),
          tools: to_tools(context.tools)
        }
      end

      def headers
        {
          "Content-Type"  => "application/json",
          "Authorization" => "Bearer #{@api_key}"
        }
      end

      def url
        "#{BASE_URL}/api/chat"
      end
    end
  end
end
