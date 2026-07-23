require_relative "helper"
require "json"

# The inspect_room feature: the player's native tool, the permission-scoped
# dispatcher it drives the MUD through, and the shared-session tool-visibility
# filter. These cover the seams with fakes — no live API or MCP server required.
# The survey's own parsing and sequencing live in test_room_inspector.rb.
class TestInspectRoom < Minitest::Test
  include McpTestHelper

  # The survey runs under inspect_room's OWN allowlist, not the player's —
  # which is what keeps `look` out of reach except through here.
  def test_tool_dispatcher_is_available
    assert_respond_to Boukensha, :tool_dispatcher
  end

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
    [Boukensha::Tools::InspectRoom.new(call_tool: fake.to_proc, warn_to: nil, **kwargs), fake]
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
  # --- permission rule parsing (matcher strings + pipes) --------------------

  def test_parses_bare_tool_and_pinned_and_piped_rules
    p = Boukensha::Permissions.from(["poll", "check(kind: exits)", "say(mode: say|emote)"])
    assert p.allow_tool?("tbamud__poll")     # bare name matches prefixed tool
    assert p.allow_tool?("tbamud__check")
    refute p.allow_tool?("tbamud__move")     # default-deny: not listed
    # single-value pin
    assert p.call_permitted?("tbamud__check", { kind: "exits" })
    refute p.call_permitted?("tbamud__check", { kind: "score" })
    # piped alternation
    assert p.call_permitted?("tbamud__say", { mode: "emote" })
    refute p.call_permitted?("tbamud__say", { mode: "shout" })
  end

  def test_bare_tool_allows_any_args
    p = Boukensha::Permissions.from(["consider"])
    assert p.call_permitted?("tbamud__consider", { target: "anything" })
    assert p.call_permitted?("tbamud__consider", {})
  end

  def test_deny_all_and_permissive
    assert Boukensha::Permissions.from(nil).permissive?
    refute Boukensha::Permissions.deny_all.allow_tool?("tbamud__anything")   # [] ⇒ deny all
    assert Boukensha::Permissions.from(nil).allow_tool?("tbamud__anything")  # nil ⇒ permissive
  end

  def test_star_pattern_leaves_param_open
    p = Boukensha::Permissions.from(["check(kind: *)"])
    assert p.call_permitted?("tbamud__check", { kind: "anything" })
    assert_equal %w[a b], p.allowed_values("tbamud__check", "kind", %w[a b])
  end

  def test_invalid_rule_syntax_raises
    assert_raises(Boukensha::Permissions::Error) { Boukensha::Permissions.from(["check(kind)"]) }
    assert_raises(Boukensha::Permissions::Error) { Boukensha::Permissions.from(["bad name!"]) }
  end

  # --- enum narrowing (advertised) ------------------------------------------

  def test_allowed_values_narrows_and_unions
    p = Boukensha::Permissions.from(["check(kind: exits|time)"])
    assert_equal %w[exits time], p.allowed_values("tbamud__check", "kind", %w[score exits time gold])
    # order preserved from the server's enum, not the rule
    assert_equal %w[time exits], p.allowed_values("tbamud__check", "kind", %w[time exits score])
    # a param the rule doesn't pin stays fully open
    assert_equal %w[a b], p.allowed_values("tbamud__check", "other", %w[a b])
  end

  # --- validation against the tool's own schema -----------------------------

  def test_validate_tool_rejects_unknown_param_and_bad_enum_value
    schema = { "properties" => { "kind" => { "type" => "string", "enum" => %w[score exits] } } }

    ok = Boukensha::Permissions.from(["check(kind: exits)"])
    ok.validate_tool!("tbamud__check", schema) # no raise

    bad_val = Boukensha::Permissions.from(["check(kind: teleport)"])
    err = assert_raises(Boukensha::Permissions::Error) { bad_val.validate_tool!("tbamud__check", schema) }
    assert_match(/not a valid kind/, err.message)
    assert_match(/one of: score, exits/, err.message)

    bad_param = Boukensha::Permissions.from(["check(knd: exits)"])
    assert_raises(Boukensha::Permissions::Error) { bad_param.validate_tool!("tbamud__check", schema) }

    # a free-string param (no enum) is not constrainable
    plain = { "properties" => { "target" => { "type" => "string" } } }
    not_constrainable = Boukensha::Permissions.from(["consider(target: bob)"])
    err2 = assert_raises(Boukensha::Permissions::Error) { not_constrainable.validate_tool!("tbamud__consider", plain) }
    assert_match(/not constrainable/, err2.message)
  end

  def test_validate_referenced_rejects_unknown_tool
    p = Boukensha::Permissions.from(["poll", "nonexistent_tool"])
    assert_raises(Boukensha::Permissions::Error) { p.validate_referenced!(%w[tbamud__poll tbamud__look]) }
    p2 = Boukensha::Permissions.from(["poll"])
    p2.validate_referenced!(%w[tbamud__poll]) # no raise
  end

  # --- Registry enforces name + value levels for every tool it registers ----
  # (register_client no longer gates its own callers — Registry#tool/#dispatch
  # is the single enforcement point every path passes through, MCP or native.)

  def test_register_client_registers_only_allowed_tools
    ctx = Boukensha::Context.new(system: "t")
    perms = Boukensha::Permissions.from(%w[move consider])
    reg = Boukensha::Registry.new(ctx, permissions: perms)
    fake = FakeMcpClient.new("look" => nil, "move" => nil, "consider" => nil)

    registered = Boukensha::Tools::Mcp.register_client(reg, fake, prefix: "tbamud", permissions: perms)

    assert_equal 2, registered
    assert_equal %w[tbamud__consider tbamud__move], ctx.tools.keys.sort
    refute ctx.tools.key?("tbamud__look")
  end

  def test_register_client_narrows_enum_and_guards_dispatch
    ctx = Boukensha::Context.new(system: "t")
    perms = Boukensha::Permissions.from(["check(kind: exits)"])
    reg = Boukensha::Registry.new(ctx, permissions: perms)
    fake = FakeMcpClient.new("check" => %w[score exits gold])

    Boukensha::Tools::Mcp.register_client(reg, fake, prefix: "tbamud", permissions: perms)

    # advertised enum narrowed to just "exits"
    desc = ctx.tools["tbamud__check"].parameters[:kind][:description]
    assert_match(/one of: exits/, desc)
    refute_match(/score/, desc)

    # permitted value reaches the server
    assert_equal "ok:check", reg.dispatch("tbamud__check", kind: "exits")
    assert_equal [["check", { "kind" => "exits" }]], fake.calls

    # forbidden value is rejected BEFORE the server is called (no new call)
    err = assert_raises(Boukensha::UnauthorizedToolError) { reg.dispatch("tbamud__check", kind: "score") }
    assert_match(/not permitted/, err.message)
    assert_equal 1, fake.calls.size
  end

  # Minimal stand-in for Boukensha::Mcp::Client. Construct with { name => enum },
  # where enum is an array of a `kind` param's values, or nil for a no-param tool.
  class FakeMcpClient
    attr_reader :calls, :tools
    def initialize(spec)
      @tools = spec.map do |name, enum|
        schema = enum ? { "properties" => { "kind" => { "type" => "string", "enum" => enum } } } : {}
        { "name" => name, "description" => name, "inputSchema" => schema }
      end
      @calls = []
    end
    def call_tool(name, args = {})
      @calls << [name, args]
      { text: "ok:#{name}", error: false }
    end
  end
end
