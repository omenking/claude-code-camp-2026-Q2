module Boukensha
  module Tools
    # The player-facing `inspect_room` tool's orchestration, kept separate from
    # the run/repl wiring so it can be unit-tested with a fake runner.
    #
    # By design this is thin: the player does NOT gather or parse room data.
    # It triggers the `room_inspector` subagent, which drives the shared MUD
    # session itself (calls the daemon survey, then consider/examine per mob)
    # and returns structured JSON. Here we only kick that off and tidy the
    # result. `run` is injected:
    #
    #   run: ->(instruction) { Boukensha.run_task(Tasks::RoomInspector, instruction) }
    module InspectRoom
      # The single instruction handed to the subagent. Its system prompt owns
      # the how (which tools to call, the JSON schema); this is just the "go".
      INSTRUCTION =
        "Inspect the current room and return the structured room JSON.".freeze

      def self.call(run:)
        clean_json(run.call(INSTRUCTION))
      end

      # LLMs occasionally wrap JSON in a ```json fence despite being told not to.
      # Strip a single surrounding fence so the player always receives bare JSON.
      def self.clean_json(text)
        s = text.to_s.strip
        s = s.sub(/\A```(?:json)?\s*\n?/m, "").sub(/\n?```\z/m, "")
        s.strip
      end
    end
  end
end
