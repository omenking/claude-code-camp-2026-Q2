require "json"
require_relative "session_pool"
require_relative "dispatcher"
require_relative "errors"

module MudManager
  module Mcp
    # JsonLineServer speaks the bespoke newline-delimited JSON protocol from the
    # plan (§2 / Option B). One JSON object per line in, one per line out. It is
    # the low-level teaching artifact and escape hatch — MCP is layered on the
    # same idea, but this format is trivial to implement a client for by hand.
    #
    # Request ops (framework → daemon):
    #   {"id":1,"op":"connect","session":"default","host":"h","port":4000,
    #                           "name":"Gandalf","password":"secret"}
    #   {"id":2,"op":"login",   ...}          # alias of connect (creds may be here)
    #   {"id":3,"op":"send","raw":"kill goblin"}
    #   {"id":4,"op":"tool","name":"attack","args":{"target":"goblin"}}
    #   {"id":5,"op":"poll"}
    #   {"id":6,"op":"list_tools"}
    #   {"id":7,"op":"close"}
    #
    # Responses (daemon → framework):
    #   {"id":4,"ok":true,"text":"You hit the goblin...\n<100hp>"}
    #   {"id":2,"ok":false,"error":"wrong password","error_type":"login_error"}
    class JsonLineServer
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
        req =
          begin
            JSON.parse(line)
          rescue JSON::ParserError => e
            return emit(nil, ok: false, code: "bad_request", error: "invalid JSON: #{e.message}")
          end

        id  = req["id"]
        op  = req["op"]
        sid = req["session"] || "default"

        begin
          result = dispatch_op(op, req, sid)
          emit(id, ok: true, extra: result)
        rescue ProtocolError => e
          emit(id, ok: false, code: e.code, error: e.message)
        rescue StandardError => e
          emit(id, ok: false, code: "internal_error", error: "#{e.class}: #{e.message}")
        end
      end

      # Returns a Hash merged into the success response.
      def dispatch_op(op, req, sid)
        case op
        when "connect", "login"
          @pool.configure(sid,
            host:     req["host"],
            port:     req["port"],
            name:     req["name"],
            password: req["password"])
          { "text" => @pool.connect(sid) }
        when "close"
          { "text" => @pool.close(sid) }
        when "status"
          { "connected" => @pool.connected?(sid), "target" => @pool.describe(sid) }
        when "send", "raw"
          { "text" => @dispatcher.call("send_raw", { "command" => req["raw"] || req["command"] }, id: sid) }
        when "tool", "primitive"
          { "text" => @dispatcher.call(req["name"], req["args"] || {}, id: sid) }
        when "poll"
          { "text" => @dispatcher.call("poll", {}, id: sid) }
        when "list_tools"
          { "tools" => Spec.mcp_tools }
        else
          raise ProtocolError.new("unknown_tool", "unknown op: #{op.inspect}")
        end
      end

      def emit(id, ok:, extra: {}, code: nil, error: nil)
        msg = { "id" => id, "ok" => ok }
        msg.merge!(extra) if extra && ok
        unless ok
          msg["error"]      = error
          msg["error_type"] = code
        end
        @mu.synchronize do
          @out.puts(JSON.generate(msg))
          @out.flush
        end
      end
    end
  end
end

require_relative "spec"
