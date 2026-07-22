require "json"
require "fileutils"
require "time"

module MudManager
  # Records every command SessionPool actually drove through the socket —
  # `run_command`, `run_raw`, `poll` — with its own full copy of what was
  # sent and received. Independent of TelnetLog by design (mud_monitor spec
  # §0.1): this log stands alone and is readable without the telnet log
  # present.
  #
  #   log = ManagerLog.from_env
  #   log&.exchange(session: "default", mode: "command", tool: "tbamud__look",
  #                 args: {}, sent: "look", received: "...", elapsed_ms: 42)
  class ManagerLog
    # nil (disabled) unless MUD_MANAGER_LOG_DIR is set — every call site is
    # `@manager_log&.exchange(...)`, so an unset env var costs nothing.
    def self.from_env
      dir = ENV["MUD_MANAGER_LOG_DIR"]
      dir && !dir.empty? ? new(dir: dir) : nil
    end

    def initialize(dir:)
      @dir = dir
      @mu  = Mutex.new
      @seq = nil
      FileUtils.mkdir_p(@dir)
    end

    # mode: "command" | "raw" | "poll" | "login"
    def exchange(session:, mode:, sent: nil, received: nil, elapsed_ms: nil,
                 tool: nil, args: nil, correlation_id: nil, error: nil)
      now = Time.now

      @mu.synchronize do
        rotate_if_needed(now)
        # 1-based: `?after=0` (the default when the param is omitted) must
        # include the very first record of the day, the same convention
        # SessionLog::Parser uses for its entries.
        @seq += 1
        record = {
          seq: @seq,
          at: now.iso8601(3),
          mono_ms: (Process.clock_gettime(Process::CLOCK_MONOTONIC) * 1000).round,
          session: session,
          mode: mode,
          tool: tool,
          args: args,
          correlation_id: correlation_id,
          sent: sent,
          received: received,
          bytes_in: received.to_s.bytesize,
          elapsed_ms: elapsed_ms,
          error: error
        }
        @io.puts(JSON.generate(record))
        @io.flush
      end
    end

    private

    # Daily rotation: the daemon outlives any one agent run, so files are cut
    # by calendar day rather than by session. `seq` restarts at the line
    # count already on disk (not zero) so a process restart mid-day never
    # reissues a `seq` another line already used — the `after` cursor stays
    # monotonic within a day regardless of how many daemon processes wrote to
    # it (spec §3.4).
    def rotate_if_needed(time)
      date = time.strftime("%Y%m%d")
      return if @date == date

      @io&.close
      @date = date
      path  = File.join(@dir, "#{date}.jsonl")
      @seq  = File.exist?(path) ? File.foreach(path).count : 0
      @io   = File.open(path, "a")
    end
  end
end
