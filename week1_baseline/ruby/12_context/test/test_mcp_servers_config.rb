require_relative "helper"

# `mcp_servers:` in settings.yaml is what makes boukensha a general MCP host:
# plugging in a server is data, not code.
class TestMcpServersConfig < Minitest::Test
  include McpTestHelper

  def test_parses_entries_and_applies_defaults
    yaml = <<~YAML
      mcp_servers:
        mud:
          command: mud-manager
          args:    [--mcp]
          prefix:  tbamud
          env:
            MUD_HOST: your.mud.host
            MUD_PORT: 4000
        filesystem:
          command: npx
          required: false
    YAML

    config_from(yaml) do |cfg|
      mud = cfg.mcp_servers["mud"]
      assert_equal "mud-manager", mud[:command]
      assert_equal ["--mcp"], mud[:args]
      assert_equal "tbamud", mud[:prefix]
      # env values are stringified — YAML would hand us 4000 as an Integer,
      # and the spawn environment only accepts strings.
      assert_equal({ "MUD_HOST" => "your.mud.host", "MUD_PORT" => "4000" }, mud[:env])
      assert mud[:required], "servers are required by default"

      fs = cfg.mcp_servers["filesystem"]
      assert_equal [], fs[:args]
      assert_equal({}, fs[:env])
      assert_nil fs[:prefix]
      refute fs[:required]
    end
  end

  def test_absent_block_is_empty
    config_from("tasks: {}") { |cfg| assert_equal({}, cfg.mcp_servers) }
  end

  # A required server that won't start is fatal: you asked for those tools.
  def test_required_server_that_fails_to_spawn_raises
    yaml = <<~YAML
      mcp_servers:
        broken:
          command: boukensha-no-such-mcp-server-xyz
    YAML

    config_from(yaml) do |cfg|
      _ctx, registry = new_registry
      err = assert_raises(RuntimeError) do
        Boukensha.send(:register_mcp_servers, registry, cfg)
      end
      assert_match(/'broken' failed to start/, err.message)
    end
  end

  # An optional server that won't start is a warning: the agent is still useful
  # without its tools.
  def test_optional_server_that_fails_to_spawn_warns_and_continues
    yaml = <<~YAML
      mcp_servers:
        decorative:
          command: boukensha-no-such-mcp-server-xyz
          required: false
    YAML

    config_from(yaml) do |cfg|
      ctx, registry = new_registry
      out, err = capture_io do
        Boukensha.send(:register_mcp_servers, registry, cfg)
      end
      assert_match(/optional MCP server 'decorative' failed to start/, out + err)
      assert_equal 0, ctx.tools.size
    end
  end

  # required: false excuses a server that won't START. It does not excuse a
  # name collision — that's a contradiction in the config, and swallowing it
  # would silently drop the whole server's toolset.
  def test_optional_server_does_not_excuse_a_collision
    @fake = start_fake_mud
    config_from(server_yaml("unprefixed", extra: "    required: false")) do |cfg|
      _ctx, registry = new_registry
      registry.tool("look", description: "pre-existing") { "local" }

      assert_raises(Boukensha::Tools::Mcp::CollisionError) do
        Boukensha.send(:register_mcp_servers, registry, cfg)
      end
    end
  ensure
    @fake&.stop
  end

  # `mud` gets no special treatment: it is spawned by the same code path as
  # any other server, and a bad command kills the agent exactly like any other
  # required entry would. The agent has no idea it's a MUD.
  def test_mud_is_just_another_server
    yaml = <<~YAML
      mcp_servers:
        mud:
          command: boukensha-no-such-mcp-server-xyz
    YAML

    config_from(yaml) do |cfg|
      _ctx, registry = new_registry
      err = assert_raises(RuntimeError) do
        Boukensha.send(:register_mcp_servers, registry, cfg)
      end
      assert_match(/'mud' failed to start/, err.message)
    end
  end

  # The banner needs to tell you what the agent can actually do, since without
  # servers it can do nothing at all.
  def test_returns_a_tool_count_per_server
    @fake = start_fake_mud
    config_from(server_yaml("mud", extra: "    prefix: tbamud")) do |cfg|
      _ctx, registry = new_registry
      summary = Boukensha.send(:register_mcp_servers, registry, cfg)
      assert_equal({ "mud" => 26 }, summary)
    end
  ensure
    @fake&.stop
  end

  private

  # An mcp_servers block with one entry pointing at the daemon + fake MUD.
  def server_yaml(name, extra: nil)
    <<~YAML
      mcp_servers:
        #{name}:
          command: #{mud_manager_command}
          args:    #{mud_manager_args.inspect}
      #{extra}
          env:
            MUD_HOST:     127.0.0.1
            MUD_PORT:     #{@fake.port}
            MUD_NAME:     Gandalf
            MUD_PASSWORD: secret
    YAML
  end
end
