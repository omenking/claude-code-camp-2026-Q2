# Step 11 — A Terminal UI

## Build
gem build boukensha.gemspec
gem install boukensha-0.11.1.gem

Boukensha now ships a full terminal UI (TUI) built on the [`charm`](https://github.com/charm-ruby/charm) gem (bubbletea + lipgloss + bubbles). The plain REPL is still there and can be selected with `tui: false`.

The standard tool library is **MCP**.

Boukensha ships **no tools of its own**. It is an MCP *host*: every tool the
agent can call comes from an MCP server declared in `settings.yaml`. Want file
access? Plug in a filesystem server. Want to play a MUD? Plug in
`mud-manager --mcp`. An agent with an empty `mcp_servers:` block can only talk.

## What's new

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

### What went away

| Gone | Replaced by |
|------|-------------|
| `Tools::FileSystem` (`pwd`, `read_file`, `write_file`, `search_files`, …) | a filesystem MCP server. Trade-off: needs node/npx, and its root is fixed in `args:` instead of tracking `working_dir`. |
| `Tools::Shell` (`run_command`) | a shell MCP server of your choosing (none configured yet). |
| `Tools::Mud` (embedded `MudManager::Session`) | the `mud-manager --mcp` daemon, which already wrapped the same `mud_manager` gem. |
| `Tools::McpMud`, the `mud:` / `working_dir:` / `allowed_commands:` / `shell_timeout:` arguments, `BOUKENSHA_MUD_MODE`, and `mud:` in settings.yaml | one `mcp_servers:` entry. |

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

The **status line** always shows: version · model · context tokens used/max · registered tool count · wall-clock time.

**Keyboard shortcuts:**

| Key | Action |
|-----|--------|
| `Enter` | Submit input or slash command |
| `Esc` | Interrupt the running agent turn |
| `Ctrl+L` | Clear conversation history |
| `PgUp` / `PgDn` | Scroll conversation viewport |
| `Ctrl+C` / `Ctrl+D` | Quit |

The agent runs in a background thread so the UI stays responsive during long turns.

### `Boukensha.repl` — new `tui:` keyword

```ruby
Boukensha.repl(tui: true)   # default — launches charm TUI
Boukensha.repl(tui: false)  # falls back to plain terminal REPL
```

The `--no-tui` CLI flag sets `tui: false` from the command line.

### `Repl` refactored for composability

`Repl` no longer hard-codes `puts`/`gets`. Three methods are now public so `Tui` (or any other front-end) can drive it:

| Method | Purpose |
|--------|---------|
| `on_output(&block)` | Route all REPL output through a callback instead of stdout |
| `handle_command(input)` | Process a slash command; returns `:quit`, `:command`, or `nil` |
| `run_turn(input)` | Run one agent turn and route the result through `on_output` |

`banner`, `logger`, `context`, `model`, and `version` are also exposed as readers.

### `Logger#subscribe`

```ruby
logger.subscribe { |event| ... }
```

Every structured log event (`:iteration`, `:tool_call`, `:tool_result`, `:response`, etc.) is now broadcast to all registered subscribers as well as being written to the JSONL file. `Tui` uses this to update the live progress line in real time without polling.

## Run the demo

The TUI is interactive, so it's run via the global `boukensha` executable
rather than `examples/example.rb` (that file is the one-shot `Boukensha.run`
demo, carried over unchanged — it doesn't exercise the TUI).

```sh
# Offline, no API key, no live MUD — uses the daemon's built-in fake MUD:
ruby examples/mcp_mud_demo.rb --dry

# Build and install this step's gem. If a later step's gem is already
# installed, `boukensha` will keep launching that version's loader instead —
# remove it first:
gem uninstall boukensha

gem build boukensha.gemspec
gem install boukensha-0.11.1.gem

# launches the charm TUI:
BOUKENSHA_DIR=/home/andrew/Sites/Claude-Code-Camp/.boukensha BOUKENSHA_PATH=~/Sites/Claude-Code-Camp/week1_baseline/11_tui boukensha

# plain REPL (no charm dependency required):
BOUKENSHA_PATH=~/Sites/boukensha/11_tui boukensha --no-tui
```

```sh
bundle exec bin/boukensha
```

## Tests

```sh
rake test
```

## Technical Considerations
This is just observations we dont want to fix these right now just to perserve current future layers.
- ~~There could be a case where if a sessions is already is in used for a user they are prompted with Yes or No to kill the session and our agent's/mud_manager doesn't have a way to handle that case.~~ **Fixed**: turns out CircleMUD doesn't actually prompt — it auto-kicks the stale connection and sends `"You take over your own body, already in use!"` instead of `"Reconnecting."`. `MudManager::Session#login` (in `week0_explore/mud_manager/lib/mud_manager/session.rb`) now recognizes that message the same way it recognizes `Reconnecting.`, so a duplicate login proceeds straight into the game instead of stalling until the login timeout.
- It seems like we need more tool work, as there might not be enough tools to accomplish tasks efficently and mostly are mapping the same task to primitives.
- Servers spawn **eagerly** at boot: every entry costs a subprocess and a handshake even if the LLM never calls it. Fine at two servers; revisit past that.
- Non-text MCP content blocks (images, embedded resources) are dropped rather than rendered — they yield an empty string, not an exception. No MUD tool can hit this.
- The backends advertise every listed parameter as required, which is wrong for third-party servers with genuinely optional params. Fixing it means plumbing `inputSchema["required"]` through `Boukensha::Tool`, which touches all tools.
- `~/.boukensharc` YAML support (`boukensha_path:` / `boukensha_dir:` keys, plus bare single-line path backward compat) from step 9 was not carried forward into an earlier rewrite, which silently mis-parsed step-9-era rc files. This step's loader restores that step-9 behavior verbatim — see [`docs/plans/floating_artifacts/bounkensharc.md`](../../../docs/plans/floating_artifacts/bounkensharc.md) for the incident writeup; keep that doc in mind before rewriting `boukensha_loader.rb` in later steps.
