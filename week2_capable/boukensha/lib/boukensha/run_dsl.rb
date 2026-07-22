module Boukensha
  # RunDSL is the object that `self` becomes inside a Boukensha.run block.
  # It exposes only `tool`, keeping the DSL surface intentionally small.
  class RunDSL
    def initialize(registry)
      @registry = registry
    end

    def tool(name, description:, parameters: {}, &block)
      @registry.tool(name, description: description, parameters: parameters, &block)
    end

    def tool_names
      @registry.tool_names
    end

    # Invoke an already-registered tool by name (including MCP tools such as
    # `tbamud__inspect_room`) and return its result. This is what lets a
    # native tool defined in a run/repl block compose over the tools the MCP
    # servers contributed — the seam the player's `inspect_room` uses to reach
    # the daemon survey before delegating the parse to a subagent.
    def call_tool(name, **args)
      @registry.dispatch(name.to_s, args)
    end
  end
end
