require "open3"
require "json"

module MudManager
  module Mcp
    # Client is a minimal MCP-over-stdio client: it spawns `mud-manager --mcp`
    # as a subprocess, performs the initialize handshake, and lets you discover
    # and call tools. This is exactly the ~40 lines a non-Ruby track would write
    # against their own SDK — provided here so the Ruby side (boukensha) can
    # drive the daemon for parity, and so the whole path is testable end to end.
    #
    #   client = MudManager::Mcp::Client.spawn
    #   client.tools.each { |t| puts t["name"] }
    #   puts client.call_tool("look")[:text]
    #   client.close
    class Client
      class Error < StandardError; end

      attr_reader :server_info, :tools

      # cmd: argv for the server. env: extra environment (e.g. MUD_* creds).
      def self.spawn(cmd: default_cmd, env: {})
        new(cmd: cmd, env: env)
      end

      def self.default_cmd
        bin = File.expand_path("../../../bin/mud-manager", __dir__)
        [RbConfig.ruby, bin, "--mcp"]
      end

      def initialize(cmd:, env: {})
        @stdin, @stdout, @stderr, @wait = Open3.popen3(env, *cmd)
        @id = 0
        handshake
        @tools = fetch_tools
      end

      # Call a tool. Returns { text:, error: (bool) }.
      def call_tool(name, arguments = {})
        res = request("tools/call", { "name" => name.to_s, "arguments" => arguments })
        result = res["result"] or raise Error, "tools/call error: #{res["error"].inspect}"
        text = Array(result["content"]).map { |c| c["text"] }.compact.join("\n")
        { text: text, error: !!result["isError"] }
      end

      def close
        @stdin.close rescue nil
        @wait&.value
        @stdout.close rescue nil
        @stderr.close rescue nil
      end

      private

      def handshake
        res = request("initialize", {
          "protocolVersion" => Server::PROTOCOL_VERSION,
          "capabilities"    => {},
          "clientInfo"      => { "name" => "mud-manager-mcp-client", "version" => VERSION }
        })
        @server_info = res.dig("result", "serverInfo")
        notify("notifications/initialized")
      end

      def fetch_tools
        request("tools/list").dig("result", "tools") || []
      end

      def request(method, params = {})
        id = (@id += 1)
        write({ "jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params })
        read_until(id)
      end

      def notify(method, params = {})
        write({ "jsonrpc" => "2.0", "method" => method, "params" => params })
      end

      def write(obj)
        @stdin.puts(JSON.generate(obj))
        @stdin.flush
      end

      def read_until(id)
        loop do
          line = @stdout.gets
          raise Error, "server closed the connection" if line.nil?
          line = line.strip
          next if line.empty?
          msg = JSON.parse(line)
          return msg if msg["id"] == id
          # ignore server-initiated notifications / mismatched ids
        end
      end
    end
  end
end

require_relative "server" # for PROTOCOL_VERSION / VERSION
