module Api
  module V1
    class ManagerController < ApplicationController
      include ActionController::Live

      POLL_INTERVAL      = 0.25
      HEARTBEAT_INTERVAL = 15

      DEFAULT_LIMIT = 500
      MAX_LIMIT     = 1000

      rescue_from ManagerLog::Store::NotFound, with: :render_not_found

      # GET /manager?date=&session=&mode=&after=&limit=
      def index
        path    = store.path_for(date_param)
        records = path ? filter(ManagerLog::Parser.load(path).records) : []
        after   = params[:after].to_i
        limit   = clamp_limit(params[:limit])

        pending = records.select { |r| r.seq > after }
        page    = pending.first(limit)

        render json: {
          entries: page.map { |r| ManagerRecordSerializer.call(r) },
          next_seq: page.last&.seq || after,
          eof: page.length == pending.length,
          live: path ? store.live?(path) : false
        }
      end

      # GET /manager/stream?date=&session=&mode=&after=   (text/event-stream)
      def stream
        path = store.path_for!(date_param)

        cfg.stream_gate.acquire { serve_stream(path) }
      rescue StreamGate::AtCapacity
        render json: { error: { code: "too_many_streams",
                                 message: "Max concurrent streams (#{cfg.max_streams}) reached" } },
               status: :service_unavailable
      end

      private

      def serve_stream(path)
        response.headers["Content-Type"]  = "text/event-stream"
        response.headers["Cache-Control"] = "no-cache"
        response.headers["X-Accel-Buffering"] = "no"

        sse           = ActionController::Live::SSE.new(response.stream, retry: 1000)
        follower      = ManagerLog::Follower.new(path)
        cursor        = (request.headers["Last-Event-ID"].presence || params[:after]).to_i
        last_beat     = Time.now
        last_activity = Time.now

        loop do
          new_records = filter(follower.records_after(cursor))

          if new_records.any?
            new_records.each do |record|
              sse.write(ManagerRecordSerializer.call(record), event: "entry", id: record.seq)
              cursor = record.seq
            end
            last_beat = last_activity = Time.now
          elsif Time.now - last_beat >= HEARTBEAT_INTERVAL
            sse.write({ at: Time.now.iso8601(3) }, event: "heartbeat")
            last_beat = Time.now
          end

          if Time.now - last_activity >= cfg.stream_idle_timeout
            sse.write({ reason: "session_end" }, event: "eof")
            break
          end

          sleep POLL_INTERVAL
        end
      rescue IOError, Errno::EPIPE
        # client disconnected mid-stream — nothing left to do
      ensure
        begin
          sse&.close
        rescue IOError
        end
      end

      def filter(records)
        records = records.select { |r| r.session == params[:session] } if params[:session].present?
        records = records.select { |r| r.mode == params[:mode] } if params[:mode].present?
        records
      end

      def date_param
        params[:date].presence || store.today
      end

      def clamp_limit(raw)
        limit = raw.presence&.to_i || DEFAULT_LIMIT
        limit.clamp(1, MAX_LIMIT)
      end

      def store
        @store ||= ManagerLog::Store.new(dir: cfg.manager_dir, live_window: cfg.live_window)
      end

      def cfg
        Rails.application.config.x.mud_monitor
      end

      def render_not_found(_error)
        render json: { error: { code: "not_found", message: "No manager log for #{date_param}" } },
               status: :not_found
      end
    end
  end
end
