ENV["BOUKENSHA_DIR"] ||= File.expand_path("../../../../.boukensha", __dir__)
require_relative "../lib/boukensha"

config          = Boukensha::Config.new
player_settings = config.tasks(:player)
system_prompt   = Boukensha::Tasks::Player.system_prompt(
  player_settings,
  user_prompts_dir: config.user_prompts_dir
)

ctx      = Boukensha::Context.new(task: Boukensha::Tasks::Player, system: system_prompt)
registry = Boukensha::Registry.new(ctx)

# Notice that we now register the tools through the registry instead of directly
# on the context in the previous step.
# They will still be attached to context which is why we pass it into
# our registry when we initialize it.
registry.tool("move",
  description: "Move the player in a direction (north, south, east, west, up, down)",
  parameters: { direction: { type: "string" } }
) do |direction:|
  "You move #{direction} into a torch-lit corridor."
end

registry.tool("shout",
  description: "Shout a message so everyone in the zone can hear it",
  parameters: { message: { type: "string" } }
) do |message:|
  message.upcase
end

puts "=== BOUKENSHA Step 2: Tool Registry ==="
puts
puts "Config:  #{config}"
puts "Context: #{ctx}"
puts "Tools:"
ctx.tools.each_value { |t| puts "  #{t}" }
puts

# Here we are mimicking what the agent would do when
# it needs to call a tool from the registry. We are
# still missing the actual code that would decide when
# to call the registry for a tool.
puts "Dispatching 'shout' with message='dragon spotted'..."
result = registry.dispatch("shout", { "message" => "dragon spotted" })
puts "Result: #{result}"
puts

puts "Dispatching 'move' with direction='north'..."
result = registry.dispatch("move", { "direction" => "north" })
puts "Result: #{result}"
puts

begin
  registry.dispatch("flee")
rescue Boukensha::UnknownToolError => e
  puts "UnknownToolError caught: #{e.message}"
end
