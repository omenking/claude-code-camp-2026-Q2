require "json"

module ManagerLog
  # Parses a mud_manager `.boukensha/manager/<YYYYMMDD>.jsonl` file into an
  # ordered list of records. Unlike SessionLog::Parser, `seq` is read from
  # the file rather than assigned positionally: manager log files are
  # daily-rotated and written by a long-lived daemon that may restart mid-day
  # (see MudManager::ManagerLog#rotate_if_needed), so `seq` must already be
  # stable in the record for `after` cursors to stay monotonic across process
  # restarts and across the session/mode filters applied at the controller.
  class Parser
    Record = Struct.new(:seq, :at, :mono_ms, :session, :mode, :tool, :args, :correlation_id,
                         :sent, :received, :bytes_in, :elapsed_ms, :error, keyword_init: true)

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
          session: event["session"], mode: event["mode"], tool: event["tool"],
          args: event["args"], correlation_id: event["correlation_id"],
          sent: event["sent"], received: event["received"], bytes_in: event["bytes_in"],
          elapsed_ms: event["elapsed_ms"], error: event["error"]
        )
      end
    end
  end
end
