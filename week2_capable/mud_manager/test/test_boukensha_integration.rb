require_relative "helper"

# Proves the daemon integrates with boukensha step 10 END TO END, exercising
# boukensha's OWN Registry + RunDSL + dispatch path (the same objects
# Boukensha.run/repl use), so we know it works there without needing an LLM or
# an ANTHROPIC_API_KEY.
#
# The registration side is boukensha's generic Boukensha::Tools::Mcp — nothing
# in it is MUD-aware, because boukensha owns no tools at all now. This test
# drives it with no prefix, so the daemon's names arrive bare; in a real agent
# the `prefix: tbamud` comes from the server's settings.yaml entry.
#
# Skips cleanly if the boukensha step can't be located.
class TestBoukenshaIntegration < Minitest::Test
  BOUKENSHA_LIB = File.expand_path(
    "../../../week1_baseline/ruby/10_standard_tool_library/lib", __dir__
  )

  def setup
    unless File.directory?(BOUKENSHA_LIB)
      skip "boukensha step 10 not found at #{BOUKENSHA_LIB}"
    end
    $LOAD_PATH.unshift(BOUKENSHA_LIB) unless $LOAD_PATH.include?(BOUKENSHA_LIB)
    require "boukensha"

    @fake   = FakeMud.new
    @client = MudManager::Mcp::Client.spawn(env: {
      "MUD_HOST"     => "127.0.0.1",
      "MUD_PORT"     => @fake.port.to_s,
      "MUD_NAME"     => "Gandalf",
      "MUD_PASSWORD" => "secret"
    })
  end

  def teardown
    @client&.close
    @fake&.stop
  end

  def build_registry
    ctx = Boukensha::Context.new(task: Boukensha::Tasks::Player,
                                 system: "test", working_dir: nil)
    registry = Boukensha::Registry.new(ctx)
    dsl      = Boukensha::RunDSL.new(registry)
    count    = Boukensha::Tools::Mcp.register_client(dsl, @client)
    [ctx, registry, count]
  end

  def test_bridge_registers_every_tool_into_boukensha
    ctx, _registry, count = build_registry
    assert_equal @client.tools.size, count
    assert_equal @client.tools.size, ctx.tools.size
    assert ctx.tools.key?("attack")
    assert ctx.tools.key?("look")
    assert ctx.tools.key?("poll")
  end

  def test_boukensha_dispatch_drives_the_mud_through_mcp
    _ctx, registry, _count = build_registry

    # No-arg tool — first call connects + logs in behind the daemon boundary.
    look = registry.dispatch("look", {})
    assert_match(/You do: look/, look)

    # Args flow boukensha -> bridge -> MCP -> Primitives -> MUD.
    atk = registry.dispatch("attack", { "target" => "goblin", "style" => "murder" })
    assert_match(/You do: murder goblin/, atk)

    # Bad enum comes back as an error STRING (not an exception), so the agent
    # loop keeps going.
    bad = registry.dispatch("move", { "direction" => "sideways" })
    assert_match(/error:/, bad)
    assert_match(/argument_error/, bad)
  end
end
