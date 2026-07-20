module Boukensha
  class PromptBuilder
    attr_reader :backend

    def initialize(context, backend)
      @context = context
      @backend = backend
    end

    def to_messages
      @backend.to_messages(@context.messages)
    end

    def to_tools
      @backend.to_tools(@context.tools)
    end

    def to_api_payload(max_output_tokens: 1024, tools: nil)
      @backend.to_payload(@context, max_output_tokens: max_output_tokens, tools: tools)
    end

    # Delegates to the backend, which normalizes a provider response into the
    # common shape documented in Backends::Base:
    #   { stop_reason: "tool_use" | "end_turn",
    #     content: [ {"type"=>"reasoning",...} | {"type"=>"text",...} | {"type"=>"tool_use",...} ] }
    def parse_response(response)
      @backend.parse_response(response)
    end

    def headers
      @backend.headers
    end

    def url
      @backend.url
    end
  end
end