require "test_helper"

module Api
  module V1
    class TelnetControllerTest < ActionDispatch::IntegrationTest
      FIXTURE_DATE = "20260722"

      setup do
        @previous_dir = Rails.application.config.x.mud_monitor.telnet_dir
        Rails.application.config.x.mud_monitor.telnet_dir =
          Pathname.new(Rails.root.join("test/fixtures/telnet_logs"))
      end

      teardown do
        Rails.application.config.x.mud_monitor.telnet_dir = @previous_dir
      end

      test "index lists every chunk for the requested date" do
        get api_v1_telnet_path, params: { date: FIXTURE_DATE }

        assert_response :success
        body = response.parsed_body
        assert_equal 8, body["entries"].length
        assert_equal 8, body["next_seq"]
        assert body["eof"]
      end

      test "index returns an empty, non-erroring list when no file exists for the date" do
        get api_v1_telnet_path, params: { date: "20200101" }

        assert_response :success
        body = response.parsed_body
        assert_equal [], body["entries"]
        assert body["eof"]
        assert_not body["live"]
      end

      test "index filters by dir" do
        get api_v1_telnet_path, params: { date: FIXTURE_DATE, dir: "out" }

        assert_response :success
        dirs = response.parsed_body["entries"].map { |e| e["dir"] }.uniq
        assert_equal [ "out" ], dirs
        assert_equal [ 1, 3, 5, 8 ], response.parsed_body["entries"].map { |e| e["seq"] }
      end

      test "index filters by session" do
        get api_v1_telnet_path, params: { date: FIXTURE_DATE, session: "room_inspector" }

        assert_response :success
        assert_equal [ 8 ], response.parsed_body["entries"].map { |e| e["seq"] }
      end

      test "index pages through entries newer than `after`, clamped to `limit`" do
        get api_v1_telnet_path, params: { date: FIXTURE_DATE, after: 0, limit: 2 }

        assert_response :success
        body = response.parsed_body
        assert_equal [ 1, 2 ], body["entries"].map { |e| e["seq"] }
        assert_equal 2, body["next_seq"]
        assert_not body["eof"]
      end

      test "a redacted record never exposes the real text over the API" do
        get api_v1_telnet_path, params: { date: FIXTURE_DATE }

        password = response.parsed_body["entries"].find { |e| e["seq"] == 3 }
        assert password["redacted"]
        assert_equal "<redacted>", password["text"]
        assert_not_includes response.body, "secret"
      end

      test "index carries an ANSI-rendered html companion field" do
        get api_v1_telnet_path, params: { date: FIXTURE_DATE }

        look_reply = response.parsed_body["entries"].find { |e| e["seq"] == 6 }
        assert_includes look_reply["text_html"], "Common Square"
        assert look_reply["text_html"].present?
      end

      test "malformed date is treated as no data rather than raising" do
        get api_v1_telnet_path, params: { date: "not-a-date" }

        assert_response :success
        assert_equal [], response.parsed_body["entries"]
      end

      test "stream 404s when no telnet log exists for the date" do
        get api_v1_telnet_stream_path, params: { date: "20200101" }

        assert_response :not_found
      end

      test "stream flushes pending entries as SSE frames, then sends eof once idle" do
        cfg = Rails.application.config.x.mud_monitor
        previous_timeout = cfg.stream_idle_timeout
        cfg.stream_idle_timeout = 0

        begin
          get api_v1_telnet_stream_path, params: { date: FIXTURE_DATE, after: 6 }

          assert_response :success
          assert_equal "text/event-stream", response.media_type
          assert_includes response.body, "event: entry"
          assert_includes response.body, "id: 7"
          assert_includes response.body, "id: 8"
          assert_includes response.body, "event: eof"
          assert_not_includes response.body, "id: 6"
        ensure
          cfg.stream_idle_timeout = previous_timeout
        end
      end

      test "stream responds 503 when the concurrent stream cap is already reached" do
        cfg = Rails.application.config.x.mud_monitor
        previous_gate = cfg.stream_gate
        cfg.stream_gate = StreamGate.new(max: 0)

        begin
          get api_v1_telnet_stream_path, params: { date: FIXTURE_DATE }

          assert_response :service_unavailable
          assert_equal "too_many_streams", response.parsed_body["error"]["code"]
        ensure
          cfg.stream_gate = previous_gate
        end
      end
    end
  end
end
