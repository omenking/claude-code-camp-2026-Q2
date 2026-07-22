require "json"
require "fileutils"
require "time"

module MudManager
  # Records every byte that crosses the telnet socket, both directions,
  # interleaved in true chronological order (mud_monitor spec §4.2). Written
  # from MudManager::Session: the reader thread for inbound chunks, and
  # `send_command` for outbound sends. That is the one place every byte
  # passes in both directions, and it sits below SessionPool, so it also
  # captures the login dance ManagerLog never sees.
  #
  #   log = TelnetLog.from_env
  #   log&.chunk(session: "default", dir: "in", text: "...")
  #   log&.chunk(session: "default", dir: "out", text: password, redacted: true)
  class TelnetLog
    # nil (disabled) unless MUD_TELNET_LOG_DIR is set — every call site is
    # `@telnet_log&.chunk(...)`, so an unset env var costs nothing.
    def self.from_env
      dir = ENV["MUD_TELNET_LOG_DIR"]
      dir && !dir.empty? ? new(dir: dir) : nil
    end

    def initialize(dir:)
      @dir = dir
      @mu  = Mutex.new
      @seq = nil
      FileUtils.mkdir_p(@dir)
    end

    # dir: "in" | "out". `bytes` is always the true byte count of `text`,
    # even when `redacted` replaces the text field with a placeholder — a
    # password send must never appear verbatim in this log.
    def chunk(session:, dir:, text:, redacted: false)
      now = Time.now

      @mu.synchronize do
        rotate_if_needed(now)
        @seq += 1
        record = {
          seq: @seq,
          at: now.iso8601(3),
          mono_ms: (Process.clock_gettime(Process::CLOCK_MONOTONIC) * 1000).round,
          session: session,
          dir: dir,
          bytes: text.to_s.bytesize,
          text: redacted ? "<redacted>" : text,
          redacted: redacted
        }
        @io.puts(JSON.generate(record))
        @io.flush
      end
    end

    private

    # Daily rotation, same scheme as ManagerLog: `seq` restarts at the line
    # count already on disk so a process restart mid-day never reissues a
    # `seq` another line already used.
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
