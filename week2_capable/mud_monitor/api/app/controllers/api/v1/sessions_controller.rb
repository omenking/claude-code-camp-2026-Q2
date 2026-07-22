module Api
  module V1
    class SessionsController < ApplicationController
      include ActionController::Live

      # §3.3: how often the stream action checks the file for new entries,
      # and how often it sends a heartbeat frame when nothing new arrived —
      # keeps intermediate proxies and idle browser tabs from timing the
      # connection out.
      POLL_INTERVAL     = 0.25
      HEARTBEAT_INTERVAL = 15

      DEFAULT_LIMIT = 500
      MAX_LIMIT     = 1000

      rescue_from SessionLog::Store::NotFound, with: :render_not_found

      def index
        sessions = store.paths.map { |path| serializer_for(path).summary }
        render json: { sessions: sessions }
      end

      def show
        path   = store.path_for(params[:id])
        render json: serializer_for(path).detail
      end

      # GET /sessions/:id/events?after=<seq>&limit=<n>
      def events
        path    = store.path_for(params[:id])
        parser  = SessionLog::Parser.load(path)
        after   = params[:after].to_i
        limit   = clamp_limit(params[:limit])

        pending = parser.entries.select { |e| e.seq > after }
        page    = pending.first(limit)

        render json: {
          entries: page.map { |e| EntrySerializer.call(e) },
          next_seq: page.last&.seq || after,
          eof: page.length == pending.length,
          live: store.live?(path)
        }
      end

      # GET /sessions/:id/stream?after=<seq>          (text/event-stream)
      def stream
        path = store.path_for(params[:id])

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
        follower      = SessionLog::Follower.new(path)
        cursor        = (request.headers["Last-Event-ID"].presence || params[:after]).to_i
        last_beat     = Time.now
        last_activity = Time.now

        loop do
          new_entries = follower.entries_after(cursor)

          if new_entries.any?
            new_entries.each do |entry|
              sse.write(EntrySerializer.call(entry), event: "entry", id: entry.seq)
              cursor = entry.seq
            end
            sse.write(session_summary(follower.parser, path), event: "session")
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

      def session_summary(parser, path)
        SessionSerializer.new(parser, live: store.live?(path), bytes: File.size(path)).summary
      end

      def clamp_limit(raw)
        limit = raw.presence&.to_i || DEFAULT_LIMIT
        limit.clamp(1, MAX_LIMIT)
      end

      def store
        @store ||= SessionLog::Store.new(dir: cfg.sessions_dir, live_window: cfg.live_window)
      end

      def cfg
        Rails.application.config.x.mud_monitor
      end

      def serializer_for(path)
        parser = SessionLog::Parser.load(path)
        SessionSerializer.new(parser, live: store.live?(path), bytes: File.size(path))
      end

      def render_not_found(_error)
        render json: { error: { code: "not_found", message: "Session not found: #{params[:id]}" } },
               status: :not_found
      end
    end
  end
end
