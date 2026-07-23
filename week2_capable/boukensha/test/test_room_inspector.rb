require_relative "helper"
require "json"

# The scripted room survey — what used to be an LLM subagent.
#
# Every fixture in mud_transcripts.json is REAL output captured from the running
# tbaMUD container (.boukensha/manager/20260722.jsonl), ANSI codes and all, so
# these tests fail if tbaMUD's formatting differs from what we assumed rather
# than from what we invented.
class TestRoomInspector < Minitest::Test
  TRANSCRIPTS = JSON.parse(
    File.read(File.expand_path("fixtures/mud_transcripts.json", __dir__))
  ).freeze

  def t(key) = TRANSCRIPTS.fetch(key)

  # Records what was asked and replies from a script. The survey's whole
  # dependency on the outside world is this lambda.
  class FakeMud
    attr_reader :calls

    def initialize(responses)
      @responses = responses
      @calls = []
    end

    def to_proc
      lambda do |name, args = {}|
        @calls << [name, args]
        key = name.sub("tbamud__", "")
        key = "#{key}:#{args[:target] || args[:kind]}" if args[:target] || args[:kind]
        @responses.fetch(key) { @responses.fetch(name.sub("tbamud__", ""), "") }
      end
    end
  end

  def inspector(responses, **kwargs)
    fake = FakeMud.new(responses)
    [Boukensha::Tools::RoomInspector.new(call_tool: fake.to_proc, warn_to: nil, **kwargs), fake]
  end

  def temple_responses
    { "poll" => "", "look" => t("look_temple"), "check:exits" => t("exits_temple") }
  end

  def common_square_responses
    { "poll" => t("poll_event"), "look" => t("look_common_square"),
      "check:exits" => t("exits_common_square"),
      "consider:fido" => t("consider_fido"), "examine:fido" => t("examine_fido") }
  end

  # --- parsing ---------------------------------------------------------------

  def test_parses_name_description_and_prompt_stats_from_real_look_output
    ri, = inspector(temple_responses)
    room = ri.parse_look(t("look_temple"))

    assert_equal "The Temple Of Midgaard", room[:name]
    assert_includes room[:description], "southern end of the temple hall"
    assert_includes room[:description], "ancient wall paintings"
    # Prose is collapsed to one line and stops at the exits line.
    refute_includes room[:description], "[ Exits:"
    refute_includes room[:description], "teller machine"
    assert_equal [20, 100, 85], [room[:hp], room[:mana], room[:move]]
  end

  # The autoexit line gives directions only; destinations come from
  # check(exits), which is why the survey pays for a third round trip.
  def test_parses_exit_destinations
    ri, = inspector(temple_responses)
    exits = ri.parse_exits(t("exits_temple"))

    assert_equal({ "north" => "By The Temple Altar",
                   "east" => "The Midgaard Donation Room",
                   "south" => "The Temple Square",
                   "west" => "The Reading Room",
                   "down" => "The Temple Square" }, exits)
  end

  # tbaMUD paints objects green and mobs yellow (act.informative.c). The room
  # NAME is also yellow, but it is the first line, so position disambiguates.
  def test_splits_mobs_from_objects_by_colour_not_by_guessing
    ri, = inspector(temple_responses)
    room = ri.parse_look(t("look_temple"))

    assert_empty room[:mob_lines]
    assert_equal ["An automatic teller machine has been installed in the wall here."],
                 room[:object_lines].keys
  end

  # Three identical fidos are one appraisal, not three: the old prompt-driven
  # version already did this by accident; here it is the point.
  def test_identical_entity_lines_are_deduped_with_a_count
    ri, = inspector(common_square_responses)
    room = ri.parse_look(t("look_common_square"))

    assert_equal 1, room[:mob_lines].size
    assert_equal 3, room[:mob_lines].values.first
  end

  def test_parses_health_and_equipment_from_examine
    ri, = inspector(temple_responses)
    assert_equal "excellent condition", ri.parse_examine(t("examine_fido"))[:health]

    guard = ri.parse_examine(t("examine_cityguard"))
    assert_equal "excellent condition", guard[:health]
    assert_includes guard[:equipment].join(" "), "wielded"
  end

  # --- keyword guessing ------------------------------------------------------

  def test_guesses_the_target_keyword_from_the_noun_phrase
    ri, = inspector(temple_responses)

    assert_equal "fido", ri.guess_keywords("A beastly fido is mucking through the garbage here.").first
    assert_equal "cityguard", ri.guess_keywords("A cityguard stands here.").first
    # The right answer is `teller`; `machine` is tried first and the MUD is
    # asked to settle it (see the retry test).
    assert_equal %w[machine teller automatic],
                 ri.guess_keywords("An automatic teller machine has been installed in the wall here.")
  end

  # --- the survey ------------------------------------------------------------

  def test_survey_issues_the_fixed_sequence_then_one_pair_per_distinct_mob
    ri, fake = inspector(common_square_responses)
    ri.survey

    assert_equal ["tbamud__poll", "tbamud__look", "tbamud__check",
                  "tbamud__consider", "tbamud__examine"], fake.calls.map(&:first)
    assert_equal({ kind: "exits" }, fake.calls[2].last)
  end

  def test_survey_returns_the_full_room_schema
    ri, = inspector(common_square_responses)
    room = ri.survey

    assert_equal "The Common Square", room[:name]
    assert_equal "The Eastern End Of Poor Alley", room[:exit_targets]["west"]
    assert_equal 1, room[:mobs].size
    assert_equal "fido", room[:mobs].first[:keyword]
    assert_equal 3, room[:mobs].first[:count]
    assert_equal "The perfect match!", room[:mobs].first[:threat]
    assert_equal "excellent condition", room[:mobs].first[:health]
    assert_equal ["The cityguard has arrived."], room[:events]
    assert_empty room[:look_candidates] # no extractor injected
  end

  # A wrong keyword costs one round trip and says so; the survey retries with
  # the next noun rather than dropping the mob.
  def test_a_wrong_keyword_guess_is_retried_against_the_mud
    responses = temple_responses.merge(
      # Repaint the teller machine yellow so it reads as a mob and gets the
      # consider/examine treatment — the keyword the guesser gets wrong.
      "look" => t("look_temple").gsub("\e[0;32m", "\e[0;33m"),
      "consider:machine" => "They aren't here.\r\n",
      "consider:teller" => "Fairly easy.\r\n",
      "examine:teller" => t("examine_cityguard")
    )
    ri, fake = inspector(responses)
    room = ri.survey

    assert_equal %w[machine teller], fake.calls.select { |n, _| n.end_with?("consider") }.map { |_, a| a[:target] }
    assert_equal "teller", room[:mobs].first[:keyword]
    assert_equal "Fairly easy.", room[:mobs].first[:threat]
  end

  def test_a_mob_that_answers_to_nothing_is_kept_with_a_null_threat
    responses = common_square_responses.merge(
      "consider:fido" => "They aren't here.\r\n", "consider:beastly" => "They aren't here.\r\n"
    )
    ri, fake = inspector(responses)
    room = ri.survey

    # Two attempts, then it gives up rather than burning turns.
    assert_equal 2, fake.calls.count { |n, _| n.end_with?("consider") }
    assert_equal 0, fake.calls.count { |n, _| n.end_with?("examine") }
    assert_nil room[:mobs].first[:threat]
    assert_equal "A beastly fido is mucking through the garbage looking for food here.",
                 room[:mobs].first[:desc]
  end

  # The cache is per-session, so the second room with fidos in it pays no miss.
  def test_a_verified_keyword_is_remembered_across_rooms
    responses = common_square_responses.merge(
      "consider:fido" => t("consider_fido"), "consider:beastly" => "They aren't here.\r\n"
    )
    ri, fake = inspector(responses)
    2.times { ri.survey }

    considers = fake.calls.select { |n, _| n.end_with?("consider") }.map { |_, a| a[:target] }
    assert_equal %w[fido fido], considers, "the second room should not re-guess"
  end

  # --- look_candidates -------------------------------------------------------

  def test_look_candidates_come_from_the_injected_extractor
    seen = nil
    extractor = lambda do |name:, description:, exit_targets:, mobs:, objects:, exclude:|
      seen = { name: name, description: description, exits: exit_targets, mobs: mobs }
      %w[garbage]
    end
    ri, = inspector(common_square_responses, look_candidates: extractor)
    room = ri.survey

    assert_equal %w[garbage], room[:look_candidates]
    assert_equal "The Common Square", seen[:name]
    assert_equal "The Eastern End Of Poor Alley", seen[:exits]["west"]
    # The extractor is handed the parsed entities so it can subtract their
    # keywords without the survey knowing how.
    assert_equal "fido", seen[:mobs].first[:keyword]
  end

  def test_survey_still_returns_when_no_extractor_is_installed
    ri, = inspector(common_square_responses, look_candidates: nil)
    assert_empty ri.survey[:look_candidates]
  end

  # --- the player-facing tool ------------------------------------------------

  def test_inspect_room_returns_bare_json
    fake = FakeMud.new(common_square_responses)
    json = Boukensha::Tools::InspectRoom.call(call_tool: fake.to_proc)
    room = JSON.parse(json)

    assert_equal "The Common Square", room["name"]
    assert_equal "fido", room["mobs"].first["keyword"]
    refute_match(/```/, json)
  end
end
