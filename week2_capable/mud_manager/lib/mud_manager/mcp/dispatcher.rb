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
        when :inspect
          inspect_room(id)
        else
          raise ProtocolError.new("unknown_tool", "tool #{name} has unknown mode #{tool[:mode]}")
        end
      end

      private

      # Composite survey: fold the two primitives an agent otherwise runs
      # back-to-back on arrival (look + exits) into one round-trip, returning
      # their labelled outputs together so the model gets room description and
      # traversal information in a single tool call.
      def inspect_room(id)
        look  = @pool.run_command(id, MudManager::Primitives.look)
        exits = @pool.run_command(id, MudManager::Primitives.info_self("exits"))
        "== look ==\n#{look}\n\n== exits ==\n#{exits}"
      end
    end
  end
end
