require "json"
require_relative "room_inspector"

module Boukensha
  module Tools
    # The player-facing `inspect_room` tool's orchestration, kept separate from
    # the run/repl wiring so it can be unit-tested with a fake dispatcher.
    #
    # By design this is thin: the player does NOT gather or parse room data. It
    # hands off to `RoomInspector`, which drives the shared MUD session itself
    # (poll → look → exits, then consider/examine per distinct mob) and returns
    # the structured room. Here we only kick that off and serialise.
    #
    # `call_tool` is injected — at the entrypoint it is a permission-scoped
    # dispatcher over the same MCP clients the player uses:
    #
    #   Boukensha::Tools::InspectRoom.call(
    #     call_tool: Boukensha.task_dispatcher(Tools::RoomInspector::TASK_NAME, logger: parent),
    #     look_candidates: Boukensha::Extractors.look_candidates
    #   )
    #
    # so the survey's MUD calls still land in the player's session file under
    # task `room_inspector` (mud_monitor's session view depends on that shape),
    # and still run under `room_inspector`'s allowlist rather than the player's.
    module InspectRoom
      def self.call(call_tool:, look_candidates: nil, prefix: "tbamud__")
        inspector = RoomInspector.new(call_tool: call_tool,
                                      look_candidates: look_candidates, prefix: prefix)
        JSON.generate(inspector.survey)
      end

      # There is no model in this path any more, so nothing here emits a fence.
      # Kept because `inspect_room`'s output is a public contract and a stray
      # fence is cheaper to strip than to debug.
      def self.clean_json(text)
        s = text.to_s.strip
        s = s.sub(/\A```(?:json)?\s*\n?/m, "").sub(/\n?```\z/m, "")
        s.strip
      end
    end
  end
end
