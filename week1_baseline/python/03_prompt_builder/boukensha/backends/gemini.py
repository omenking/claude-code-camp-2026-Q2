from .base import Base


class Gemini(Base):
    BASE_URL = "https://generativelanguage.googleapis.com/v1beta/models"
    MODELS = {
        "gemini-3.5-flash": {
            "context_window": 1_048_576,
            "cost_per_million": {"input": 1.5, "output": 9.0},
            "usage_unit": "tokens",
        },
        "gemini-3.1-flash-lite": {
            "context_window": 1_048_576,
            "cost_per_million": {"input": 0.25, "output": 1.5},
            "usage_unit": "tokens",
        },
        "gemini-2.5-pro": {
            "context_window": 1_048_576,
            "cost_per_million": {"input": 1.25, "output": 10.0},
            "usage_unit": "tokens",
        },
        "gemini-2.5-flash": {
            "context_window": 1_048_576,
            "cost_per_million": {"input": 0.30, "output": 2.50},
            "usage_unit": "tokens",
        },
        "gemini-2.5-flash-lite": {
            "context_window": 1_048_576,
            "cost_per_million": {"input": 0.10, "output": 0.40},
            "usage_unit": "tokens",
        },
    }

    def __init__(self, api_key, model):
        self.api_key = api_key
        self._configure_model(model)

    def to_messages(self, messages):
        result = []
        for msg in messages:
            if msg.role == "assistant":
                result.append({"role": "model", "parts": [{"text": msg.content}]})
            elif msg.role == "tool_result":
                result.append({
                    "role": "user",
                    "parts": [{
                        "functionResponse": {
                            "name": msg.tool_use_id,
                            "response": {"content": msg.content},
                        }
                    }],
                })
            else:
                result.append({"role": msg.role, "parts": [{"text": msg.content}]})
        return result

    def to_tools(self, tools):
        if not tools:
            return []

        return [{
            "functionDeclarations": [
                {
                    "name": tool.name,
                    "description": tool.description,
                    "parameters": {
                        "type": "object",
                        "properties": tool.parameters,
                        "required": list(tool.parameters.keys()),
                    },
                }
                for tool in tools.values()
            ]
        }]

    def to_payload(self, context, max_output_tokens=1024):
        return {
            "systemInstruction": {"parts": [{"text": context.system}]},
            "contents": self.to_messages(context.messages),
            "tools": self.to_tools(context.tools),
            "generationConfig": {"maxOutputTokens": max_output_tokens},
        }

    def headers(self):
        return {
            "Content-Type": "application/json",
            "x-goog-api-key": self.api_key,
        }

    def url(self):
        return f"{self.BASE_URL}/{self.model}:generateContent"
