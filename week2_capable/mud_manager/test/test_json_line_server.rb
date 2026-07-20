require_relative "helper"

class TestJsonLineServer < Minitest::Test
  def setup
    @fake = FakeMud.new
  end

  def teardown
    @fake.stop
  end

  def test_connect_send_and_close
    # Raw protocol supplies credentials via the connect op (framework-driven).
    pool = MudManager::Mcp::SessionPool.new(
      default_config: MudManager::Mcp::Config.new(host: "127.0.0.1", port: @fake.port),
      timeout: 5.0
    )
    out = drive(MudManager::Mcp::JsonLineServer, pool, [
      { "id" => 1, "op" => "connect", "host" => "127.0.0.1", "port" => @fake.port,
        "name" => "Gandalf", "password" => "secret" },
      { "id" => 2, "op" => "tool", "name" => "look", "args" => {} },
      { "id" => 3, "op" => "send", "raw" => "who" },
      { "id" => 4, "op" => "close" }
    ])

    assert_equal true, out.find { |m| m["id"] == 1 }["ok"]
    assert_match(/You do: look/, out.find { |m| m["id"] == 2 }["text"])
    assert_match(/You do: who/, out.find { |m| m["id"] == 3 }["text"])
    assert_equal true, out.find { |m| m["id"] == 4 }["ok"]
  end

  def test_structured_error_shape
    pool = MudManager::Mcp::SessionPool.new(
      default_config: MudManager::Mcp::Config.new(host: "127.0.0.1", port: @fake.port),
      timeout: 5.0
    )
    out = drive(MudManager::Mcp::JsonLineServer, pool, [
      { "id" => 1, "op" => "connect", "host" => "127.0.0.1", "port" => @fake.port,
        "name" => "Gandalf", "password" => "secret" },
      { "id" => 2, "op" => "tool", "name" => "attack", "args" => { "target" => "orc", "style" => "nope" } }
    ])
    err = out.find { |m| m["id"] == 2 }
    assert_equal false, err["ok"]
    assert_equal "argument_error", err["error_type"]
  end

  def test_bad_json_is_reported
    pool = MudManager::Mcp::SessionPool.new
    out = drive(MudManager::Mcp::JsonLineServer, pool, ["{not json"])
    assert_equal false, out[0]["ok"]
    assert_equal "bad_request", out[0]["error_type"]
  end

  def test_list_tools_op
    pool = MudManager::Mcp::SessionPool.new
    out = drive(MudManager::Mcp::JsonLineServer, pool, [{ "id" => 1, "op" => "list_tools" }])
    names = out[0]["tools"].map { |t| t["name"] }
    assert_includes names, "cast_spell"
  end
end
