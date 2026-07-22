require "json"

module TelnetLog
  # Parses a mud_manager `.boukensha/telnet/<YYYYMMDD>.jsonl` file into an
  # ordered list of records. `seq` is read from the file rather than assigned
  # positionally, same reasoning as ManagerLog::Parser: the log is written by
  # a long-lived daemon that may restart mid-day.
  class Parser
    Record = Struct.new(:seq, :at, :mono_ms, :session, :dir, :bytes, :text, :redacted, keyword_init: true)

    attr_reader :records

    def self.load(path)
      new(path).tap(&:parse!)
    end

    def initialize(path)
      @path    = path
      @records = []
    end

    def parse!
      File.foreach(@path) do |line|
        line = line.strip
        next if line.empty?

        event = begin
          JSON.parse(line)
        rescue JSON::ParserError
          next # truncated final line of a file still being written
        end

        @records << Record.new(
          seq: event["seq"], at: event["at"], mono_ms: event["mono_ms"],
          session: event["session"], dir: event["dir"], bytes: event["bytes"],
          text: event["text"], redacted: event["redacted"]
        )
      end
    end
  end
end
