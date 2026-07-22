require_relative "errors"
require_relative "permissions"

module Boukensha
  # The single enforcement point for a task's `allow:` rules. Every tool
  # reaches the registry through #tool, whether it came from an MCP server
  # (Tools::Mcp.register_client) or was defined natively in a run/repl block
  # (RunDSL#tool) — so both paths get the same name-level (#tool) and
  # value-level (#dispatch) gate for free. `permissions:` defaults to a
  # permissive Permissions (no restriction), matching the standalone/test path
  # that never had gating to begin with.
  class Registry
    def initialize(context, permissions: Permissions.new(nil))
      @context     = context
      @permissions = permissions
    end

    def tool(name, description:, parameters: {}, &block)
      return nil unless @permissions.allow_tool?(name)
      tool = Tool.new(name.to_s, description, parameters, block)
      @context.register_tool(tool)
      tool
    end

    def tool_names
      @context.tools.keys
    end

    def dispatch(name, args = {})
      tool = @context.tools[name.to_s]
      raise UnknownToolError, "No tool registered as '#{name}'" unless tool
      raise UnauthorizedToolError, "#{name} is not permitted with #{args.inspect}" \
        unless @permissions.call_permitted?(name, args)
      tool.block.call(**args.transform_keys(&:to_sym))
    end
  end
end