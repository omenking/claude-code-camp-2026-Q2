from .base import Base


class Anthropic(Base):
    BASE_URL = "https://api.anthropic.com/v1/messages"
    MODELS = {
        "claude-haiku-4-5": {
            "context_window": 200_000,
            "cost_per_million": {"input": 1.0, "output": 5.0},
            "usage_unit": "tokens",
        },
        "claude-haiku-4-5-20251001": {
            "context_window": 200_000,
            "cost_per_million": {"input": 1.0, "output": 5.0},
            "usage_unit": "tokens",
        },
        "claude-sonnet-4-6": {
            "context_window": 1_000_000,
            "cost_per_million": {"input": 3.0, "output": 15.0},
            "usage_unit": "tokens",
        },
        "claude-opus-4-8": {
            "context_window": 1_000_000,
            "cost_per_million": {"input": 5.0, "output": 25.0},
            "usage_unit": "tokens",
        },
    }

    def __init__(self, api_key, model):
        self.api_key = api_key
        self._configure_model(model)

    def to_messages(self, messages):
        result = []
        for msg in messages:
            if msg.role == "tool_result":
                result.append({
                    "role": "user",
                    "content": [{
                        "type": "tool_result",
                        "tool_use_id": msg.tool_use_id,
                        "content": msg.content,
                    }],
                })
            elif msg.role == "assistant":
                result.append({"role": "assistant", "content": self._assistant_content(msg.content)})
            else:
                result.append({"role": msg.role, "content": msg.content})
        return result

    def to_tools(self, tools):
        return [
            {
                "name": tool.name,
                "description": tool.description,
                "input_schema": {
                    "type": "object",
                    "properties": tool.parameters,
                    "required": list(tool.parameters.keys()),
                },
            }
            for tool in tools.values()
        ]

    def to_payload(self, context, max_output_tokens=1024, tools=None):
        return {
            "model": self.model,
            "system": context.system,
            "max_tokens": max_output_tokens,
            "tools": self.to_tools(context.tools) if tools is None else tools,
            "messages": self.to_messages(context.messages),
        }

    def headers(self):
        return {
            "Content-Type": "application/json",
            "x-api-key": self.api_key,
            "anthropic-version": "2023-06-01",
        }

    def url(self):
        return self.BASE_URL

    def parse_response(self, response):
        return {
            "stop_reason": (
                "tool_use" if response.get("stop_reason") == "tool_use" else "end_turn"
            ),
            "content": [self._normalize_block(block) for block in (response.get("content") or [])],
        }

    def _normalize_block(self, block):
        if block.get("type") == "thinking":
            return {
                "type": "reasoning", "text": str(block.get("thinking") or ""),
                "signature": block.get("signature"),
            }
        if block.get("type") == "redacted_thinking":
            return {
                "type": "reasoning", "text": "", "redacted": True,
                "signature": block.get("data"),
            }
        return block

    def _assistant_content(self, content):
        if isinstance(content, str):
            return content
        return [self._denormalize_block(block) for block in content]

    def _denormalize_block(self, block):
        if block.get("type") != "reasoning":
            return block
        if block.get("redacted"):
            return {"type": "redacted_thinking", "data": block.get("signature")}
        return {
            "type": "thinking", "thinking": str(block.get("text") or ""),
            "signature": block.get("signature"),
        }
