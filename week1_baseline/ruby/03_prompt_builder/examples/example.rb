ENV["BOUKENSHA_DIR"] ||= File.expand_path("../../../../.boukensha", __dir__)
require_relative "../lib/boukensha"
require "json"

config          = Boukensha::Config.new
player_settings = config.tasks(:player)
system_prompt   = Boukensha::Tasks::Player.system_prompt(
  player_settings,
  user_prompts_dir: config.user_prompts_dir,
  default_prompts_dir: Boukensha::Config::PROMPTS_DIR
)

ctx      = Boukensha::Context.new(task: Boukensha::Tasks::Player, system: system_prompt)
registry = Boukensha::Registry.new(ctx)

registry.tool("look",
  description: "Look around the current room for details",
  parameters: {}
) do
  "A damp stone corridor stretches north. Torches flicker on the walls."
end

registry.tool("move",
  description: "Move the player in a direction (north, south, east, west, up, down)",
  parameters: { direction: { type: "string", description: "The direction to move" } }
) do |direction:|
  "You move #{direction} into a torch-lit corridor."
end

ctx.add_message(:user, "I just arrived in the dungeon. What's around me, and can you move north?")
ctx.add_message(:assistant, "Let me take a look around first.")
ctx.add_message(:tool_result, "A damp stone corridor stretches north. Torches flicker on the walls.", tool_use_id: "toolu_01X")

puts "=== BOUKENSHA Step 3: Prompt Builder ==="
provider = Boukensha::Tasks::Player.provider(player_settings)
model    = Boukensha::Tasks::Player.model(player_settings)

backend =
case provider
when "anthropic"
  Boukensha::Backends::Anthropic.new(api_key: ENV.fetch("ANTHROPIC_API_KEY"), model: model)
when "ollama"
  Boukensha::Backends::Ollama.new(model: model)
when "ollama_cloud"
  Boukensha::Backends::OllamaCloud.new(api_key: ENV.fetch("OLLAMA_API_KEY"), model: model)
when "openai"
  Boukensha::Backends::OpenAI.new(api_key: ENV.fetch("OPENAI_API_KEY"), model: model)
when "gemini"
  Boukensha::Backends::Gemini.new(api_key: ENV.fetch("GEMINI_API_KEY"), model: model)
else
  raise ArgumentError, "Unsupported provider for player task: #{provider}"
end

builder = Boukensha::PromptBuilder.new(ctx, backend)

puts
puts "Config: #{config}"
puts "Provider: #{provider}"
puts "Model: #{model}"
puts JSON.pretty_generate(builder.to_api_payload)
