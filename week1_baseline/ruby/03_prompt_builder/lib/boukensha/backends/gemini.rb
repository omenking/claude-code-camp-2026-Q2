require_relative "base"

module Boukensha
  module Backends
    class Gemini < Base
      BASE_URL = "https://generativelanguage.googleapis.com/v1beta/models"
      MODELS = {
        "gemini-3.5-flash" => {
          context_window: 1_048_576,
          cost_per_million: { input: 1.5, output: 9.0 },
          usage_unit: :tokens
        },
        "gemini-3.1-flash-lite" => {
          context_window: 1_048_576,
          cost_per_million: { input: 0.25, output: 1.5 },
          usage_unit: :tokens
        },
        "gemini-2.5-pro" => {
          context_window: 1_048_576,
          cost_per_million: { input: 1.25, output: 10.0 },
          usage_unit: :tokens
        },
        "gemini-2.5-flash" => {
          context_window: 1_048_576,
          cost_per_million: { input: 0.30, output: 2.50 },
          usage_unit: :tokens
        },
        "gemini-2.5-flash-lite" => {
          context_window: 1_048_576,
          cost_per_million: { input: 0.10, output: 0.40 },
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
          when :assistant
            { role: "model", parts: [{ text: msg.content }] }
          when :tool_result
            {
              role: "user",
              parts: [{
                functionResponse: {
                  name: msg.tool_use_id,
                  response: { content: msg.content }
                }
              }]
            }
          else
            { role: msg.role.to_s, parts: [{ text: msg.content }] }
          end
        end
      end

      def to_tools(tools)
        return [] if tools.empty?

        [{
          functionDeclarations: tools.values.map do |tool|
            {
              name: tool.name,
              description: tool.description,
              parameters: {
                type: "object",
                properties: tool.parameters,
                required: tool.parameters.keys.map(&:to_s)
              }
            }
          end
        }]
      end

      def to_payload(context, max_output_tokens: 1024)
        {
          systemInstruction: { parts: [{ text: context.system }] },
          contents: to_messages(context.messages),
          tools: to_tools(context.tools),
          generationConfig: { maxOutputTokens: max_output_tokens }
        }
      end

      def headers
        {
          "Content-Type"   => "application/json",
          "x-goog-api-key" => @api_key
        }
      end

      def url
        "#{BASE_URL}/#{@model}:generateContent"
      end
    end
  end
end
