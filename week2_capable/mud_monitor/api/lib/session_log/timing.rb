require "time"

module SessionLog
  # Session-level timing rollups (spec §4.4), derived from the per-entry
  # `dt_ms`/`duration_ms` a Parser already computed. Read time between agent
  # "think" (model latency) and "MUD time" (tool duration) is exactly what the
  # dropped-strip UI needs to separate.
  class Timing
    def initialize(parser)
      @parser = parser
    end

    def summary
      {
        p50_tool_ms: percentile(tool_durations, 50),
        p95_tool_ms: percentile(tool_durations, 95),
        p50_model_ms: percentile(model_durations, 50),
        p95_model_ms: percentile(model_durations, 95),
        total_idle_ms: idle_ms,
        wall_ms: wall_ms,
        busy_ms: busy_ms
      }
    end

    private

    IDLE_THRESHOLD_MS = 5_000

    def tool_durations
      @parser.entries.select { |e| e.type == :tool }.filter_map(&:duration_ms)
    end

    def model_durations
      @parser.entries.select { |e| e.type == :assistant }.filter_map(&:duration_ms)
    end

    # Sum of gaps between consecutive entries greater than the idle threshold
    # — think time or MUD time, distinct from dead air waiting on nothing.
    def idle_ms
      @parser.entries.filter_map(&:dt_ms).select { |dt| dt > IDLE_THRESHOLD_MS }.sum
    end

    def wall_ms
      return nil unless @parser.started_at && @parser.ended_at

      ((Time.parse(@parser.ended_at) - Time.parse(@parser.started_at)) * 1000).round
    rescue ArgumentError, TypeError
      nil
    end

    def busy_ms
      w = wall_ms
      return nil unless w

      w - idle_ms
    end

    def percentile(values, pct)
      return nil if values.empty?

      sorted = values.sort
      index  = ((pct / 100.0) * (sorted.length - 1)).round
      sorted[index]
    end
  end
end
