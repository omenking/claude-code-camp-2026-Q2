require_relative "../lib/boukensha"

# Config is loaded automatically inside Boukensha.repl — system prompt, model,
# and API key all coue from ~/.boukensha (or BOUKENSHA_DIR) by default.

puts "Config: #{Boukensha.config}"
puts

# The base directory tools will operate relative to — the step 7 folder makes
# a good playground since it already has source files to read.
base_dir = File.expand_path("../../07_the_run_dsl", __dir__)

Boukensha.repl do
  tool "read_file",
    description: "Read the contents of a file from disk",
    parameters:  { path: { type: "string", description: "File path (relative to the working directory)" } } do |path:|
    File.read(File.expand_path(path, base_dir))
  end

  tool "list_directory",
    description: "List the files in a directory",
    parameters:  { path: { type: "string", description: "Directory path (relative to the working directory, or '.' for root)" } } do |path:|
    Dir.entries(File.expand_path(path, base_dir))
       .reject { |f| f.start_with?(".") }
       .sort
       .join(", ")
  end
end
