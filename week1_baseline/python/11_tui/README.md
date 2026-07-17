# Step 11 — A Terminal UI

Boukensha now ships a full terminal UI (TUI) built on
[Textual](https://github.com/Textualize/textual). The plain REPL is still
there and can be selected with `tui=False` (or the `--no-tui` flag).

The standard tool library is **MCP**.

Boukensha ships **no tools of its own**. It is an MCP *host*: every tool the
agent can call comes from an MCP server declared in `settings.yaml`. Want file
access? Plug in a filesystem server. Want to play a MUD? Plug in
`mud-manager --mcp`. An agent with an empty `mcp_servers:` block can only talk.

## What's new

### `boukensha.tui.Tui`

Wraps a `Repl` instance and replaces its raw `print`/`input` I/O with a
structured four-zone display:

```
┌──────────────────────────────────────────────┐
│  conversation viewport (scrollable)           │
├──────────────────────────────────────────────┤
│  ⟳ live progress line (hidden when idle)     │
├──────────────────────────────────────────────┤
│  boukensha> input box                         │
├──────────────────────────────────────────────┤
│  status line (always-on)                      │
└──────────────────────────────────────────────┘
```

The **progress line** shows a spinner, current action, iteration counter
(`n/MAX`), elapsed seconds, token counts (↑ in / ↓ out), and tool call count
while the agent is running. When idle it shows context usage and turn count.

The **status line** always shows: version · model · context tokens used ·
registered tool count · wall-clock time.

**Keyboard shortcuts:**

| Key | Action |
|-----|--------|
| `Enter` | Submit input or slash command |
| `Esc` | Interrupt the running agent turn |
| `Ctrl+L` | Clear conversation history |
| `PgUp` / `PgDn` | Scroll conversation viewport |
| `Ctrl+C` / `Ctrl+D` | Quit |

The agent runs in a background thread so the UI stays responsive during long
turns. Both the Repl's output callback and the Logger's event subscriber are
invoked from that background thread, so `Tui` never mutates a widget directly
from them — it enqueues onto a `queue.Queue` and drains it once per tick
(every 60ms) on the app's own event-loop thread, which is the only thread
allowed to touch widget state.

### `boukensha.repl` — new `tui=` keyword

```python
from boukensha import repl

repl(tui=True)    # default — launches the Textual TUI
repl(tui=False)   # falls back to the plain terminal REPL
```

The `--no-tui` flag on `examples/example.py` sets `tui=False` from the
command line.

### `Repl` refactored for composability

`Repl` no longer hard-codes `print`/`sys.stdin.readline`. Three methods
support driving it from a front end other than raw stdio:

| Method | Purpose |
|--------|---------|
| `on_output(callback)` | Route all REPL output through `callback` instead of stdout |
| `handle_command(input)` | Process a slash command; returns `"quit"`, `"command"`, or `None` |
| `run_turn(input)` | Run one agent turn and route the result through `on_output` |

`banner`, `logger`, `context`, `model`, and `version` are public attributes
(or, for `banner`, a property), the same as before — Python instance
attributes have no `attr_reader`-style visibility to add.

### `Logger.subscribe`

```python
logger.subscribe(lambda event: ...)
```

Every structured log event (`iteration`, `tool_call`, `tool_result`,
`response`, etc.) is broadcast to all registered subscribers as well as being
written to the JSONL file. `Tui` uses this to update the live progress line in
real time without polling.

### Cooperative turn cancellation

`Agent` accepts an optional `cancel_event` (a `threading.Event`), checked at
the top of each loop iteration; if set, `Agent.run()` raises
`boukensha.errors.TurnCancelled`. `Repl.run_turn` builds a fresh event per
turn and passes it to the `Agent` it constructs, catching `TurnCancelled`
alongside `LoopError`/`ApiError` and reporting `"(interrupted)"` through
`on_output`. `Tui`'s `Esc` key sets that event when a turn is in flight.

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

Prefixing is applied **client-side**: the server still sees `look` on the
wire. It exists so two servers can't silently clobber each other's names — a
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
# Launches the Textual TUI by default.
# Launch from the repo root so the example config's relative path resolves:
BOUKENSHA_DIR=.boukensha python week1_baseline/python/11_tui/examples/example.py

# plain REPL, no Textual UI:
BOUKENSHA_DIR=.boukensha python week1_baseline/python/11_tui/examples/example.py --no-tui

# or via the launcher, pointed at the repo root's .boukensha by default:
./week1_baseline/bin/python/11_tui
./week1_baseline/bin/python/11_tui --no-tui
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

- **Esc does not interrupt a single in-flight backend call.** Ruby's `Tui`
  uses `Thread#raise(Interrupt)` to asynchronously inject an exception into
  the turn thread, which MRI can deliver even while that thread is blocked on
  network I/O. Python has no safe equivalent — injecting an async exception
  via `ctypes.pythonapi.PyThreadState_SetAsyncExc` only fires the next time the
  target thread returns to Python bytecode, so it cannot cut short an HTTP
  call already in flight. This port instead gives `Agent` a cooperative
  `cancel_event` checked at the top of each loop iteration. **Accepted gap:**
  pressing `Esc` while the agent is mid-network-call takes effect only once
  that call returns, at the next iteration/tool-call boundary — not
  mid-call the way ruby's can. This is a deliberate, documented divergence,
  not a missed port.
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
