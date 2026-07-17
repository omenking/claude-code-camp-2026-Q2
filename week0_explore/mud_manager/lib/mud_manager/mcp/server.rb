require "json"
require_relative "session_pool"
require_relative "dispatcher"
require_relative "spec"
require_relative "errors"
require_relative "../version"

module MudManager
  module Mcp
    # Server exposes the daemon as a Model Context Protocol server over stdio
    # (plan Option C — the blessed interface). MCP is just JSON-RPC 2.0 with tool
    # discovery, so any agent SDK that speaks MCP gets typed MUD tools with no
    # protocol code of its own.
    #
    # Transport: newline-delimited JSON-RPC messages on stdin/stdout (the MCP
    # stdio transport). One JSON object per line.
    #
    # The session lifecycle is completely hidden (plan §5): the LLM only ever
    # sees gameplay tools + poll + send_raw; connect/login happen lazily inside
    # the SessionPool using env/config credentials.
    class Server
      PROTOCOL_VERSION = "2025-06-18".freeze
      SERVER_INFO = { "name" => "mud-manager", "version" => VERSION }.freeze

      # JSON-RPC error codes
      PARSE_ERROR      = -32_700
      INVALID_REQUEST  = -32_600
      METHOD_NOT_FOUND = -32_601
      INVALID_PARAMS   = -32_602
      INTERNAL_ERROR   = -32_603

      def initialize(pool: nil, input: $stdin, output: $stdout)
        @pool       = pool || SessionPool.new
        @dispatcher = Dispatcher.new(@pool)
        @in         = input
        @out        = output
        @mu         = Mutex.new
      end

      def run
        @in.each_line do |line|
          line = line.strip
          next if line.empty?
          handle_line(line)
        end
      ensure
        @pool.close_all
      end

      private

      def handle_line(line)
        msg =
          begin
            JSON.parse(line)
          rescue JSON::ParserError => e
            return send_error(nil, PARSE_ERROR, "parse error: #{e.message}")
          end

        # Notifications have no "id" and expect no response.
        id       = msg["id"]
        method   = msg["method"]
        params   = msg["params"] || {}
        is_notif = !msg.key?("id")

        case method
        when "initialize"
          reply(id, initialize_result(params))
        when "notifications/initialized", "initialized"
          # no response for notifications
        when "ping"
          reply(id, {})
        when "tools/list"
          reply(id, { "tools" => Spec.mcp_tools })
        when "tools/call"
          reply(id, call_tool(params))
        else
          send_error(id, METHOD_NOT_FOUND, "method not found: #{method}") unless is_notif
        end
      rescue StandardError => e
        send_error(msg && msg["id"], INTERNAL_ERROR, "#{e.class}: #{e.message}")
      end

      def initialize_result(params)
        # Echo the client's requested protocol version when present for maximum
        # compatibility; otherwise advertise ours.
        version = params["protocolVersion"] || PROTOCOL_VERSION
        {
          "protocolVersion" => version,
          "capabilities"    => { "tools" => { "listChanged" => false } },
          "serverInfo"      => SERVER_INFO
        }
      end

      # tools/call → result with content blocks. Per MCP, *tool* errors are
      # returned as a normal result with isError:true (so the model sees them),
      # not as JSON-RPC errors. We embed the structured error code in the text.
      def call_tool(params)
        name = params["name"]
        args = params["arguments"] || {}
        begin
          text = @dispatcher.call(name, args, id: "default")
          { "content" => [ text_block(text) ], "isError" => false }
        rescue ProtocolError => e
          { "content" => [ text_block("error [#{e.code}]: #{e.message}") ], "isError" => true }
        end
      end

      def text_block(text)
        { "type" => "text", "text" => text.to_s }
      end

      # ── JSON-RPC framing ────────────────────────────────────────────────────

      def reply(id, result)
        return if id.nil? # was a notification; nothing to reply to
        write({ "jsonrpc" => "2.0", "id" => id, "result" => result })
      end

      def send_error(id, code, message)
        write({ "jsonrpc" => "2.0", "id" => id, "error" => { "code" => code, "message" => message } })
      end

      def write(obj)
        @mu.synchronize do
          @out.puts(JSON.generate(obj))
          @out.flush
        end
      end
    end
  end
end
