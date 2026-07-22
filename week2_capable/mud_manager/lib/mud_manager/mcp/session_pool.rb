require_relative "../session"
require_relative "../manager_log"
require_relative "../telnet_log"
require_relative "config"
require_relative "errors"

module MudManager
  module Mcp
    # SessionPool owns the one stateful thing in the whole system: live
    # MudManager::Session objects. It is the *only* place telnet / threading /
    # login lives — every server (MCP or raw JSON) drives sessions through here.
    #
    # It supports MULTIPLE named sessions (plan open-Q #1). The MCP facade uses
    # a single implicit "default" session and hides its lifecycle entirely; the
    # raw JSON protocol can address several by id.
    #
    # Lifecycle is lazy and self-healing (plan §5): the first gameplay call on a
    # session opens the socket and runs the CircleMUD login dance using
    # credentials from config (never from tool args); if the socket has dropped,
    # the next call transparently reconnects and re-logs-in.
    class SessionPool
      Entry = Struct.new(:session, :config, keyword_init: true)

      def initialize(default_config: nil, timeout: 10.0, manager_log: :from_env, telnet_log: :from_env)
        @default_config = default_config || Config.resolve
        @timeout        = timeout
        @entries        = {}
        @mu             = Mutex.new
        @manager_log    = manager_log == :from_env ? MudManager::ManagerLog.from_env : manager_log
        @telnet_log     = telnet_log == :from_env ? MudManager::TelnetLog.from_env : telnet_log
      end

      # Configure/replace a named session's connection settings without opening
      # it. Used by the raw protocol's `connect`/`login` ops. Returns the id.
      def configure(id = "default", host: nil, port: nil, name: nil, password: nil)
        cfg = Config.resolve(host: host, port: port, name: name, password: password)
        @mu.synchronize do
          existing = @entries[id]
          existing&.session&.close
          @entries[id] = Entry.new(session: nil, config: cfg)
        end
        id
      end

      # Explicitly open + login a session (raw protocol). Idempotent-ish: if
      # already open, returns without reconnecting. Returns the login banner.
      def connect(id = "default")
        ensure_ready(id)
        "connected to #{describe(id)}"
      end

      def connected?(id = "default")
        s = @mu.synchronize { @entries[id]&.session }
        !!(s && s.open?)
      end

      def describe(id = "default")
        cfg = config_for(id)
        "#{cfg.host}:#{cfg.port}"
      end

      # ── gameplay execution ────────────────────────────────────────────────

      # Run a MudManager::Primitives::Command (or String) and return the MUD's
      # response text, waiting for the CircleMUD prompt sentinel.
      def run_command(id, command, tool: nil, args: nil, correlation_id: nil)
        with_reconnect(id) do
          log_exchange(id, mode: "command", tool: tool, args: args, correlation_id: correlation_id) do
            s = ensure_ready(id)
            s.drain
            sent = s.send_command(command)
            [ sent, s.read_until_prompt ]
          end
        end
      end

      # Send a raw command string; collect the response via a quiet window
      # (inherited from the since-deleted Boukensha::Tools::Mud#send_raw — some
      # commands need it because they don't emit the standard prompt promptly).
      def run_raw(id, raw, tool: nil, args: nil, correlation_id: nil)
        with_reconnect(id) do
          log_exchange(id, mode: "raw", tool: tool, args: args, correlation_id: correlation_id) do
            s = ensure_ready(id)
            sent = s.send_command(raw)
            [ sent, s.read_until_quiet ]
          end
        end
      end

      # Non-blocking: return whatever unprompted output the reader thread has
      # buffered since the last command (combat ticks, other players, …).
      def poll(id, tool: nil, args: nil, correlation_id: nil)
        log_exchange(id, mode: "poll", tool: tool, args: args, correlation_id: correlation_id) do
          s = @mu.synchronize { @entries[id]&.session }
          [ nil, (s && s.open? ? s.drain : "") ]
        end
      end

      def close(id = "default")
        @mu.synchronize do
          e = @entries[id]
          e&.session&.close
          @entries.delete(id)
        end
        "closed"
      end

      def close_all
        @mu.synchronize do
          @entries.each_value { |e| e.session&.close }
          @entries.clear
        end
      end

      def session_ids
        @mu.synchronize { @entries.keys }
      end

      private

      # Times `blk`, which must return `[sent, received]`, and writes one
      # ManagerLog record around it (spec §4.3) whether it succeeds or
      # raises. A no-op wrapper (just runs the block) when logging is
      # disabled, so the common case pays nothing beyond the branch.
      def log_exchange(id, mode:, tool:, args:, correlation_id:)
        return yield.last unless @manager_log

        start   = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        sent    = nil
        result  = nil
        failure = nil
        begin
          sent, result = yield
          result
        rescue StandardError => e
          failure = "#{e.class}: #{e.message}"
          raise
        ensure
          elapsed_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - start) * 1000).round
          @manager_log.exchange(session: id, mode: mode, tool: tool, args: args,
                                 correlation_id: correlation_id, sent: sent, received: result,
                                 elapsed_ms: elapsed_ms, error: failure)
        end
      end

      def config_for(id)
        @mu.synchronize { @entries[id]&.config } || @default_config
      end

      # Ensure the session for `id` is open and logged in, connecting lazily and
      # reconnecting if the socket has dropped. Returns the live Session.
      def ensure_ready(id)
        entry = nil
        @mu.synchronize do
          @entries[id] ||= Entry.new(session: nil, config: @default_config)
          entry = @entries[id]
        end

        return entry.session if entry.session && entry.session.open?

        cfg = entry.config
        unless cfg.credentials?
          raise ProtocolError.new("not_configured",
            "no MUD credentials for session #{id.inspect}: set MUD_NAME/MUD_PASSWORD " \
            "(or ~/.boukensha/settings.yaml mud:), or use the connect op with name/password")
        end

        session = MudManager::Session.new(host: cfg.host, port: cfg.port, timeout: @timeout,
                                           telnet_log: @telnet_log, session_id: id)
        login_started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        login_error   = nil
        begin
          session.open
          session.login(cfg.name, cfg.password)
        rescue MudManager::Session::LoginError => e
          session.close
          login_error = e.message
          raise ProtocolError.new("login_error", e.message)
        rescue MudManager::Session::ConnectionError => e
          session.close
          login_error = e.message
          raise ProtocolError.new("connection_error", e.message)
        rescue MudManager::Session::Timeout => e
          session.close
          login_error = e.message
          raise ProtocolError.new("timeout", "login timed out: #{e.message}")
        rescue MudManager::Session::Error => e
          session.close
          login_error = e.message
          raise ProtocolError.new("connection_error", e.message)
        ensure
          # mode: "login" carries only the username (spec §4.3) — the
          # password is never passed to ManagerLog, unlike TelnetLog (§4.2)
          # where it must be explicitly redacted because it crosses that log
          # verbatim.
          elapsed_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - login_started) * 1000).round
          @manager_log&.exchange(session: id, mode: "login", sent: cfg.name, received: nil,
                                  elapsed_ms: elapsed_ms, error: login_error)
        end

        @mu.synchronize { entry.session = session }
        session
      end

      # Run a block; if it fails because the socket dropped, drop the dead
      # session once and let the block re-establish it. Translates MudManager
      # errors into ProtocolErrors.
      def with_reconnect(id, retried: false, &blk)
        blk.call
      rescue MudManager::Session::ConnectionError => e
        if retried
          raise ProtocolError.new("connection_error", e.message)
        else
          @mu.synchronize { @entries[id]&.session&.close; @entries[id]&.session = nil }
          with_reconnect(id, retried: true, &blk)
        end
      rescue MudManager::Session::Timeout => e
        raise ProtocolError.new("timeout", e.message)
      rescue MudManager::Session::Error => e
        raise ProtocolError.new("connection_error", e.message)
      end
    end
  end
end
