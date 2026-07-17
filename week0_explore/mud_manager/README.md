# MudManager — CircleMUD sessions, command primitives, and an MCP daemon

One gem, one binary. `MudManager` has two layers:

- **The domain** (`MudManager::Session` + `MudManager::Primitives`): a
  long-lived telnet connection with background buffering, IAC stripping, and
  the CircleMUD login/reconnect dance, plus a stateless library of
  enum-validated command builders.
- **The daemon** (`MudManager::Mcp::*`, the `mud-manager` binary): a single
  long-lived process that owns a `Session` and exposes it to agents in *any*
  language over stdio, so nobody has to reimplement telnet, threading, or the
  login dance in Java, Python, Rust, or Go.

This implements [`docs/plans/mud_manager/generic_interfacing.md`](../../docs/plans/mud_manager/generic_interfacing.md)
and [`docs/plans/mud_manager/single_gem.md`](../../docs/plans/mud_manager/single_gem.md)
(the plan that folded what used to be a separate `mud_manager_mcp` gem into
this one).

## Two protocols, one daemon

| Mode | Command | For |
|------|---------|-----|
| **MCP** (JSON-RPC 2.0 + tool discovery) | `mud-manager --mcp` | The blessed path. Any agent SDK that speaks MCP gets typed MUD tools with zero protocol code. |
| **Raw JSON-line** | `mud-manager --stdio-json` | The low-level teaching artifact / escape hatch — one JSON object per line, trivial to implement a client for by hand. |

Both are driven by the **same** `SessionPool` + `Dispatcher` and expose the
**same** tools, generated from one canonical Ruby source (`ToolSpec`).

## Running the MCP server

`--mcp` is the default mode, so bare `mud-manager` and `mud-manager --mcp` are
the same thing. The server speaks JSON-RPC over **stdio** — it has no port and
you don't start it yourself in a terminal; your MCP client spawns it as a
subprocess and keeps it alive for the session. Credentials come from the
environment (see below), never from tool args.

```jsonc
// Any MCP client's server config — e.g. .mcp.json, claude_desktop_config.json
{
  "mcpServers": {
    "mud": {
      "command": "mud-manager",
      "args": ["--mcp"],
      "env": {
        "MUD_HOST": "localhost",
        "MUD_PORT": "4000",
        "MUD_NAME": "YourCharacterName",
        "MUD_PASSWORD": "yourpassword"
      }
    }
  }
}
```

For Claude Code specifically:

```sh
claude mcp add mud --env MUD_NAME=YourCharacterName --env MUD_PASSWORD=yourpassword -- mud-manager --mcp
```

If you haven't `gem install`ed yet, swap `mud-manager` for
`ruby /abs/path/to/mud_manager/bin/mud-manager`.

The daemon doesn't touch the MUD at startup — it connects and logs in lazily on
the first gameplay tool call, so a misconfigured `MUD_*` surfaces as a tool
error, not a failed launch. To sanity-check the process without a client, run
`mud-manager --list-tools` (no MUD needed) or pipe JSON-RPC in by hand as shown
under [Quick start](#quick-start).

```
agent (any lang) ──stdio──> mud-manager ──TCP/telnet──> CircleMUD
                              │
                              ├─ Mcp::Server / Mcp::JsonLineServer  (transport)
                              ├─ Mcp::Dispatcher                   (tool name+args → text)
                              ├─ Mcp::SessionPool                  (the one stateful thing)
                              │    └─ Session + Primitives         (the domain)
                              └─ Mcp::ToolSpec  ──generates──> primitives.json
```

## Tools

The daemon exposes exactly the gameplay surface `Boukensha::Tools::Mud`
registered back when boukensha had in-process tools (`look`, `move`,
`attack`, `cast_spell`, `shop`, …, `send_raw`), **plus** two daemon additions:

- `poll` — return unprompted output that arrived while idle (combat ticks, other
  players) without sending anything.
- `mud_status` — is the session connected?

Connection tools (`connect`/`login`) are **not** exposed to the LLM. Session
lifecycle is a framework concern (plan §5): the daemon connects and logs in
lazily on the first gameplay call, using credentials from env/config, and
transparently reconnects on a dropped socket.

### Credentials (never from tool args)

Resolution order: explicit → env → `~/.boukensha/settings.yaml` → defaults.

```
MUD_HOST   (default localhost)     MUD_NAME / MUD_USER
MUD_PORT   (default 4000)          MUD_PASSWORD
```

## primitives.json — Ruby is canonical

`ToolSpec` pulls every enum **live** from `MudManager::Primitives` constants, so
`primitives.json` can never drift from the gem. Regenerate it with:

```sh
mud-manager --dump-spec       # or: rake spec
```

Other language tracks generate local typed builders from this one file.

## Build and install the gem

From this directory:

```sh
gem build mud_manager.gemspec
gem install ./mud_manager-0.2.0.gem
```

That's the whole distribution story: one `gem install`, and `mud-manager` is
on your PATH. No second gem to keep version-locked, and no Ruby toolchain
needed beyond running `gem install` itself.

```sh
mud-manager --list-tools
```

### Uninstall

```sh
gem uninstall mud_manager
```

## Quick start

```sh
# See the tool schemas (no MUD needed):
ruby bin/mud-manager --list-tools

# Talk MCP by hand:
printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}' \
  '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' | ruby bin/mud-manager --mcp
```

## Using the domain directly

`MudManager::Session` and `MudManager::Primitives` are also usable on their
own, without the daemon — this is what the daemon's `SessionPool` does
internally.

```sh
MUD_NAME=YourCharacterName MUD_PASSWORD=yourpassword ruby examples/live_session_test.rb
```

```ruby
require "mud_manager"

session = MudManager::Session.new(host: "localhost", port: 4000)
session.open
session.login("YourCharacterName", "yourpassword")

session.send_command(MudManager::Primitives.look)
puts session.read_until_quiet

session.close
```

## Using it from boukensha (the Ruby "MCP path")

`examples/boukensha_mcp_demo.rb` spawns `mud-manager --mcp`, discovers its
tools, and registers them into a `Boukensha.run` block via boukensha's own
generic MCP layer (`Boukensha::Tools::Mcp`) — the identical flow the
Python/Go/Rust/Java tracks follow with their own SDKs. This package ships no
boukensha-specific code; to boukensha, `mud-manager` is just an MCP server.
Run it self-contained (built-in fake MUD, no API key):

```sh
ruby examples/boukensha_mcp_demo.rb --dry
```

For a full agent run, set `ANTHROPIC_API_KEY` + `MUD_*` and drop `--dry`.

## Testing offline

`MudManager::FakeMud` is an in-process CircleMUD stand-in (login dance +
command echo, `push` for async output) so clients — in any language pointed at
`127.0.0.1:fake.port` — can be validated without a live server.

```sh
rake test
```

## Packaging

This gem ships the domain (`Session`, `Primitives`) and the daemon
(`Mcp::*`, the `mud-manager` binary) together, dependency-free: a Rust/Go/
Python bootcamper runs one `gem install mud_manager` and gets the
`mud-manager` binary on their PATH — no Ruby knowledge needed to *use* it.
This used to be two gems (`mud_manager` + `mud_manager_mcp`, the latter
depending on the former); they were folded into one because they always
shared a single release cadence — `Mcp::ToolSpec` reads `Primitives`
constants live, so the two could never actually version independently. See
[`docs/plans/mud_manager/single_gem.md`](../../docs/plans/mud_manager/single_gem.md)
for the full rationale.

The namespace still marks the internal boundary — `MudManager::Session` /
`MudManager::Primitives` (domain) vs. `MudManager::Mcp::*` (interface) — it
just doesn't charge a second `gem install` for it.
