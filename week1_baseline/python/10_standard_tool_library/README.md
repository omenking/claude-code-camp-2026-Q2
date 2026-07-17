# Step 10 — A Standard Tool Library

The standard tool library is **MCP**.

Boukensha ships **no tools of its own**. It is an MCP *host*: every tool the
agent can call comes from an MCP server declared in `settings.yaml`. Want file
access? Plug in a filesystem server. Want to play a MUD? Plug in
`mud-manager --mcp`. An agent with an empty `mcp_servers:` block can only talk.

> The directory is still named `10_standard_tool_library` from when this step
> shipped built-in `read_file` / `list_directory` tools in `examples/example.py`.
> Those are gone. The name is kept so the step ordering and every path that
> points here still resolve.

## What's new

### `boukensha.mcp.client.Client`

A minimal MCP-over-stdio client: spawn a server, handshake, `tools/list`,
`tools/call`. It is server-agnostic — `command` / `args` / `env` is the
standard stdio transport config, the same triple every MCP host uses.

### `boukensha.tools.mcp`

The only tool-registration module left. Registers a server's discovered tools
into a registry, optionally scoping their names with a `prefix`.

```python
from boukensha.tools import mcp as tools_mcp

tools_mcp.register(
    registry, "mud-manager", args=["--mcp"],
    env={"MUD_HOST": "localhost"},
    prefix="tbamud",          # the daemon's `look` registers as `tbamud__look`
)
```

Prefixing is applied **client-side**: the server still sees `look` on the wire.
It exists so two servers can't silently clobber each other's names — a
collision raises and names the fix.

### `mcp_servers:` in `settings.yaml`

Adding a capability is a config edit, not a code change:

```yaml
mcp_servers:
  mud:
    command: mud-manager
    args:    [--mcp]
    prefix:  tbamud
    env:                     # a stdio server's credentials travel by environment
      MUD_HOST:     your.mud.host
      MUD_NAME:     Gandalf
      MUD_PASSWORD: secret

  filesystem:
    command:  npx
    args:     [-y, "@modelcontextprotocol/server-filesystem", /tmp]
    prefix:   fs
    required: false          # can't start? warn and carry on
```

| Key | Default | Meaning |
|-----|---------|---------|
| `command` | — | Executable to spawn. Resolved by the OS, so a relative path depends on your cwd — nothing hunts for a binary for you. |
| `args` | `[]` | Its argv. |
| `env` | `{}` | Extra environment. Servers inherit boukensha's environment; these keys override it. |
| `prefix` | none | Scopes discovered names (`fs` → `fs__read_file`). |
| `required` | `true` | `false` downgrades a failure to start into a warning. |

### What went away

| Gone | Replaced by |
|------|-------------|
| `read_file` / `list_directory` (registered via `configure=` in `examples/example.py`) | a filesystem MCP server. Trade-off: needs `npx`, and its root is fixed in `args:` instead of tracking `working_dir`. |
| The HTTP 401 special case in `Client.call()` | the generic non-2xx failure message, matching ruby's own step-9 revert. |
| The cwd `.boukensha` fallback in `Config._resolve_dir()` | a strict `BOUKENSHA_DIR` → `~/.boukensha` precedence, matching ruby's own step-9 revert. |

`working_dir` survives on `boukensha.run` / `.repl`, but only as `Context`
metadata: it registers nothing.

## Run the demo

```sh
# Offline, no API key, no live MUD — uses the daemon's built-in fake MUD:
python examples/mcp_mud_demo.py --dry

# Full run — needs ANTHROPIC_API_KEY and an mcp_servers: mud entry.
# Launch from the repo root so the example config's relative path resolves:
BOUKENSHA_DIR=.boukensha python week1_baseline/python/10_standard_tool_library/examples/example.py

# or via the launcher, pointed at the repo root's .boukensha by default:
./week1_baseline/bin/python/10_standard_tool_library
```

## Tests

```sh
python -m unittest discover -s test -t .
```

The MCP tests spawn the real `mud-manager` daemon from the sibling
`week0_explore/mud_manager` checkout (talking to its own built-in fake MUD, no
network needed) and skip automatically if that checkout — or a `ruby`
interpreter to run it — isn't present.

## Technical Considerations

These are observations, not bugs to fix right now — preserving them here so
later steps don't reintroduce them by accident.

- There could be a case where if a session is already in use for a user they
  are prompted with Yes or No to kill the session, and our agent/mud_manager
  doesn't have a way to handle that case.
- It seems like we need more tool work, as there might not be enough tools to
  accomplish tasks efficiently, and most are mapping the same task to
  primitives.
- Servers spawn **eagerly** at boot: every entry costs a subprocess and a
  handshake even if the LLM never calls it. Fine at two servers; revisit past
  that.
- Non-text MCP content blocks (images, embedded resources) are dropped rather
  than rendered — they yield an empty string, not an exception. No MUD tool
  can hit this.
- The backends advertise every listed parameter as required, which is wrong
  for third-party servers with genuinely optional params. Fixing it means
  plumbing `inputSchema["required"]` through `boukensha.tool.Tool`, which
  touches all tools.
