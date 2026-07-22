module Diff
  # telnet − manager: what SessionPool's pre-command `drain` (and its
  # siblings — read_until leftover, the login dance, uncovered poll windows)
  # discarded before the agent ever saw it (spec §0.2, §3.6).
  #
  # The manager log never invents bytes: `received` is always the literal
  # return value of a `Session#read_until*` call, which is itself built out
  # of chunks TelnetLog already recorded for `dir: "in"`. That makes this an
  # exact alignment, not a fuzzy one — concatenate telnet's inbound text into
  # one stream, walk the manager's `received` payloads across it in order,
  # and whatever sits between two consecutive matches was never returned to
  # any tool call.
  class TelnetManager
    Dropped = Struct.new(:at, :telnet_seqs, :text, :bytes,
                          :after_manager_seq, :before_manager_seq, :cause, keyword_init: true)

    def self.call(telnet_records:, manager_records:, session: nil)
      new(telnet_records: telnet_records, manager_records: manager_records, session: session).call
    end

    def initialize(telnet_records:, manager_records:, session: nil)
      @telnet  = session ? telnet_records.select { |r| r.session == session } : telnet_records.dup
      @manager = session ? manager_records.select { |r| r.session == session } : manager_records.dup
      @telnet.sort_by!(&:seq)
      @manager.sort_by!(&:seq)
    end

    def call
      inbound = @telnet.select { |r| r.dir == "in" }
      stream, spans = build_stream(inbound)
      matched = align(stream)
      dropped = build_dropped(stream, spans, matched)

      dropped_bytes  = dropped.sum(&:bytes)
      received_bytes = matched.sum { |start, fin, _seq| stream[start...fin].bytesize }
      total          = dropped_bytes + received_bytes

      {
        dropped: dropped,
        summary: {
          dropped_bytes: dropped_bytes,
          dropped_runs: dropped.length,
          received_bytes: received_bytes,
          drop_ratio: total.zero? ? nil : (dropped_bytes.to_f / total).round(4)
        }
      }
    end

    private

    # Concatenates every inbound chunk in seq order into one string, and
    # records the [start, stop) character range each chunk occupies within
    # it — the map back from a byte offset in the merged stream to the
    # telnet record(s) that contributed it.
    def build_stream(inbound)
      stream = +""
      spans  = []
      inbound.each do |record|
        text  = record.text.to_s
        start = stream.length
        stream << text
        spans << { seq: record.seq, start: start, stop: start + text.length }
      end
      [ stream, spans ]
    end

    # Greedily locate each manager `received` payload as a substring of the
    # merged inbound stream, searching forward from the end of the previous
    # match. Returns [[start, stop, manager_seq], ...] in stream order.
    def align(stream)
      cursor  = 0
      matched = []

      @manager.each do |record|
        text = record.received
        next if text.nil? || text.empty?

        idx = stream.index(text, cursor)
        next unless idx # manager quoted bytes the telnet log never captured (rotated, disabled mid-session, …)

        matched << [ idx, idx + text.length, record.seq ]
        cursor = idx + text.length
      end

      matched
    end

    def build_dropped(stream, spans, matched)
      gaps(matched, stream.length).filter_map do |gap_start, gap_end, after_seq, before_seq|
        next if gap_start >= gap_end

        text = stream[gap_start...gap_end]
        overlapping = spans.select { |s| s[:start] < gap_end && s[:stop] > gap_start }
        seqs = overlapping.map { |s| s[:seq] }

        Dropped.new(
          at: overlapping.first && telnet_at(overlapping.first[:seq]),
          telnet_seqs: seqs,
          text: text,
          bytes: text.bytesize,
          after_manager_seq: after_seq,
          before_manager_seq: before_seq,
          cause: cause_for(after_seq, overlapping.last)
        )
      end
    end

    # The complement of `matched` within [0, stream_len): the stretch before
    # the first match, between each consecutive pair, and after the last —
    # tagged with the manager seqs bracketing it (nil at either end).
    def gaps(matched, stream_len)
      out = []
      prev_end = 0
      prev_seq = nil
      matched.each do |start, fin, seq|
        out << [ prev_end, start, prev_seq, seq ]
        prev_end = fin
        prev_seq = seq
      end
      out << [ prev_end, stream_len, prev_seq, nil ]
      out
    end

    # cause is inferred from position (spec §3.6):
    #   - before the first manager record at all            -> "login"
    #   - the next telnet record after the gap is outbound   -> "pre_command_drain"
    #   - otherwise                                          -> "post_prompt_leftover"
    def cause_for(after_seq, last_span)
      return "login" if after_seq.nil?

      next_record = last_span && @telnet.find { |r| r.seq > last_span[:seq] }
      next_record && next_record.dir == "out" ? "pre_command_drain" : "post_prompt_leftover"
    end

    def telnet_at(seq)
      @telnet.find { |r| r.seq == seq }&.at
    end
  end
end
