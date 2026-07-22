module Api
  module V1
    class DiffsController < ApplicationController
      DEFAULT_SESSION = "default"

      # GET /diffs/dropped?date=&session=&from=&to=
      #
      # telnet - manager, computed at read time (spec §3.6): nothing in
      # mud_manager reports on itself, so this is the only place the loss
      # from §0.2 becomes visible. Scoped to one MUD session because the
      # byte-alignment only holds within a single connection's stream — mixing
      # two sessions' inbound text would break the substring match.
      def dropped
        date = date_param

        telnet_records  = load(telnet_store, date) { |path| TelnetLog::Parser.load(path).records }
        manager_records = load(manager_store, date) { |path| ManagerLog::Parser.load(path).records }

        result = Diff::TelnetManager.call(
          telnet_records: within_window(telnet_records),
          manager_records: within_window(manager_records),
          session: params[:session].presence || DEFAULT_SESSION
        )

        render json: {
          dropped: result[:dropped].map { |d| DroppedSerializer.call(d) },
          summary: result[:summary]
        }
      end

      private

      def load(store, date)
        path = store.path_for(date)
        path ? yield(path) : []
      end

      def within_window(records)
        from = parse_time(params[:from])
        to   = parse_time(params[:to])
        return records unless from || to

        records.select do |r|
          t = parse_time(r.at)
          t && (from.nil? || t >= from) && (to.nil? || t <= to)
        end
      end

      def parse_time(value)
        value.present? ? Time.iso8601(value) : nil
      rescue ArgumentError
        nil
      end

      def date_param
        params[:date].presence || manager_store.today
      end

      def telnet_store
        @telnet_store ||= TelnetLog::Store.new(dir: cfg.telnet_dir, live_window: cfg.live_window)
      end

      def manager_store
        @manager_store ||= ManagerLog::Store.new(dir: cfg.manager_dir, live_window: cfg.live_window)
      end

      def cfg
        Rails.application.config.x.mud_monitor
      end
    end
  end
end
