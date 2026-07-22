require "test_helper"

module Diff
  class TelnetManagerTest < ActiveSupport::TestCase
    def telnet(seq:, dir:, text:, session: "default", at: "2026-07-22T12:00:0#{seq}.000-04:00")
      TelnetLog::Parser::Record.new(seq: seq, at: at, mono_ms: seq * 100, session: session,
                                     dir: dir, bytes: text.bytesize, text: text, redacted: false)
    end

    def manager(seq:, mode:, sent:, received:, session: "default", at: "2026-07-22T12:00:1#{seq}.000-04:00")
      ManagerLog::Parser::Record.new(seq: seq, at: at, mono_ms: seq * 100, session: session, mode: mode,
                                      tool: nil, args: nil, correlation_id: nil, sent: sent,
                                      received: received, bytes_in: received.to_s.bytesize,
                                      elapsed_ms: 10, error: nil)
    end

    # Synthetic stream covering all three causes plus a trailing gap with no
    # following command at all — the login banner and the very end of the
    # log, per spec §10.
    setup do
      @telnet = [
        telnet(seq: 1, dir: "in",  text: "\r\nWelcome to CircleMUD!\r\n"),
        telnet(seq: 2, dir: "out", text: "look"),
        telnet(seq: 3, dir: "in",  text: "The Common Square\r\n> "),
        telnet(seq: 4, dir: "in",  text: "\r\nThe Mayor arrives.\r\n"),
        telnet(seq: 5, dir: "out", text: "north"),
        telnet(seq: 6, dir: "in",  text: "You walk north.\r\n> "),
        telnet(seq: 7, dir: "in",  text: "\r\nA goblin snarls.\r\n"),
        telnet(seq: 8, dir: "in",  text: "20H 100M > "),
        telnet(seq: 9, dir: "in",  text: "\r\nTrailing chatter after everything.\r\n")
      ]
      @manager = [
        manager(seq: 1, mode: "command", sent: "look", received: "The Common Square\r\n> "),
        manager(seq: 2, mode: "command", sent: "north", received: "You walk north.\r\n> "),
        manager(seq: 3, mode: "poll", sent: nil, received: "20H 100M > ")
      ]
    end

    test "finds exactly the four gaps, in order" do
      result = TelnetManager.call(telnet_records: @telnet, manager_records: @manager, session: "default")

      texts = result[:dropped].map(&:text)
      assert_equal [
        "\r\nWelcome to CircleMUD!\r\n",
        "\r\nThe Mayor arrives.\r\n",
        "\r\nA goblin snarls.\r\n",
        "\r\nTrailing chatter after everything.\r\n"
      ], texts
    end

    test "tags the login-dance gap, before any manager record" do
      login_gap = TelnetManager.call(telnet_records: @telnet, manager_records: @manager, session: "default")[:dropped].first

      assert_equal "login", login_gap.cause
      assert_nil login_gap.after_manager_seq
      assert_equal 1, login_gap.before_manager_seq
      assert_equal [ 1 ], login_gap.telnet_seqs
    end

    test "tags a gap ending right before an outbound send as pre_command_drain" do
      gap = TelnetManager.call(telnet_records: @telnet, manager_records: @manager, session: "default")[:dropped][1]

      assert_equal "pre_command_drain", gap.cause
      assert_equal 1, gap.after_manager_seq
      assert_equal 2, gap.before_manager_seq
      assert_equal [ 4 ], gap.telnet_seqs
    end

    test "tags a gap not immediately followed by an outbound send as post_prompt_leftover" do
      gap = TelnetManager.call(telnet_records: @telnet, manager_records: @manager, session: "default")[:dropped][2]

      assert_equal "post_prompt_leftover", gap.cause
      assert_equal 2, gap.after_manager_seq
      assert_equal 3, gap.before_manager_seq
    end

    test "tags trailing chatter after the last exchange, with no following command" do
      gap = TelnetManager.call(telnet_records: @telnet, manager_records: @manager, session: "default")[:dropped].last

      assert_equal "post_prompt_leftover", gap.cause
      assert_equal 3, gap.after_manager_seq
      assert_nil gap.before_manager_seq
    end

    test "summary totals reconcile: dropped + received bytes account for every inbound byte" do
      summary = TelnetManager.call(telnet_records: @telnet, manager_records: @manager, session: "default")[:summary]

      inbound_bytes = @telnet.select { |r| r.dir == "in" }.sum { |r| r.text.bytesize }
      assert_equal inbound_bytes, summary[:dropped_bytes] + summary[:received_bytes]
      assert_equal 4, summary[:dropped_runs]
      assert_in_delta summary[:dropped_bytes].to_f / inbound_bytes, summary[:drop_ratio], 0.0001
    end

    test "scopes to the requested session, ignoring another session's telnet/manager traffic" do
      telnet = @telnet + [ telnet(seq: 10, dir: "in", text: "should be invisible", session: "room_inspector") ]
      manager = @manager + [
        manager(seq: 4, mode: "raw", sent: "score", received: "should be invisible", session: "room_inspector")
      ]

      result = TelnetManager.call(telnet_records: telnet, manager_records: manager, session: "default")

      assert_equal 4, result[:dropped].length
      refute(result[:dropped].any? { |d| d.text.include?("invisible") })
    end

    test "an empty session produces no dropped runs and a nil drop_ratio" do
      result = TelnetManager.call(telnet_records: [], manager_records: [], session: "default")

      assert_equal [], result[:dropped]
      assert_nil result[:summary][:drop_ratio]
      assert_equal 0, result[:summary][:dropped_bytes]
    end

    test "a manager record whose received text isn't found in the telnet stream is skipped, not raised" do
      manager = @manager + [
        manager(seq: 4, mode: "raw", sent: "score", received: "text the telnet log never captured")
      ]

      result = TelnetManager.call(telnet_records: @telnet, manager_records: manager, session: "default")

      assert_equal 4, result[:dropped].length
    end
  end
end
