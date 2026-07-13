require_relative "../lib/boukensha"

# Override the config directory so the example works from the repo root.
# In real usage a user's ~/.boukensha is picked up automatically.
ENV["BOUKENSHA_DIR"] ||= File.expand_path("../../../../.boukensha", __dir__)

config = Boukensha::Config.new
player_settings = config.tasks(:player)

puts "=== Boukensha Step 0: Configuration ==="
puts
puts "Config dir:     #{config.dir}"
puts "Tasks:          #{config.tasks.keys.join(', ')}"
puts
puts "-- player task --"
puts "Provider:       #{Boukensha::Tasks::Player.provider(player_settings)}"
puts "Model:          #{Boukensha::Tasks::Player.model(player_settings)}"
puts "Prompt override?#{Boukensha::Tasks::Player.prompt_override?(player_settings, :system)}"
puts "System prompt:  #{Boukensha::Tasks::Player.system_prompt(player_settings, user_prompts_dir: config.user_prompts_dir, default_prompts_dir: Boukensha::Config::PROMPTS_DIR)&.slice(0, 60)}..."
puts
puts "MUD host:       #{config.mud_host}:#{config.mud_port}"
puts "MUD user:       #{config.mud_username}"
puts
puts "API key set?    #{!ENV['ANTHROPIC_API_KEY'].nil?}"
puts
puts config
