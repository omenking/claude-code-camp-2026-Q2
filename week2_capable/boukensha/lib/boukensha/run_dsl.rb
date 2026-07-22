module Boukensha
  # RunDSL is the object that `self` becomes inside a Boukensha.run block.
  # It exposes `tool` plus the run's `logger`, keeping the DSL surface
  # intentionally small.
  class RunDSL
    # The run's session logger. A native tool that delegates to a subagent
    # passes this to Boukensha.run_task so the sub-run writes into THIS session
    # file instead of minting its own (plan Amendment A). Handed over
    # explicitly rather than read from an ambient thread-local, so the
    # delegation graph stays readable and a test can inject a fake.
    attr_reader :logger

    def initialize(registry, logger: nil)
      @registry = registry
      @logger   = logger
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
