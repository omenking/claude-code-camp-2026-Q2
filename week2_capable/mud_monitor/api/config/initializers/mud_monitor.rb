require "yaml"

repo_root = Rails.root.join("../../..").expand_path

# Where boukensha actually keeps its state. The monitor is a reader of another
# process's directory, so it must resolve that directory the same way the
# writer does rather than guessing from its own location — see
# boukensha/lib/boukensha_loader.rb, which applies exactly this precedence:
#
#   1. BOUKENSHA_DIR
#   2. boukensha_dir: in ~/.boukensharc (relative paths expand against ~)
#   3. ~/.boukensha
#
# Guessing (repo_root/.boukensha) is what made the /telnet and /manager pages
# report "logging is off" while the daemon was happily writing elsewhere: the
# health check keys off `dir.directory?`, and a wrong path is indistinguishable
# from a disabled log.
boukensha_dir = begin
  rc_file = File.expand_path("~/.boukensharc")

  rc = if File.exist?(rc_file)
    parsed = YAML.safe_load(File.read(rc_file), permitted_classes: [], aliases: false)
    # A bare single-line path is the pre-step-9 format and means boukensha_path,
    # never boukensha_dir — so it contributes nothing here.
    parsed.is_a?(Hash) ? parsed : {}
  else
    {}
  end

  from_rc = rc["boukensha_dir"]
  from_rc = nil unless from_rc.is_a?(String) && !from_rc.strip.empty?

  dir = ENV["BOUKENSHA_DIR"] ||
        (from_rc && File.expand_path(from_rc, File.dirname(rc_file))) ||
        File.expand_path("~/.boukensha")

  Pathname.new(dir)
rescue Psych::SyntaxError => e
  # Don't take the whole app down over a malformed rc file; fall back to the
  # old guess and say so, since every path below is only a default anyway.
  Rails.logger.warn("[mud_monitor] invalid YAML in ~/.boukensharc (#{e.message}); falling back to #{repo_root.join('.boukensha')}")
  repo_root.join(".boukensha")
end

Rails.application.config.x.mud_monitor = ActiveSupport::OrderedOptions.new.tap do |c|
  c.boukensha_dir = boukensha_dir
  c.sessions_dir  = Pathname.new(ENV.fetch("MUD_MONITOR_SESSIONS_DIR", boukensha_dir.join("sessions").to_s))
  c.telnet_dir    = Pathname.new(ENV.fetch("MUD_MONITOR_TELNET_DIR", boukensha_dir.join("telnet").to_s))
  c.manager_dir   = Pathname.new(ENV.fetch("MUD_MONITOR_MANAGER_DIR", boukensha_dir.join("manager").to_s))
  # Not part of .boukensha — world files ship with the repo, so this one stays
  # anchored to repo_root.
  c.world_dir     = Pathname.new(ENV.fetch("MUD_MONITOR_WORLD_DIR", repo_root.join("week0_explore/preview/data/world").to_s))
  c.knowledge_db  = Pathname.new(ENV.fetch("MUD_KNOWLEDGE_DB", boukensha_dir.join("knowledge.sqlite3").to_s))
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
