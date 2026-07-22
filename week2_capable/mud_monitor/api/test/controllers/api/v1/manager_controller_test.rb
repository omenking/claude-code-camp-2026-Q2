require "test_helper"

module Api
  module V1
    class ManagerControllerTest < ActionDispatch::IntegrationTest
      FIXTURE_DATE = "20260722"

      setup do
        @previous_dir = Rails.application.config.x.mud_monitor.manager_dir
        Rails.application.config.x.mud_monitor.manager_dir =
          Pathname.new(Rails.root.join("test/fixtures/manager_logs"))
      end

      teardown do
        Rails.application.config.x.mud_monitor.manager_dir = @previous_dir
      end

      test "index lists every exchange for the requested date" do
        get api_v1_manager_path, params: { date: FIXTURE_DATE }

        assert_response :success
        body = response.parsed_body
        assert_equal 6, body["entries"].length
        assert_equal 6, body["next_seq"]
        assert body["eof"]
      end

      test "index returns an empty, non-erroring list when no file exists for the date" do
        get api_v1_manager_path, params: { date: "20200101" }

        assert_response :success
        body = response.parsed_body
        assert_equal [], body["entries"]
        assert body["eof"]
        assert_not body["live"]
      end

      test "index filters by mode" do
        get api_v1_manager_path, params: { date: FIXTURE_DATE, mode: "command" }

        assert_response :success
        modes = response.parsed_body["entries"].map { |e| e["mode"] }.uniq
        assert_equal [ "command" ], modes
        assert_equal [ 2, 3, 6 ], response.parsed_body["entries"].map { |e| e["seq"] }
      end

      test "index filters by session" do
        get api_v1_manager_path, params: { date: FIXTURE_DATE, session: "room_inspector" }

        assert_response :success
        assert_equal [ 5 ], response.parsed_body["entries"].map { |e| e["seq"] }
      end

      test "index pages through entries newer than `after`, clamped to `limit`" do
        get api_v1_manager_path, params: { date: FIXTURE_DATE, after: 0, limit: 2 }

        assert_response :success
        body = response.parsed_body
        assert_equal [ 1, 2 ], body["entries"].map { |e| e["seq"] }
        assert_equal 2, body["next_seq"]
        assert_not body["eof"]
      end

      test "index carries the tool call and its raw sent/received text" do
        get api_v1_manager_path, params: { date: FIXTURE_DATE, mode: "command" }

        look = response.parsed_body["entries"].find { |e| e["seq"] == 2 }
        assert_equal "tbamud__look", look["tool"]
        assert_equal "look", look["sent"]
        assert_includes look["received"], "Common Square"
        assert look["received_html"].present?
      end

      test "index surfaces a captured error without a received payload" do
        get api_v1_manager_path, params: { date: FIXTURE_DATE, mode: "command" }

        failed = response.parsed_body["entries"].find { |e| e["seq"] == 6 }
        assert_nil failed["received"]
        assert_match(/ConnectionError/, failed["error"])
      end

      test "malformed date is treated as no data rather than raising" do
        get api_v1_manager_path, params: { date: "not-a-date" }

        assert_response :success
        assert_equal [], response.parsed_body["entries"]
      end

      test "stream 404s when no manager log exists for the date" do
        get api_v1_manager_stream_path, params: { date: "20200101" }

        assert_response :not_found
      end

      test "stream flushes pending entries as SSE frames, then sends eof once idle" do
        cfg = Rails.application.config.x.mud_monitor
        previous_timeout = cfg.stream_idle_timeout
        cfg.stream_idle_timeout = 0

        begin
          get api_v1_manager_stream_path, params: { date: FIXTURE_DATE, after: 3 }

          assert_response :success
          assert_equal "text/event-stream", response.media_type
          assert_includes response.body, "event: entry"
          assert_includes response.body, "id: 4"
          assert_includes response.body, "id: 5"
          assert_includes response.body, "event: eof"
          assert_not_includes response.body, "id: 3"
        ensure
          cfg.stream_idle_timeout = previous_timeout
        end
      end

      test "stream responds 503 when the concurrent stream cap is already reached" do
        cfg = Rails.application.config.x.mud_monitor
        previous_gate = cfg.stream_gate
        cfg.stream_gate = StreamGate.new(max: 0)

        begin
          get api_v1_manager_stream_path, params: { date: FIXTURE_DATE }

          assert_response :service_unavailable
          assert_equal "too_many_streams", response.parsed_body["error"]["code"]
        ensure
          cfg.stream_gate = previous_gate
        end
      end
    end
  end
end
