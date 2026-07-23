require "test_helper"

module SessionLog
  class MessageTimelineTest < ActiveSupport::TestCase
    FIXTURES = Rails.root.join("test/fixtures/session_logs")

    # ---- request-mode: the definitive payload ------------------------------

    def request_timeline
      @request_timeline ||= MessageTimeline.load(FIXTURES.join("request_timeline.jsonl"))
    end

    test "builds one checkpoint per request event, marked as the definitive source" do
      cps = request_timeline.checkpoints

      assert_equal 4, cps.length
      assert_equal %w[request request request request], cps.map(&:source)
      assert_equal [ 1, 3, 4, 1 ], cps.map(&:message_count)
    end

    test "the first request carries the system prompt and full tool schemas" do
      cp = request_timeline.checkpoints.first

      assert_equal "claude-haiku-4-5", cp.model
      assert_equal 1024, cp.max_tokens
      assert_equal "You are a MUD player.", cp.system
      assert cp.system_changed
      assert_equal 2, cp.tool_count
      assert cp.tools_changed
      assert_equal %w[look move], cp.tools.map { |t| t["name"] }
    end

    test "unchanged system and tools are carried forward, not re-reported as changed" do
      cp = request_timeline.checkpoints[1]

      assert_equal "You are a MUD player.", cp.system   # carried from checkpoint 1
      refute cp.system_changed
      assert_equal 2, cp.tool_count                     # carried count
      refute cp.tools_changed
      assert_equal %w[look move], cp.tools.map { |t| t["name"] }
    end

    test "messages are the provider wire format — tool_result folded into a user block" do
      cp = request_timeline.checkpoints[1]

      assert_equal %w[user assistant user], cp.messages.map { |m| m["role"] }
      folded = cp.messages.last["content"].first
      assert_equal "tool_result", folded["type"]
      assert_equal "t1", folded["tool_use_id"]
    end

    test "a compaction that trims the front is reported as dropped-prefix with a marker" do
      cp = request_timeline.checkpoints[2]

      assert_equal 1, cp.dropped
      assert_equal 2, cp.carried
      assert_equal "compaction", cp.marker
    end

    test "a clear reads as everything dropped and everything new" do
      cp = request_timeline.checkpoints[3]

      assert_equal 4, cp.dropped
      assert_equal 0, cp.carried
      assert_equal "clear", cp.marker
      assert_equal [ { "role" => "user", "content" => "new" } ], cp.messages
    end

    test "turn and iteration are stamped from the surrounding events" do
      turns = request_timeline.checkpoints.map { |c| [ c.turn, c.iteration ] }

      assert_equal [ [ 0, 1 ], [ 0, 2 ], [ 0, 3 ], [ 1, 1 ] ], turns
    end

    # ---- legacy fallback: prompt-only logs ---------------------------------

    def prompt_timeline
      @prompt_timeline ||= MessageTimeline.load(FIXTURES.join("messages_timeline.jsonl"))
    end

    test "falls back to prompt events when a log has no request events" do
      cps = prompt_timeline.checkpoints

      assert_equal 4, cps.length
      assert_equal %w[prompt prompt prompt prompt], cps.map(&:source)
      assert_nil cps.first.system         # a reconstruction has no system prompt
      assert_nil cps.first.tools
    end

    test "prompt fallback still computes deltas, compaction and clear markers" do
      cps = prompt_timeline.checkpoints

      assert_equal [ 1, 3, 4, 1 ], cps.map(&:message_count)
      assert_equal "compaction", cps[2].marker
      assert_equal 1, cps[2].dropped
      assert_equal "clear", cps[3].marker
    end

    test "a truncated final request line is skipped rather than raised" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "partial.jsonl")
        File.write(path, <<~JSONL)
          {"phase":"request","messages":[{"role":"user","content":"hi"}],"system":"S","tools":[],"at":"2026-07-23T10:00:00-04:00"}
          {"phase":"request","messages":[{"role":"user","con
        JSONL

        tl = MessageTimeline.load(path)
        assert_equal 1, tl.checkpoints.length
        assert_equal "request", tl.checkpoints.first.source
      end
    end
  end
end
