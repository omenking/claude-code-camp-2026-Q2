import contextlib
import io
import textwrap

import boukensha
from boukensha.tools.mcp import CollisionError

from .helper import McpTestCase


# `mcp_servers:` in settings.yaml is what makes boukensha a general MCP host:
# plugging in a server is data, not code.
class TestMcpServersConfig(McpTestCase):
    def test_parses_entries_and_applies_defaults(self):
        yaml_text = textwrap.dedent("""\
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
        """)

        with self.config_from(yaml_text) as cfg:
            mud = cfg.mcp_servers["mud"]
            self.assertEqual("mud-manager", mud["command"])
            self.assertEqual(["--mcp"], mud["args"])
            self.assertEqual("tbamud", mud["prefix"])
            # env values are stringified — YAML would hand us 4000 as an
            # int, and the spawn environment only accepts strings.
            self.assertEqual({"MUD_HOST": "your.mud.host", "MUD_PORT": "4000"}, mud["env"])
            self.assertTrue(mud["required"], "servers are required by default")

            fs = cfg.mcp_servers["filesystem"]
            self.assertEqual([], fs["args"])
            self.assertEqual({}, fs["env"])
            self.assertIsNone(fs["prefix"])
            self.assertFalse(fs["required"])

    def test_absent_block_is_empty(self):
        with self.config_from("tasks: {}") as cfg:
            self.assertEqual({}, cfg.mcp_servers)

    # A required server that won't start is fatal: you asked for those tools.
    def test_required_server_that_fails_to_spawn_raises(self):
        yaml_text = textwrap.dedent("""\
            mcp_servers:
              broken:
                command: boukensha-no-such-mcp-server-xyz
        """)

        with self.config_from(yaml_text) as cfg:
            _context, registry = self.new_registry()
            with self.assertRaises(RuntimeError) as ctx:
                boukensha._register_mcp_servers(registry, cfg)
            self.assertIn("'broken' failed to start", str(ctx.exception))

    # An optional server that won't start is a warning: the agent is still
    # useful without its tools.
    def test_optional_server_that_fails_to_spawn_warns_and_continues(self):
        yaml_text = textwrap.dedent("""\
            mcp_servers:
              decorative:
                command: boukensha-no-such-mcp-server-xyz
                required: false
        """)

        with self.config_from(yaml_text) as cfg:
            context, registry = self.new_registry()
            stderr = io.StringIO()
            with contextlib.redirect_stderr(stderr):
                boukensha._register_mcp_servers(registry, cfg)
            self.assertIn("optional MCP server 'decorative' failed to start", stderr.getvalue())
            self.assertEqual(0, len(context.tools))

    # required: false excuses a server that won't START. It does not excuse a
    # name collision — that's a contradiction in the config, and swallowing
    # it would silently drop the whole server's toolset.
    def test_optional_server_does_not_excuse_a_collision(self):
        self.fake = self.start_fake_mud()
        try:
            with self.config_from(
                self._server_yaml("unprefixed", extra="    required: false")
            ) as cfg:
                _context, registry = self.new_registry()

                @registry.tool("look", description="pre-existing")
                def _look():
                    return "local"

                with self.assertRaises(CollisionError):
                    boukensha._register_mcp_servers(registry, cfg)
        finally:
            self.fake.stop()

    # `mud` gets no special treatment: it is spawned by the same code path as
    # any other server, and a bad command kills the agent exactly like any
    # other required entry would. The agent has no idea it's a MUD.
    def test_mud_is_just_another_server(self):
        yaml_text = textwrap.dedent("""\
            mcp_servers:
              mud:
                command: boukensha-no-such-mcp-server-xyz
        """)

        with self.config_from(yaml_text) as cfg:
            _context, registry = self.new_registry()
            with self.assertRaises(RuntimeError) as ctx:
                boukensha._register_mcp_servers(registry, cfg)
            self.assertIn("'mud' failed to start", str(ctx.exception))

    # The banner needs to tell you what the agent can actually do, since
    # without servers it can do nothing at all.
    def test_returns_a_tool_count_per_server(self):
        self.fake = self.start_fake_mud()
        try:
            with self.config_from(self._server_yaml("mud", extra="    prefix: tbamud")) as cfg:
                _context, registry = self.new_registry()
                summary = boukensha._register_mcp_servers(registry, cfg)
                self.assertEqual({"mud": 26}, summary)
        finally:
            self.fake.stop()

    # An mcp_servers block with one entry pointing at the daemon + fake MUD.
    def _server_yaml(self, name, extra=None):
        from .helper import MUD_MANAGER_ARGS, MUD_MANAGER_COMMAND

        args_yaml = str(MUD_MANAGER_ARGS).replace("'", '"')
        extra_line = extra or ""
        return textwrap.dedent(f"""\
            mcp_servers:
              {name}:
                command: {MUD_MANAGER_COMMAND}
                args:    {args_yaml}
            {extra_line}
                env:
                  MUD_HOST:     127.0.0.1
                  MUD_PORT:     {self.fake.port}
                  MUD_NAME:     Gandalf
                  MUD_PASSWORD: secret
        """)
