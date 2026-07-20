require "yaml"

module MudManager
  module Mcp
    # Connection config for the daemon. Per plan §5, credentials are a
    # *framework* concern — they come from env/config, NEVER from LLM tool
    # args. Resolution order (first non-nil wins):
    #
    #   1. explicit keyword (used by tests / the raw connect op)
    #   2. environment: MUD_HOST / MUD_PORT / MUD_NAME / MUD_PASSWORD
    #   3. ~/.boukensha/settings.yaml `mud:` block (BOUKENSHA_DIR overrides dir),
    #      so a bootcamper who already configured boukensha needs no extra setup
    #   4. built-in defaults (localhost:4000) for host/port only
    #
    Config = Struct.new(:host, :port, :name, :password, keyword_init: true) do
      def self.resolve(host: nil, port: nil, name: nil, password: nil)
        y = boukensha_mud
        new(
          host:     host     || ENV["MUD_HOST"]                    || y["host"] || "localhost",
          port:     (port    || ENV["MUD_PORT"]                    || y["port"] || 4000).to_i,
          name:     name     || ENV["MUD_NAME"] || ENV["MUD_USER"] || y["username"],
          password: password || ENV["MUD_PASSWORD"]                || y["password"]
        )
      end

      def self.boukensha_mud
        dir  = ENV.fetch("BOUKENSHA_DIR", File.join(Dir.home, ".boukensha"))
        file = File.join(File.expand_path(dir), "settings.yaml")
        return {} unless File.exist?(file)
        data = YAML.safe_load(File.read(file)) || {}
        mud  = data["mud"] || data[:mud] || {}
        mud.transform_keys(&:to_s)
      rescue StandardError
        {}
      end

      def credentials?
        !name.to_s.empty? && !password.to_s.empty?
      end

      def to_h_safe
        { host: host, port: port, name: name, password: password ? "***" : nil }
      end
    end
  end
end
