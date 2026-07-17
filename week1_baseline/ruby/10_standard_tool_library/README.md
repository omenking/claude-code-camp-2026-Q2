# Step 10 — A Standard Tool Library

## Build
gem build boukensha.gemspec
gem install boukensha-0.10.0.gem

The standard tool library is **MCP**.

Boukensha ships **no tools of its own**. It is an MCP *host*: every tool the
agent can call comes from an MCP server declared in `settings.yaml`. Want file
access? Plug in a filesystem server. Want to play a MUD? Plug in
`mud-manager --mcp`. An agent with an empty `mcp_servers:` block can only talk.

> The directory is still named `10_standard_tool_library` from when this step
> shipped built-in `Tools::FileSystem` / `Tools::Shell` / `Tools::Mud` modules.
> Those are deleted. The name is kept so the step ordering and every path that
> points here still resolve.

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
| `Tools::Shell` (`run_command`) | a shell MCP server of your choosing. |
| `Tools::Mud` (embedded `MudManager::Session`) | the `mud-manager --mcp` daemon, which already wrapped the same `mud_manager` gem. |
| `Tools::McpMud`, the `mud:` / `working_dir:` / `allowed_commands:` / `shell_timeout:` arguments, `BOUKENSHA_MUD_MODE`, and `mud:` in settings.yaml | one `mcp_servers:` entry. |

The gemspec now declares **no tool dependencies at all** — `mud_manager` went
with `Tools::Mud`. Servers are separate processes and bring their own.

`working_dir:` survives on `Boukensha.run` / `.repl`, but only as Context
metadata: it registers nothing.

## Run the demo

```sh
# Offline, no API key, no live MUD — uses the daemon's built-in fake MUD:
ruby examples/mcp_mud_demo.rb --dry

# Full run — needs ANTHROPIC_API_KEY and an mcp_servers: mud entry.
# Launch from the repo root so the example config's relative path resolves:
BOUKENSHA_DIR=.boukensha ruby week1_baseline/ruby/10_standard_tool_library/examples/example.rb

# or via the global executable pointed at this step:
BOUKENSHA_PATH=~/Sites/boukensha/10_standard_tool_library boukensha
```

## Tests

```sh
rake test
```

## Technical Considerations
This is just observations we dont want to fix these right now just to perserve current future layers.
- There could be a case where if a sessions is already is in used for a user they are prompted with Yes or No to kill the session and our agent's/mud_manager doesn't have a way to handle that case.
- It seems like we need more tool work, as there might not be enough tools to accomplish tasks efficently and mostly are mapping the same task to primitives.
- Servers spawn **eagerly** at boot: every entry costs a subprocess and a handshake even if the LLM never calls it. Fine at two servers; revisit past that.
- Non-text MCP content blocks (images, embedded resources) are dropped rather than rendered — they yield an empty string, not an exception. No MUD tool can hit this.
- The backends advertise every listed parameter as required, which is wrong for third-party servers with genuinely optional params. Fixing it means plumbing `inputSchema["required"]` through `Boukensha::Tool`, which touches all tools.
- `~/.boukensharc` YAML support (`boukensha_path:` / `boukensha_dir:` keys, plus bare single-line path backward compat) from step 9 was not carried forward into this step's initial rewrite, which silently mis-parsed step-9-era rc files. This step's loader now restores that step-9 behavior verbatim — see [`docs/plans/floating_artifacts/bounkensharc.md`](../../../docs/plans/floating_artifacts/bounkensharc.md) for the incident writeup; keep that doc in mind before rewriting `boukensha_loader.rb` in later steps.
