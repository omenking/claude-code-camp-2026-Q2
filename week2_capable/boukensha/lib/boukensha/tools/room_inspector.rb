require "json"
require "set"

module Boukensha
  module Tools
    # Surveys the current room over the shared MUD session and returns it as
    # structured data. No LLM: this used to be an agentic subagent that asked
    # Haiku which of five fixed commands to run next, three inferences to issue
    # a sequence its own prompt named in order (18.6s of a 33.8s call, and 47%
    # of a session's spend). The sequence is fixed and the parse is mechanical,
    # so both are Ruby now.
    #
    # It still runs under the `room_inspector` permission scope from
    # settings.yaml — poll, look, check(exits), consider, examine, and nothing
    # else — because removing the model must not widen the tool surface. `look`
    # is deliberately absent from the *player's* allowlist, so this is the only
    # route to a room survey.
    #
    # `call_tool` is injected (`->(name, args) { text }`) so the whole survey is
    # testable against a transcript with no MUD, no MCP, and no network.
    # See docs/plans/week_2/scripted_room_survey.md.
    class RoomInspector
      TASK_NAME = "room_inspector".freeze

      # tbaMUD colours the two entity lists differently, verified in
      # src/act.informative.c: list_obj_to_char() wraps ground objects in
      # CCGRN, list_char_to_char() wraps mobs in CCYEL. look_at_room() also
      # paints the ROOM NAME with CCYEL — same code as mobs — but it is the
      # first line, so position disambiguates it.
      YELLOW = "\e[0;33m".freeze   # mobs (and the room name)
      GREEN  = "\e[0;32m".freeze   # ground objects
      RESET  = "\e[0m".freeze
      ANSI   = /\e\[[0-9;]*m/.freeze

      EXITS_LINE  = /^\[ Exits:.*\]$/.freeze
      PROMPT_LINE = /^\d+H \d+M \d+V/.freeze
      STATS       = /(\d+)H (\d+)M (\d+)V/.freeze

      # "north - By The Temple Altar"
      EXIT_TARGET = /^(\w+)\s+-\s+(.+)$/.freeze

      # Where a mob's long description stops being its name. "A beastly fido IS
      # mucking…", "A cityguard STANDS here." Everything before the verb is the
      # noun phrase we can guess a keyword from.
      VERB = /\b(?:is|are|was|were|has|have|had|stands?|sits?|lies?|rests?|sleeps?|
                 hangs?|leans?|waits?|guards?|paces?|walks?|blocks?|kneels?|floats?)\b/x.freeze

      ARTICLES = %w[a an the some].to_set

      # tbaMUD's answer when a keyword doesn't match anything in the room.
      NOT_HERE = /aren't here|isn't here|no one here|nothing here/i.freeze

      MAX_KEYWORD_ATTEMPTS = 2

      def initialize(call_tool:, look_candidates: nil, prefix: "tbamud__", warn_to: $stderr)
        @call_tool  = call_tool
        @extract    = look_candidates
        @prefix     = prefix
        @warn_to    = warn_to
        # Session-lifetime: entity line -> the keyword the MUD actually answered
        # to. Fidos, cityguards and Peacekeepers recur constantly, so after the
        # first room most rooms cost zero extra round trips to resolve.
        # NOT the same cache as look_candidates' — that one maps noun ->
        # is-examinable. Merging them would be a category error.
        @keywords = {}
      end

      # The survey. Steps 1-3 are unconditional and fixed; step 4 is the only
      # data-dependent part, and dedupe means three identical fidos cost one
      # consider/examine pair, not three.
      def survey
        # Every MUD response ends with the prompt ("20H 100M 85V (news) >").
        # It is never an event, and shipping it as one would put a false line
        # into the room record the player reasons over.
        events = lines(call(:poll)).reject { |l| l =~ PROMPT_LINE }
        room   = parse_look(call(:look))
        exits  = parse_exits(call(:check, kind: "exits"))

        mobs = room[:mob_lines].map { |line, count| appraise(line, count) }
        objects = room[:object_lines].map do |line, count|
          { keyword: guess_keywords(line).first, desc: line, count: count }.compact
        end

        {
          name: room[:name],
          description: room[:description],
          exit_targets: exits,
          hp: room[:hp], mana: room[:mana], move: room[:move],
          mobs: mobs,
          objects: objects,
          look_candidates: candidates(room, exits, mobs, objects),
          events: events
        }
      end

      def to_json(*_args) = JSON.generate(survey)

      # --- parsing (pure, no I/O) ----------------------------------------------

      # The room name, the prose, the entity lines after `[ Exits: ]`, and the
      # prompt stats — all in one pass over `look`'s output.
      def parse_look(text)
        raw = text.to_s.split(/\r?\n/)
        coloured = raw.map { |l| [l, colour_of(l)] }
        stripped = raw.map { |l| strip(l) }

        exits_at = stripped.index { |l| l =~ EXITS_LINE }
        name = stripped.find { |l| !l.empty? } || ""
        body = exits_at ? stripped[(stripped.index(name) + 1)...exits_at] : []

        entities = exits_at ? coloured[(exits_at + 1)..] || [] : []
        mob_lines, object_lines = classify(entities)

        stats = stripped.find { |l| l =~ PROMPT_LINE }&.match(STATS)
        { name: name,
          description: body.map(&:strip).reject(&:empty?).join(" ").squeeze(" "),
          mob_lines: mob_lines, object_lines: object_lines,
          hp: stats && stats[1].to_i, mana: stats && stats[2].to_i, move: stats && stats[3].to_i }
      end

      # "Obvious exits:" then "direction - Destination" per line. The
      # `[ Exits: n e s w ]` line in `look` gives directions only, never
      # destinations, so this second call is load-bearing rather than redundant.
      def parse_exits(text)
        lines(text).each_with_object({}) do |line, out|
          next if line =~ PROMPT_LINE || line.start_with?("Obvious exits")

          m = line.match(EXIT_TARGET) or next
          out[m[1].downcase] = m[2].strip
        end
      end

      # "The cityguard is in excellent condition." plus anything after
      # "is using:".
      def parse_examine(text)
        rows = lines(text)
        health = rows.find { |l| l =~ /is in (.+?) condition/ }&.match(/is in (.+?) condition/)&.captures&.first
        using = rows.index { |l| l =~ /is using:/ }
        equipment = using ? rows[(using + 1)..].reject { |l| l =~ PROMPT_LINE } : []
        { health: health && "#{health} condition", equipment: equipment }
      end

      # Keyword guesses, best first: the nouns of the leading noun phrase, read
      # right to left. "A beastly fido is mucking…" -> ["fido", "beastly"];
      # "An automatic teller machine has been…" -> ["machine", "teller",
      # "automatic"]. The first guess is usually right and the caller verifies
      # the rest against the MUD rather than trusting this.
      def guess_keywords(line)
        phrase = strip(line).split(VERB).first.to_s
        phrase.scan(/[A-Za-z]+/)
              .map(&:downcase)
              .reject { |w| ARTICLES.include?(w) }
              .reverse
      end

      private

      def call(tool, **args)
        @call_tool.call("#{@prefix}#{tool}", args)
      end

      def lines(text) = text.to_s.split(/\r?\n/).map { |l| strip(l).strip }.reject(&:empty?)

      def strip(line) = line.to_s.gsub(ANSI, "").delete("\r")

      # The colour a line's text is actually printed in — the LAST non-reset
      # code in its leading run of escapes. tbaMUD does not emit one code per
      # line: the reset that closes entity N lands at the start of the line
      # carrying entity N+1 ("\e[0m\e[0;33mA beastly fido…"), so reading the
      # first code finds the reset and every entity after the first looks
      # uncoloured.
      def colour_of(line)
        leading = line.to_s[/\A(?:\e\[[0-9;]*m)+/] or return nil
        leading.scan(ANSI).reject { |c| c == RESET }.last
      end

      # Split the post-exits lines into mobs and objects, deduping identical
      # lines (three fidos are one appraisal). Colour is the signal; if the
      # character's `color` toggle is off there are no codes at all, and we say
      # so rather than guessing silently.
      def classify(entities)
        mobs = Hash.new(0)
        objects = Hash.new(0)
        uncoloured = 0

        entities.each do |raw, colour|
          line = strip(raw).strip
          next if line.empty? || line =~ PROMPT_LINE

          case colour
          when GREEN  then objects[line] += 1
          when YELLOW then mobs[line] += 1
          else
            uncoloured += 1
            # Positional fallback: tbaMUD prints objects before mobs, but with
            # no colour we cannot tell where the boundary is. Mobs is the safer
            # bucket — a wrong `consider` costs one round trip and answers
            # "They aren't here", where a missed mob silently drops a threat.
            mobs[line] += 1
          end
        end

        if uncoloured.positive?
          @warn_to&.puts "[room_inspector] #{uncoloured} entity line(s) had no colour codes; " \
                         "mob/object split is a guess. Enable the character's `color` toggle."
        end
        [mobs, objects]
      end

      # consider + examine per DISTINCT mob, with the keyword verified against
      # the MUD instead of assumed.
      def appraise(line, count)
        keyword, threat = resolve(line)
        return { keyword: nil, desc: line, count: count, threat: nil } unless keyword

        detail = parse_examine(call(:examine, target: keyword))
        { keyword: keyword, desc: line, count: count, threat: threat,
          health: detail[:health], equipment: detail[:equipment] }
      end

      # Returns [keyword, threat]. A cached keyword still costs one `consider`
      # (that IS the threat reading) but never costs a miss.
      def resolve(line)
        guesses = @keywords[line] ? [@keywords[line]] : guess_keywords(line).first(MAX_KEYWORD_ATTEMPTS)

        guesses.each do |guess|
          answer = call(:consider, target: guess).to_s
          next if answer =~ NOT_HERE

          @keywords[line] = guess
          return [guess, lines(answer).reject { |l| l =~ PROMPT_LINE }.first]
        end
        # Give up rather than burning turns — same posture the old prompt
        # specified: emit the mob with a null threat.
        [nil, nil]
      end

      # The one field no parse can produce. Advisory by design, so a missing
      # model just means an empty list.
      def candidates(room, exits, mobs, objects)
        return [] unless @extract

        @extract.call(name: room[:name], description: room[:description],
                      exit_targets: exits, mobs: mobs, objects: objects,
                      exclude: Set.new)
      end
    end
  end
end
