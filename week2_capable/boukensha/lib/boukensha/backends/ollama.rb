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
          when :assistant
            assistant_message(msg.content)
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

      def to_payload(context, max_output_tokens: 1024, tools: nil)
        {
          model: @model,
          stream: false,
          messages: to_messages(context.system, context.messages),
          tools: tools.nil? ? to_tools(context.tools) : tools,
          think: false
        }
      end

      def headers
        { "Content-Type" => "application/json" }
      end

      def url
        "#{@host}/api/chat"
      end

      # Normalizes an Ollama /api/chat response into the common shape:
      #   { stop_reason: "tool_use" | "end_turn", content: [ {"type"=>"text", "text"=>...} | {"type"=>"tool_use", "id"=>, "name"=>, "input"=>} ] }
      #
      # Ollama doesn't assign call ids, so the function name is reused as the
      # id (Ollama also matches tool results back to a call by name).
      def parse_response(response)
        message    = response["message"] || {}
        tool_calls = message["tool_calls"] || []

        content = []
        content << { "type" => "reasoning", "text" => message["thinking"] } if message["thinking"] && !message["thinking"].empty?
        content << { "type" => "text", "text" => message["content"] } if message["content"] && !message["content"].empty?

        tool_calls.each do |tc|
          fn = tc["function"] || {}
          content << { "type" => "tool_use", "id" => fn["name"], "name" => fn["name"], "input" => fn["arguments"] || {} }
        end

        { stop_reason: tool_calls.empty? ? "end_turn" : "tool_use", content: content }
      end

      private

      # Rebuilds an Ollama assistant message from normalized content blocks
      # (the inverse of parse_response). Text-only turns are stored as a bare
      # String, so wrap it back into a single text block before filtering.
      def assistant_message(content)
        blocks = content.is_a?(String) ? [{ "type" => "text", "text" => content }] : content

        text_blocks = blocks.select { |b| b["type"] == "text" }
        tool_blocks = blocks.select { |b| b["type"] == "tool_use" }

        message = { role: "assistant", content: text_blocks.map { |b| b["text"] }.join }
        unless tool_blocks.empty?
          message[:tool_calls] = tool_blocks.map do |b|
            { function: { name: b["name"], arguments: b["input"] } }
          end
        end
        message
      end
    end
  end
end