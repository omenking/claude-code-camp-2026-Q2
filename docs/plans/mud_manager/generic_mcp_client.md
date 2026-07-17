# Generic MCP client — from `Tools::McpMud` to `Boukensha::Mcp` + `mcp_servers`

Follow-on to [`generic_interfacing.md`](generic_interfacing.md). That plan asked
"where does the one stateful Session live, and how do foreign-language agents
drive it?" and answered: a Ruby daemon behind an MCP facade. That shipped and
works.

This plan answers the question that surfaced *after* it:

> If we're speaking MCP, why does boukensha need a bespoke `Tools::McpMud` at
> all? Shouldn't the agent generically plug into **any** MCP server and register
> whatever tools it advertises?

Short answer: yes. The current coupling is an accident of where the code was
written, not a design necessity.

---

## 1. Diagnosis: what is actually MUD-specific?

The suspicion worth killing first is that the MUD's **statefulness** forces the
coupling. It doesn't — that's the thing MCP already solved here.

The daemon owns `SessionPool`. Connect, login, and reconnect all happen behind
the boundary. The LLM never sees a session id or a credential, and boukensha
never sees a socket. From the agent's side, a MUD tool call is `tools/call`
returning text — indistinguishable from any other server's tool. **Session state
is hidden by the protocol, not leaking through it.** That's an argument *for*
the generic path, not against it.

So what's left? Auditing the three files involved:

| File | MUD-specific logic | Verdict |
| --- | --- | --- |
| `mud_manager_mcp/lib/mud_manager_mcp/mcp_client.rb` | **None.** initialize / tools/list / tools/call over stdio. The only MUD reference is `default_cmd` pointing at `bin/mud-manager`. | Generic. Misfiled. |
| `mud_manager_mcp/lib/mud_manager_mcp/boukensha_bridge.rb` | **None.** `client.tools.each { dsl.tool(...) { client.call_tool(...) } }`. | Generic. Misfiled. |
| `10_standard_tool_library/lib/boukensha/tools/mcp_mud.rb` | Three things, all **data**: which binary to spawn, which env vars to hand it (`MUD_*`), where the package lives on disk. | The only real MUD part — and it's config, not code. |

The genuinely wrong thing is the **direction of the dependency**: boukensha
reaches into a MUD-named gem to obtain a *generic* MCP client. `MudManagerMcp::McpClient`
and `MudManagerMcp::BoukenshaBridge` know nothing about MUDs. That misfiling is
what makes MCP *look* like it needs a bespoke integration per server.

Spawning a subprocess with a command, args, and env is not coupling — it is the
MCP stdio transport's standard configuration shape (the same `command`/`args`/`env`
triple Claude Code and every other host uses). Passing credentials via the
server's environment is likewise the standard pattern: the spec has no
"send creds over the wire" concept for stdio servers, deliberately.

**Conclusion:** this is a move-and-rename plus a config reader. It is not a
rearchitecture, and it does not touch the daemon.

---

## 2. Target shape

```ruby
# boukensha owns the generic layer
Boukensha::Mcp::Client                                  # was MudManagerMcp::McpClient
Boukensha::Tools::Mcp.register(registry, command:, args:, env:, prefix: nil)
```

Servers become data in `~/.boukensha/settings.yaml`:

```yaml
mcp_servers:
  mud:
    command: mud-manager
    args:    [--mcp]
    prefix:  tbamud          # → tbamud__look, tbamud__attack (see §5a)
    env:
      MUD_HOST:     your.mud.host
      MUD_PORT:     4000
      MUD_NAME:     Gandalf
      MUD_PASSWORD: secret
```

`Tools::McpMud` collapses into a preset that resolves the `mud` entry — or
disappears entirely. And third-party servers come free, which today is
impossible:

```yaml
  filesystem:
    command: npx
    args:    [-y, "@modelcontextprotocol/server-filesystem", /tmp]
```

---

## 3. What this buys, honestly

- **The bootcamp story gets better.** "boukensha is an MCP host" is a lesson.
  "boukensha has a MUD module that happens to use MCP internally" is plumbing.
- Bootcampers can plug in any MCP server without touching boukensha's source.
- The Ruby track stops being a special case: it configures a server entry, the
  same way the Python/Go/Rust/Java tracks point their SDK at `mud-manager --mcp`.
- One client implementation instead of a generic one wearing a MUD's name.

**What it does not buy:** any change in MUD behavior. This is a refactor. If it
changes what the agent can do in the game, something went wrong.

---

## 4. Deferred non-problems (do not fix in this plan)

Two issues get raised whenever "generic MCP" comes up. Both are real *eventually*
and both are wrong to fix now — recording them so they don't get re-litigated.

### Non-text content blocks
MCP tools may return images or embedded resources, not just text. **Irrelevant
to the MUD**: `read_until_prompt` returns a String, `ToolSpec` builds text
commands, the daemon wraps everything in `{"type":"text"}`. There is no path to
a non-text MUD result.

It is also already handled defensively by accident:

```ruby
Array(result["content"]).map { |c| c["text"] }.compact.join("\n")
```

Non-text blocks are dropped, not crashed on. The day a third-party server
returns an image, that yields an empty string — bad, but not an exception.
**Fix when a second server actually needs it.**

### Every parameter marked required
`backends/anthropic.rb:61` does `required: tool.parameters.keys.map(&:to_s)` —
every listed param is advertised as required. Harmless today because `ToolSpec`
is a spec we control and the daemon treats blank strings as absent
(`ToolSpec.present`). It will bite against arbitrary third-party schemas that
have genuinely optional params.

The correct fix is to plumb `inputSchema["required"]` through `Boukensha::Tool`
and have the backends respect it. That's a **backend/Tool change affecting all
tools**, not just MCP ones — it deserves its own plan and its own tests.
**Out of scope. Do not bundle it.**

---

## 5. The design decisions that are genuinely open

Unlike §4, these must be settled before writing code, because they shape the
config schema and are painful to change later.

> **Terminology.** Throughout §5, **"server" means an MCP server process** — one
> entry in `mcp_servers`, one subprocess. It never means a MUD. Connecting to
> multiple MUDs is a *different axis*, already solved inside the daemon: the
> `SessionPool` holds multiple named sessions in **one** `mud-manager` process.
> Two MUDs is two sessions in one server, not two servers.

### 5a. Tool-name collisions across servers
Two servers can both advertise `search`. Today, impossible (one server). With
`mcp_servers`, likely. `Registry#tool` will happily let the second silently
clobber the first — a real bug that would be maddening to debug.

| Option | Shape | Trade-off |
| --- | --- | --- |
| **Always prefix** | `mud__look`, `filesystem__read_file` | No collisions ever. But renames every existing MUD tool → breaks the prompts, the docs, and `test_mcp_mud_module.rb`. Also makes tool names uglier for the LLM. |
| **Never prefix, raise on collision** | `look` stays `look`; a dupe is a hard error at registration | Zero churn. Fails loudly and early, which is the right failure. Forces a config change when a real collision appears. |
| **Optional `prefix:` per server, raise on collision** | default bare; `prefix: fs` when you need it | Zero churn now, escape hatch later. Slightly more config surface. |

**Recommendation: option 3.** Collisions raise a clear error naming both
servers; `prefix:` is the documented fix. Keeps `look` as `look`.

**DECIDED — prefix, named after the underlying MUD engine (`tbamud`).**
Not option 3; closer to option 1, but the prefix is the *engine*, not the config
key. So `tbamud__look`, `tbamud__attack`. Rationale: a second "tbaMUD" is
unlikely, and scoping by engine is sufficient to keep names distinct.

Consequences to carry into §6/§7 — this is now the highest-churn part of the
plan, not the lowest:

- Every MUD tool name changes. The prompts, `docs/mud_manager_mcp_integration.md`,
  and the assertions in `test_mcp_mud_module.rb` / `test_boukensha_integration.rb`
  (`ctx.tools.key?("look")`, `"poll"`, `"mud_connect"`) all reference bare names
  and must be updated. §7's "the tests should not need edits" no longer holds for
  the MCP path — **the name change is the one sanctioned reason to edit them.**
- The prefix is a property of the **server**, not of boukensha, so it stays a
  per-entry config value (`prefix: tbamud`) that the generic `Tools::Mcp` applies
  blindly. `Tools::Mcp` must not know the word "tbamud".
- Collisions must *still* raise. Prefixing makes them unlikely, not impossible
  (two entries could share a prefix, e.g. two tbaMUD daemons). The error is cheap
  and the silent-clobber failure is expensive. Keep it.
- Open: does `send_raw` / `poll` / `mud_status` get the prefix too? They come from
  the same server, so yes by default — the rule is per-server, not per-tool.
  Flagging only because `poll` and `mud_status` are daemon additions rather than
  MUD verbs.

### 5b. Spawn eagerly or lazily?
`register` currently spawns at registration and blocks on the handshake. With N
**MCP servers** (subprocesses — see the terminology note above, not N MUDs),
every agent boot pays N subprocess spawns + N handshakes, even for servers the
LLM never calls.

For the MUD that's correct — you want to know at boot that the daemon is
reachable. For a config with five MCP servers (say `mud-manager` + filesystem +
github + …) it's a slow, fragile boot.

**Recommendation: eager for now**, matching current behavior, and revisit if the
server list grows past ~2. Lazy spawning interacts badly with `tools/list` (you
can't register tools you haven't discovered), so "lazy" really means "register
from a cached manifest" — a much bigger change. Note it and move on.

### 5c. What happens when a server fails to spawn?
Today, `McpMud.register` raising means the agent dies. That's right for the MUD
(no MUD, no point). It's wrong for a decorative filesystem server.

**Recommendation:** `required: true` (default) per server entry. Required server
fails → raise. Optional server fails → `warn` and continue without its tools.

### 5d. Does `mud_manager_mcp` keep its own client copy?
The daemon package has `McpClient` for its own end-to-end tests
(`test_mcp_client_e2e.rb`).

**Recommendation: keep it.** The daemon must not depend on boukensha — it's
meant to serve five language tracks, and a test-only dependency on one of them
would be backwards. A ~60-line duplicated stdio client is a cheaper price than
that dependency edge. Boukensha's copy becomes canonical for boukensha; the
daemon's stays test-scoped.

---

## 6. Migration plan

Ordered so the suite stays green at every step.

### Step 1 — Hoist the client
Copy `mud_manager_mcp/lib/mud_manager_mcp/mcp_client.rb` →
`10_standard_tool_library/lib/boukensha/mcp/client.rb` as `Boukensha::Mcp::Client`.

Changes on the way in:
- Drop `default_cmd` (the `bin/mud-manager` reference) — callers now always pass `command`.
- Inline `PROTOCOL_VERSION` instead of requiring `mcp_server.rb` for it.
- Keep `spawn(command:, args:, env:)`, `#tools`, `#call_tool` → `{text:, error:}`, `#close`.

### Step 2 — Hoist the bridge
`boukensha_bridge.rb` → `10_standard_tool_library/lib/boukensha/tools/mcp.rb` as
`Boukensha::Tools::Mcp`, with the register signature:

```ruby
Boukensha::Tools::Mcp.register(registry, command:, args: [], env: {}, prefix: nil)
```

It spawns a `Mcp::Client`, registers each discovered tool (applying `prefix`,
raising on collision per §5a), `at_exit { client.close }`, returns the client.
The `RegistryDsl` adapter in `mcp_mud.rb` is no longer needed — `Registry` and
`RunDSL` already share the `#tool` surface, so accept either directly.

Prefixing rule: `prefix: tbamud` → `tbamud__#{name}`; `prefix: nil` → bare name.
`Tools::Mcp` applies whatever it's given and **must not know the word "tbamud"**
— that string lives only in config and in the `McpMud` preset's default.

### Step 3 — Config
Add to `config.rb`, beside `mud_mode`:

```ruby
def mcp_servers          # => { "mud" => { command:, args:, env:, prefix:, required: } }
  dig(:mcp_servers) || {}
end
```

Normalize keys, default `args: []`, `env: {}`, `required: true`.

### Step 4 — Reduce `McpMud` to a preset
`Tools::McpMud.register(registry, host:, port:, name:, password:)` keeps its
signature (so `register_mud_tools` and `test_mcp_mud_module.rb` are untouched),
but its body becomes:

1. Resolve the `mud` entry from `mcp_servers` if present.
2. Otherwise fall back to today's behavior: locate the sibling package via
   `MUD_MANAGER_MCP_PATH` / the sibling checkout, build `MUD_*` env from the args.
3. Delegate to `Tools::Mcp.register`.

Keep `candidate_lib_dirs` — it's how the repo layout works without an installed gem.

### Step 5 — Register configured servers in `run`/`repl`
Beside the existing `register_mud_tools(...) if resolved_mud`, add registration
of any `mcp_servers` entries **other than** `mud` (which the mode switch owns),
honoring §5c's required/optional rule.

### Step 6 — Docs
Update [`docs/mud_manager_mcp_integration.md`](../../mud_manager_mcp_integration.md):
§2's two-interface table gains the generic layer; add an `mcp_servers` section.
The doc's core claims (mud_manager unchanged, fake MUD is a test double, MCP is
a real terminal interface) all remain true.

---

## 7. Test plan

The 21 existing tests are the safety net. **The `tbamud` prefix decision (§5a)
splits them into two groups**, and the distinction is the whole point of the
test plan:

**Group 1 — must pass with only name changes.** `test_mcp_mud_module.rb` and
`test_boukensha_integration.rb` assert on bare tool names (`ctx.tools.key?("look")`,
`"poll"`, `"mud_connect"`). Under the prefix these become `tbamud__look`,
`tbamud__poll`. Updating those strings is expected and sanctioned. **Nothing else
in them may change** — the dispatch assertions (`/You do: look/`,
`/You do: kill dragon/`) must still pass untouched, because the *behavior* is
identical; only the label moved. If a dispatch assertion needs editing, the
refactor broke something. Stop and re-read.

Note `mud_connect` is an **embedded-mode** tool (`Tools::Mud`), not an MCP one —
it does **not** get prefixed. The mode-switch test distinguishes the two paths by
tool identity, so it becomes: mcp mode has `tbamud__poll` and no `mud_connect`;
embedded mode has `mud_connect` and no `tbamud__poll`. That asymmetry is now
load-bearing and worth a comment in the test.

**Group 2 — must pass completely untouched.** Everything in
`week1_baseline/mud_manager_mcp/test/` that isn't boukensha-facing
(`test_spec.rb`, `test_mcp_server.rb`, `test_json_line_server.rb`,
`test_mcp_client_e2e.rb`). The daemon is not changing. The prefix is applied
**client-side, in boukensha**; the daemon still advertises `look`. If a daemon
test needs editing, the prefix leaked across the boundary — that's a bug.

New tests, in boukensha's own suite (this is now boukensha's code):

| Test | Proves |
| --- | --- |
| `Mcp::Client` against `FakeMud` + `mud-manager` | the hoisted client still handshakes, lists, and calls. |
| `Tools::Mcp.register` with an explicit `command:` | generic registration works with no MUD knowledge. |
| `prefix:` applied | `prefix: tbamud` yields `tbamud__look`; the daemon still sees `look` on the wire. |
| `prefix: nil` | bare names still work — proves prefixing is a policy, not baked in. |
| collision raises | two entries sharing a prefix error clearly (§5a). |
| `Config#mcp_servers` | parses the YAML block, applies defaults. |
| optional server fails to spawn | warns and continues; required one raises (§5c). |

Manual verification:
`ruby examples/mcp_mud_demo.rb --dry` from step 10 must still print the daemon
info, 26 tools, and `[dry run OK …]` — **with the tool list now showing
`tbamud__` names.** The demo prints discovered names, so this is a cheap visual
confirmation the prefix landed.

---

## 8. Risks

- **Step 10 is a lesson snapshot.** This adds a `boukensha/mcp/` namespace and a
  config key to a baseline step. Additive and default-off, but if these steps are
  pinned teaching artifacts, land it on a branch or as step 11.
- **Scope creep toward §4.** The required-params fix will look tempting while
  touching schema code. It changes all tools, not just MCP ones. Resist.
- **Duplicated client drift** (§5d). Two stdio clients now exist. Accepted
  deliberately; the daemon's is test-scoped and shouldn't grow features.

---

## 9. Open questions

1. **Tool-name collisions** — confirm §5a option 3 (bare names, optional
   `prefix:`, raise on collision)?
2. **Step 10 vs step 11** — modify the baseline step in place, or land the
   generic MCP layer as a new step?
3. **Does `mud:` stay special?** Keeping `mud: { mode: mcp }` means the MUD has
   a bespoke config path *and* an `mcp_servers` entry. Cleaner long-term is
   `mud` being just another server entry — but that breaks the mode switch and
   its test. Keep the mode switch for continuity, or cut it now?
4. **Do we ship a second server** (e.g. filesystem) in the example config to
   prove genericity, or leave `mcp_servers` MUD-only until someone needs more?
