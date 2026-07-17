# Step 12 — Context Management

When you call an LLM directly you are responsible for the context window.
There is no auto-compacting. This step adds proper token tracking, visual
warnings, and automatic compaction so the agent never silently blows past the
limit — on top of the MCP-host tool model and terminal UI carried forward
from earlier steps.

The standard tool library is **MCP**.

Boukensha ships **no tools of its own**. It is an MCP *host*: every tool the
agent can call comes from an MCP server declared in `settings.yaml`. Want file
access? Plug in a filesystem server. Want to play a MUD? Plug in
`mud-manager --mcp`. An agent with an empty `mcp_servers:` block can only talk.

## What's new

### Accurate context tracking

`Context` now maintains two distinct token counts:

| Attribute | What it measures |
|-----------|-------------------|
| `context_window` | The model's maximum input token capacity, looked up from `models.context_window(model)` |
| `current_tokens` | Tokens actually used in the most recent API call (`usage["input_tokens"]` from the response) |

Previously the output `max_output_tokens` cap was shown as if it were the
context limit, and a cumulative session token sum was displayed as usage —
growing without bound even after `/clear`. Both are fixed: `Agent` updates
`current_tokens` after every API response (including mid-turn tool-use
calls), so the display always reflects what the next call will actually send.

### `boukensha.models`

A static model → capability table built from every backend's own `MODELS`
dict, so `Context` can be sized correctly *before* a backend is constructed:

```python
from boukensha import models

models.context_window("gpt-5.5")  # => 1_000_000
```

Unknown models fall back to a conservative `DEFAULT_CONTEXT_WINDOW` (32,000)
rather than silently assuming a huge window.

### Context colour coding

The TUI's progress and status lines now colour the context indicator based on
how full the window is:

| Usage | Colour | Meaning |
|-------|--------|---------|
| < 70% | Dim | Normal |
| 70–84% | Yellow | Approaching limit |
| ≥ 85% | Red | Compaction imminent |

A `⚠` symbol also appears in the status bar at 85%+.

### Auto-compaction

At the start of each agent turn, if `current_tokens / context_window` is at
or above the configured `agent.compaction_threshold` (default `0.85`), the
`Agent` automatically compacts the context before making any API call:

```
[context compacted — 12 messages dropped to free space]
```

Compaction drops the oldest 40% of messages (keeping at least 2) and resets
`current_tokens` to 0. The first API call after compaction reports the true
new size.

### `Context.compact_messages`

```python
dropped = context.compact_messages(target_fraction=0.60)
# => 12  (number of messages dropped)
```

`target_fraction` is accepted for signature parity but currently unused —
compaction always targets the oldest 40%.

### `/compact` command

Manual compaction from the REPL or TUI:

```
boukensha> /compact
(compacted context — 12 messages dropped)
```

### `Logger.compaction` event

```json
{"phase":"compaction","before":172000,"dropped":12,"context_window":200000}
```

Emitted whenever auto- or manual compaction runs. `Tui` subscribes to this
event to display the compaction notice in the conversation view.

### A second, independent circuit breaker: `max_turn_tokens`

`Agent` now stops a turn on whichever of two thresholds trips first: the
existing `max_iterations` (tool-call count) or `max_turn_tokens` (cumulative
input+output tokens spent this turn). Both read from `settings.yaml`'s
`agent:` block (`agent.max_iterations`, `agent.max_output_tokens`,
`agent.max_turn_tokens`, `agent.compaction_threshold`), with sane defaults
(25 / 1024 / 60,000 / 0.85) when the block is absent.

### Reasoning/thinking normalization

Every backend now normalizes provider-specific "thinking" output into a
common `"type": "reasoning"` content block (see `backends/base.py`'s
docstring for the full contract), so the agent's reasoning is a first-class,
loggable step regardless of provider:

- **Anthropic**: native `thinking`/`redacted_thinking` blocks, signature
  preserved for round-tripping.
- **Gemini**: `thought`/`thoughtSignature` parts.
- **Ollama** / **Ollama Cloud**: `message["thinking"]`.

`Logger.reasoning` and `Logger.plan` log these as their own event types;
`Agent._log_reasoning` emits one `reasoning` event per block, skipping empty
non-redacted ones.

#### Normalized response contract

Every backend's `parse_response` returns:

```
{"stop_reason": "tool_use" | "end_turn",
 "content": [<block>, <block>, ...]}
```

where each block is one of:

```
{"type": "reasoning",
 "text":      "<human-readable reasoning, may be empty>",
 "signature": "<opaque provider token, optional>",  # round-trip only
 "redacted":  True | False}                         # optional

{"type": "text", "text": "..."}

{"type": "tool_use", "id": ..., "name": ..., "input": {...}}
```

Reasoning blocks come first in `content`, before text and tool_use (matching
Anthropic's native ordering). `text` is what the viewer renders and may be
empty (redacted/omitted reasoning). `signature`/`redacted` are opaque
carry-through for providers that require the block echoed back unchanged
(Anthropic thinking signatures, Gemini `thoughtSignature`) — consumers never
interpret them. Backends that don't accept reasoning back in a request drop
these blocks when rebuilding assistant turns.

### The OpenAI backend now targets `/v1/responses`

gpt-5.x rejects `reasoning_effort` + tools on `/v1/chat/completions` ("Please
use /v1/responses"), so the OpenAI backend migrated to the Responses API.
That changes more than the URL: messages become `input` items, the system
prompt becomes a top-level `instructions` string, tool defs are flat (no
`function:` wrapper), and tool results round-trip via `function_call_output`
items matched by `call_id` rather than a `{"role": "tool"}` message.

### `boukensha.run` / `boukensha.repl` — `context_window=` keyword

```python
from boukensha import repl

repl(context_window=128_000)  # override for a smaller model
```

Defaults to `models.context_window(model)` when omitted.

### `boukensha.mcp.client.Client`

A minimal MCP-over-stdio client: spawn a server, handshake, `tools/list`,
`tools/call`. It is server-agnostic — `command` / `args` / `env` is the
standard stdio transport config, the same triple every MCP host uses. A
crash during spawn/handshake now surfaces the subprocess's stderr in the
raised error instead of a bare "server closed the connection".

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

### `agent:` in `settings.yaml`

Static per-turn circuit breakers, read where the `Agent` is constructed:

```yaml
agent:
  max_iterations:        25
  max_output_tokens:      1024
  max_turn_tokens:       60000
  compaction_threshold:  0.85
```

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
while the agent is running. When idle it shows colour-coded context usage
(used/max, percentage) and turn count.

The **status line** always shows: version · model · context tokens used/max
(colour-coded, `⚠` at 85%+) · registered tool count · wall-clock time.

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

### `boukensha.repl` — `tui=` keyword

```python
from boukensha import repl

repl(tui=True)    # default — launches the Textual TUI
repl(tui=False)   # falls back to the plain terminal REPL
```

The `--no-tui` flag on `examples/example.py` sets `tui=False` from the
command line.

### `Repl` — composable, with `/quiet` / `/loud` / `/clear` / `/compact`

`Repl` doesn't hard-code `print`/`sys.stdin.readline`. Three methods support
driving it from a front end other than raw stdio:

| Method | Purpose |
|--------|---------|
| `on_output(callback)` | Route all REPL output through `callback` instead of stdout |
| `handle_command(input)` | Process a slash command; returns `"quit"`, `"command"`, or `None` |
| `run_turn(input)` | Run one agent turn and route the result through `on_output` |

`banner`, `logger`, `context`, `model`, and `version` are public attributes
(or, for `banner`, a property). Built-in commands: `/quiet` and `/loud`
toggle logging output, `/clear` wipes conversation history (tools stay
registered), `/compact` frees context on demand, `/exit`/`/quit` leave the
REPL.

### `Logger.subscribe`

```python
logger.subscribe(lambda event: ...)
```

Every structured log event (`iteration`, `tool_call`, `tool_result`,
`response`, `compaction`, `reasoning`, `plan`, etc.) is broadcast to all
registered subscribers as well as being written to the JSONL file. `Tui`
uses this to update the live progress line and conversation view in real
time without polling.

### Cooperative turn cancellation

`Agent` accepts an optional `cancel_event` (a `threading.Event`), checked at
the top of each loop iteration; if set, `Agent.run()` raises
`boukensha.errors.TurnCancelled`. `Repl.run_turn` builds a fresh event per
turn and passes it to the `Agent` it constructs, catching `TurnCancelled`
alongside `LoopError`/`ApiError` and reporting `"(interrupted)"` through
`on_output`. `Tui`'s `Esc` key sets that event when a turn is in flight.

### What went away

`12_context` carries forward the MCP-host rewrite from earlier steps — there
is no built-in tool library left to remove here.

`working_dir` survives on `boukensha.run` / `.repl`, but only as `Context`
metadata: it registers nothing.

## Run the demo

```sh
# Offline, no API key, no live MUD — uses the daemon's built-in fake MUD:
python examples/mcp_mud_demo.py --dry

# Full run — needs ANTHROPIC_API_KEY and an mcp_servers: mud entry.
# Launches the Textual TUI by default.
# Launch from the repo root so the example config's relative path resolves:
BOUKENSHA_DIR=.boukensha python week1_baseline/python/12_context/examples/example.py

# plain REPL, no Textual UI:
BOUKENSHA_DIR=.boukensha python week1_baseline/python/12_context/examples/example.py --no-tui

# or via the launcher, pointed at the repo root's .boukensha by default:
./week1_baseline/bin/python/12_context
./week1_baseline/bin/python/12_context --no-tui
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

- **`record_usage` reads `response["usage"]` raw**, which silently zeroes out
  context tracking for Gemini/Ollama/OllamaCloud. The step-11 `Agent` had a
  usage-normalization helper that checked `"usage"`, then `"usageMetadata"`
  (Gemini), then `prompt_eval_count`/`eval_count` (Ollama) in turn. This step
  drops that helper — `record_usage` and the final `logger.response` call now
  read `response.get("usage")` directly, which only exists in Anthropic's and
  the rewritten OpenAI Responses API's raw response shape. For Gemini/Ollama/
  OllamaCloud, `Context.update_tokens`/`.add_turn_tokens` (and therefore the
  compaction trigger, the context gauge, and the logged token/cost figures)
  silently see zero every turn. This is inherited from the ruby step-12
  source, not a Python-specific gap.
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
- `Config.provider_type`/`.model` are dead code, ported for fidelity with the
  ruby source's `Config#to_s`. Neither is called anywhere in `__init__.py`,
  `repl.py`, or the test suite — `Tasks.Player` still owns provider/model/
  system-prompt resolution end to end.
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
