require_relative "tool"
require_relative "message"

module Boukensha
  class Context
    attr_reader :task, :system, :messages, :tools, :working_dir

    def initialize(task:, system: nil, working_dir: nil)
      @task        = task
      @system      = system
      @working_dir  = working_dir ? File.expand_path(working_dir) : nil
      @messages     = []
      @tools        = {}
    end

    def register_tool(tool)
      @tools[tool.name] = tool
    end

    def add_message(role, content, tool_use_id: nil)
      @messages << Message.new(role, content, tool_use_id)
    end

    # Drop all conversation history, keeping tools and system prompt intact.
    # Used by the REPL's `clear` command.
    def clear_messages!
      @messages = []
    end

    def tool_count = @tools.size
    def turn_count = @messages.size

    def to_s
      "#<Context task=#{task&.task_name} turns=#{turn_count} tools=#{tool_count}>"
    end
  end
end
