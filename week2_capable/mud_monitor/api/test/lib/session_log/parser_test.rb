require "test_helper"

module SessionLog
  class ParserTest < ActiveSupport::TestCase
    FIXTURES = Rails.root.join("test/fixtures/session_logs")

    test "parses a complete session into ordered entries with turns and usage" do
      parser = Parser.load(FIXTURES.join("complete.jsonl"))

      assert_equal "complete", parser.id
      assert_equal "2026-07-22T10:00:00-04:00", parser.started_at
      assert_equal %i[user assistant tool assistant turn_end], parser.entries.map(&:type)
      assert_equal 300, parser.total_input_tokens
      assert_equal 30, parser.total_output_tokens
      assert_equal 2, parser.usage_series.length
      assert_equal "completed", parser.end_reason
      refute parser.stopped?
      assert_in_delta 0.0006, parser.estimated_cost, 0.0001
    end

    test "assigns a monotonically increasing seq to every entry" do
      parser = Parser.load(FIXTURES.join("complete.jsonl"))

      assert_equal (1..parser.entries.length).to_a, parser.entries.map(&:seq)
    end

    test "unrecognized phases pass through as type unknown with the raw event attached" do
      parser = Parser.load(FIXTURES.join("unknown_phase.jsonl"))

      unknown = parser.entries.find { |e| e.type == :unknown }
      refute_nil unknown
      assert_equal "goal", unknown.raw["phase"]
      assert_equal "reach the temple", unknown.raw["text"]
    end

    test "a truncated final line (live file mid-write) is skipped, not raised" do
      parser = Parser.load(FIXTURES.join("truncated.jsonl"))

      assert_equal %i[user], parser.entries.map(&:type)
    end

    test "a clear event becomes a :clear entry rather than passing through as unknown" do
      parser = Parser.load(FIXTURES.join("messages_timeline.jsonl"))

      clear = parser.entries.find { |e| e.type == :clear }
      refute_nil clear
      assert_equal 4, clear.dropped
      refute parser.entries.any? { |e| e.type == :unknown }
    end

    test "each request becomes a compact marker entry (a sidebar button), never a raw blob" do
      parser   = Parser.load(FIXTURES.join("request_timeline.jsonl"))
      requests = parser.entries.select { |e| e.type == :request }

      refute parser.entries.any? { |e| e.type == :unknown }, "request events must not render as raw unknown blocks"
      # one marker per request, carrying the 1-based ordinal that maps to the
      # sidebar checkpoint plus a message count for the button label
      assert_equal 4, requests.length
      assert_equal [ 1, 2, 3, 4 ], requests.map(&:request_seq)
      assert_equal [ 1, 3, 4, 1 ], requests.map(&:message_count)
      # the narrative still renders around them (assistant responses, etc.)
      assert_includes parser.entries.map(&:type), :assistant
    end

    test "an empty file parses to no entries and no crash" do
      parser = Parser.load(FIXTURES.join("empty.jsonl"))

      assert_empty parser.entries
      assert_nil parser.started_at
      assert_nil parser.estimated_cost
    end

    test "a 1s-resolution log without mono_ms reports wallclock_coarse timing" do
      parser = Parser.load(FIXTURES.join("complete.jsonl"))

      assert_equal "wallclock_coarse", parser.timing_source
      assert_nil parser.entries.first.mono_ms
    end

    test "an ms-resolution log without mono_ms reports wallclock timing and real sub-second durations" do
      parser = Parser.load(FIXTURES.join("wallclock_ms.jsonl"))

      assert_equal "wallclock", parser.timing_source

      tool  = parser.entries.find { |e| e.type == :tool }
      assert_equal 1000, tool.duration_ms

      turn_end = parser.entries.find { |e| e.type == :turn_end }
      assert_equal 1920, turn_end.duration_ms
    end

    test "a log with mono_ms reports monotonic timing and exact tool/model/turn durations" do
      parser = Parser.load(FIXTURES.join("monotonic.jsonl"))

      assert_equal "monotonic", parser.timing_source

      user, assistant1, tool, assistant2, turn_end = parser.entries
      assert_nil user.dt_ms # first entry has nothing to diff against

      assert_equal 120, assistant1.duration_ms # model latency: prompt -> first response
      assert_equal assistant1.dt_ms, assistant1.duration_ms

      assert_equal 2000, tool.duration_ms # exact tool_call -> tool_result round trip
      refute_equal tool.dt_ms, tool.duration_ms # dt_ms also carries the assistant's post-response overhead

      assert_equal 305, assistant2.duration_ms # model latency: tool_result -> second response
      assert_equal 2465, turn_end.duration_ms # whole-turn wall time
    end

    # ---- plan Amendment A: one file per run, task labelled -----------------

    test "a delegated sub-run parses as one session with task and depth on every entry" do
      parser = Parser.load(FIXTURES.join("delegated.jsonl"))

      assert_equal %i[user assistant task_start tool assistant turn_end task_end tool assistant turn_end],
                   parser.entries.map(&:type)
      assert(parser.entries.all? { |e| e.task.present? }, "every entry carries a task")

      inside  = parser.entries.select { |e| e.task == "room_inspector" }
      outside = parser.entries.select { |e| e.task == "player" }

      assert_equal [ 1 ], inside.map(&:depth).uniq
      assert_equal [ 0 ], outside.map(&:depth).uniq
      assert_equal "player", parser.root_task
      assert_equal %w[player room_inspector], parser.task_roster.sort
      assert_equal 1, parser.sub_runs
      assert_equal 0, parser.unclosed_tasks
    end

    test "task_start carries the sub-run's own configuration and task_end its duration" do
      parser = Parser.load(FIXTURES.join("delegated.jsonl"))

      start = parser.entries.find { |e| e.type == :task_start }
      assert_equal "room_inspector", start.task_name
      assert_equal "claude-haiku-4-5", start.model      # not the parent's opus
      assert_equal 12, start.max_iterations             # not the parent's 20

      finish = parser.entries.find { |e| e.type == :task_end }
      assert_equal 1000, finish.duration_ms             # mono 2100 -> 3100

      # The parent's own inspect_room tool entry measures the same interval from
      # outside; the difference is the subagent's startup overhead.
      outer = parser.entries.select { |e| e.type == :tool }.last
      assert_equal "inspect_room", outer.tool_name
      assert_equal 1100, outer.duration_ms
    end

    # The delegating call is still pending while the sub-run's own calls open and
    # close inside it, so FIFO pairing would hand each result the other one's
    # timestamps.
    test "a tool call that is still open while a sub-run runs pairs with its own result" do
      parser = Parser.load(FIXTURES.join("delegated.jsonl"))

      inner, outer = parser.entries.select { |e| e.type == :tool }

      assert_equal "tbamud__look", inner.tool_name
      assert_equal 480, inner.duration_ms   # mono 2120 -> 2600, not the outer call's 2010
      assert_equal 1, inner.depth
      assert_equal "inspect_room", outer.tool_name
      assert_equal 0, outer.depth
    end

    test "cost breaks down per task now that responses are attributed" do
      parser = Parser.load(FIXTURES.join("delegated.jsonl"))

      by_task = parser.cost_breakdown.to_h { |row| [ row[:task], row ] }

      assert_equal %w[player room_inspector], by_task.keys.sort
      assert_equal 2, by_task["player"][:calls]
      assert_equal 1, by_task["room_inspector"][:calls]
      assert_equal "claude-haiku-4-5", by_task["room_inspector"][:model]
      assert_in_delta 0.0006, by_task["room_inspector"][:cost], 0.00001
    end

    test "a session killed mid-sub-run parses, and the unclosed group is reported" do
      parser = Parser.load(FIXTURES.join("killed_mid_sub_run.jsonl"))

      assert_equal %i[user task_start], parser.entries.map(&:type)
      assert_equal 1, parser.sub_runs
      assert_equal 1, parser.unclosed_tasks, "the group never closed — say so rather than implying it did"
      assert_nil parser.entries.find { |e| e.type == :task_end }
    end

    # Sessions written before Amendment A carry no task/depth at all. They are
    # one unlabelled root task, which is exactly what they were.
    test "a pre-amendment log parses with no task labels and depth 0 throughout" do
      parser = Parser.load(FIXTURES.join("unknown_phase.jsonl"))

      assert_equal [ 0 ], parser.entries.map(&:depth).uniq
      assert_equal 0, parser.sub_runs
      assert_empty parser.task_roster
      assert_nil parser.root_task
    end
  end
end
