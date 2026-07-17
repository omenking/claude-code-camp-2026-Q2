from boukensha.tools.mcp import CollisionError, register

from .helper import MUD_MANAGER_ARGS, MUD_MANAGER_COMMAND, McpTestCase


# boukensha.tools.mcp is the generic MCP host layer: point it at any MCP
# server and that server's tools become boukensha tools. These tests use the
# mud-manager daemon as "some MCP server" and deliberately never rely on it
# being a MUD.
class TestToolsMcp(McpTestCase):
    def setUp(self):
        self.fake = self.start_fake_mud()
        self.client = None

    def tearDown(self):
        if self.client is not None:
            self.client.close()
        self.fake.stop()

    def register(self, registry, prefix=None):
        self.client = register(
            registry, MUD_MANAGER_COMMAND, args=MUD_MANAGER_ARGS,
            env=self.fake_mud_env(self.fake), prefix=prefix,
        )
        return self.client

    def test_register_populates_the_registry_from_discovery(self):
        context, registry = self.new_registry()
        client = self.register(registry)

        self.assertEqual(len(client.tools), len(context.tools))
        self.assertIn("look", context.tools)
        self.assertIn("You do: look", registry.dispatch("look", {}))

    # Prefixing is a policy applied agent-side. The server keeps its own names.
    def test_prefix_is_applied_locally_and_the_server_still_sees_bare_names(self):
        context, registry = self.new_registry()
        self.register(registry, prefix="tbamud")

        self.assertIn("tbamud__look", context.tools)
        self.assertNotIn("look", context.tools)

        # If the prefix leaked onto the wire the daemon would reject this as
        # an unknown tool; getting the MUD's response back proves it didn't.
        self.assertIn("You do: look", registry.dispatch("tbamud__look", {}))
        self.assertIn(
            "You do: kill dragon",
            registry.dispatch("tbamud__attack", {"target": "dragon"}),
        )

    # Proves prefixing is opt-in policy, not baked into the mechanism.
    def test_none_prefix_yields_bare_names(self):
        context, registry = self.new_registry()
        self.register(registry, prefix=None)
        self.assertIn("look", context.tools)
        self.assertNotIn("tbamud__look", context.tools)

    def test_schema_enum_is_surfaced_in_the_parameter_description(self):
        context, registry = self.new_registry()
        self.register(registry)
        self.assertIn("one of:", context.tools["move"].parameters["direction"]["description"])
        self.assertIn("north", context.tools["move"].parameters["direction"]["description"])

    # Silent clobbering would be maddening to debug, so a collision is a hard
    # error naming the fix. Two servers sharing a prefix is the realistic case.
    def test_colliding_tool_names_raise(self):
        _context, registry = self.new_registry()
        self.register(registry, prefix="tbamud")

        second = None
        with self.assertRaises(CollisionError) as ctx:
            second = register(
                registry, MUD_MANAGER_COMMAND, args=MUD_MANAGER_ARGS,
                env=self.fake_mud_env(self.fake), prefix="tbamud",
            )
        self.assertIn("collision on 'tbamud__look'", str(ctx.exception))
        self.assertIn("prefix", str(ctx.exception))
        if second is not None:
            second.close()

    # A collision against a tool boukensha registered itself (not another MCP
    # server) must be caught too — a filesystem server advertising
    # `read_file` is the obvious one.
    def test_collision_with_an_existing_non_mcp_tool_raises(self):
        _context, registry = self.new_registry()

        @registry.tool("look", description="pre-existing")
        def _look():
            return "local"

        with self.assertRaises(CollisionError) as ctx:
            self.register(registry)
        self.assertIn("collision on 'look'", str(ctx.exception))
