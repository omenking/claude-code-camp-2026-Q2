require_relative "helper"

# Boukensha::Mcp::Client is boukensha's own MCP-over-stdio client. It is
# server-agnostic: it takes a command, args, and env, and speaks the protocol.
# We point it at the mud-manager daemon because that is the MCP server this
# repo ships — nothing in the client knows that.
class TestMcpClient < Minitest::Test
  include McpTestHelper

  def setup
    @fake = start_fake_mud
  end

  def teardown
    @client&.close
    @fake&.stop
  end

  def spawn_client
    @client = Boukensha::Mcp::Client.spawn(
      command: mud_manager_command, args: mud_manager_args, env: fake_mud_env(@fake)
    )
  end

  def test_handshake_reports_server_info
    client = spawn_client
    assert_equal "mud-manager", client.server_info["name"]
    refute_nil client.server_info["version"]
  end

  def test_tools_list_is_discovered
    client = spawn_client
    names = client.tools.map { |t| t["name"] }
    assert_includes names, "look"
    assert_includes names, "attack"
    # Discovery is the server's word, not ours — the client invents nothing.
    assert_operator client.tools.size, :>, 1
    assert client.tools.all? { |t| t.key?("inputSchema") }
  end

  def test_call_tool_reaches_the_mud
    client = spawn_client
    assert_match(/You do: look/, client.call_tool("look")[:text])
    assert_match(/You do: kill dragon/, client.call_tool("attack", "target" => "dragon")[:text])
  end

  # A tool-level failure is data (isError), not an exception — the agent loop
  # must be able to keep going.
  def test_tool_error_comes_back_as_data
    client = spawn_client
    result = client.call_tool("move", "direction" => "sideways")
    assert result[:error], "expected isError to be set"
    assert_match(/argument_error/, result[:text])
  end

  def test_spawning_a_nonexistent_command_raises
    assert_raises(Errno::ENOENT) do
      Boukensha::Mcp::Client.spawn(command: "boukensha-no-such-mcp-server-xyz")
    end
  end
end
