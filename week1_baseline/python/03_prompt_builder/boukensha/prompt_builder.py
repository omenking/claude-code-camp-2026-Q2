class PromptBuilder:
    def __init__(self, context, backend):
        self.context = context
        self.backend = backend

    def to_messages(self):
        return self.backend.to_messages(self.context.messages)

    def to_tools(self):
        return self.backend.to_tools(self.context.tools)

    def to_api_payload(self, max_output_tokens=1024):
        return self.backend.to_payload(self.context, max_output_tokens=max_output_tokens)

    def headers(self):
        return self.backend.headers()

    def url(self):
        return self.backend.url()
