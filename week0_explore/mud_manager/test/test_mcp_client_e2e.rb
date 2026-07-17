require_relative "helper"

# Full-stack test: a real McpClient spawns the real `mud-manager --mcp`
# subprocess, which connects to an in-process FakeMud via MUD_* env vars.
# This proves the exact path a foreign-language track (or boukensha) uses.
class TestMcpClientE2E < Minitest::Test
  def setup
    @fake = FakeMud.new
  end

  def teardown
    @fake.stop
    @client&.close
  end

  def test_discovers_tools_without_a_mud
    @client = MudManager::Mcp::Client.spawn
    assert_equal "mud-manager", @client.server_info["name"]
    names = @client.tools.map { |t| t["name"] }
    assert_includes names, "attack"
    assert_includes names, "poll"
  end

  def test_calls_a_tool_against_the_mud
    @client = MudManager::Mcp::Client.spawn(env: {
      "MUD_HOST"     => "127.0.0.1",
      "MUD_PORT"     => @fake.port.to_s,
      "MUD_NAME"     => "Gandalf",
      "MUD_PASSWORD" => "secret"
    })

    res = @client.call_tool("look")
    assert_equal false, res[:error]
    assert_match(/You do: look/, res[:text])

    res = @client.call_tool("attack", { "target" => "goblin", "style" => "murder" })
    assert_match(/You do: murder goblin/, res[:text])

    # Structured error surfaces as isError with a code the model can read.
    res = @client.call_tool("move", { "direction" => "widdershins" })
    assert_equal true, res[:error]
    assert_match(/argument_error/, res[:text])
  end
end
