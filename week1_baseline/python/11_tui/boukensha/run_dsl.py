class RunDSL:
    """The deliberately small tool-registration surface used by ``run``."""

    def __init__(self, registry):
        self._registry = registry

    def tool(self, name, description, parameters=None):
        return self._registry.tool(
            name, description=description, parameters=parameters
        )

    def tool_names(self):
        return self._registry.tool_names()
