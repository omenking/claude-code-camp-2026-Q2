require "open3"
require "timeout"

module Boukensha
  module Tools
    # Shell registers command-execution tools against a registry.
    #
    # Tools registered:
    #   run_command  — run an arbitrary shell command inside the working directory
    #
    # Options:
    #   working_dir:  (required) all commands run with this as their cwd
    #   timeout:      seconds before a command is killed (default 30)
    #   allowed_commands: optional Array of allowed executable names (e.g. ["ruby", "git"]).
    #                 When nil (the default) all commands are permitted.
    #                 When set, any command whose first token is not in the list
    #                 is rejected before execution.
    #
    # Usage (handled automatically by Boukensha.run / Boukensha.repl when working_dir:
    # is set):
    #
    #   Boukensha::Tools::Shell.register(
    #     registry,
    #     working_dir:      "/my/project",
    #     allowed_commands: ["ruby", "bundle", "rspec", "git"]
    #   )
    #
    module Shell
      def self.register(registry, working_dir:, timeout: 30, allowed_commands: nil)
        root = File.expand_path(working_dir)
        oops = ->(msg) { "error: #{msg}" }

        registry.tool "run_command",
          description: "Run a shell command inside the working directory and return its combined stdout+stderr output. " \
                       "Commands run with a #{timeout}-second timeout. " \
                       "#{"Allowed executables: #{allowed_commands.join(', ')}." if allowed_commands}",
          parameters: {
            command: { type: "string", description: "The shell command to execute (e.g. 'ruby script.rb', 'ls -la', 'git status')" }
          } do |command:|

          # Guard: check the first token against the allow-list when one is set
          if allowed_commands
            executable = command.to_s.strip.split(/\s+/).first.to_s
            unless allowed_commands.map(&:to_s).include?(executable)
              next oops.call("'#{executable}' is not in the allowed-commands list (#{allowed_commands.join(', ')})")
            end
          end

          stdout_err, status = nil, nil

          begin
            Timeout.timeout(timeout) do
              stdout_err, status = Open3.capture2e(command, chdir: root)
            end
          rescue Errno::ENOENT => e
            next oops.call("command not found: #{e.message}")
          rescue Timeout::Error
            next oops.call("command timed out after #{timeout}s: #{command}")
          rescue => e
            next oops.call(e.message)
          end

          exit_note = status.success? ? "" : "\n[exit #{status.exitstatus}]"
          output    = stdout_err.to_s.strip
          output.empty? ? "(no output)#{exit_note}" : "#{output}#{exit_note}"
        end

      end # def self.register
    end # Shell
  end # Tools
end # Boukensha
