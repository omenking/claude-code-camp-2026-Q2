require_relative "boukensha/version"
require_relative "boukensha/config"
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
    api_key ||= case backend
                when :anthropic    then ENV["ANTHROPIC_API_KEY"]
                when :openai       then ENV["OPENAI_API_KEY"]
                when :gemini       then ENV["GEMINI_API_KEY"]
                when :ollama_cloud then ENV["OLLAMA_API_KEY"]
                end

    ctx      = Context.new(task: task_class, system: system, working_dir: working_dir)
    registry = Registry.new(ctx)

    register_mcp_servers(registry, cfg)

    RunDSL.new(registry).instance_eval(&block) if block

    be = case backend
         when :anthropic    then Backends::Anthropic.new(api_key: api_key, model: model)
         when :openai       then Backends::OpenAI.new(api_key: api_key, model: model)
         when :gemini       then Backends::Gemini.new(api_key: api_key, model: model)
         when :ollama       then Backends::Ollama.new(host: ollama_host, model: model)
         when :ollama_cloud then Backends::OllamaCloud.new(api_key: api_key, model: model)
         else raise ArgumentError, "Unknown backend #{backend.inspect}. Use :anthropic, :openai, :gemini, :ollama, or :ollama_cloud."
         end

    builder = PromptBuilder.new(ctx, be)
    client  = Client.new(builder)
    effective_max_iterations = task_class.max_iterations(task_settings)
    effective_max_output_tokens = max_output_tokens || task_class.max_output_tokens(task_settings)
    logger  = Logger.new(log: log, snapshot: {
      task:              task_class.task_name,
      max_iterations:    effective_max_iterations,
      max_output_tokens: effective_max_output_tokens,
      model:             model,
      provider:          backend
    })
    agent   = Agent.new(context: ctx, registry: registry, builder: builder, client: client, logger: logger,
                        task_settings: task_settings, max_iterations: effective_max_iterations, max_output_tokens: effective_max_output_tokens)

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
    api_key ||= case backend
                when :anthropic    then ENV["ANTHROPIC_API_KEY"]
                when :openai       then ENV["OPENAI_API_KEY"]
                when :gemini       then ENV["GEMINI_API_KEY"]
                when :ollama_cloud then ENV["OLLAMA_API_KEY"]
                end

    ctx      = Context.new(task: task_class, system: system, working_dir: working_dir)
    registry = Registry.new(ctx)

    servers = register_mcp_servers(registry, cfg)

    RunDSL.new(registry).instance_eval(&block) if block

    be = case backend
         when :anthropic    then Backends::Anthropic.new(api_key: api_key, model: model)
         when :openai       then Backends::OpenAI.new(api_key: api_key, model: model)
         when :gemini       then Backends::Gemini.new(api_key: api_key, model: model)
         when :ollama       then Backends::Ollama.new(host: ollama_host, model: model)
         when :ollama_cloud then Backends::OllamaCloud.new(api_key: api_key, model: model)
         else raise ArgumentError, "Unknown backend #{backend.inspect}. Use :anthropic, :openai, :gemini, :ollama, or :ollama_cloud."
         end

    builder = PromptBuilder.new(ctx, be)
    client  = Client.new(builder)
    effective_max_iterations = task_class.max_iterations(task_settings)
    effective_max_output_tokens = max_output_tokens || task_class.max_output_tokens(task_settings)
    logger  = Logger.new(log: log, snapshot: {
      task:              task_class.task_name,
      max_iterations:    effective_max_iterations,
      max_output_tokens: effective_max_output_tokens,
      model:             model,
      provider:          backend
    })

    repl = Repl.new(
      context:    ctx,
      registry:   registry,
      builder:    builder,
      client:     client,
      logger:     logger,
      task_settings: task_settings,
      max_iterations:    effective_max_iterations,
      max_output_tokens: effective_max_output_tokens,
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
  # Returns { server_name => tool_count } for the servers that came up.
  def self.register_mcp_servers(registry, cfg)
    cfg.mcp_servers.each_with_object({}) do |(name, entry), summary|
      begin
        client = Tools::Mcp.register(registry, command: entry[:command], args: entry[:args],
                                               env: entry[:env], prefix: entry[:prefix])
        summary[name] = client.tools.size
      rescue Tools::Mcp::CollisionError
        raise
      rescue StandardError => e
        raise "boukensha: MCP server '#{name}' failed to start: #{e.message}" if entry[:required]
        warn "[boukensha] optional MCP server '#{name}' failed to start: #{e.message} — continuing without its tools"
      end
    end
  end
  private_class_method :register_mcp_servers
end

require_relative "boukensha/tool"
require_relative "boukensha/message"
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
require_relative "boukensha/tui"
