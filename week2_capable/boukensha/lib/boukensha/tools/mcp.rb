require_relative "../mcp/client"

module Boukensha
  module Tools
    # Mcp makes boukensha an MCP host: point it at any MCP server and every
    # tool that server advertises becomes a boukensha tool. It knows nothing
    # about any particular server — `command`/`args`/`env` is the standard
    # stdio transport config, the same triple every other MCP host uses.
    #
    #   Boukensha::Tools::Mcp.register(
    #     registry, command: "mud-manager", args: ["--mcp"],
    #     env: { "MUD_HOST" => "localhost" }, prefix: "tbamud"
    #   )
    #
    # `registry` is anything with the #tool surface — a Registry or the RunDSL
    # yielded to a run/repl block.
    #
    # prefix: scopes the discovered names ("tbamud" => tbamud__look). The
    # prefix is a property of the server entry, supplied by config; this module
    # applies whatever it is given. Names are only prefixed agent-side — the
    # server still sees its own bare name on the wire.
    module Mcp
      SEPARATOR = "__".freeze

      # Two tools claiming one name. Always fatal, even for an optional server:
      # this is a config contradiction, not a server being unreachable, and
      # silently dropping the loser is the expensive failure.
      class CollisionError < ArgumentError; end

      def self.register(registry, command:, args: [], env: {}, prefix: nil)
        client = Boukensha::Mcp::Client.spawn(command: command, args: args, env: env)
        # Close the server subprocess cleanly when the agent process exits.
        at_exit { client.close rescue nil }
        register_client(registry, client, prefix: prefix)
        client
      end

      # Register an already-spawned client's tools into `registry`. Returns the
      # number of tools actually registered.
      #
      # `permissions:` is an optional Boukensha::Permissions (a task's `allow:`
      # rules). `registry` itself enforces NAME level (a disallowed tool is
      # never registered) and VALUE level (a dispatch guard rejects any call
      # the rules don't permit) — the same gate a natively-registered tool
      # goes through. `permissions:` here is only used for what the registry
      # can't do generically: narrowing a registered tool's *advertised* enum
      # params to the permitted values, which needs the tool's MCP-specific
      # inputSchema to know what an enum even is. Each tool's rules are also
      # validated against its own schema first, so a typo or an illegal enum
      # value fails loudly at registration.
      def self.register_client(registry, client, prefix: nil, permissions: nil)
        taken = begin
          registry.respond_to?(:tool_names) ? registry.tool_names.to_a : []
        end

        registered = 0
        client.tools.each do |tool|
          remote = tool["name"]
          local  = prefixed(remote, prefix)

          permissions.validate_tool!(local, tool["inputSchema"]) if permissions

          if taken.include?(local)
            raise CollisionError,
                  "boukensha: MCP tool name collision on '#{local}' — a tool by that " \
                  "name is already registered. Give this server a distinct `prefix:` " \
                  "in mcp_servers."
          end

          # Name/value permission gating happens in Registry#tool/#dispatch —
          # the single enforcement point shared with natively-registered tools
          # (RunDSL#tool). registry.tool returns nil for a disallowed name, so
          # bookkeeping below only counts/tracks what actually got registered.
          registered_tool = registry.tool(local, description: tool["description"].to_s,
                               parameters: to_boukensha_params(tool["inputSchema"], permissions: permissions, tool_name: local)) do |**kwargs|
            # Boukensha hands us symbol-keyed kwargs; the server wants strings.
            # Blank/omitted values are normalized server-side.
            result = client.call_tool(remote, kwargs.transform_keys(&:to_s))
            result[:error] ? "error: #{result[:text]}" : result[:text]
          end
          next unless registered_tool

          taken << local
          registered += 1
        end
        registered
      end

      def self.prefixed(name, prefix)
        p = prefix.to_s.strip
        p.empty? ? name.to_s : "#{p}#{SEPARATOR}#{name}"
      end

      # Convert an MCP inputSchema into boukensha's `parameters` shape
      # ({ name => { type:, description: } }). We list every property so the
      # model can supply optional ones too (servers treat blanks as absent).
      #
      # When `permissions` narrows an enum param on `tool_name`, the advertised
      # enum is reduced to the permitted values here, so the model is never
      # offered a value it isn't allowed to use.
      def self.to_boukensha_params(input_schema, permissions: nil, tool_name: nil)
        props = (input_schema && input_schema["properties"]) || {}
        props.each_with_object({}) do |(pname, schema), out|
          desc = schema["description"].to_s
          enum = schema["enum"]
          enum = permissions.allowed_values(tool_name, pname, enum) if enum && permissions && tool_name
          if enum
            desc = "#{desc} (one of: #{enum.join(", ")})".strip
          end
          out[pname.to_sym] = { type: schema["type"] || "string", description: desc }
        end
      end
    end
  end
end
