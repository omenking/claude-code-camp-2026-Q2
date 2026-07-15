from .errors import UnknownToolError
from .tool import Tool


class Registry:
    def __init__(self, context):
        self.context = context

    def tool(self, name, description, parameters=None):
        def decorator(block):
            registered = Tool(str(name), description, parameters or {}, block)
            self.context.register_tool(registered)
            return block
        return decorator

    def dispatch(self, name, args=None):
        tool = self.context.tools.get(str(name))
        if tool is None:
            raise UnknownToolError(f"No tool registered as '{name}'")
        # Python dicts are already string-keyed, so no symbol/string key
        # translation is needed before calling the block as kwargs.
        return tool.block(**(args or {}))
