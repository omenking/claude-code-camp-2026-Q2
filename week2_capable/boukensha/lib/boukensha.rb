require_relative "boukensha/version"
require_relative "boukensha/config"
require_relative "boukensha/permissions"
require_relative "boukensha/tasks/player"
require_relative "boukensha/tasks/room_inspector"

module Boukensha
  @quiet  = false
  @debug  = false
  @config = nil

  def self.config
    @config ||= Config.new
  end

  def self.quiet!
    @quiet = true
  end

  def self.loud!
    @quiet = false
  end

  def self.quiet?
    @quiet
  end

  def self.debug!
    @debug = true
  end

  def self.debug?
    @debug
  end

  # One-shot run: send a single task, get a response, return.
  #
  # The agent ships with NO tools of its own. Every tool it can call arrives
  # over an MCP connection, declared in settings.yaml's `mcp_servers:` block
  # (see Boukensha::Config#mcp_servers). Want file access? Point at a
  # filesystem MCP server. Want to play a MUD? Point at `mud-manager --mcp`.
  # Boukensha is the host; the servers own the tools.
  #
  # working_dir:      Recorded on the Context as the agent's notion of "where
  #                   it is". It registers nothing — an MCP server that touches
  #                   the filesystem is rooted by its own spawn args.
  def self.run(
    task:,
    system:           nil,
    model:            nil,
    backend:          nil,
    api_key:          nil,
    ollama_host:      "http://localhost:11434",
    log:              nil,
    context_window:   nil,
    max_output_tokens: nil,
    working_dir:      Dir.pwd,
    &block
  )
    cfg           = config                           # loads .env; populates ENV
    task_class    = Tasks::Player
    task_settings = cfg.tasks(task_class.task_name)
    system      ||= task_class.system_prompt(task_settings, user_prompts_dir: cfg.user_prompts_dir, default_prompts_dir: Config::PROMPTS_DIR)
    model       ||= task_class.model(task_settings)
    backend     ||= task_class.provider(task_settings).to_sym
    context_window ||= Models.context_window(model)
    api_key ||= api_key_for(backend)

    perms    = task_permissions(cfg, task_class.task_name)
    ctx      = Context.new(system: system, context_window: context_window, working_dir: working_dir, compaction_threshold: cfg.agent_compaction_threshold)
    registry = Registry.new(ctx, permissions: perms)

    register_task_tools(registry, cfg, perms)

    RunDSL.new(registry).instance_eval(&block) if block

    perms.validate_referenced!(registry.tool_names)

    be = build_backend(backend, api_key: api_key, model: model, ollama_host: ollama_host)

    builder = PromptBuilder.new(ctx, be)
    client  = Client.new(builder)
    logger  = Logger.new(log: log, snapshot: {
      max_iterations:    cfg.agent_max_iterations,
      max_turn_tokens:   cfg.agent_max_turn_tokens,
      max_output_tokens: (max_output_tokens || cfg.agent_max_output_tokens),
      context_window:    context_window,
      model:             model,
      provider:          backend
    })
    agent   = Agent.new(context: ctx, registry: registry, builder: builder, client: client, logger: logger,
                        max_iterations: cfg.agent_max_iterations,
                        max_turn_tokens: cfg.agent_max_turn_tokens,
                        max_output_tokens: (max_output_tokens || cfg.agent_max_output_tokens))

    ctx.add_message(:user, task)
    agent.run
  ensure
    logger&.close
  end

  # Interactive REPL — see Boukensha.run for full option documentation.
  #
  # tui: true (default) wraps the REPL in a charm-ruby TUI.  Pass tui: false or
  # use the --no-tui CLI flag to fall back to the plain terminal REPL.
  def self.repl(
    system:           nil,
    model:            nil,
    backend:          nil,
    api_key:          nil,
    ollama_host:      "http://localhost:11434",
    log:              nil,
    context_window:   nil,
    max_output_tokens: nil,
    working_dir:      Dir.pwd,
    tui:              true,
    &block
  )
    cfg           = config                           # loads .env; populates ENV
    task_class    = Tasks::Player
    task_settings = cfg.tasks(task_class.task_name)
    system      ||= task_class.system_prompt(task_settings, user_prompts_dir: cfg.user_prompts_dir, default_prompts_dir: Config::PROMPTS_DIR)
    model       ||= task_class.model(task_settings)
    backend     ||= task_class.provider(task_settings).to_sym
    context_window ||= Models.context_window(model)
    api_key ||= api_key_for(backend)

    perms    = task_permissions(cfg, task_class.task_name)
    ctx      = Context.new(system: system, context_window: context_window, working_dir: working_dir, compaction_threshold: cfg.agent_compaction_threshold)
    registry = Registry.new(ctx, permissions: perms)

    servers = register_task_tools(registry, cfg, perms)

    RunDSL.new(registry).instance_eval(&block) if block

    perms.validate_referenced!(registry.tool_names)

    be = build_backend(backend, api_key: api_key, model: model, ollama_host: ollama_host)

    builder = PromptBuilder.new(ctx, be)
    client  = Client.new(builder)
    logger  = Logger.new(log: log, snapshot: {
      max_iterations:    cfg.agent_max_iterations,
      max_turn_tokens:   cfg.agent_max_turn_tokens,
      max_output_tokens: (max_output_tokens || cfg.agent_max_output_tokens),
      context_window:    context_window,
      model:             model,
      provider:          backend
    })

    repl = Repl.new(
      context:    ctx,
      registry:   registry,
      builder:    builder,
      client:     client,
      logger:     logger,
      max_iterations:    cfg.agent_max_iterations,
      max_turn_tokens:   cfg.agent_max_turn_tokens,
      max_output_tokens: (max_output_tokens || cfg.agent_max_output_tokens),
      config_dir: cfg.dir,
      provider:   backend,
      model:      model,
      version:    VERSION,
      api_key:    api_key,
      servers:    servers
    )

    if tui && defined?(Tui)
      Tui.new(repl).start
    else
      repl.start
    end
  rescue Interrupt
    puts "\nInterrupted."
  ensure
    logger&.close
  end

  # Run a subagent turn and return its text response.
  #
  # This is how one task delegates to another. It resolves `task_class`'s
  # provider / model / system prompt from settings.yaml (exactly as .run does
  # for the player), registers the tools that task is allowed to see, feeds
  # `input` as the sole user message, and runs the agent loop to completion.
  #
  # The subagent's tools come from the SAME shared MCP clients the parent uses
  # (#mcp_clients), scoped by the task's `tools:` filter — so an agentic
  # room_inspector drives the player's live MUD session (no second login) but
  # sees only its slice (e.g. inspect_room + consider + examine). It runs for up
  # to the task's own `max_iterations`, because gathering a room and appraising
  # its mobs is several tool calls, not one.
  #
  # Because provider/model/prompt come from the task's settings block, swapping
  # room_inspector to a local Ollama model later is config-only (plan §9).
  def self.run_task(task_class, input, log: nil, max_output_tokens: nil, ollama_host: "http://localhost:11434")
    cfg            = config
    task_settings  = cfg.tasks(task_class.task_name)
    system         = task_class.system_prompt(task_settings, user_prompts_dir: cfg.user_prompts_dir, default_prompts_dir: Config::PROMPTS_DIR)
    model          = task_class.model(task_settings)
    backend        = task_class.provider(task_settings).to_sym
    context_window = Models.context_window(model)
    api_key        = api_key_for(backend)
    max_out        = max_output_tokens || task_class.max_output_tokens(task_settings)
    max_iters      = task_class.max_iterations(task_settings)

    perms    = task_permissions(cfg, task_class.task_name)
    ctx      = Context.new(system: system, context_window: context_window, working_dir: Dir.pwd, compaction_threshold: cfg.agent_compaction_threshold)
    registry = Registry.new(ctx, permissions: perms)
    register_task_tools(registry, cfg, perms)   # shared session, scoped by the task's filter
    perms.validate_referenced!(registry.tool_names)   # no block/native tools here, so this can run immediately
    be       = build_backend(backend, api_key: api_key, model: model, ollama_host: ollama_host)
    builder  = PromptBuilder.new(ctx, be)
    client   = Client.new(builder)
    logger   = Logger.new(log: log, snapshot: {
      max_iterations:    max_iters,
      max_turn_tokens:   cfg.agent_max_turn_tokens,
      max_output_tokens: max_out,
      context_window:    context_window,
      model:             model,
      provider:          backend
    })
    agent = Agent.new(context: ctx, registry: registry, builder: builder, client: client, logger: logger,
                      max_iterations: max_iters, max_turn_tokens: cfg.agent_max_turn_tokens, max_output_tokens: max_out)
    ctx.add_message(:user, input)
    agent.run
  ensure
    logger&.close
  end

  # Construct a backend from its symbol name. Extracted so .run, .repl, and
  # .run_task all build providers the same way.
  def self.build_backend(backend, api_key:, model:, ollama_host: "http://localhost:11434")
    case backend
    when :anthropic    then Backends::Anthropic.new(api_key: api_key, model: model)
    when :openai       then Backends::OpenAI.new(api_key: api_key, model: model)
    when :gemini       then Backends::Gemini.new(api_key: api_key, model: model)
    when :ollama       then Backends::Ollama.new(host: ollama_host, model: model)
    when :ollama_cloud then Backends::OllamaCloud.new(api_key: api_key, model: model)
    else raise ArgumentError, "Unknown backend #{backend.inspect}. Use :anthropic, :openai, :gemini, :ollama, or :ollama_cloud."
    end
  end
  private_class_method :build_backend

  # The environment variable that carries a given backend's key, if any.
  def self.api_key_for(backend)
    case backend
    when :anthropic    then ENV["ANTHROPIC_API_KEY"]
    when :openai       then ENV["OPENAI_API_KEY"]
    when :gemini       then ENV["GEMINI_API_KEY"]
    when :ollama_cloud then ENV["OLLAMA_API_KEY"]
    end
  end
  private_class_method :api_key_for

  # Register every server in settings.yaml's `mcp_servers:` block. This is the
  # agent's ONLY source of tools — boukensha ships none of its own. Nothing
  # here knows what any particular server does; a MUD daemon and a filesystem
  # server are registered by the identical code path.
  #
  # A server marked `required: false` that fails to spawn is a warning, not a
  # fatal error — the agent runs without its tools. A name collision is never
  # excused that way: it means the config asks for two tools with one name, and
  # answering by dropping one of them silently is the worst option available.
  #
  # Returns { server_name => registered_tool_count } for the servers that came up.
  #
  # `clients:` — pass a pre-spawned set (from #mcp_clients) to register the
  # SHARED connections instead of spawning fresh; omit it and each server is
  # spawned for this registry alone (the standalone / test path).
  # `permissions:` — an optional Permissions that scopes which tools get
  # registered and narrows their enum parameters (a task's `allow:` block).
  def self.register_mcp_servers(registry, cfg, clients: nil, permissions: nil)
    (clients || spawn_mcp_clients(cfg)).each_with_object({}) do |entry, summary|
      summary[entry[:name]] = Tools::Mcp.register_client(
        registry, entry[:client], prefix: entry[:prefix], permissions: permissions
      )
    end
  end
  private_class_method :register_mcp_servers

  # Spawn every configured MCP server ONCE for the life of the process and
  # memoize the clients, so the player and every subagent SHARE one connection
  # per server — one telnet login into the MUD, not one per task. This is what
  # lets a subagent like room_inspector drive the same live session the player
  # is on. Access is serial (a subagent runs inside the parent's tool call), so
  # there is no concurrent use of a shared client.
  def self.mcp_clients(cfg)
    @mcp_clients ||= spawn_mcp_clients(cfg)
  end

  # Drop the memoized clients (they close at_exit). Test seam.
  def self.reset_mcp_clients!
    @mcp_clients = nil
  end

  # Spawn each server's client, applying the required/optional policy: a
  # `required` server that won't start is fatal; an optional one warns and is
  # skipped. Returns [{ name:, prefix:, client: }, ...] for those that came up.
  def self.spawn_mcp_clients(cfg)
    cfg.mcp_servers.each_with_object([]) do |(name, entry), out|
      begin
        client = Boukensha::Mcp::Client.spawn(command: entry[:command], args: entry[:args], env: entry[:env])
        at_exit { client.close rescue nil }
        out << { name: name, prefix: entry[:prefix], client: client }
      rescue StandardError => e
        raise "boukensha: MCP server '#{name}' failed to start: #{e.message}" if entry[:required]
        warn "[boukensha] optional MCP server '#{name}' failed to start: #{e.message} — continuing without its tools"
      end
    end
  end
  private_class_method :spawn_mcp_clients

  # Register the SHARED clients' tools into `registry`, scoped to what `perms`
  # (the task's `allow:` block, built by the caller via #task_permissions)
  # permits. Registration only — the caller validates every rule resolved to
  # a real tool (Permissions#validate_referenced!) itself, once ALL of a
  # task's tools (MCP-derived here, plus any native tools a run/repl block
  # registers afterward) exist in the registry. Validating any earlier would
  # reject a rule naming a native tool that hasn't been registered yet.
  def self.register_task_tools(registry, cfg, perms)
    register_mcp_servers(registry, cfg, clients: mcp_clients(cfg), permissions: perms)
  end
  private_class_method :register_task_tools

  # Build the Permissions for a task from its `allow:` block. Default-deny: a
  # task with no `allow:` block may call NOTHING. (The standalone/test path that
  # calls register_mcp_servers with no permissions is permissive — unrelated.)
  def self.task_permissions(cfg, task_name)
    spec  = cfg.tasks(task_name) || {}
    allow = spec["allow"] || spec[:allow]
    allow.nil? ? Permissions.deny_all : Permissions.from(allow)
  end
end

require_relative "boukensha/tool"
require_relative "boukensha/message"
require_relative "boukensha/models"
require_relative "boukensha/context"
require_relative "boukensha/errors"
require_relative "boukensha/registry"
require_relative "boukensha/prompt_builder"
require_relative "boukensha/logger"
require_relative "boukensha/backends/base"
require_relative "boukensha/backends/anthropic"
require_relative "boukensha/backends/gemini"
require_relative "boukensha/backends/ollama"
require_relative "boukensha/backends/ollama_cloud"
require_relative "boukensha/backends/openai"
require_relative "boukensha/client"
require_relative "boukensha/agent"
require_relative "boukensha/run_dsl"
require_relative "boukensha/repl"
require_relative "boukensha/tools/mcp"
require_relative "boukensha/tools/inspect_room"
require_relative "boukensha/tui"
