require_relative "base"

module Boukensha
  module Tasks
    # A single-purpose subagent: turn the raw text of an `inspect` survey
    # (events + look + exits) into the structured room JSON the player agent
    # consumes. It never plays the game and holds no conversation — its entire
    # job is text → JSON against a fixed schema (see prompts/room_inspector/
    # system.md). Cheap and swappable: model/provider live in settings.yaml, so
    # the managed Haiku 4.5 used today can later be swapped for a local Ollama
    # 3B with no code change.
    class RoomInspector < Base
      def self.task_name = "room_inspector"
    end
  end
end
