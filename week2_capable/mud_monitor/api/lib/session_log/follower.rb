module SessionLog
  # Polls a single session .jsonl file for entries newer than a cursor.
  # Re-parses only when the file's mtime/size has changed since the last
  # check — session files are small enough that a full reparse is cheap
  # (the same trade `Parser` already makes for `show`), but rereading a
  # static file on every 250ms tick of a live stream is not worth doing for
  # nothing.
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

    def entries_after(seq)
      parser.entries.select { |e| e.seq > seq }
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
