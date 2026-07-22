require_relative "helper"

# Coverage for docs/plans/week_2/native_tool_permissions.md: a native tool
# (registered by a run/repl block, e.g. the player's inspect_room) is gated by
# `allow:` exactly like an MCP tool, and the ordering bug where
# validate_referenced! used to run BEFORE native tools existed in the registry
# is fixed — register_task_tools no longer validates itself; the caller
# (Boukensha.run/.repl/.run_task) validates only after ALL registration,
# MCP and native, is done.
class TestTaskToolRegistration < Minitest::Test
  include McpTestHelper

  # This is the ordering bug's regression test: before the fix,
  # `validate_referenced!` ran inside register_task_tools, before a run/repl
  # block's native tools were registered — so a rule naming a native tool
  # aborted boot with "references unknown tool" even though the rule was
  # perfectly valid.
  def test_a_rule_naming_a_tool_registered_only_after_register_task_tools_still_validates
    @fake = start_fake_mud
    yaml = <<~YAML
      tasks:
        player:
          allow:
            - inspect_room
            - tbamud__poll
      mcp_servers:
        mud:
          command: #{mud_manager_command}
          args:    #{mud_manager_args.inspect}
          prefix:  tbamud
          env:
            MUD_HOST:     127.0.0.1
            MUD_PORT:     #{@fake.port}
            MUD_NAME:     Gandalf
            MUD_PASSWORD: secret
    YAML

    config_from(yaml) do |cfg|
      perms    = Boukensha.task_permissions(cfg, "player")
      ctx      = Boukensha::Context.new(system: "t")
      registry = Boukensha::Registry.new(ctx, permissions: perms)

      Boukensha.send(:register_task_tools, registry, cfg, perms)

      # Simulate a run/repl block's native tool registration — the exact seam
      # RunDSL#tool uses — happening AFTER register_task_tools, mirroring
      # Boukensha.run/.repl's call order.
      registry.tool("inspect_room", description: "d") { |**_| "json" }

      # Must not raise: by the time validate_referenced! runs, both the
      # MCP-derived and the native tool are in the registry.
      perms.validate_referenced!(registry.tool_names)

      assert_includes registry.tool_names, "inspect_room"
      assert_includes registry.tool_names, "tbamud__poll"
    end
  ensure
    @fake&.stop
  end

  def test_a_native_tool_absent_from_allow_is_never_registered_and_cannot_be_dispatched
    yaml = <<~YAML
      tasks:
        player:
          allow:
            - tbamud__poll
    YAML

    config_from(yaml) do |cfg|
      perms    = Boukensha.task_permissions(cfg, "player")
      ctx      = Boukensha::Context.new(system: "t")
      registry = Boukensha::Registry.new(ctx, permissions: perms)

      registry.tool("inspect_room", description: "d") { |**_| "json" }

      refute_includes registry.tool_names, "inspect_room"
      assert_raises(Boukensha::UnknownToolError) { registry.dispatch("inspect_room") }
    end
  end
end
