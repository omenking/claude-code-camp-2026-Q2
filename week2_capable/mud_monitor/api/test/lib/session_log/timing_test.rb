require "test_helper"

module SessionLog
  class TimingTest < ActiveSupport::TestCase
    FIXTURES = Rails.root.join("test/fixtures/session_logs")

    test "summary rolls up tool/model percentiles, idle time, and wall vs busy time" do
      parser  = Parser.load(FIXTURES.join("monotonic.jsonl"))
      summary = Timing.new(parser).summary

      assert_equal 2000, summary[:p50_tool_ms]
      assert_equal 2000, summary[:p95_tool_ms]
      assert_equal 305, summary[:p50_model_ms]
      assert_equal 305, summary[:p95_model_ms]
      assert_equal 0, summary[:total_idle_ms] # no gap exceeds the 5s idle threshold
      assert_equal 2465, summary[:wall_ms]
      assert_equal 2465, summary[:busy_ms] # wall_ms - total_idle_ms, and idle is 0 here
    end

    test "an empty session reports nil rollups instead of crashing" do
      parser  = Parser.load(FIXTURES.join("empty.jsonl"))
      summary = Timing.new(parser).summary

      assert_nil summary[:p50_tool_ms]
      assert_nil summary[:p50_model_ms]
      assert_equal 0, summary[:total_idle_ms]
      assert_nil summary[:wall_ms]
      assert_nil summary[:busy_ms]
    end
  end
end
