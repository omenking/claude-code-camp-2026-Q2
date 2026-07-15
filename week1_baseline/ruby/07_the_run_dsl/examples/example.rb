ENV["BOUKENSHA_DIR"] ||= File.expand_path("../../../.boukensha", __dir__)
require_relative "../lib/boukensha"

# Config is loaded automatically inside Boukensha.run — system prompt, model,
# and API key all come from ~/.boukensha (or BOUKENSHA_DIR) by default.
# You can still override any of them as keyword arguments if you want.

puts "=== BOUKENSHA Step 7: The Boukensha.run DSL ==="
puts
puts "Config: #{Boukensha.config}"
puts

base_dir = File.expand_path("..", __dir__)

result = Boukensha.run(
  task: "Read the README.md file and summarise what this MUD player assistant framework can do."
) do
  tool "read_file",
    description: "Read the contents of a file from disk",
    parameters:  { path: { type: "string", description: "The file path to read" } } do |path:|
    File.read(File.expand_path(path, base_dir))
  end

  tool "list_directory",
    description: "List the files in a directory",
    parameters:  { path: { type: "string", description: "The directory path to list" } } do |path:|
    Dir.entries(File.expand_path(path, base_dir))
       .reject { |f| f.start_with?(".") }
       .join(", ")
  end
end

puts
puts "=== FINAL RESPONSE ==="
puts result
