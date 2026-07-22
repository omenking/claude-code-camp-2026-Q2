# Task tool permissions (`allow:`)

Each boukensha **task** (the `player`, the `room_inspector` subagent, …) declares
which MCP tools it may call — and with which argument values — through an
`allow:` block in `settings.yaml`. This is a **pure allowlist with
default-deny**: a task can call a tool only if a rule names it, and can pass an
argument value only if the rule permits it.

Tools themselves come from the `mcp_servers:` block. All tasks share one spawned
client per server (one MUD login, not one per task); `allow:` is what scopes
each task down to its own slice of that shared surface.

---

## Where it goes

Under `tasks.<name>` in `~/.boukensha/settings.yaml` (or `$BOUKENSHA_DIR`):

```yaml
tasks:
  room_inspector:
    provider: anthropic
    model: claude-haiku-4-5
    allow:
      - poll
      - look
      - check(kind: exits)
      - consider
      - examine
```

Each list item is one **rule** (a string). The task may call exactly the tools
its rules name, nothing else.

---

## Rule grammar

```ebnf
Rule    ::= Tool [ "(" Arg { "," Arg } ")" ]
Arg     ::= Param ":" Pattern
Pattern ::= "*" | Value { "|" Value }
```

| Form | Meaning |
|---|---|
| `poll` | call `poll` with any arguments |
| `check(kind: exits)` | call `check` only when `kind` is `exits` |
| `check(kind: score\|gold)` | `kind` may be `score` **or** `gold` (pipe = alternation) |
| `check(kind: *)` | `kind` may be anything (explicit "open") |
| `move(direction: north\|south)` | values must be real enum members (`north`, not `n`) |
| `tool(p: a, q: b)` | multiple params, comma-separated (rare) |

Two rules that name the same tool are **unioned** — `check(kind: exits)` plus
`check(kind: score)` means `kind ∈ {exits, score}`. (Or write
`check(kind: exits|score)`.)

### Bare vs. prefixed tool names

MCP tools are registered under their server prefix (`tbamud__check`) — that
prefixed name is also what the model sees as the tool's callable name; the
bare name never reaches the model. In a rule you may write either the **bare**
name (`check`) or the full prefixed name (`tbamud__check`); a bare name
matches regardless of prefix.

**Write the prefixed form.** A bare rule matches *any* server's tool with that
name, so if two servers ever expose the same bare tool name, one bare rule
silently matches both — validated against each tool's own (possibly
different) schema, and granting whatever it permits on both. The prefixed
form (`tbamud__check`) pins the rule to exactly one server's tool, so it's
the explicit, unambiguous choice and the one this project's `settings.yaml`
uses. Bare is only a shorthand for quick one-off configs.

### Parameters you don't name are open

A rule only constrains the parameters it lists. `consider` (a tool whose
`target` is a free-form mob name) is written bare — you never enumerate targets.
You pin a parameter only when you want to restrict it.

---

## Validation happens at startup, against each tool's own schema

The "grammar" for a tool's arguments is the tool's own parameter schema — the
`enum` declared next to it in the MUD manager's `tool_spec.rb`, delivered to
boukensha over MCP as `inputSchema`. Every rule is checked against that schema
when the agent boots. A bad rule **aborts startup** rather than failing silently
later:

| Mistake | Error at boot |
|---|---|
| `flyaway` (no such tool) | `permission rule references unknown tool 'flyaway'` |
| `check(knd: exits)` (no such param) | `'check' has no parameter 'knd'` |
| `check(kind: teleport)` (not a real value) | `teleport is not a valid kind (one of: score, inventory, …, exits)` |
| `consider(target: bob)` (param has no enum) | `parameter 'target' of 'consider' is not constrainable` |

**Only enum parameters are constrainable.** A parameter has to declare an `enum`
for a value pattern to be legal — that's the only case we can validate against a
known set. Free-form strings and numbers are not constrainable today (a rule
that tries is the last error above); such a tool would have to opt in
explicitly, which nothing needs yet.

---

## How it's enforced

Enforcement lives in `Boukensha::Registry` — the one place every tool passes
through, whether it came from an MCP server (`Tools::Mcp.register_client`) or
was registered natively in a run/repl block (`RunDSL#tool`, e.g. the player's
`inspect_room`):

1. **Name level (registration, `Registry#tool`).** A tool no rule names is
   never registered — so the model is never even told it exists, and it can't
   be dispatched. Same gate for an MCP tool or a native one.
2. **Value level.** For a tool that *is* allowed:
   - For MCP tools, `Tools::Mcp.register_client` **narrows the advertised
     enum** to the permitted values before registering, so the model is only
     offered values it may use. (Native tools have no enum concept to narrow
     — see the known limitation below.)
   - `Registry#dispatch` re-checks the actual call at runtime and rejects any
     value the rules don't permit, *before* the tool's block ever runs. (This
     guard is the real enforcement — the narrowed enum is only carried in the
     parameter's description text, which is a strong hint, not a hard API
     constraint.)

So a blocked value is both hidden up front (where a schema can express it) and
refused if attempted anyway, for every tool regardless of where it came from.

---

## Default-deny

- A task **with** an `allow:` block may call only what its rules permit.
- A task **without** an `allow:` block may call **nothing** (default-deny).

If a task can't call anything unexpectedly, check that it has an `allow:` block.

> **Native tools are gated too.** A tool the deployment registers directly in
> code (e.g. the player's native `inspect_room`, wired at the entrypoint rather
> than coming from an MCP server) goes through the exact same `Registry`
> allowlist as an MCP tool — it just needs an explicit rule in `allow:` like
> anything else. The only difference is the rule's shape: native tools have no
> server `prefix:`, so there's nothing to disambiguate and the rule is always
> the tool's bare name (`inspect_room`, not `something__inspect_room`) — there
> is only ever one server for a given native tool name: the entrypoint.

---

## Worked examples

### A narrow subagent — grant exactly its slice

`room_inspector` assembles a room survey from primitives and appraises mobs. It
needs `check` only to read exits:

```yaml
room_inspector:
  allow:
    - tbamud__poll
    - tbamud__look
    - tbamud__check(kind: exits)   # advertised + guarded to exits only
    - tbamud__consider
    - tbamud__examine
```

Result: its `check` offers only `exits`; `check(kind: score)` is refused;
`check(kind: exits)` reaches the MUD. Every other tool is invisible to it.

### A broad task — the cost of pure allowlist

The `player` uses many tools but must **not** survey rooms directly (that's the
`inspect_room` subagent's job), so `look` is absent and `check` is pinned to
every kind *except* `exits`. Pure allowlist means listing them:

```yaml
player:
  allow:
    - tbamud__move
    - tbamud__attack
    - tbamud__consider
    - tbamud__examine
    - tbamud__check(kind: score|inventory|equipment|gold|time|weather|levels|wimpy|toggle|where)
    - tbamud__say
    - tbamud__tell
    # …every other tool the player may use…
```

The pipe keeps the `check` line to one entry, and the advertised enum narrows to
exactly those kinds (`exits` hidden). This verbosity is the deliberate trade of
an allowlist-only model: you grant explicitly, and adding a new tool means
adding a line.

---

## Quick reference

```yaml
allow:
  - server__tool                       # any arguments — prefixed, explicit
  - server__tool(p: v)                 # p must equal v
  - server__tool(p: a|b|c)             # p ∈ {a, b, c}
  - server__tool(p: *)                 # p unrestricted (same as omitting p)
  - server__tool(p: v, q: w)           # multiple params
  # bare `tool` also works and matches any server's tool of that name — only
  # safe when no two servers share a bare tool name; prefer prefixed.
```

- Pure allowlist, default-deny. No `deny`, no wildcard-all-tools.
- Only enum parameters are constrainable; rules are validated against the enum.
- Bad rule → startup aborts with a specific message.
- Native (non-MCP) tools are gated exactly like MCP tools — bare name, no `prefix:` form.

---

## Where it lives in the code

| Concern | Location |
|---|---|
| Parse rules, match, validate, narrow, guard | `boukensha/lib/boukensha/permissions.rb` (`Boukensha::Permissions`) |
| Build a task's permissions from `allow:` | `Boukensha.task_permissions` (`boukensha/lib/boukensha.rb`) |
| Enforce name/value gate for every tool (MCP or native) | `Boukensha::Registry#tool` / `#dispatch` |
| Narrow an MCP tool's advertised enum; validate rules against its schema | `Boukensha::Tools::Mcp.register_client` |
| Every rule matched a real, registered tool (checked after all registration) | `Permissions#validate_referenced!`, called from `Boukensha.run`/`.repl`/`.run_task` |
| The tool schemas rules validate against | `mud_manager/lib/mud_manager/mcp/tool_spec.rb` (each tool's `enum`) |
