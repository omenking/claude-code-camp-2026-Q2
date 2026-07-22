module Api
  module V1
    class HealthController < ApplicationController
      def show
        cfg = Rails.application.config.x.mud_monitor

        render json: {
          ok: true,
          # Reported so a "logging is off" answer can be told apart from
          # "monitor is looking in the wrong .boukensha".
          boukensha_dir: cfg.boukensha_dir.to_s,
          telnet_dir: cfg.telnet_dir.to_s,
          manager_dir: cfg.manager_dir.to_s,
          sessions_dir: cfg.sessions_dir.to_s,
          telnet_logging_enabled: cfg.telnet_dir.directory?,
          manager_logging_enabled: cfg.manager_dir.directory?,
          world_ready: cfg.world_dir.directory? && !cfg.world_dir.children.empty?,
          knowledge_attached: cfg.knowledge_db.file?,
          live_sessions: live_session_count(cfg)
        }
      end

      private

      def live_session_count(cfg)
        return 0 unless cfg.sessions_dir.directory?

        cutoff = Time.now - cfg.live_window
        cfg.sessions_dir.glob("*.jsonl").count { |f| f.mtime >= cutoff }
      end
    end
  end
end
