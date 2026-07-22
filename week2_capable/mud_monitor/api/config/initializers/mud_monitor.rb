repo_root = Rails.root.join("../../..").expand_path

Rails.application.config.x.mud_monitor = ActiveSupport::OrderedOptions.new.tap do |c|
  c.sessions_dir  = Pathname.new(ENV.fetch("MUD_MONITOR_SESSIONS_DIR", repo_root.join(".boukensha/sessions").to_s))
  c.telnet_dir    = Pathname.new(ENV.fetch("MUD_MONITOR_TELNET_DIR", repo_root.join(".boukensha/telnet").to_s))
  c.manager_dir   = Pathname.new(ENV.fetch("MUD_MONITOR_MANAGER_DIR", repo_root.join(".boukensha/manager").to_s))
  c.world_dir     = Pathname.new(ENV.fetch("MUD_MONITOR_WORLD_DIR", repo_root.join("week0_explore/preview/data/world").to_s))
  c.knowledge_db  = Pathname.new(ENV.fetch("MUD_KNOWLEDGE_DB", repo_root.join(".boukensha/knowledge.sqlite3").to_s))
  c.max_streams   = ENV.fetch("MUD_MONITOR_MAX_STREAMS", 8).to_i
  c.live_window   = ENV.fetch("MUD_MONITOR_LIVE_WINDOW", 10).to_i

  # How long a `stream` action keeps polling after its last new entry before
  # it gives up and tells the client the session is over. Deliberately much
  # larger than `live_window` (which only drives the "live" badge/list flag,
  # §3.1) — an LLM turn or a slow MUD round-trip can easily leave the log
  # quiet for well over `live_window` seconds without the session actually
  # having ended.
  c.stream_idle_timeout = ENV.fetch("MUD_MONITOR_STREAM_IDLE_TIMEOUT", 120).to_i
end

# Deferred until after boot: `StreamGate` lives under `lib/`, autoloaded by
# the main Zeitwerk loader, which isn't engaged yet while config/initializers
# are still being evaluated. Shared across every SSE-capable controller
# (sessions today; telnet/manager in later phases) so the cap is process-wide,
# not per log type.
Rails.application.config.after_initialize do
  cfg = Rails.application.config.x.mud_monitor
  cfg.stream_gate = StreamGate.new(max: cfg.max_streams)
end
