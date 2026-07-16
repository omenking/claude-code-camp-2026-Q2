module Boukensha
  # Repl is the interactive session loop.
  #
  # It wraps the same primitives as a single Boukensha.run call, but instead of
  # running once it stays alive: it reads a task from the user, runs the agent,
  # prints the reply, and loops back to the prompt.
  #
  # The Context is shared across every turn so conversation history accumulates
  # naturally — the agent sees the full transcript each time it is called.
  #
  # Built-in commands (not sent to the agent):
  #   /help    print the command list
  #   /quiet   suppress detailed logging
  #   /loud    re-enable logging
  #   /clear   wipe conversation history (tools stay registered)
  #   /exit    leave the REPL
  #   /quit    alias for /exit
  class Repl
    PROMPT = "boukensha> "

    HELP = <<~HELP
      Commands:
        /quiet   suppress logging output
        /loud    re-enable logging output
        /clear   wipe conversation history (tools stay)
        /exit    leave the REPL
        /help    show this message
    HELP

    def initialize(context:, registry:, builder:, client:, logger:, config_dir: nil, provider: nil, model: nil, version: nil, api_key: nil, task_settings: nil, max_iterations: nil, max_output_tokens: nil)
      @context    = context
      @registry   = registry
      @builder    = builder
      @client     = client
      @logger     = logger
      @task_settings     = task_settings
      @max_iterations    = max_iterations
      @max_output_tokens = max_output_tokens
      @config_dir = config_dir
      @provider   = provider
      @model      = model
      @version    = version
      @api_key    = api_key
      @turn       = 0
    end

    def start
      puts banner

      loop do
        print PROMPT
        $stdout.flush

        input = $stdin.gets
        break unless input  # EOF / Ctrl-D

        input = input.chomp.strip
        next if input.empty?

        case input
        when "/exit", "/quit"
          puts "Goodbye."
          break
        when "/help"
          puts HELP
          next
        when "/quiet"
          Boukensha.quiet!
          puts "(logging suppressed — type /loud to re-enable)"
          next
        when "/loud"
          Boukensha.loud!
          puts "(logging enabled)"
          next
        when "/clear"
          @context.clear_messages!
          @turn = 0
          puts "(conversation history cleared)"
          next
        end

        run_turn(input)
      end
    end

    private

    def banner
      key_status    = (@api_key.nil? || @api_key.strip.empty?) ? "✗ API key not set" : "✓ API key set"
      provider_line = "#{@provider || "default"} (#{@model || "default"})  #{key_status}"
      config_exists = @config_dir && Dir.exist?(@config_dir)
      config_line   = config_exists ? @config_dir : "#{@config_dir || "(default)"}  ✗ directory not found"
      ver           = @version || "?.?.?"

      <<~BANNER

        ╔══════════════════════════════════════╗
        ║  BOUKENSHA MUD Assistant (v#{ver})#{" " * (9 - ver.length)}║
        ╚══════════════════════════════════════╝
          config:    #{config_line}
          provider:  #{provider_line}

          /quiet or /loud   toggle logging
          /clear           reset conversation history
          /exit or /quit    leave the REPL

      BANNER
    end

    def run_turn(input)
      @turn += 1
      @logger.turn(n: @turn)

      @context.add_message(:user, input)

      agent  = Agent.new(
        context:  @context,
        registry: @registry,
        builder:  @builder,
        client:   @client,
        logger:   @logger,
        task_settings: @task_settings,
        max_iterations:    @max_iterations,
        max_output_tokens: @max_output_tokens
      )
      result = agent.run

      # Print the final response outside of the logger so it is always visible,
      # even when Boukensha.quiet! is active.
      puts
      puts result
    rescue LoopError => e
      puts "\n[error] #{e.message}"
    rescue ApiError => e
      puts "\n[error] API call failed: #{e.message}"
    end
  end
end
