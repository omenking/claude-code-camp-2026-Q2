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

    def to_api_payload(max_output_tokens: 1024)
      @backend.to_payload(@context, max_output_tokens: max_output_tokens)
    end

    def headers
      @backend.headers
    end

    def url
      @backend.url
    end
  end
end