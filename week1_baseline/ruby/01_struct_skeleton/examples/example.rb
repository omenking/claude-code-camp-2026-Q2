require_relative "../lib/boukensha"
ENV["BOUKENSHA_DIR"] ||= File.expand_path("../../../../.boukensha", __dir__)

config = Boukensha::Config.new
player_settings = config.tasks(:player)
system_prompt = Boukensha::Tasks::Player.system_prompt(
  player_settings,
  user_prompts_dir: config.user_prompts_dir
)

ctx = Boukensha::Context.new(
  task: Boukensha::Tasks::Player,
  system: system_prompt
)

ctx.register_tool(
  Boukensha::Tool.new(
    "move",
    "Move the player in a direction (north, south, east, west, up, down)",
    { direction: { type: "string", description: "The direction to move" } },
    ->(direction) { "You move #{direction} into a torch-lit corridor." }
  )
)

ctx.add_message(:user, "Explore north and tell me what you find.")
ctx.add_message(:assistant, "Sure, let me head north and take a look.")

puts "=== Boukensha Step 1: Struct Skeleton ==="
puts
puts "Config:   #{config}"
puts "Context:  #{ctx}"
puts "Tool:     #{ctx.tools['move']}"
puts "Messages:"
ctx.messages.each { |m| puts "  #{m}" }
