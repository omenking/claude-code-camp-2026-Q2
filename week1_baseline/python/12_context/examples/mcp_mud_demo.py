import os
import subprocess
import sys
from pathlib import Path

STEP_DIR = Path(__file__).resolve().parent.parent
os.environ.setdefault(
    "BOUKENSHA_DIR", str(STEP_DIR.parent.parent.parent / ".boukensha")
)
sys.path.insert(0, str(STEP_DIR))

MUD_MANAGER_ROOT = STEP_DIR.parent.parent.parent / "week0_explore" / "mud_manager"
MUD_MANAGER_BIN = MUD_MANAGER_ROOT / "bin" / "mud-manager"
MUD_MANAGER_LIB = MUD_MANAGER_ROOT / "lib"

# Step 10 x mud-manager (MCP path).
#
# boukensha has no MUD code at all. This points its generic MCP client at the
# `mud-manager` daemon and registers whatever tools the daemon advertises —
# exactly what the Ruby / Go / Rust / Java tracks do with their own SDKs.
# Nothing in boukensha.tools.mcp knows what a MUD is; the daemon is just a
# server, and this file is just a host.
#
# Note the names: the daemon advertises `look`, but we pass prefix="tbamud",
# so the agent sees `tbamud__look`. Prefixing is applied agent-side; the
# daemon never hears about it. In a real run that prefix comes from config.
#
#   # Self-contained smoke test — no API key, no live MUD (built-in fake MUD):
#   python examples/mcp_mud_demo.py --dry
#
#   # Full agent run — needs ANTHROPIC_API_KEY and a reachable MUD via MUD_* or
#   # ~/.boukensha/settings.yaml (mcp_servers: mud entry):
#   python examples/mcp_mud_demo.py

# There is no Python mud_manager port, so a fake MUD for --dry mode is booted
# by shelling out to a tiny ruby one-liner that boots the real
# MudManager::FakeMud and prints its port. This keeps the process-management
# code isolated here — it can be deleted without touching the MCP demo path
# if a Python mud_manager port ever exists.
_FAKE_MUD_SCRIPT = """
$LOAD_PATH.unshift(ARGV[0])
require "mud_manager/fake_mud"
fake = MudManager::FakeMud.new
puts fake.port
STDOUT.flush
STDIN.gets
fake.stop
"""


class _FakeMudProcess:
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


def main():
    dry = "--dry" in sys.argv[1:]

    if not dry:
        # Full agent run — Boukensha.repl spawns whatever is in
        # mcp_servers: and registers its tools. There is no mode to select
        # and no MUD argument to pass, because the agent has no concept of a
        # MUD. See examples/example.py — at this point the two demos are the
        # same program.
        from boukensha import repl

        repl()
        return

    from boukensha import Context, Registry
    from boukensha.tasks.player import Player
    from boukensha.tools import mcp as tools_mcp

    fake = _FakeMudProcess()
    creds = {
        "MUD_HOST": "127.0.0.1", "MUD_PORT": str(fake.port),
        "MUD_NAME": "Gandalf", "MUD_PASSWORD": "secret",
    }

    # Register the daemon's tools into a real boukensha Registry through the
    # generic MCP layer, then dispatch through it — the full agent path,
    # minus the LLM.
    context = Context(system="demo")
    registry = Registry(context)

    client = tools_mcp.register(
        registry, "ruby", args=[str(MUD_MANAGER_BIN), "--mcp"],
        env=creds, prefix="tbamud",
    )

    print(f"daemon: {client.server_info!r}")
    print(f"tools:  {len(context.tools)} — {', '.join(context.tools.keys())}")
    print()

    print(f"tbamud__look       => {registry.dispatch('tbamud__look', {})!r}")
    print(f"tbamud__attack orc => {registry.dispatch('tbamud__attack', {'target': 'orc'})!r}")
    print(f"bad cast           => {registry.dispatch('tbamud__cast_spell', {'spell': ''})!r}")

    client.close()
    fake.stop()
    print("\n[dry run OK — daemon + step 10 generic MCP layer working]")


if __name__ == "__main__":
    main()
