import os
import sys
from pathlib import Path

STEP_DIR = Path(__file__).resolve().parent.parent
os.environ.setdefault(
    "BOUKENSHA_DIR", str(STEP_DIR.parent.parent.parent / ".boukensha")
)
sys.path.insert(0, str(STEP_DIR))

from boukensha import config, repl

# Step 11 — the agent owns no tools. There is no register_tools/configure=
# here, because boukensha has nothing of its own to register. Every tool this
# agent can call arrives from an MCP server listed in settings.yaml's
# `mcp_servers:` block — the MUD daemon, a filesystem server, anything that
# speaks MCP. Swapping what the agent can do is a config edit, not a code
# change.

cfg = config()
print("=== BOUKENSHA Step 11: A Terminal UI ===")
print()
print(f"Config:  {cfg}")
print(f"Servers: {', '.join(cfg.mcp_servers.keys())}")
print(f"API key set? {bool(os.environ.get('ANTHROPIC_API_KEY'))}")
print()

# system/model/api_key come from config automatically.
# Tools come from mcp_servers — there is nothing to wire up here.
# --no-tui falls back to the plain terminal REPL from step 10.
repl(tui="--no-tui" not in sys.argv)
