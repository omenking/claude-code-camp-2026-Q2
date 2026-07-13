from dataclasses import dataclass
from typing import Any, Callable


@dataclass
class Tool:
    name: str
    description: str
    parameters: dict
    block: Callable[..., Any] | None = None

    def __str__(self):
        return (
            f"#<Tool name={self.name} "
            f"description={str(self.description)[:43]} "
            f"params={list(self.parameters.keys())}>"
        )

    __repr__ = __str__
