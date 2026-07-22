module TelnetLog
  # Polls a single day's telnet log file for records newer than a cursor.
  # Same reload-on-change trade as ManagerLog::Follower.
  class Follower
    def initialize(path)
      @path      = path
      @last_stat = nil
      @parser    = nil
    end

    def parser
      reload_if_changed
      @parser
    end

    def records_after(seq)
      parser.records.select { |r| r.seq > seq }
    end

    private

    def reload_if_changed
      stat = File.stat(@path)
      key  = [ stat.mtime, stat.size ]
      return if @parser && key == @last_stat

      @parser    = Parser.load(@path)
      @last_stat = key
    end
  end
end
