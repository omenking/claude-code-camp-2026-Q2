import math
import os

from .message import Message
from .tool import Tool


class Context:
    def __init__(self, system=None, context_window=200_000, working_dir=None, compaction_threshold=0.85):
        self.system = system
        self.context_window = context_window
        self.working_dir = (
            os.path.expanduser(os.path.abspath(working_dir)) if working_dir else None
        )
        self.compaction_threshold = compaction_threshold
        self.messages = []
        self.tools = {}
        self.current_tokens = 0
        self.turn_tokens = 0

    def register_tool(self, tool: Tool):
        self.tools[tool.name] = tool

    def add_message(self, role, content, tool_use_id=None):
        self.messages.append(Message(role, content, tool_use_id))

    def clear_messages(self):
        """Clear conversation history while preserving tools and list identity."""
        self.messages.clear()
        self.current_tokens = 0

    def update_tokens(self, n):
        self.current_tokens = int(n or 0)

    def reset_turn_tokens(self):
        self.turn_tokens = 0

    def add_turn_tokens(self, input_tokens, output_tokens):
        self.turn_tokens += int(input_tokens or 0) + int(output_tokens or 0)

    @property
    def usage_fraction(self):
        return self.current_tokens / self.context_window if self.context_window > 0 else 0.0

    @property
    def usage_pct(self):
        return round(self.usage_fraction * 100)

    def needs_compaction(self, threshold=None):
        threshold = self.compaction_threshold if threshold is None else threshold
        return self.usage_fraction >= threshold

    def compact_messages(self, target_fraction=0.60):
        drop_count = min(math.ceil(len(self.messages) * 0.40), len(self.messages) - 2)
        drop_count = max(drop_count, 0)
        self.messages = self.messages[drop_count:]
        self.current_tokens = 0
        return drop_count

    @property
    def tool_count(self):
        return len(self.tools)

    @property
    def turn_count(self):
        return len(self.messages)

    def __str__(self):
        return (
            f"#<Context turns={self.turn_count} tools={self.tool_count} "
            f"window={self.context_window} current={self.current_tokens}>"
        )

    __repr__ = __str__
