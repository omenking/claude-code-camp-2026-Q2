import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

STEP_DIR = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(STEP_DIR))

import boukensha
from boukensha.context import Context
from boukensha.registry import Registry
from boukensha.tasks.player import Player

# The MCP tests need a real MCP server to spawn. The mud-manager daemon in the
# week0_explore package is the one we have, so it plays the role of "some MCP
# server" — the code under test knows nothing about it beyond command/args/env.
MUD_MANAGER_ROOT = STEP_DIR.parent.parent.parent / "week0_explore" / "mud_manager"
MUD_MANAGER_BIN = MUD_MANAGER_ROOT / "bin" / "mud-manager"
MUD_MANAGER_LIB = MUD_MANAGER_ROOT / "lib"

MUD_MANAGER_COMMAND = "ruby"
MUD_MANAGER_ARGS = [str(MUD_MANAGER_BIN), "--mcp"]

_FAKE_MUD_SCRIPT = """
$LOAD_PATH.unshift(ARGV[0])
require "mud_manager/fake_mud"
fake = MudManager::FakeMud.new
puts fake.port
STDOUT.flush
STDIN.gets
fake.stop
"""


class FakeMud:
    """A real MudManager::FakeMud, run in a ruby subprocess since there is no
    Python mud_manager port. Only used to give the mud-manager MCP daemon
    something to talk to during tests.
    """

    def __init__(self):
        self._process = subprocess.Popen(
            ["ruby", "-e", _FAKE_MUD_SCRIPT, "--", str(MUD_MANAGER_LIB)],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            text=True,
            bufsize=1,
        )
        self.port = int(self._process.stdout.readline().strip())

    def stop(self):
        try:
            self._process.stdin.write("\n")
            self._process.stdin.flush()
        except Exception:
            pass
        self._process.wait()


class FakeLogger:
    """A no-op Logger stand-in for tests that exercise Repl/Agent without
    touching the real JSONL-backed Logger (which otherwise requires a
    resolvable BOUKENSHA_DIR/settings.yaml).
    """

    def __init__(self):
        self._subscribers = []

    def turn(self, n):
        pass

    def iteration(self, n, max):
        pass

    def limit_reached(self, **kwargs):
        pass

    def turn_end(self, **kwargs):
        pass

    def prompt(self, **kwargs):
        pass

    def tool_call(self, **kwargs):
        pass

    def tool_result(self, **kwargs):
        pass

    def response(self, **kwargs):
        pass

    def raw(self, **kwargs):
        pass

    def subscribe(self, callback):
        self._subscribers.append(callback)


class McpTestCase(unittest.TestCase):
    """Shared fixtures for the MCP test suite."""

    def start_fake_mud(self):
        if not MUD_MANAGER_BIN.exists():
            self.skipTest(f"mud_manager not found at {MUD_MANAGER_ROOT}")
        if not shutil.which("ruby"):
            self.skipTest("ruby not found on PATH")
        return FakeMud()

    def fake_mud_env(self, fake):
        return {
            "MUD_HOST": "127.0.0.1", "MUD_PORT": str(fake.port),
            "MUD_NAME": "Gandalf", "MUD_PASSWORD": "secret",
        }

    def new_registry(self):
        context = Context(task=Player, system="test")
        return context, Registry(context)

    def config_from(self, yaml_text):
        """Build a Config from a settings.yaml written into a throwaway
        BOUKENSHA_DIR, as a context manager: `with self.config_from(yaml) as cfg:`.
        """
        return _ConfigFromContext(yaml_text)


class _ConfigFromContext:
    def __init__(self, yaml_text):
        self._yaml_text = yaml_text
        self._tmpdir = None
        self._old_dir = None

    def __enter__(self):
        self._tmpdir = tempfile.mkdtemp()
        Path(self._tmpdir, "settings.yaml").write_text(self._yaml_text)
        self._old_dir = os.environ.get("BOUKENSHA_DIR")
        os.environ["BOUKENSHA_DIR"] = self._tmpdir
        return boukensha.Config()

    def __exit__(self, exc_type, exc, tb):
        if self._old_dir is None:
            os.environ.pop("BOUKENSHA_DIR", None)
        else:
            os.environ["BOUKENSHA_DIR"] = self._old_dir
        shutil.rmtree(self._tmpdir, ignore_errors=True)
        return False
