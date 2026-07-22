module TelnetLog
  # Date-based lookup for telnet log files. Same shape as ManagerLog::Store:
  # `DATE_RE` only ever admits an 8-digit string, so `date` can't escape the
  # configured directory regardless of what the caller sends.
  class Store
    class NotFound < StandardError; end

    DATE_RE = /\A\d{8}\z/

    def initialize(dir:, live_window: 10)
      @dir         = Pathname.new(dir)
      @live_window = live_window
    end

    def today
      Time.now.strftime("%Y%m%d")
    end

    # nil when `date` is malformed or no file exists yet — "telnet logging is
    # off" and "nothing happened today" are the same observable state from
    # here, and both render as an empty list rather than an error (spec
    # §4.2: off by default).
    def path_for(date)
      return nil unless date.to_s.match?(DATE_RE)

      path = @dir.join("#{date}.jsonl")
      path.file? ? path : nil
    end

    # Same lookup, but for callers (stream) that need something to actually
    # tail and should 404 rather than silently serve nothing.
    def path_for!(date)
      path_for(date) || raise(NotFound, date)
    end

    def live?(path)
      Time.now - File.mtime(path) <= @live_window
    end
  end
end
