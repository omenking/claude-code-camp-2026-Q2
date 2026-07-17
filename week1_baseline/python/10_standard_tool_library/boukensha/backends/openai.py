import json

from .base import Base


class OpenAI(Base):
    BASE_URL = "https://api.openai.com/v1/chat/completions"
    MODELS = {
        "gpt-5.5": {
            "context_window": 1_000_000,
            "cost_per_million": {"input": 5.0, "output": 30.0},
            "usage_unit": "tokens",
        },
        "gpt-5.4": {
            "context_window": 1_000_000,
            "cost_per_million": {"input": 2.5, "output": 15.0},
            "usage_unit": "tokens",
        },
        "gpt-5.4-mini": {
            "context_window": 400_000,
            "cost_per_million": {"input": 0.75, "output": 4.5},
            "usage_unit": "tokens",
        },
    }

    def __init__(self, api_key, model):
        self.api_key = api_key
        self._configure_model(model)

    def to_messages(self, system, messages):
        system_message = [{"role": "system", "content": system}]
        conversation = []
        for msg in messages:
            if msg.role == "tool_result":
                conversation.append({"role": "tool", "tool_call_id": msg.tool_use_id, "content": msg.content})
            elif msg.role == "assistant":
                conversation.append(self._assistant_message(msg.content))
            else:
                conversation.append({"role": msg.role, "content": msg.content})
        return system_message + conversation

    def to_tools(self, tools):
        return [
            {
                "type": "function",
                "function": {
                    "name": tool.name,
                    "description": tool.description,
                    "parameters": {
                        "type": "object",
                        "properties": tool.parameters,
                        "required": list(tool.parameters.keys()),
                    },
                },
            }
            for tool in tools.values()
        ]

    def to_payload(self, context, max_output_tokens=1024, tools=None):
        return {
            "model": self.model,
            "messages": self.to_messages(context.system, context.messages),
            "tools": self.to_tools(context.tools) if tools is None else tools,
            "max_completion_tokens": max_output_tokens,
        }

    def headers(self):
        return {
            "Content-Type": "application/json",
            "Authorization": f"Bearer {self.api_key}",
        }

    def url(self):
        return self.BASE_URL

    def parse_response(self, response):
        choices = response.get("choices") or []
        message = (choices[0].get("message") or {}) if choices else {}
        tool_calls = message.get("tool_calls") or []
        content = []
        if message.get("content") is not None:
            content.append({"type": "text", "text": message["content"]})
        for tool_call in tool_calls:
            function = tool_call.get("function") or {}
            content.append({
                "type": "tool_use",
                "id": tool_call.get("id"),
                "name": function.get("name"),
                "input": json.loads(function.get("arguments") or "{}"),
            })
        return {"stop_reason": "tool_use" if tool_calls else "end_turn", "content": content}

    def _assistant_message(self, content):
        blocks = [{"type": "text", "text": content}] if isinstance(content, str) else content
        blocks = blocks or []
        message = {
            "role": "assistant",
            "content": "".join(block.get("text", "") for block in blocks if block.get("type") == "text"),
        }
        tool_blocks = [block for block in blocks if block.get("type") == "tool_use"]
        if tool_blocks:
            message["tool_calls"] = [
                {
                    "id": block.get("id"),
                    "type": "function",
                    "function": {
                        "name": block.get("name"),
                        "arguments": json.dumps(block.get("input") or {}),
                    },
                }
                for block in tool_blocks
            ]
        return message
