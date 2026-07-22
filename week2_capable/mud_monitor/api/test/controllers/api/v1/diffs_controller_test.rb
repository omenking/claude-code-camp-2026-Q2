require "test_helper"

module Api
  module V1
    class DiffsControllerTest < ActionDispatch::IntegrationTest
      FIXTURE_DATE = "20260723"

      setup do
        cfg = Rails.application.config.x.mud_monitor
        @previous_telnet_dir  = cfg.telnet_dir
        @previous_manager_dir = cfg.manager_dir
        cfg.telnet_dir  = Pathname.new(Rails.root.join("test/fixtures/telnet_logs"))
        cfg.manager_dir = Pathname.new(Rails.root.join("test/fixtures/manager_logs"))
      end

      teardown do
        cfg = Rails.application.config.x.mud_monitor
        cfg.telnet_dir  = @previous_telnet_dir
        cfg.manager_dir = @previous_manager_dir
      end

      test "reports every gap for the date, defaulting to the default session" do
        get api_v1_diffs_dropped_path, params: { date: FIXTURE_DATE }

        assert_response :success
        body = response.parsed_body
        assert_equal 4, body["dropped"].length
        assert_equal 4, body["summary"]["dropped_runs"]
      end

      test "each dropped entry carries its cause, byte-rendered text, and manager-seq boundary" do
        get api_v1_diffs_dropped_path, params: { date: FIXTURE_DATE }

        login_gap = response.parsed_body["dropped"].first
        assert_equal "login", login_gap["cause"]
        assert_nil login_gap["between"]["after_manager_seq"]
        assert_equal 1, login_gap["between"]["before_manager_seq"]
        assert_equal [ 1 ], login_gap["telnet_seqs"]
        assert_equal "\r\nWelcome to CircleMUD!\r\n", login_gap["text"]
        assert login_gap["text_html"].present?
      end

      test "drop_ratio is the fraction of inbound bytes never returned to a tool call" do
        get api_v1_diffs_dropped_path, params: { date: FIXTURE_DATE }

        summary = response.parsed_body["summary"]
        total = summary["dropped_bytes"] + summary["received_bytes"]
        assert_in_delta summary["dropped_bytes"].to_f / total, summary["drop_ratio"], 0.0001
      end

      test "unknown session filters out all traffic, yielding no gaps" do
        get api_v1_diffs_dropped_path, params: { date: FIXTURE_DATE, session: "nobody_here" }

        assert_response :success
        assert_equal [], response.parsed_body["dropped"]
        assert_nil response.parsed_body["summary"]["drop_ratio"]
      end

      test "no telnet or manager log for the date renders an empty, non-erroring diff" do
        get api_v1_diffs_dropped_path, params: { date: "20200101" }

        assert_response :success
        assert_equal [], response.parsed_body["dropped"]
        assert_equal 0, response.parsed_body["summary"]["dropped_bytes"]
      end

      test "malformed date is treated as no data rather than raising" do
        get api_v1_diffs_dropped_path, params: { date: "not-a-date" }

        assert_response :success
        assert_equal [], response.parsed_body["dropped"]
      end

      test "from/to narrows the window before diffing" do
        get api_v1_diffs_dropped_path,
            params: { date: FIXTURE_DATE, from: "2026-07-23T12:00:00-04:00", to: "2026-07-23T12:00:04-04:00" }

        assert_response :success
        # Only the login gap (seq 1) and the pre_command_drain gap (seq 4)
        # fall entirely inside this window.
        seqs = response.parsed_body["dropped"].flat_map { |d| d["telnet_seqs"] }
        assert_equal [ 1, 4 ], seqs
      end
    end
  end
end
