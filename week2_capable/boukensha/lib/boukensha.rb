require_relative "boukensha/version"
require_relative "boukensha/config"
require_relative "boukensha/permissions"
require_relative "boukensha/tasks/player"

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

    # The logger is built BEFORE the block is evaluated so the block can reach
    # it (RunDSL#logger) and hand it to a delegating tool — one session file per
    # run, not one per delegation. It depends only on values resolved above.
    logger = Logger.new(log: log, task: task_class.task_name, snapshot: {
      max_iterations:    cfg.agent_max_iterations,
      max_turn_tokens:   cfg.agent_max_turn_tokens,
      max_output_tokens: (max_output_tokens || cfg.agent_max_output_tokens),
      context_window:    context_window,
      model:             model,
      provider:          backend
    })

    RunDSL.new(registry, logger: logger).instance_eval(&block) if block

    perms.validate_referenced!(registry.tool_names)

    be = build_backend(backend, api_key: api_key, model: model, ollama_host: ollama_host)

    builder = PromptBuilder.new(ctx, be)
    client  = Client.new(builder)
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

    # Built before the block for the same reason as in .run — see there.
    logger = Logger.new(log: log, task: task_class.task_name, snapshot: {
      max_iterations:    cfg.agent_max_iterations,
      max_turn_tokens:   cfg.agent_max_turn_tokens,
      max_output_tokens: (max_output_tokens || cfg.agent_max_output_tokens),
      context_window:    context_window,
      model:             model,
      provider:          backend
    })

    RunDSL.new(registry, logger: logger).instance_eval(&block) if block

    perms.validate_referenced!(registry.tool_names)

    be = build_backend(backend, api_key: api_key, model: model, ollama_host: ollama_host)

    builder = PromptBuilder.new(ctx, be)
    client  = Client.new(builder)

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
  #
  # `logger:` — pass the CALLER's logger (the player's) and the sub-run appends
  # to that session file, bracketed by task_start/task_end and with every event
  # stamped with this task's name (plan Amendment A). Omit it and the sub-run
  # mints its own file as before, which is what standalone callers and tests
  # want. A borrowed logger is never closed here: it belongs to the parent, and
  # closing it would silently truncate the rest of the parent's turn.
  def self.run_task(task_class, input, log: nil, logger: nil, max_output_tokens: nil, ollama_host: "http://localhost:11434")
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
    run_snapshot = {
      max_iterations:    max_iters,
      max_turn_tokens:   cfg.agent_max_turn_tokens,
      max_output_tokens: max_out,
      context_window:    context_window,
      model:             model,
      provider:          backend
    }

    own_logger = logger.nil?
    logger   ||= Logger.new(log: log, task: task_class.task_name, snapshot: run_snapshot)
    agent      = Agent.new(context: ctx, registry: registry, builder: builder, client: client, logger: logger,
                           max_iterations: max_iters, max_turn_tokens: cfg.agent_max_turn_tokens, max_output_tokens: max_out)

    body = lambda do
      ctx.add_message(:user, input)
      agent.run
    end

    # A logger of our own already has this task as its root (depth 0) and this
    # configuration in its session_start, so bracketing would nest it against
    # itself. A borrowed one needs both: the marker that opens the group, and
    # the sub-run's own limits/model, which the parent's session_start does not
    # carry.
    own_logger ? body.call : logger.task(task_class.task_name, snapshot: run_snapshot, &body)
  ensure
    logger&.close if own_logger
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

  # A permission-scoped tool dispatcher for a native tool that has NO model.
  #
  #   call = Boukensha.tool_dispatcher("inspect_room", logger: parent)
  #   call.call("tbamud__look", {})   # => the MUD's text
  #
  # `inspect_room` used to be an LLM subagent, so it reached its tools through
  # run_task. It is a plain Ruby survey now, but it still must NOT inherit the
  # player's permissions — `look` is off the player deliberately, and the survey
  # is the only route to it. So the tool keeps its own `allow:` block under
  # `tools.<name>.allow`, and this hands it exactly that slice.
  #
  # Everything except the agent is what run_task already assembles: the same
  # shared MCP clients (#mcp_clients, so the survey drives the player's live
  # session with no second login), the same Registry, the same default-deny.
  #
  # `logger:` — pass the caller's logger and every call is bracketed with
  # tool_call/tool_result stamped with the tool's name, which is the shape
  # mud_monitor's session view reads. The task_start/task_end pair is the
  # caller's to open, because it brackets the whole survey rather than each
  # command.
  def self.tool_dispatcher(tool_name, logger: nil)
    cfg      = config
    allow    = cfg.dig(:tools, tool_name, :allow)
    perms    = allow.nil? ? Permissions.deny_all : Permissions.from(allow)
    ctx      = Context.new(system: "", context_window: 0, working_dir: Dir.pwd)
    registry = Registry.new(ctx, permissions: perms)
    register_task_tools(registry, cfg, perms)
    perms.validate_referenced!(registry.tool_names)

    lambda do |name, args = {}|
      logger&.tool_call(name: name, args: args)
      begin
        result = registry.dispatch(name, args)
      rescue StandardError => e
        logger&.tool_result(name: name, result: "", ok: false, error: e.message)
        raise
      end
      logger&.tool_result(name: name, result: result)
      result
    end
  end

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
# `onnxruntime` is only required when a model is actually loaded, so a checkout
# without the artifact (or without the gem) still boots.
require_relative "boukensha/extractors"
require_relative "boukensha/tui"
