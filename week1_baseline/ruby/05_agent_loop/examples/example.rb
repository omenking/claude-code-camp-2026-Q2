ENV["BOUKENSHA_DIR"] ||= File.expand_path("../../../../.boukensha", __dir__)
require_relative "../lib/boukensha"

config          = Boukensha::Config.new
player_settings = config.tasks(:player)
system_prompt   = Boukensha::Tasks::Player.system_prompt(
  player_settings,
  user_prompts_dir: config.user_prompts_dir,
  default_prompts_dir: Boukensha::Config::PROMPTS_DIR
)
base_dir        = File.expand_path("..", __dir__)

ctx      = Boukensha::Context.new(task: Boukensha::Tasks::Player, system: system_prompt)
registry = Boukensha::Registry.new(ctx)

provider = Boukensha::Tasks::Player.provider(player_settings)
model    = Boukensha::Tasks::Player.model(player_settings)

backend =
case provider
when "anthropic"
  Boukensha::Backends::Anthropic.new(
    api_key: ENV.fetch("ANTHROPIC_API_KEY"),
    model:   model
  )
when "openai"
  Boukensha::Backends::OpenAI.new(
    api_key: ENV.fetch("OPENAI_API_KEY"),
    model:   model
  )
when "gemini"
  Boukensha::Backends::Gemini.new(
    api_key: ENV.fetch("GEMINI_API_KEY"),
    model:   model
  )
when "ollama"
  Boukensha::Backends::Ollama.new(
    model: model
  )
when "ollama_cloud"
  Boukensha::Backends::OllamaCloud.new(
    api_key: ENV.fetch("OLLAMA_API_KEY"),
    model:   model
  )
else
  raise ArgumentError, "Unsupported provider for player task: #{provider}"
end

builder  = Boukensha::PromptBuilder.new(ctx, backend)
client   = Boukensha::Client.new(builder)
agent    = Boukensha::Agent.new(
  context: ctx,
  registry: registry,
  builder: builder,
  client: client,
  task_settings: player_settings
)

registry.tool("read_file",
  description: "Read the contents of a file from disk",
  parameters: { path: { type: "string", description: "The file path to read" } }
) do |path:|
  File.read(File.expand_path(path, base_dir))
end

registry.tool("list_directory",
  description: "List the files in a directory",
  parameters: { path: { type: "string", description: "The directory path to list" } }
) do |path:|
  Dir.entries(File.expand_path(path, base_dir)).reject { |f| f.start_with?(".") }.join(", ")
end

ctx.add_message(:user, "Read the README.md file and summarise what this MUD player assistant framework can do.")

puts "=== BOUKENSHA Step 5: Agent Loop ==="
puts
puts "Config: #{config}"
puts "Provider: #{provider}"
puts "Model: #{model}"
puts "Max iterations: #{Boukensha::Tasks::Player.max_iterations(player_settings)}"
puts "Max output tokens: #{Boukensha::Tasks::Player.max_output_tokens(player_settings)}"
puts

result = agent.run

puts
puts "=== FINAL RESPONSE ==="
puts result
