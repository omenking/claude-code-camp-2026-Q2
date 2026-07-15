module Boukensha
  class PromptBuilder
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