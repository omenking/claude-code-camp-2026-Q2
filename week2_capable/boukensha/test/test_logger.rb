require_relative "helper"
require "json"

# mud_monitor spec §4.1: `at` gains millisecond resolution and every event
# carries a monotonic `mono_ms`, so cross-layer joins (telnet/manager/agent)
# compare like with like and durations survive NTP steps / DST.
class TestLogger < Minitest::Test
  def test_write_log_stamps_millisecond_at_and_monotonic_mono_ms
    Dir.mktmpdir do |dir|
      path = File.join(dir, "session.jsonl")
      logger = Boukensha::Logger.new(session_id: "test", log: path)
      logger.turn(n: 0)
      logger.close

      lines = File.readlines(path).map { |l| JSON.parse(l) }
      turn_event = lines.find { |e| e["phase"] == "turn" }

      assert_match(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}/, turn_event["at"])
      assert_kind_of Integer, turn_event["mono_ms"]
    end
  end

  def test_mono_ms_is_non_decreasing_across_events
    Dir.mktmpdir do |dir|
      path = File.join(dir, "session.jsonl")
      logger = Boukensha::Logger.new(session_id: "test", log: path)
      logger.turn(n: 0)
      logger.turn(n: 1)
      logger.close

      mono = File.readlines(path).map { |l| JSON.parse(l)["mono_ms"] }

      assert_equal mono.sort, mono
    end
  end

  # --- Amendment A: the task stack ----------------------------------------

  def test_every_event_carries_the_root_task_at_depth_zero
    events = capture do |logger|
      logger.turn(n: 0)
      logger.tool_call(name: "look", args: {})
    end

    assert_equal %w[player player player], events.map { |e| e["task"] }
    assert_equal [ 0, 0, 0 ], events.map { |e| e["depth"] }
  end

  def test_task_brackets_a_sub_run_and_labels_only_its_events
    events = capture do |logger|
      logger.turn(n: 0)
      logger.task("room_inspector", snapshot: { model: "claude-haiku-4-5", max_iterations: 12 }) do
        logger.tool_call(name: "tbamud__look", args: {})
      end
      logger.tool_result(name: "inspect_room", result: "{}")
    end

    labelled = events.map { |e| [ e["phase"], e["task"], e["depth"] ] }

    assert_equal [
      [ "session_start", "player",         0 ],
      [ "turn",          "player",         0 ],
      [ "task_start",    "room_inspector", 1 ],
      [ "tool_call",     "room_inspector", 1 ],
      [ "task_end",      "room_inspector", 1 ],
      [ "tool_result",   "player",         0 ]
    ], labelled

    start = events.find { |e| e["phase"] == "task_start" }
    assert_equal "room_inspector", start["task_name"]
    assert_equal 12, start["max_iterations"]   # the sub-run's own config, not the parent's
  end

  def test_task_returns_the_blocks_value
    capture { |logger| assert_equal "json", logger.task("room_inspector") { "json" } }
  end

  def test_nested_delegation_reaches_depth_two_and_unwinds
    events = capture do |logger|
      logger.task("room_inspector") do
        logger.task("appraiser") { logger.turn(n: 1) }
      end
      logger.turn(n: 2)
    end

    depths = events.each_with_object({}) { |e, h| (h[e["phase"]] ||= []) << e["depth"] }

    assert_equal [ 2 ], depths["turn"].first(1)   # innermost event
    assert_equal 0, events.last["depth"]           # stack fully unwound
    assert_equal "player", events.last["task"]
  end

  # The regression that mislabels everything after a failed sub-run: without
  # `ensure`, the stack would never pop and the player's later events would be
  # filed under room_inspector.
  def test_a_raise_inside_a_sub_run_still_closes_the_group_and_pops
    events = capture do |logger|
      assert_raises(RuntimeError) do
        logger.task("room_inspector") { raise "subagent blew up" }
      end
      logger.turn(n: 1)
    end

    assert_equal "task_end", events[-2]["phase"]
    assert_equal [ "player", 0 ], [ events[-1]["task"], events[-1]["depth"] ]
  end

  def test_current_task_reports_what_is_running_now
    capture do |logger|
      assert_equal "player", logger.current_task
      logger.task("room_inspector") { assert_equal "room_inspector", logger.current_task }
      assert_equal "player", logger.current_task
    end
  end

  private

  def capture
    Dir.mktmpdir do |dir|
      path   = File.join(dir, "session.jsonl")
      logger = Boukensha::Logger.new(session_id: "test", log: path)
      begin
        yield logger
      ensure
        logger.close
      end
      return File.readlines(path).map { |l| JSON.parse(l) }
    end
  end
end
