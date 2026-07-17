import json

from .base import Base


class OpenAI(Base):
    # gpt-5.x rejects `reasoning_effort` + tools on /v1/chat/completions ("Please
    # use /v1/responses"), so this backend targets the Responses API instead of
    # chat completions. That changes more than the URL: messages become `input`
    # items, the system prompt becomes a top-level `instructions` string, tool
    # defs are flat (no `function:` wrapper), and tool results round-trip via
    # `function_call_output` items matched by `call_id` rather than a
    # `{role: "tool"}` message.
    BASE_URL = "https://api.openai.com/v1/responses"
    MODELS = {
        "gpt-5.5": {
            "context_window": 1_000_000,
            "cost_per_million": {"input": 5.0, "output": 30.0},
            "usage_unit": "tokens",
        },
        "gpt-5.4-mini": {
            "context_window": 400_000,
            "cost_per_million": {"input": 0.75, "output": 4.5},
            "usage_unit": "tokens",
        },
        "gpt-5.4-nano": {
            "context_window": 400_000,
            "cost_per_million": {"input": 0.2, "output": 1.25},
            "usage_unit": "tokens",
        },
    }

    def __init__(self, api_key, model):
        self.api_key = api_key
        self._configure_model(model)

    def to_input(self, messages):
        result = []
        for msg in messages:
            if msg.role == "tool_result":
                result.append({
                    "type": "function_call_output",
                    "call_id": msg.tool_use_id,
                    "output": str(msg.content),
                })
            elif msg.role == "assistant":
                result.extend(self._assistant_items(msg.content))
            else:
                result.append({"role": msg.role, "content": msg.content})
        return result

    def to_tools(self, tools):
        return [
            {
                "type": "function",
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

    def to_payload(self, context, max_output_tokens=1024, tools=None):
        return {
            "model": self.model,
            "instructions": context.system,
            "input": self.to_input(context.messages),
            "tools": self.to_tools(context.tools) if tools is None else tools,
            "max_output_tokens": max_output_tokens,
            "reasoning": {"effort": "none"},
        }

    def headers(self):
        return {
            "Content-Type": "application/json",
            "Authorization": f"Bearer {self.api_key}",
        }

    def url(self):
        return self.BASE_URL

    def parse_response(self, response):
        function_calls = []
        content = []
        for item in response.get("output") or []:
            item_type = item.get("type")
            if item_type == "reasoning":
                text = "".join(s.get("text", "") for s in (item.get("summary") or []))
                content.append({"type": "reasoning", "text": text})
            elif item_type == "message":
                text = "".join(
                    c.get("text", "") for c in (item.get("content") or [])
                    if c.get("type") == "output_text"
                )
                if text:
                    content.append({"type": "text", "text": text})
            elif item_type == "function_call":
                function_calls.append(item)

        for function_call in function_calls:
            content.append({
                "type": "tool_use",
                "id": function_call.get("call_id"),
                "name": function_call.get("name"),
                "input": json.loads(function_call.get("arguments") or "{}"),
            })

        return {
            "stop_reason": "tool_use" if function_calls else "end_turn",
            "content": content,
        }

    def _assistant_items(self, content):
        blocks = [{"type": "text", "text": content}] if isinstance(content, str) else content
        blocks = blocks or []

        text = "".join(block.get("text", "") for block in blocks if block.get("type") == "text")
        items = [] if not text else [{"role": "assistant", "content": text}]

        for block in blocks:
            if block.get("type") != "tool_use":
                continue
            items.append({
                "type": "function_call",
                "call_id": block.get("id"),
                "name": block.get("name"),
                "arguments": json.dumps(block.get("input") or {}),
            })
        return items
