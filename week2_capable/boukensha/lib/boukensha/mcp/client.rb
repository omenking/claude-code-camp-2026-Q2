require "open3"
require "json"
require "rbconfig"

module Boukensha
  module Mcp
    # Client is a minimal MCP-over-stdio client: it spawns an MCP server as a
    # subprocess, performs the initialize handshake, and lets you discover and
    # call the tools it advertises. It knows nothing about any particular
    # server — command, args, and env are the standard stdio transport config.
    #
    #   client = Boukensha::Mcp::Client.spawn(command: "mud-manager", args: ["--mcp"])
    #   client.tools.each { |t| puts t["name"] }
    #   puts client.call_tool("look")[:text]
    #   client.close
    class Client
      class Error < StandardError; end

      PROTOCOL_VERSION = "2025-06-18".freeze

      attr_reader :server_info, :tools

      # command: executable to spawn. args: argv for it. env: extra environment
      # (e.g. a server's credentials — the stdio transport's standard channel).
      def self.spawn(command:, args: [], env: {})
        new(command: command, args: args, env: env)
      end

      def initialize(command:, args: [], env: {})
        cmd = [command.to_s, *Array(args).map(&:to_s)]
        env = env.each_with_object({}) { |(k, v), h| h[k.to_s] = expand_env(v.to_s) }
        spawn_unbundled { @stdin, @stdout, @stderr, @wait = Open3.popen3(env, *cmd) }
        @id = 0
        handshake
        @tools = fetch_tools
      end

      # Substitute ${VAR} in an `env:` value from this process's own
      # environment, so settings.yaml can write a path relative to something
      # stable instead of the shell's cwd:
      #
      #   MUD_TELNET_LOG_DIR: ${BOUKENSHA_DIR}/telnet
      #
      # BOUKENSHA_DIR is exported by BoukenshaLoader before anything spawns
      # (from ~/.boukensharc, or ~/.boukensha), which is the same directory
      # mud_monitor resolves — a bare `.boukensha/telnet` instead lands
      # wherever you happened to launch from, and reads to the monitor as
      # "logging disabled".
      #
      # An unset variable is left verbatim rather than blanked: silently
      # collapsing to "/telnet" would create a directory at the filesystem
      # root, whereas the literal "${BOUKENSHA_DIR}/telnet" fails visibly.
      def expand_env(value)
        value.gsub(/\$\{(\w+)\}/) { ENV.fetch(::Regexp.last_match(1), ::Regexp.last_match(0)) }
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

      # An MCP server is a separate program with its own dependencies — it may
      # not even be a Ruby process. If *boukensha itself* is running under
      # Bundler (e.g. launched via `bundle exec`), BUNDLE_GEMFILE/RUBYOPT would
      # otherwise leak into the spawned server's environment and force it to
      # activate boukensha's bundle instead of its own, which fails outright
      # for a server whose gems aren't in that Gemfile (a double "already
      # initialized constant Gem::Platform::..." warning from rubygems_ext
      # loading twice is the telltale sign).
      #
      # Nil-ing BUNDLE_GEMFILE/RUBYOPT in the env hash passed to Open3.popen3
      # does NOT work here: once Bundler.setup has run in *this* process, it
      # patches Process.spawn to always re-inject its own captured env into
      # every child, overriding explicit unsets. Bundler.with_unbundled_env is
      # its own sanctioned escape hatch for exactly this case — it restores
      # the environment Bundler captured before activating itself. A no-op
      # when Bundler was never loaded (boukensha run outside `bundle exec`).
      def spawn_unbundled(&block)
        if defined?(Bundler)
          Bundler.with_unbundled_env(&block)
        else
          block.call
        end
      end

      def handshake
        res = request("initialize", {
          "protocolVersion" => PROTOCOL_VERSION,
          "capabilities"    => {},
          "clientInfo"      => { "name" => "boukensha", "version" => Boukensha::VERSION }
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
          raise Error, "server closed the connection#{stderr_detail}" if line.nil?
          line = line.strip
          next if line.empty?
          msg = JSON.parse(line)
          return msg if msg["id"] == id
          # ignore server-initiated notifications / mismatched ids
        end
      end

      # Drains whatever the subprocess wrote to stderr before it died, so a
      # crash during spawn/handshake (bad Ruby version, missing gem,
      # unhandled exception before the request loop starts) is diagnosable
      # instead of a bare "server closed the connection". @stdout hitting EOF
      # means the process is exiting or has exited, so @wait.value (bounded —
      # it's already at EOF) reaps it and guarantees @stderr is fully flushed
      # before the blocking read below.
      def stderr_detail
        @wait&.value
        output = @stderr.read
        output && !output.strip.empty? ? " — stderr: #{output.strip}" : ""
      rescue IOError
        ""
      end
    end
  end
end
