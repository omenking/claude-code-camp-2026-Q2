require_relative "base"

module Boukensha
  module Backends
    class Ollama < Base
      MODELS = {
        "gemma4" => {
          context_window: 128_000,
          cost_per_million: { input: 0.0, output: 0.0 },
          usage_unit: :local_compute
        },
        "gemma4:e2b" => {
          context_window: 128_000,
          cost_per_million: { input: 0.0, output: 0.0 },
          usage_unit: :local_compute
        },
        "gemma4:e4b" => {
          context_window: 128_000,
          cost_per_million: { input: 0.0, output: 0.0 },
          usage_unit: :local_compute
        },
        "gemma4:12b" => {
          context_window: 256_000,
          cost_per_million: { input: 0.0, output: 0.0 },
          usage_unit: :local_compute
        },
        "gemma4:26b" => {
          context_window: 256_000,
          cost_per_million: { input: 0.0, output: 0.0 },
          usage_unit: :local_compute
        },
        "gemma4:31b" => {
          context_window: 256_000,
          cost_per_million: { input: 0.0, output: 0.0 },
          usage_unit: :local_compute
        },
        "qwen3:30b" => {
          context_window: 256_000,
          cost_per_million: { input: 0.0, output: 0.0 },
          usage_unit: :local_compute
        },
        "qwen3:8b" => {
          context_window: 40_000,
          cost_per_million: { input: 0.0, output: 0.0 },
          usage_unit: :local_compute
        },
        "deepseek-r1:8b" => {
          context_window: 128_000,
          cost_per_million: { input: 0.0, output: 0.0 },
          usage_unit: :local_compute
        }
      }.freeze

      def initialize(host: "http://localhost:11434", model:)
        @host  = host
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
        { "Content-Type" => "application/json" }
      end

      def url
        "#{@host}/api/chat"
      end
    end
  end
end
