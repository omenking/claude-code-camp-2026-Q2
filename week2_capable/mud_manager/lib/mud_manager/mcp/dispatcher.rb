require_relative "tool_spec"
require_relative "session_pool"
require_relative "errors"
require_relative "../primitives"

module MudManager
  module Mcp
    # Dispatcher is the seam between "a named tool with arguments" and "text
    # sent to / read from a session". It is transport-agnostic: both the MCP
    # facade and the raw JSON-line protocol call #call and get back a plain
    # String (or a ProtocolError is raised, carrying a structured code).
    #
    # This is exactly the work Boukensha::Tools::Mud's `send_cmd` lambda used to
    # do — drain → send → read — lifted out of the framework so every language
    # track inherits it for free. Ruby included: that module has since been
    # deleted, and boukensha drives this daemon over MCP like everyone else.
    class Dispatcher
      def initialize(pool)
        @pool = pool
      end

      # name: tool name String; args: Hash with String keys; id: session id.
      # Returns the response text. Raises ProtocolError on any failure.
      def call(name, args = {}, id: "default")
        tool = ToolSpec.find(name)
        raise ProtocolError.new("unknown_tool", "no such tool: #{name}") unless tool

        args ||= {}

        case tool[:mode]
        when :primitive
          command =
            begin
              tool[:build].call(args)
            rescue ArgumentError => e
              # Primitives raises ArgumentError for bad enums / missing required.
              raise ProtocolError.new("argument_error", e.message)
            end
          @pool.run_command(id, command)
        when :raw
          raw = args["command"].to_s
          raise ProtocolError.new("argument_error", "command is required") if raw.strip.empty?
          @pool.run_raw(id, raw)
        when :poll
          @pool.poll(id)
        when :status
          @pool.connected?(id) ? "connected to #{@pool.describe(id)}" : "disconnected"
        else
          raise ProtocolError.new("unknown_tool", "tool #{name} has unknown mode #{tool[:mode]}")
        end
      end

      # The room survey composite (poll → look → exits) is deliberately NOT a
      # daemon tool. The daemon exposes only primitives; the composite is
      # assembled agent-side by the boukensha `room_inspector` subagent, which
      # calls `poll`, `look`, and `check(kind: "exits")` itself. Keeping
      # composition out of the daemon means every consumer sees the same flat
      # primitive surface and no policy about "what a survey is" lives here.
    end
  end
end
