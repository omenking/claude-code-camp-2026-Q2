Native tools (registered directly in code, e.g. the player's `inspect_room`)
bypass `allow:` entirely today. That was a deliberate v1 simplification
(`task_permissions.md`, "Native tools are not gated") but it's an oversight
from a security-model standpoint: a task's tool surface should be one
allowlist, not "the allowlist, plus whatever the entrypoint bolts on
unchecked." This plan closes that gap so **every** tool — MCP-derived or
native — goes through the same `allow:` gate.

---

## TL;DR

- **Root cause: permission enforcement lives in the wrong layer.** It's
  bolted onto `Tools::Mcp.register_client`'s registration loop
  (`mcp.rb:56-86`), which only ever sees tools discovered from an MCP
  server's `client.tools`. `RunDSL#tool` (`run_dsl.rb:9-11`) — the path
  `inspect_room` uses (`boukensha_loader.rb:120-130`) — calls
  `@registry.tool(...)` directly and never passes through a `Permissions`
  check at all.
- **Fix: move the gate into `Registry` itself.** `Registry#tool` (name-level:
  skip registering if not allowed) and `Registry#dispatch` (value-level:
  reject a disallowed call before it runs) become the single enforcement
  point. Every caller of `registry.tool` — `Mcp.register_client` **and**
  `RunDSL#tool` — gets the same gate for free, with no change needed in
  `run_dsl.rb` or `boukensha_loader.rb`.
- **There's an ordering bug to fix alongside this.** `register_task_tools`
  calls `perms.validate_referenced!(registry.tool_names)`
  (`boukensha.rb:311`) *before* the `RunDSL` block runs
  (`boukensha.rb:130`), i.e. before `inspect_room` exists in the registry.
  Today that's silently fine because `inspect_room` isn't a permission
  target. The moment it becomes one, a rule naming it would fail
  `validate_referenced!` with "references unknown tool 'inspect_room'" and
  abort boot — because validation runs too early. Validation has to move to
  after *all* registration (MCP + native) completes.
- **Once gated, `player.allow:` must explicitly list `inspect_room`** (bare —
  native tools have no server prefix) or the player loses access to it,
  since default-deny now applies uniformly.

---

## 1. Where the gate is today and why it misses native tools

`Boukensha::Permissions` (`permissions.rb`) is the correct, already-built
allow/deny engine — `allow_tool?` (name), `allowed_values`/`call_permitted?`
(value), `validate_tool!`/`validate_referenced!` (boot-time checks). The
problem isn't the engine, it's where it's wired in:

```ruby
# mcp.rb:56-86 — Tools::Mcp.register_client
client.tools.each do |tool|
  remote = tool["name"]
  local  = prefixed(remote, prefix)

  next if permissions && !permissions.allow_tool?(local)        # name gate
  permissions.validate_tool!(local, tool["inputSchema"]) if permissions
  ...
  registry.tool(local, ...) do |**kwargs|
    if permissions && !permissions.call_permitted?(local, kwargs)  # value gate
      next "error: #{local} is not permitted with #{kwargs.inspect} in this context"
    end
    ...
  end
end
```

This loop only ever iterates `client.tools` — tools a spawned MCP server
advertised. `inspect_room` never enters it. It's added straight to the
registry instead:

```ruby
# boukensha_loader.rb:119-131
Boukensha.repl(tui: !no_tui) do
  tool "inspect_room", description: "...", ... do |**_|
    Boukensha::Tools::InspectRoom.call(...)
  end
end
```

```ruby
# run_dsl.rb:9-11 — RunDSL#tool
def tool(name, description:, parameters: {}, &block)
  @registry.tool(name, description: description, parameters: parameters, &block)
end
```

`Registry#tool` (`registry.rb:9-13`) just registers unconditionally. No
`Permissions` object is ever consulted for anything reaching the registry
through `RunDSL#tool` — which is precisely how `inspect_room` gets in.
`task_permissions.md:121-124` documents this as intentional today; this plan
changes that.

---

## 2. Design: enforcement moves into `Registry`

`Registry` gains an optional `permissions:` and becomes the one place both
registration paths pass through:

```ruby
class Registry
  def initialize(context, permissions: Permissions.new(nil))  # nil = permissive, current default
    @context     = context
    @permissions = permissions
  end

  def tool(name, description:, parameters: {}, &block)
    return nil unless @permissions.allow_tool?(name)   # name-level gate, uniform
    tool = Tool.new(name.to_s, description, parameters, block)
    @context.register_tool(tool)
    tool
  end

  def dispatch(name, args = {})
    tool = @context.tools[name.to_s]
    raise UnknownToolError, "No tool registered as '#{name}'" unless tool
    raise UnauthorizedToolError, "#{name} is not permitted with #{args.inspect}" \
      unless @permissions.call_permitted?(name, args)   # value-level gate, uniform
    tool.block.call(**args.transform_keys(&:to_sym))
  end
end
```

Two things fall out for free:

- **`RunDSL#tool` needs zero changes.** It already just calls
  `@registry.tool(...)`; once `Registry` enforces, `inspect_room` is gated
  the same way any MCP tool is, with no touch to `run_dsl.rb` or
  `boukensha_loader.rb`.
- **Dispatch errors compose with the existing error path for free.**
  `Agent#run` already wraps `@registry.dispatch` in
  `rescue StandardError => e` (`agent.rb:167-173`) and turns it into a
  `"ERROR: ..."` tool_result. So `Registry#dispatch` can simply `raise`
  (new `UnauthorizedToolError` in `errors.rb`) instead of the MCP guard's
  current pattern of manually returning an `"error: ..."` string from
  inside its own block (`mcp.rb:76-77`). That manual return becomes
  redundant once `Registry#dispatch` raises for every caller — worth
  deleting as part of this change rather than keeping two mechanisms.

`Mcp.register_client` **keeps** its `permissions:` argument, but only for
what `Registry` can't do generically: **narrowing the advertised enum**
(`to_boukensha_params`, `mcp.rb:100-111`), which needs the tool's
MCP-specific `inputSchema` to know what an enum even is. It drops its own
`allow_tool?`/`call_permitted?` calls — those move to `Registry` — so there
is exactly one place enforcing name/value permission, not two.

**Bookkeeping that depended on the removed gate has to move with it.** Today
`next if permissions && !permissions.allow_tool?(local)` (`mcp.rb:60`) runs
*before* the collision check (`taken.include?(local)`, `mcp.rb:63-68`) and
before `registered += 1` (`mcp.rb:83`), so both only ever see tools that
actually got registered. Deleting that line outright — rather than replacing
what it guarded — breaks both:

- `registered` would count every tool the server *advertised*, not every
  tool `Registry#tool` actually let through, inflating the `name (count)`
  the REPL banner shows (`repl.rb:180`, fed by `register_mcp_servers`'
  per-server summary).
- `taken << local` would fire for a disallowed tool too, so a later,
  *permitted* tool with that same local name could raise a spurious
  `CollisionError` for a name nothing ever actually claimed.

Fix: don't re-test `allow_tool?` in `mcp.rb` (that would restore the second
enforcement point this section is trying to eliminate) — instead, gate the
bookkeeping on `Registry#tool`'s return value, which is already `nil` for a
disallowed name:

```ruby
registered_tool = registry.tool(local, description: ..., parameters: ...) do |**kwargs|
  result = client.call_tool(remote, kwargs.transform_keys(&:to_s))
  result[:error] ? "error: #{result[:text]}" : result[:text]
end
next unless registered_tool
taken << local
registered += 1
```

The collision check itself (`taken.include?(local)` before calling
`registry.tool`) stays exactly where it is — it only ever needs to compare
against names that were *actually* registered, which is precisely what
`taken` tracks once it's populated this way.

---

## 3. The ordering bug: `validate_referenced!` runs before native tools exist

`register_task_tools` (`boukensha.rb:305-314`) does registration *and*
"did every rule match something real" validation in one call, and every
caller invokes it **before** the `RunDSL` block:

```ruby
# boukensha.rb:126-130 (repl; run/run_task follow the same shape)
registry = Registry.new(ctx)
servers  = register_task_tools(registry, cfg, task_class.task_name)   # validate_referenced! fires HERE
RunDSL.new(registry).instance_eval(&block) if block                   # inspect_room registered HERE
```

Today that ordering is invisible because no rule ever names a native tool.
The instant `player.allow:` gains an `inspect_room` entry, `validate_referenced!`
sees a registry that doesn't have `inspect_room` yet and raises `permission
rule references unknown tool 'inspect_room'` — a hard boot failure, for a
perfectly valid rule.

**Fix:** split `register_task_tools` into "register" and "finalize", and
call `validate_referenced!` only after the block (all native tools) has run:

```ruby
def self.register_task_tools(registry, cfg, task_name)      # registration only, no validate_referenced!
  perms   = task_permissions(cfg, task_name)
  summary = register_mcp_servers(registry, cfg, clients: mcp_clients(cfg), permissions: perms)
  [summary, perms]
end

# call sites (run, repl):
registry = Registry.new(ctx, permissions: perms)             # perms built up front now
servers, perms = register_task_tools(registry, cfg, task_class.task_name)
RunDSL.new(registry).instance_eval(&block) if block
perms.validate_referenced!(registry.tool_names)              # moved here — after ALL registration
```

`run_task` has no block/native tools today, so validating immediately after
`register_task_tools` there is unchanged in effect — but route it through
the same helper so a future native tool added to a subagent isn't a second
place to remember this fix.

`Permissions` also needs building **before** `Registry.new` now (so the
registry can enforce from its first `tool` call, including any native tools
a future subagent might register before its own block point) — a small
reordering of `task_permissions(cfg, task_name)` to run ahead of
`Registry.new` at each of the three call sites (`run`, `repl`, `run_task`).

---

## 4. Config and doc changes

- **`.boukensha/settings.yaml`** — add `inspect_room` (bare; native tools
  have no server `prefix:`, so there's no `tbamud__`-style form for it) to
  `player.allow:`. Without this the player silently loses the tool the
  moment enforcement goes live.
- **`docs/task_permissions.md`** — remove the "Native tools are not gated"
  callout (`task_permissions.md:131-134` and the matching note under
  Quick reference, `task_permissions.md:200`) and replace it with a short
  section: native tools are
  registered through the same `Registry#tool`/`#dispatch` path as MCP tools
  and **are** gated; the only difference is they have no `prefix:`, so their
  rule is written as the tool's bare name with nothing to disambiguate
  (there's only ever one server for a given native tool name: the
  entrypoint).
- **`docs/plans/week_2/inspect_command_expanded.md:388`** — the note there
  ("the native `inspect_room` tool ... isn't gated by `allow:`") becomes
  stale once this ships; update it to point at this plan instead of
  reasserting the old behavior.

---

## 5. Known limitation this doesn't solve (call out, don't fix here)

`Permissions#validate_tool!` (`permissions.rb:92-111`) validates a rule's
pinned parameter values against the tool's schema `enum`. Native tools
registered via `RunDSL#tool` describe `parameters:` as `{ type:,
description: }` only (`run_dsl.rb:9`) — there's no `enum` concept for a
native tool today. `inspect_room` takes no arguments, so a bare
`inspect_room` rule (empty `where`) never touches this path and needs
nothing further. But a **future** native tool that takes a parameter and
wants that parameter constrained (`inspect_room(mode: quick)`, say) can't be
until native tool definitions can declare an `enum` the same way MCP
`inputSchema` does. Out of scope here; flag it so the next native tool with
parameters doesn't quietly assume constraining works.

---

## 6. Work items

1. `errors.rb` — add `UnauthorizedToolError < StandardError`.
2. `registry.rb` — accept `permissions:` (default a permissive
   `Permissions.new(nil)`), gate `#tool` (name) and `#dispatch` (value).
3. `mcp.rb` — `register_client` drops its own `allow_tool?`/`call_permitted?`
   calls and the manual `"error: ..."` string return; keeps
   `permissions:` only for `to_boukensha_params` enum-narrowing. Move the
   `taken << local` / `registered += 1` bookkeeping to run only when
   `registry.tool(...)` returns non-nil (see §2) so tool counts and the
   collision check still reflect what actually got registered.
4. `boukensha.rb` — reorder all three call sites (`run`, `repl`,
   `run_task`): build `perms` before `Registry.new`, pass it in, drop
   `validate_referenced!` from inside `register_task_tools`, call it after
   the `RunDSL` block (or immediately for `run_task`, which has no block).
5. `.boukensha/settings.yaml` — add `- inspect_room` to `player.allow:`.
6. `docs/task_permissions.md` — remove the native-tools-ungated callouts;
   document native tools as gated with no `prefix:` form.
7. `docs/plans/week_2/inspect_command_expanded.md:388` — update the stale
   note.
8. Tests (`boukensha/test/`):
   - `Registry` unit tests: a tool registered under a deny-all/omitting
     `Permissions` is not in `tool_names` and dispatch raises
     `UnauthorizedToolError`; permissive default (`Registry.new(ctx)`, no
     `permissions:`) behaves exactly as every existing test currently
     expects (regression guard for `test/helper.rb:39`,
     `test/test_inspect_room.rb:117,130,142,146`, all of which construct
     `Registry.new(ctx)` with no `permissions:` and must keep working
     unchanged).
   - Integration test booting the `player` task: `inspect_room` present in
     `registry.tool_names` iff listed in `player.allow:`; absent → dispatch
     raises/errors, not silently unavailable-but-unnoticed.
   - Ordering regression test: an `allow:` rule naming a tool only
     registered via the `RunDSL` block (i.e. after `register_task_tools`)
     must validate successfully — this is the test that would have caught
     today's bug.
