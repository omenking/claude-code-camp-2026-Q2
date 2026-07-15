require_relative "tool"
require_relative "message"

module Boukensha
  class Context
    attr_reader :task, :system, :messages, :tools

    def initialize(task:, system: nil)
      @task        = task
      @system      = system
      @messages     = []
      @tools        = {}
    end

    def register_tool(tool)
      @tools[tool.name] = tool
    end

    def add_message(role, content, tool_use_id: nil)
      @messages << Message.new(role, content, tool_use_id)
    end

    def tool_count = @tools.size
    def turn_count = @messages.size

    def to_s
      "#<Context task=#{task&.task_name} turns=#{turn_count} tools=#{tool_count}>"
    end
  end
end