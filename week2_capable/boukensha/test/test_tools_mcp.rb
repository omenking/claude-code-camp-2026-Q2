require_relative "helper"

# Boukensha::Tools::Mcp is the generic MCP host layer: point it at any MCP
# server and that server's tools become boukensha tools. These tests use the
# mud-manager daemon as "some MCP server" and deliberately never rely on it
# being a MUD.
class TestToolsMcp < Minitest::Test
  include McpTestHelper

  def setup
    @fake = start_fake_mud
  end

  def teardown
    @client&.close
    @fake&.stop
  end

  def register(registry, prefix: nil)
    @client = Boukensha::Tools::Mcp.register(
      registry, command: mud_manager_command, args: mud_manager_args,
                env: fake_mud_env(@fake), prefix: prefix
    )
  end

  # Registration with an explicit command: no MUD knowledge anywhere.
  def test_register_populates_the_registry_from_discovery
    ctx, registry = new_registry
    client = register(registry)

    assert_equal client.tools.size, ctx.tools.size
    assert ctx.tools.key?("look")
    assert_match(/You do: look/, registry.dispatch("look", {}))
  end

  # Prefixing is a policy applied agent-side. The server keeps its own names.
  def test_prefix_is_applied_locally_and_the_server_still_sees_bare_names
    ctx, registry = new_registry
    register(registry, prefix: "tbamud")

    assert ctx.tools.key?("tbamud__look")
    refute ctx.tools.key?("look")

    # If the prefix leaked onto the wire the daemon would reject this as an
    # unknown tool; getting the MUD's response back proves it didn't.
    assert_match(/You do: look/, registry.dispatch("tbamud__look", {}))
    assert_match(/You do: kill dragon/, registry.dispatch("tbamud__attack", "target" => "dragon"))
  end

  # Proves prefixing is opt-in policy, not baked into the mechanism.
  def test_nil_prefix_yields_bare_names
    ctx, registry = new_registry
    register(registry, prefix: nil)
    assert ctx.tools.key?("look")
    refute ctx.tools.key?("tbamud__look")
  end

  def test_schema_enum_is_surfaced_in_the_parameter_description
    ctx, registry = new_registry
    register(registry)
    assert_match(/one of:.*north/, ctx.tools["move"].parameters[:direction][:description])
  end

  # Silent clobbering would be maddening to debug, so a collision is a hard
  # error naming the fix. Two servers sharing a prefix is the realistic case.
  def test_colliding_tool_names_raise
    _ctx, registry = new_registry
    register(registry, prefix: "tbamud")

    second = nil
    err = assert_raises(ArgumentError) do
      second = Boukensha::Tools::Mcp.register(
        registry, command: mud_manager_command, args: mud_manager_args,
                  env: fake_mud_env(@fake), prefix: "tbamud"
      )
    end
    assert_match(/collision on 'tbamud__look'/, err.message)
    assert_match(/prefix/, err.message)
  ensure
    second&.close
  end

  # A collision against a tool boukensha registered itself (not another MCP
  # server) must be caught too — a filesystem server advertising `read_file`
  # is the obvious one.
  def test_collision_with_an_existing_non_mcp_tool_raises
    _ctx, registry = new_registry
    registry.tool("look", description: "pre-existing") { "local" }

    err = assert_raises(ArgumentError) { register(registry) }
    assert_match(/collision on 'look'/, err.message)
  end
end
