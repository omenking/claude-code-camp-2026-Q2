require "set"

module Boukensha
  module Extractors
    # The free half of `look_candidates`: words we can rule out with no model
    # at all, because the survey already knows what they are.
    #
    # Room descriptions are mostly navigation. From The Common Square:
    #
    #   "To the west is the poor alley and to the east is the dark alley. To
    #    the north, this square is connected to the market square."
    #
    # Every noun there names an adjacent room — and `check(kind: exits)` already
    # told us their names. Probing them costs a MUD round trip each and can
    # never succeed. The same holds for the mobs and objects the room listed:
    # they are entities you interact with, not scenery hiding a description.
    #
    # This runs in front of the model and is worth building even if the model is
    # never installed (docs/plans/week_2/scripted_room_survey.md 10.6).
    module Structural
      WORD = /[A-Za-z]{2,}/.freeze

      # exit_targets: { "north" => "The Temple Of Midgaard", ... }
      # mobs/objects: the parsed entity records; only their `keyword` is used.
      #
      # Entity *long descriptions* are deliberately NOT subtracted, though the
      # plan first specified them. "A beastly fido is mucking through the
      # garbage" would remove `garbage`, and garbage heaps are exactly the kind
      # of thing a builder hides an extra-description on. Exit names and
      # keywords can never be examinable scenery; a noun that merely co-occurs
      # with a mob often can.
      def self.exclusions(exit_targets: {}, mobs: [], objects: [])
        words = Set.new
        exit_targets.each_value { |dest| add(words, dest) }
        (mobs + objects).each { |e| add(words, e[:keyword] || e["keyword"]) }
        words
      end

      def self.add(set, text)
        text.to_s.scan(WORD) { |w| set << w.downcase }
      end
      private_class_method :add
    end
  end
end
