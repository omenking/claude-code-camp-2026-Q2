require_relative "helper"

# Registry is the single enforcement point for a task's `allow:` rules: every
# tool reaches it through #tool, whether it's MCP-derived (Tools::Mcp) or
# registered natively (RunDSL#tool, e.g. the player's inspect_room). These
# tests exercise that gate directly, independent of either caller.
class TestRegistry < Minitest::Test
  def test_permissive_default_registers_and_dispatches_freely
    ctx = Boukensha::Context.new(system: "t")
    reg = Boukensha::Registry.new(ctx) # no permissions: — permissive, current default

    tool = reg.tool("anything", description: "d") { |**_| "ok" }

    refute_nil tool
    assert_includes reg.tool_names, "anything"
    assert_equal "ok", reg.dispatch("anything")
  end

  def test_deny_all_registers_nothing
    ctx = Boukensha::Context.new(system: "t")
    reg = Boukensha::Registry.new(ctx, permissions: Boukensha::Permissions.deny_all)

    tool = reg.tool("anything", description: "d") { |**_| "ok" }

    assert_nil tool
    refute_includes reg.tool_names, "anything"
  end

  def test_dispatch_raises_unknown_tool_for_a_name_never_registered
    ctx = Boukensha::Context.new(system: "t")
    reg = Boukensha::Registry.new(ctx)

    assert_raises(Boukensha::UnknownToolError) { reg.dispatch("nope") }
  end

  def test_dispatch_raises_unauthorized_for_a_value_the_rule_forbids
    ctx = Boukensha::Context.new(system: "t")
    perms = Boukensha::Permissions.from(["check(kind: exits)"])
    reg = Boukensha::Registry.new(ctx, permissions: perms)
    reg.tool("check", description: "d") { |**kwargs| "ok:#{kwargs[:kind]}" }

    assert_equal "ok:exits", reg.dispatch("check", kind: "exits")
    err = assert_raises(Boukensha::UnauthorizedToolError) { reg.dispatch("check", kind: "score") }
    assert_match(/not permitted/, err.message)
  end

  # The exact seam RunDSL#tool uses (a bare Registry#tool call, no MCP
  # involved) — a native tool is gated identically to an MCP tool.
  def test_a_native_style_tool_not_named_by_any_rule_is_never_registered
    ctx = Boukensha::Context.new(system: "t")
    perms = Boukensha::Permissions.from(["poll"]) # does not name inspect_room
    reg = Boukensha::Registry.new(ctx, permissions: perms)

    reg.tool("inspect_room", description: "d") { |**_| "json" }

    refute_includes reg.tool_names, "inspect_room"
    assert_raises(Boukensha::UnknownToolError) { reg.dispatch("inspect_room") }
  end
end
