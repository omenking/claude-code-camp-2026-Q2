# Step 12 — Context Management

## Build
gem build boukensha.gemspec
gem install boukensha-0.13.0.gem

When you call an LLM directly you are responsible for the context window. There is no auto-compacting. This step adds proper token tracking, visual warnings, and automatic compaction so the agent never silently blows past the limit — on top of the MCP-host tool model and terminal UI carried forward from earlier steps.

The standard tool library is **MCP**.

Boukensha ships **no tools of its own**. It is an MCP *host*: every tool the
agent can call comes from an MCP server declared in `settings.yaml`. Want file
access? Plug in a filesystem server. Want to play a MUD? Plug in
`mud-manager --mcp`. An agent with an empty `mcp_servers:` block can only talk.

## What's new

### Accurate context tracking

`Context` now maintains two distinct token counts:

| Attribute | What it measures |
|-----------|-----------------|
| `context_window` | The model's maximum input token capacity, looked up from `Models.context_window(model)` |
| `current_tokens` | Tokens actually used in the most recent API call (`usage.input_tokens` from the response) |

Previously `token_budget` (8,192) was displayed as the limit — that was the *output* `max_tokens`, not the context window. And the cumulative session token sum was shown as usage, which grew without bound even after `/clear`. Both are fixed.

The Agent updates `current_tokens` after every API response (including mid-turn tool-use calls), so the display always reflects what the next call will actually send.

### `Boukensha::Models`

A static model → capability table built from every backend's own `MODELS` constant, so `Context` can be sized correctly *before* a backend is constructed:

```ruby
Boukensha::Models.context_window("gpt-5.5")  # => 1_000_000
```

Unknown models fall back to a conservative `DEFAULT_CONTEXT_WINDOW` (32,000) rather than silently assuming a huge window.

### Context colour coding

The progress and status lines now colour the context indicator based on how full the window is:

| Usage | Colour | Meaning |
|-------|--------|---------|
| < 70% | Grey | Normal |
| 70–84% | Yellow | Approaching limit |
| ≥ 85% | Red | Compaction imminent |

A `⚠` symbol also appears in the status bar at 85%+.

### Auto-compaction

At the start of each agent turn, if `current_tokens / context_window ≥` the configured `agent.compaction_threshold` (default 0.85), the Agent automatically compacts the context before making any API call:

```
[context compacted — 12 messages dropped to free space]
```

Compaction drops the oldest 40% of messages (keeping at least 2) and resets `current_tokens` to 0. The first API call after compaction will report the true new size.

### `Context#compact_messages!`

```ruby
dropped = context.compact_messages!(target_fraction: 0.60)
# => 12  (number of messages dropped)
```

### `/compact` command

Manual compaction from the REPL or TUI:

```
boukensha> /compact
(compacted context — 12 messages dropped)
```

### `Logger#compaction` event

```json
{"phase":"compaction","before":172000,"dropped":12,"context_window":200000}
```

Emitted whenever auto- or manual compaction runs. The TUI subscribes to this event to display the compaction notice in the conversation view.

### A second, independent circuit breaker: `max_turn_tokens`

`Agent` now stops a turn on whichever of two thresholds trips first: the existing `max_iterations` (tool-call count) or `max_turn_tokens` (cumulative input+output tokens spent this turn). Both read from `settings.yaml`'s `agent:` block (`agent.max_iterations`, `agent.max_output_tokens`, `agent.max_turn_tokens`, `agent.compaction_threshold`), with sane defaults (25 / 1024 / 60,000 / 0.85) when the block is absent.

### Reasoning/thinking normalization

Every backend now normalizes provider-specific "thinking" output into a common `"type" => "reasoning"` content block (see `Backends::Base`'s doc comment for the full contract below), so the agent's reasoning is a first-class, loggable step regardless of provider:

- **Anthropic**: native `thinking`/`redacted_thinking` blocks, signature preserved for round-tripping.
- **Gemini**: `thought`/`thoughtSignature` parts.
- **Ollama** / **Ollama Cloud**: `message["thinking"]`.

`Logger#reasoning` and `Logger#plan` log these as their own event types; `Agent#log_reasoning` emits one `reasoning` event per block, skipping empty non-redacted ones.

#### Normalized response contract

Every backend's `#parse_response` returns:

```
{ stop_reason: "tool_use" | "end_turn",
  content: [ <block>, <block>, ... ] }
```

where each block is one of:

```
{ "type" => "reasoning",
  "text"      => "<human-readable reasoning, may be empty>",
  "signature" => "<opaque provider token, optional>",  # round-trip only
  "redacted"  => true | false }                        # optional

{ "type" => "text", "text" => "..." }

{ "type" => "tool_use", "id" => ..., "name" => ..., "input" => {...} }
```

Reasoning blocks come first in `content`, before text and tool_use (matching Anthropic's native ordering). `text` is what the viewer renders and may be empty (redacted/omitted reasoning). `signature`/`redacted` are opaque carry-through for providers that require the block echoed back unchanged (Anthropic thinking signatures, Gemini `thoughtSignature`) — consumers never interpret them. Backends that don't accept reasoning back in a request drop these blocks when rebuilding assistant turns.

### The OpenAI backend now targets `/v1/responses`

gpt-5.x rejects `reasoning_effort` + tools on `/v1/chat/completions` ("Please use /v1/responses"), so the OpenAI backend migrated to the Responses API. That changes more than the URL: messages become `input` items, the system prompt becomes a top-level `instructions` string, tool defs are flat (no `function:` wrapper), and tool results round-trip via `function_call_output` items matched by `call_id` rather than a `{role: "tool"}` message.

### `Boukensha.run` / `Boukensha.repl` — `context_window:` keyword

`token_budget:` is replaced by `context_window:`, defaulting to `Models.context_window(model)`:

```ruby
Boukensha.repl(context_window: 128_000)  # override for a smaller model
```

### `Tasks::Player`-driven settings

Provider, model, and system-prompt-override resolution now go through `Tasks::Base`/`Tasks::Player` against `tasks.player.*` in `settings.yaml`, restoring the bundled-default fallback (`Config::PROMPTS_DIR`) that a narrower, hand-rolled version of this lookup had silently dropped — without it, a user with no `~/.boukensha/prompts/system.md` got no system prompt at all.

### `Boukensha::Mcp::Client`

A minimal MCP-over-stdio client: spawn a server, handshake, `tools/list`,
`tools/call`. It is server-agnostic — `command` / `args` / `env` is the standard
stdio transport config, the same triple every MCP host uses.

### `Boukensha::Tools::Mcp`

The only file left under `tools/`. Registers a server's discovered tools into a
registry, optionally scoping their names with a `prefix:`.

```ruby
Boukensha::Tools::Mcp.register(
  registry,
  command: "mud-manager", args: ["--mcp"],
  env: { "MUD_HOST" => "localhost" },
  prefix: "tbamud"          # the daemon's `look` registers as `tbamud__look`
)
```

Prefixing is applied **client-side**: the server still sees `look` on the wire.
It exists so two servers can't silently clobber each other's names — a collision
raises and names the fix.

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

### What went away (in this step)

`12_context` was branched from a pre-MCP base and carried its own built-in tool
modules until this merge. They're now gone, same as every other step past the
MCP-host rewrite:

| Gone | Replaced by |
|------|-------------|
| `Tools::FileSystem` (`pwd`, `read_file`, `write_file`, `search_files`, …) | a filesystem MCP server. Trade-off: needs node/npx, and its root is fixed in `args:` instead of tracking `working_dir`. |
| `Tools::Shell` (`run_command`) | a shell MCP server of your choosing (none configured yet). |
| `Tools::Mud` (embedded `MudManager::Session`) | the `mud-manager --mcp` daemon, which already wrapped the same `mud_manager` gem. |
| the `mud:` / `working_dir:` / `allowed_commands:` / `shell_timeout:` arguments and `mud:` in settings.yaml | one `mcp_servers:` entry. |

The gemspec now declares **no tool dependencies at all** — `mud_manager` went
with `Tools::Mud`. Servers are separate processes and bring their own; boukensha
itself needs only `charm`, for the TUI.

`working_dir:` survives on `Boukensha.run` / `.repl`, but only as Context
metadata: it registers nothing.

### `Boukensha::Tui`

Wraps a `Repl` instance and replaces its raw `puts`/`gets` I/O with a structured four-zone display:

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

The **progress line** shows a spinner, current action, iteration counter (`n/MAX`), elapsed seconds, token counts (↑ in / ↓ out), and tool call count while the agent is running. When idle it shows context usage and turn count.

The **status line** always shows: version · model · context tokens used/max (colour-coded, `⚠` at 85%+) · registered tool count · wall-clock time.

**Keyboard shortcuts:**

| Key | Action |
|-----|--------|
| `Enter` | Submit input or slash command |
| `Esc` | Interrupt the running agent turn |
| `Ctrl+L` | Clear conversation history |
| `PgUp` / `PgDn` | Scroll conversation viewport |
| `Ctrl+C` / `Ctrl+D` | Quit |

The agent runs in a background thread so the UI stays responsive during long turns.

### `Boukensha.repl` — `tui:` keyword

```ruby
Boukensha.repl(tui: true)   # default — launches charm TUI
Boukensha.repl(tui: false)  # falls back to plain terminal REPL
```

The `--no-tui` CLI flag sets `tui: false` from the command line.

### `Repl` — composable, with `/quiet` / `/loud` / `/clear` / `/compact`

`Repl` doesn't hard-code `puts`/`gets`. Three methods are public so `Tui` (or any other front-end) can drive it:

| Method | Purpose |
|--------|---------|
| `on_output(&block)` | Route all REPL output through a callback instead of stdout |
| `handle_command(input)` | Process a slash command; returns `:quit`, `:command`, or `nil` |
| `run_turn(input)` | Run one agent turn and route the result through `on_output` |

`banner`, `logger`, `context`, `model`, and `version` are also exposed as readers. Built-in commands: `/quiet` and `/loud` toggle logging output, `/clear` wipes conversation history (tools stay registered), `/compact` frees context on demand, `/exit`/`/quit` leave the REPL.

### `Logger#subscribe`

```ruby
logger.subscribe { |event| ... }
```

Every structured log event (`:iteration`, `:tool_call`, `:tool_result`, `:response`, `:compaction`, `:reasoning`, etc.) is now broadcast to all registered subscribers as well as being written to the JSONL file. `Tui` uses this to update the live progress line and conversation view in real time without polling.

### `Logger#response` — cost/provider/model metadata

```json
{"phase":"response","text":"...","usage":{...},"stop_reason":"end_turn","task":null,"provider":"anthropic","model":"claude-haiku-4-5","usage_unit":"tokens","input_tokens":1200,"output_tokens":340,"cost_usd":0.0029}
```

Every response event now carries `execution_metadata` — provider, model, token counts, and an estimated USD cost (via `Backends::Base#estimate_cost`) when the backend prices in tokens.

## Run the demo

```sh
# Offline, no API key, no live MUD — uses the daemon's built-in fake MUD:
ruby examples/mcp_mud_demo.rb --dry

# One-shot demo:
ruby examples/example.rb

# Build and install this step's gem. If a later step's gem is already
# installed, `boukensha` will keep launching that version's loader instead —
# remove it first:
gem uninstall boukensha

gem build boukensha.gemspec
gem install boukensha-0.13.0.gem

# launches the charm TUI:
BOUKENSHA_DIR=~/Sites/Claude-Code-Camp/.boukensha BOUKENSHA_PATH=~/Sites/Claude-Code-Camp/week1_baseline/12_context boukensha

# plain REPL (no charm dependency required):
BOUKENSHA_PATH=~/Sites/boukensha/12_context boukensha --no-tui
```

## Tests

```sh
rake test
```
