require_relative "helper"

class TestMcpServer < Minitest::Test
  def setup
    @fake = FakeMud.new
  end

  def teardown
    @fake.stop
  end

  def test_initialize_and_tools_list
    pool = pool_for(@fake)
    out = drive(MudManager::Mcp::Server, pool, [
      { "jsonrpc" => "2.0", "id" => 1, "method" => "initialize",
        "params" => { "protocolVersion" => "2025-06-18" } },
      { "jsonrpc" => "2.0", "method" => "notifications/initialized" },
      { "jsonrpc" => "2.0", "id" => 2, "method" => "tools/list" }
    ])

    init = out.find { |m| m["id"] == 1 }
    assert_equal "mud-manager", init["result"]["serverInfo"]["name"]
    assert init["result"]["capabilities"]["tools"]

    list = out.find { |m| m["id"] == 2 }
    names = list["result"]["tools"].map { |t| t["name"] }
    assert_includes names, "attack"
    # notification produced no response line
    assert_nil out.find { |m| m["id"].nil? && m["result"] }
  end

  def test_tools_call_drives_the_mud
    pool = pool_for(@fake)
    out = drive(MudManager::Mcp::Server, pool, [
      { "id" => 1, "method" => "tools/call",
        "params" => { "name" => "look", "arguments" => {} } },
      { "id" => 2, "method" => "tools/call",
        "params" => { "name" => "attack", "arguments" => { "target" => "goblin" } } }
    ])

    look = out.find { |m| m["id"] == 1 }["result"]
    assert_equal false, look["isError"]
    # The first call connects+logs in (banner consumed during the login dance);
    # the look command then returns its own echo, terminated by the prompt.
    assert_match(/You do: look/, look["content"][0]["text"])

    atk = out.find { |m| m["id"] == 2 }["result"]
    assert_equal false, atk["isError"]
    assert_match(/You do: kill goblin/, atk["content"][0]["text"])
  end

  def test_room_survey_is_not_a_daemon_tool_only_primitives_are
    # The room survey (poll → look → exits) is composed agent-side by the
    # room_inspector subagent, not by the daemon. The daemon exposes only the
    # primitives that composition is built from.
    pool = pool_for(@fake)
    out = drive(MudManager::Mcp::Server, pool, [
      { "jsonrpc" => "2.0", "id" => 1, "method" => "tools/list" }
    ])
    names = out.find { |m| m["id"] == 1 }["result"]["tools"].map { |t| t["name"] }

    refute_includes names, "inspect_room", "the survey composite must not be a daemon tool"
    %w[poll look check].each { |t| assert_includes names, t, "primitive #{t} must remain" }

    # And calling the removed composite is now an error, not a survey.
    err = drive(MudManager::Mcp::Server, pool, [
      { "id" => 2, "method" => "tools/call",
        "params" => { "name" => "inspect_room", "arguments" => {} } }
    ]).find { |m| m["id"] == 2 }["result"]
    assert_equal true, err["isError"]
  end

  def test_bad_enum_is_structured_tool_error_not_jsonrpc_error
    pool = pool_for(@fake)
    out = drive(MudManager::Mcp::Server, pool, [
      { "id" => 1, "method" => "tools/call",
        "params" => { "name" => "move", "arguments" => { "direction" => "sideways" } } }
    ])
    res = out.find { |m| m["id"] == 1 }["result"]
    assert_equal true, res["isError"]
    assert_match(/argument_error/, res["content"][0]["text"])
    assert_match(/invalid direction/, res["content"][0]["text"])
  end

  def test_unknown_method_is_jsonrpc_error
    pool = pool_for(@fake)
    out = drive(MudManager::Mcp::Server, pool, [
      { "id" => 9, "method" => "does/not/exist" }
    ])
    err = out.find { |m| m["id"] == 9 }
    assert_equal(-32_601, err["error"]["code"])
  end

  def test_login_failure_surfaces_structured_error
    cfg = MudManager::Mcp::Config.new(host: "127.0.0.1", port: @fake.port,
                                    name: "Gandalf", password: "wrong")
    pool = MudManager::Mcp::SessionPool.new(default_config: cfg, timeout: 5.0)
    out = drive(MudManager::Mcp::Server, pool, [
      { "id" => 1, "method" => "tools/call",
        "params" => { "name" => "look", "arguments" => {} } }
    ])
    res = out.find { |m| m["id"] == 1 }["result"]
    assert_equal true, res["isError"]
    assert_match(/login_error/, res["content"][0]["text"])
  end

  def test_poll_returns_async_output
    pool = pool_for(@fake)
    dispatcher = MudManager::Mcp::Dispatcher.new(pool)
    # First call connects + logs in.
    dispatcher.call("look", {}, id: "default")
    # Server pushes unsolicited output; give the reader thread a moment.
    @fake.push("\r\nA goblin arrives from the north.\r\n")

    text = ""
    20.times do
      text = dispatcher.call("poll", {}, id: "default")
      break unless text.empty?
      sleep 0.05
    end
    assert_match(/A goblin arrives/, text)
  end
end
