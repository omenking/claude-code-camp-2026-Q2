# BoukenshaLoader resolves which step folder to load from, then boots the REPL.
#
# Resolution order:
#   1. BOUKENSHA_PATH environment variable (selects which *step* lib to load)
#   2. ~/.boukensharc  (a file containing a single path)
#   3. The lib/ directory bundled inside this gem (step 10 — the latest release)
#
# Config directory (settings.yaml, .env, system.md) is separate:
#   BOUKENSHA_DIR=~/.boukensha  (default; set to override)
#
# MUD connection details come from settings.yaml (mud: block) by default.
# The legacy MUD_NAME / MUD_HOST / MUD_PORT / MUD_PASSWORD env vars are still
# honoured and take precedence over config when set.
#
# Examples:
#   boukensha                                                              # uses bundled lib + ~/.boukensha
#   BOUKENSHA_PATH=~/Sites/boukensha/04_api_client boukensha              # loads step 4
#   BOUKENSHA_DIR=~/projects/mybot/.boukensha boukensha                   # custom config dir
#   echo ~/Sites/boukensha/10_standard_tool_library > ~/.boukensharc && boukensha
module BoukenshaLoader
  # Absolute path to this gem's own bundled boukensha lib.
  BUNDLED_LIB = File.expand_path("../boukensha.rb", __FILE__)

  def self.resolve
    # 1. Env var wins.
    if ENV["BOUKENSHA_PATH"]
      dir  = File.expand_path(ENV["BOUKENSHA_PATH"])
      main = File.join(dir, "lib", "boukensha.rb")
      return main if File.exist?(main)

      abort <<~MSG
        boukensha: BOUKENSHA_PATH is set but no lib/boukensha.rb found at:
               #{dir}
               Make sure BOUKENSHA_PATH points to a step folder, e.g.:
               BOUKENSHA_PATH=~/Sites/boukensha/07_the_repl_loop boukensha
      MSG
    end

    # 2. ~/.boukensharc
    rc = File.expand_path("~/.boukensharc")
    if File.exist?(rc)
      dir  = File.read(rc).strip
      unless dir.empty?
        main = File.join(File.expand_path(dir), "lib", "boukensha.rb")
        return main if File.exist?(main)

        abort <<~MSG
          boukensha: ~/.boukensharc points to #{dir}
                 but no lib/boukensha.rb was found there.
                 Update ~/.boukensharc or remove it to use the bundled default.
        MSG
      end
    end

    # 3. Bundled default.
    BUNDLED_LIB
  end

  def self.load_and_start_repl
    main = resolve
    step_dir = File.dirname(File.dirname(main))

    puts "[boukensha] loading from: #{step_dir}" if ENV["BOUKENSHA_DEBUG"]

    require main

    unless Boukensha.respond_to?(:repl)
      abort <<~MSG
        boukensha: the step at #{step_dir}
               does not support the interactive REPL (added in step 7).
               Run its examples directly, e.g.:
                 ruby #{step_dir}/examples/*.rb
               Or point BOUKENSHA_PATH at step 7 or later.
      MSG
    end

    repl_opts = {}

    if ENV["MUD_NAME"]
      # Legacy env-var override still works and takes precedence over config.
      repl_opts[:working_dir] = false
      repl_opts[:mud] = {
        host:     ENV.fetch("MUD_HOST",     "localhost"),
        port:     ENV.fetch("MUD_PORT",     "4000").to_i,
        name:     ENV.fetch("MUD_NAME"),
        password: ENV.fetch("MUD_PASSWORD") { abort "boukensha: MUD_NAME is set but MUD_PASSWORD is missing." }
      }
    end
    # If MUD_NAME is not set, Boukensha.repl will fall back to config.mud_* values
    # automatically (via mud_opts_from_config inside Boukensha.repl).

    Boukensha.repl(**repl_opts)
  end
end
