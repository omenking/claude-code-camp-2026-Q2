from dataclasses import dataclass


@dataclass
class Message:
    role: str
    content: str
    tool_use_id: str | None = None

    def __str__(self):
        id_tag = f" [{self.tool_use_id}]" if self.tool_use_id else ""
        return f"#<Message role={self.role}{id_tag} content={str(self.content)[:61]}...>"

    __repr__ = __str__
