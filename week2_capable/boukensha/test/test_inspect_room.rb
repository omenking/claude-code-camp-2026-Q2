require_relative "helper"

# The inspect_room feature: the player's native tool triggers the agentic
# room_inspector subagent (which drives the shared MUD session itself), plus the
# shared-session tool-visibility filter. These cover the seams with fakes — no
# live API or MCP server required.
class TestInspectRoom < Minitest::Test
  include McpTestHelper

  # --- the player-facing tool: trigger subagent, return clean JSON ----------

  def test_call_triggers_subagent_with_instruction_and_returns_clean_json
    seen = nil
    result = Boukensha::Tools::InspectRoom.call(
      run: ->(instruction) { seen = instruction; %({"name":"Market Square"}) }
    )

    # The player passes NO room data in — it just kicks off the inspector.
    assert_equal Boukensha::Tools::InspectRoom::INSTRUCTION, seen
    assert_equal %({"name":"Market Square"}), result
  end

  def test_clean_json_strips_a_stray_markdown_fence
    fenced = "```json\n{\"name\":\"Temple\"}\n```"
    assert_equal %({"name":"Temple"}), Boukensha::Tools::InspectRoom.clean_json(fenced)
    bare = %({"name":"Temple"})
    assert_equal bare, Boukensha::Tools::InspectRoom.clean_json(bare)
  end

  def test_run_task_is_available_for_subagent_delegation
    assert_respond_to Boukensha, :run_task
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
