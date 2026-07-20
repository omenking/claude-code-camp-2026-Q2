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
        },
        # It has
        #"gemini-3.1-pro-preview-customtools" => {
        #  context_window: 1_048_576,
        #  cost_per_million: { input: 2.0, output: 12.0 },
        #  usage_unit: :tokens
        #}
      }.freeze

      def initialize(api_key:, model:)
        @api_key = api_key
        configure_model(model)
      end

      def to_messages(messages)
        messages.map do |msg|
          case msg.role
          when :assistant
            { role: "model", parts: assistant_parts(msg.content) }
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

      def to_payload(context, max_output_tokens: 1024, tools: nil)
        {
          systemInstruction: { parts: [{ text: context.system }] },
          contents: to_messages(context.messages),
          tools: tools.nil? ? to_tools(context.tools) : tools,
          generationConfig: {
            maxOutputTokens: max_output_tokens,
            thinkingConfig: thinking_config
          }
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

      # Normalizes a Gemini generateContent response into the common shape:
      #   { stop_reason: "tool_use" | "end_turn", content: [ {"type"=>"text", "text"=>...} | {"type"=>"tool_use", "id"=>, "name"=>, "input"=>} ] }
      #
      # Gemini doesn't assign call ids, so the function name is reused as the
      # id (Gemini also matches functionResponse back to a call by name).
      def parse_response(response)
        parts = response.dig("candidates", 0, "content", "parts") || []

        content   = []
        tool_used = false

        parts.each do |part|
          if part["functionCall"]
            fc = part["functionCall"]
            content << { "type" => "tool_use", "id" => fc["name"], "name" => fc["name"], "input" => fc["args"] || {}, "signature" => part["thoughtSignature"] }
            tool_used = true
          elsif part["thought"]
            content << { "type" => "reasoning", "text" => part["text"].to_s, "signature" => part["thoughtSignature"] }
          elsif part["text"]
            content << { "type" => "text", "text" => part["text"] }
          end
        end

        { stop_reason: tool_used ? "tool_use" : "end_turn", content: content }
      end

      private

      def thinking_config
        case @model
        when "gemini-3.1-pro-preview-customtools"
          { thinkingLevel: "LOW" }   # full disable not supported on this model
        else
          { thinkingBudget: 0 }      # gemini-3.5-flash, gemini-3.1-flash-lite
        end
      end

      # Rebuilds Gemini "model" parts from normalized content blocks
      # (the inverse of parse_response). Text-only turns are stored as a bare
      # String, so wrap it back into a single text block before mapping.
      def assistant_parts(content)
        blocks = content.is_a?(String) ? [{ "type" => "text", "text" => content }] : content

        blocks.map do |b|
          case b["type"]
          when "tool_use"
            part = { functionCall: { name: b["name"], args: b["input"] } }
            part[:thoughtSignature] = b["signature"] if b["signature"]
            part
          when "reasoning"
            part = { text: b["text"].to_s, thought: true }
            part[:thoughtSignature] = b["signature"] if b["signature"]
            part
          else
            { text: b["text"] }
          end
        end
      end
    end
  end
end
