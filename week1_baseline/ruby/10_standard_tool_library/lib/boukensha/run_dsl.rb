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
  end
end
