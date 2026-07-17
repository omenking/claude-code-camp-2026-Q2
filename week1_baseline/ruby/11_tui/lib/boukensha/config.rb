require "yaml"
require "dotenv"
require "pathname"

module Boukensha
  class Config
    # The .boukensha config directory is resolved in this order:
    #   1. BOUKENSHA_DIR environment variable (set before loading .env)
    #   2. ~/.boukensha  (default)
    DEFAULT_DIR = File.join(Dir.home, ".boukensha").freeze

    # Default prompts shipped alongside this step.
    PROMPTS_DIR = File.expand_path("../../../prompts", __dir__).freeze

    attr_reader :dir, :settings

    def initialize
      @dir = resolve_dir
      load_env
      @settings = load_settings
    end

    # ---------- tasks -----------------------------------------------------

    # With no argument: returns the full tasks hash from settings.yaml.
    # With a name: returns that task's settings hash, e.g. tasks(:player).
    def tasks(name = nil)
      all = dig(:tasks) || {}
      name ? (all[name.to_s] || all[name.to_sym]) : all
    end

    # The user's prompts directory for task prompt overrides.
    def user_prompts_dir
      File.join(@dir, "prompts")
    end

    # ---------- MCP servers ------------------------------------------------

    # MCP servers to plug into the agent, keyed by name. This is where ALL of
    # the agent's tools come from — boukensha ships none of its own:
    #
    #   mcp_servers:
    #     mud:
    #       command: mud-manager
    #       args:    [--mcp]
    #       prefix:  tbamud
    #       env:
    #         MUD_HOST: your.mud.host      # a stdio server's credentials
    #         MUD_NAME: Gandalf            # travel by environment
    #
    # Returns { "mud" => { command:, args:, env:, prefix:, required: } } with
    # defaults applied. `required: false` lets a server fail to spawn without
    # taking the agent down with it.
    def mcp_servers
      (dig(:mcp_servers) || {}).each_with_object({}) do |(name, raw), out|
        entry = raw.is_a?(Hash) ? raw : {}
        get   = ->(k) { entry[k.to_s].nil? ? entry[k.to_sym] : entry[k.to_s] }
        req   = get.call(:required)

        out[name.to_s] = {
          command:  get.call(:command).to_s,
          args:     Array(get.call(:args)).map(&:to_s),
          env:      (get.call(:env) || {}).each_with_object({}) { |(k, v), h| h[k.to_s] = v.to_s },
          prefix:   get.call(:prefix)&.to_s,
          required: req.nil? ? true : !!req
        }
      end
    end

    # ---------- low-level helpers -----------------------------------------

    # Fetch a nested key path from settings, e.g. dig(:mud, :host)
    def dig(*keys)
      keys.reduce(@settings) do |node, key|
        case node
        when Hash then node[key.to_s] || node[key.to_sym]
        else nil
        end
      end
    end

    def to_s
      "#<Boukensha::Config dir=#{@dir} tasks=#{tasks.keys.join(',')}>"
    end

    def inspect = to_s

    private

    def resolve_dir
      raw = ENV.fetch("BOUKENSHA_DIR", nil) || DEFAULT_DIR
      Pathname.new(raw).expand_path.to_s
    end

    def load_env
      env_file = File.join(@dir, ".env")
      if File.exist?(env_file)
        Dotenv.load(env_file)
      end
    end

    def load_settings
      settings_file = File.join(@dir, "settings.yaml")
      if File.exist?(settings_file)
        YAML.safe_load(File.read(settings_file)) || {}
      else
        {}
      end
    end
  end
end
