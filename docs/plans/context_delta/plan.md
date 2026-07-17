# Carrying the 10/11 infrastructure improvements into `12_context`

## Context

`12_context` was **not** branched from `11_tui`. A `diff -rq` and file-by-file
read shows its base predates the MCP-host rewrite (`f5bea8b`, folded into
`10_standard_tool_library`/`11_tui` — see
[`docs/plans/tui_mcp_delta/plan.md`](../tui_mcp_delta/plan.md)) and predates the
`Tasks::Player` settings abstraction. Concretely, `12_context` still has:

- direct tool registration (`Tools::FileSystem`/`Tools::Shell`/`Tools::Mud`,
  `working_dir:`/`allowed_commands:`/`shell_timeout:`/`mud:` keywords on
  `Boukensha.run`/`.repl`) instead of the MCP-host model
  (`Tools::Mcp`, `Mcp::Client`, `mcp_servers:`)
- `examples/example.rb` still headed "Step 10 — A Standard Tool Library (MUD
  demo)", using `working_dir: false` / implicit `mud:` — the pre-MCP demo
- no `Tasks::Player`/`Tasks::Base` — `Config` reimplements a narrower,
  hand-rolled version of the same provider/model/prompt-override lookup
  directly against `tasks.player.*`
- the old, bare-string `~/.boukensharc` loader (no YAML, no `boukensha_dir`
  support — the bug documented in
  [`docs/plans/floating_artifacts/bounkensharc.md`](../floating_artifacts/bounkensharc.md))
- no `Logger#response` cost/provider/model metadata (`execution_metadata`,
  `estimate_cost`) — the old flat `response(text:, usage:, stop_reason:)`
  shape survives, minus even the `task:`/`backend:` params 11_tui has
- no `test/`, no `Rakefile`, no `prompts/system.md`, no
  `examples/mcp_mud_demo.rb`
- the repo-root `.boukensha/settings.yaml` **already uses** `tasks.player.*`
  and `mcp_servers:` — meaning `12_context` as it stands cannot pick up either
  the model/provider selection *or* any tools when pointed at the real config
  most other steps already run against

On top of that old base, `12_context` has real, new, step-12-specific work
that must **not** be lost in this merge:

- `Context#current_tokens`/`context_window`/`usage_pct`/`compact_messages!`/
  `needs_compaction?`, `Agent` auto-compaction at turn start, `/compact`,
  `Logger#compaction`, TUI colour coding (`ctx_color`, `CTX_WARN_PCT`/
  `CTX_ALERT_PCT`) — the actual "step 12" feature
- `Agent`'s second circuit breaker, `max_turn_tokens` (`Context#turn_tokens`/
  `add_turn_tokens`/`reset_turn_tokens`), independent of `max_iterations`
- reasoning/thinking normalization across every backend (`"type" =>
  "reasoning"` blocks, `Logger#reasoning`/`#plan`, `Agent#log_reasoning`) —
  Anthropic `thinking`/`redacted_thinking`, Gemini `thought`/
  `thoughtSignature`, Ollama/Ollama Cloud `message["thinking"]`
- the OpenAI backend's migration from `/v1/chat/completions` to
  `/v1/responses` (documented in-file: gpt-5.x rejects `reasoning_effort` +
  tools on the chat-completions endpoint)
- `Models.context_window(model)` — a static lookup used to size `Context`
  *before* a backend is constructed

**Goal:** make `12_context` an MCP host with `Tasks::Player`-driven settings,
the improved `~/.boukensharc` loader, cost-estimation logging, tests, and
docs — exactly like `11_tui` — **without** losing any of the context-tracking,
compaction, or reasoning-normalization work described above. This is a merge
in the opposite direction of `tui_mcp_delta`: here, `12_context` is the
*behind* branch for infrastructure and the *ahead* branch for the step's own
feature.

**Non-goal:** no new features beyond what's needed to reconcile the two
trees. If neither branch did it, this plan doesn't either.

---

## 1. File-by-file delta

Confirmed via `diff -rq` and full-file reads across both trees. Byte-identical
today: `tool.rb`, `message.rb`, `Gemfile`, `bin/boukensha`, all of `patches/*`.

| File | Action | Why |
|---|---|---|
| `lib/boukensha/mcp/client.rb` | **add** (copy verbatim from `11_tui`) | stdio MCP client, no step-12 dependency |
| `lib/boukensha/tools/mcp.rb` | **add** (copy verbatim from `11_tui`) | registers a server's tools into `Registry`/`RunDSL` |
| `lib/boukensha/tools/file_system.rb` | **delete** | replaced by a filesystem MCP server, same as `tui_mcp_delta` §1 |
| `lib/boukensha/tools/shell.rb` | **delete** | replaced by a shell MCP server (none configured yet — fine) |
| `lib/boukensha/tools/mud.rb` | **delete** | replaced by the `mud-manager --mcp` daemon |
| `lib/boukensha/tasks/base.rb` | **add** (copy verbatim from `11_tui`) | task settings abstraction — see §2 for why `Config` needs it back |
| `lib/boukensha/tasks/player.rb` | **add** (copy verbatim from `11_tui`) | the one concrete task |
| `lib/boukensha/config.rb` | **merge, careful** | restore `mcp_servers`/`tasks`/`PROMPTS_DIR`/`user_prompts_dir`; **keep** `agent_*` limit methods and `Models`-based context window (§2) |
| `lib/boukensha/context.rb` | **no change** | 12_context's version is a strict superset of 11_tui's (adds token tracking, keeps everything else) — confirmed identical apart from additions |
| `lib/boukensha/models.rb` | **add, then fix** | new file, real gap in its model table — see §3 |
| `lib/boukensha/registry.rb` | **merge (additive)** | re-add `tool_names` — `Tools::Mcp` needs it for collision detection |
| `lib/boukensha/run_dsl.rb` | **merge (additive)** | re-add `tool_names` passthrough, same reason |
| `lib/boukensha/errors.rb` | **cosmetic only** | 11_tui's alignment tweak; take either, no behavior difference |
| `lib/boukensha/logger.rb` | **merge** | restore `execution_metadata`/cost estimation on `#response`; **keep** `context_window:` param on `#prompt`, `#compaction`, `#reasoning`, `#plan` (§4) |
| `lib/boukensha/agent.rb` | **merge, careful** | restore task-settings resolution *shape* is gone (task_settings deleted on purpose in both — fine), but restore `log_response`'s `task:`/`backend:` passthrough into the now-richer `Logger#response`; **keep** all of 12_context's compaction/`max_turn_tokens`/reasoning logic (§5) |
| `lib/boukensha/backends/base.rb` | **keep 12_context's** | pure additive doc comment, functionally identical to 11_tui |
| `lib/boukensha/backends/anthropic.rb` | **keep 12_context's**, restore pruned model | reasoning normalization is real step-12 work; re-add `claude-haiku-4-5-20251001` (present in 11_tui, silently dropped — see §3) |
| `lib/boukensha/backends/openai.rb` | **keep 12_context's** (Responses API) | documented, deliberate migration; confirm `gpt-5.4` removal is intentional (§3) |
| `lib/boukensha/backends/gemini.rb` | **merge** | keep `thinking_config`/reasoning parsing; restore the three real models 12_context deleted (`gemini-2.5-pro`/`-flash`/`-flash-lite`) — the surviving entry is a commented-out preview model, this looks like accidental data loss (§3) |
| `lib/boukensha/backends/ollama.rb` | **merge** | keep `think: false` + reasoning parsing; restore the seven model variants 12_context deleted (`gemma4`, `:e2b`, `:12b`, `:26b`, `:31b`, `qwen3:30b`, `qwen3:8b`, `deepseek-r1:8b`) (§3) |
| `lib/boukensha/backends/ollama_cloud.rb` | **keep 12_context's** | reorder + `think: false` only, no data loss |
| `lib/boukensha/prompt_builder.rb` | **either** | 12_context's is 11_tui's plus a doc comment describing the reasoning-block contract; take 12_context's |
| `lib/boukensha.rb` | **merge, the big one** | restore MCP host registration, `Tasks::Player`, `quiet!`/`loud!`; **keep** `context_window:`/`Models`/`agent_*` wiring (§6) |
| `lib/boukensha/repl.rb` | **merge, careful** | restore `/quiet`+`/loud`, `servers:` (not `mud:`), `servers_status_string`; **keep** `/compact` (§7) |
| `lib/boukensha/tui.rb` | **merge (additive, low risk)** | 12_context's is 11_tui's plus colour coding and a `compaction` event handler and a couple of width fixes — no conflicting changes, safe to layer directly onto whatever `tui.rb` ends up looking like after §7 |
| `lib/boukensha_loader.rb` | **merge** | take 11_tui's YAML rc/`boukensha_dir` resolution; **keep** 12_context's own decision on `--no-tui` (§8) |
| `boukensha.gemspec` | **merge** | drop `mud_manager` dependency (12_context still declares it); keep `charm` (§9) |
| `Gemfile.lock` | **regenerate** | `bundle lock` after the gemspec edit |
| `lib/boukensha/version.rb` | **keep 12_context's** | `0.12.0` is already correct for this step |
| `prompts/system.md` | **add** (copy verbatim from `11_tui`), **append** | the MUD auto-connect paragraph is unchanged by context work; see §10 for whether it also needs a context/compaction note |
| `examples/example.rb` | **rewrite** | currently the stale step-10 MUD demo; port 11_tui's MCP-host version (§10) |
| `examples/mcp_mud_demo.rb` | **add** (copy verbatim from `11_tui`) | no REPL/TUI/context involvement |
| `Rakefile` | **add** (copy verbatim from `11_tui`) | `rake test` |
| `test/*.rb` | **add** (copy verbatim from `11_tui`) | none reference `Repl`/`Tui`/`Context` token tracking (§11) |
| `README.md` | **rewrite** | merge 12_context's context-management sections with 11_tui's MCP-host + TUI sections (§12) |

---

## 2. `config.rb` — the load-bearing merge

12_context's `Config` diverged from `Tasks::Base`/`Tasks::Player` in a way
that is **not just missing MCP support** — it's read against a different
settings.yaml shape than the one actually deployed. The repo-root
`.boukensha/settings.yaml` has:

```yaml
tasks:
  player:
    provider: anthropic
    model: claude-haiku-4-5
    prompt_override:
      system: true
mcp_servers:
  mud: {...}
  filesystem: {...}
```

12_context's `Config#provider_type`/`#model` already correctly read
`tasks.player.provider`/`tasks.player.model` (so those two survive as-is —
they happen to match `Tasks::Base#provider`/`#model`'s dig path). But:

- `Config#mcp_servers` doesn't exist — **restore it verbatim from 11_tui**.
  Without it, `12_context` pointed at the real settings.yaml registers zero
  tools, silently.
- `Config#load_system_prompt` hand-rolls `Tasks::Base#prompt_override?`/
  `#prompt`'s logic, but narrower: hardcoded to task `"player"` and prompt
  `"system"`, and — critically — **has no bundled-default fallback**
  (`PROMPTS_DIR`/`default_prompts_dir` doesn't exist in 12_context). If the
  user has no `~/.boukensha/prompts/system.md`, `system` is `nil` and the
  agent runs with no system prompt at all, silently. Restore
  `Tasks::Base`/`Tasks::Player` (§1) and `Config::PROMPTS_DIR` and route
  `system_prompt` through `Tasks::Player.system_prompt(tasks(:player),
  user_prompts_dir:, default_prompts_dir: Config::PROMPTS_DIR)`, matching
  11_tui exactly. This also removes the now-redundant hand-rolled
  `system_override?`/`load_system_prompt` methods.
- `Config#mud_host`/`#mud_port`/`#mud_username`/`#mud_password` — **delete**,
  same as `tui_mcp_delta` §2. Nothing needs them once `boukensha.rb` stops
  calling `mud_opts_from_config` (§6).
- `Config#tasks(name = nil)` — **restore verbatim from 11_tui**. Needed both
  by the `Tasks::Player.system_prompt`/`.provider`/`.model` calls above and
  by `agent_*` if the project later wants those under `tasks.player` too
  (out of scope here — see §13 open question 1).
- `Config#agent_max_iterations`/`#agent_max_output_tokens`/
  `#agent_max_turn_tokens`/`#agent_compaction_threshold` — **keep exactly as
  written**. These read a `agent:` settings.yaml block that doesn't exist yet
  in the repo-root config; all four have sane defaults (25 / 1024 / 60_000 /
  0.85) so this is inert until someone adds an `agent:` block, not a bug.
- `Config#user_prompts_dir` — **restore verbatim from 11_tui** (needed by the
  `Tasks::Player.system_prompt` call above).
- `Config#to_s` — reconcile: 12_context's version
  (`provider=#{provider_type} model=#{model}`) is arguably more useful than
  11_tui's (`tasks=#{tasks.keys.join(',')}`) now that `Config` still exposes
  both `tasks` and `provider_type`/`model`. Keep 12_context's.

---

## 3. Backend model tables — restore pruned entries

Three of the five backends lost models between 11_tui and 12_context with no
comment explaining why, unlike the OpenAI backend's Responses-API migration
(which has an explicit rationale in-file). Treat the OpenAI change as
intentional; treat these three as accidental loss to be restored *underneath*
the (legitimate, keep) reasoning-normalization changes:

- **`anthropic.rb`**: `claude-haiku-4-5-20251001` (the dated pin) is gone.
  Restore it alongside `claude-haiku-4-5`.
- **`gemini.rb`**: `gemini-2.5-pro`, `gemini-2.5-flash`,
  `gemini-2.5-flash-lite` are gone; the only surviving `MODELS` entry is a
  *commented-out* `gemini-3.1-pro-preview-customtools`, referenced by a
  broken/incomplete comment (`# It has`). Restore the three 2.5-series models
  from 11_tui. Leave the preview-model comment as a TODO if it reflects
  real in-flight work — confirm with whoever wrote it (§13 open question 2)
  before deleting the comment outright.
- **`ollama.rb`**: only `gemma4:e4b` survives; `gemma4`, `gemma4:e2b`,
  `gemma4:12b`, `gemma4:26b`, `gemma4:31b`, `qwen3:30b`, `qwen3:8b`,
  `deepseek-r1:8b` are gone. Restore all from 11_tui.

**`models.rb`'s own gap**: `Models::TABLE` only has the three Anthropic
models, with everything else (OpenAI, Gemini, Ollama, Ollama Cloud) silently
falling back to `DEFAULT_CONTEXT_WINDOW = 32_000`. That default is far below
several real windows (`gpt-5.5` is 1,000,000; `gemini-2.5-pro` is 1,048,576),
which — combined with the `needs_compaction?` ≥ 0.85 auto-compaction added
this step — means picking a non-Anthropic model would trigger constant,
needless compaction almost immediately. `Models.context_window` exists
because `Context` (and thus `context_window`) has to be sized *before* the
backend object is constructed in `Boukensha.run`/`.repl` (§6), so it can't
just delegate to `backend.context_window` — but its table needs an entry for
every model already listed in every backend's own `MODELS` hash, not just
Anthropic's. Populate `Models::TABLE` from all five backends' `MODELS`
constants (or generate it from them at load time — either is fine, but a
hand-maintained table that's this incomplete is exactly how this gap
happened) as part of this merge, not deferred.

---

## 4. `logger.rb`

12_context's `#prompt`/`#compaction`/`#reasoning`/`#plan` additions are new,
correct, and unrelated to what 11_tui lost — keep all of them as-is.

11_tui's `#response` computes `execution_metadata` (`task:`, `provider:`,
`model:`, `usage_unit:`, `usage_level:`, `input_tokens:`, `output_tokens:`,
`cost_usd:`) via `task_name`/`provider_name`/`usage_tokens`/`first_integer`/
`estimate_cost` — all private helpers 12_context deleted along with the
params. Restore `#response(text:, usage: nil, stop_reason: nil, task: nil,
backend: nil)` and all five restored private helpers verbatim. This is
additive to 12_context's call sites in `agent.rb` (§5) — every existing
`@logger.response(...)` call just gains two more keyword args.

---

## 5. `agent.rb`

12_context's structural changes (the two independent ceilings —
`iteration_limit_reached?`/`token_limit_reached?` —, `record_usage`,
`compact_if_needed` called at the top of `run`, `log_reasoning`, the
`preamble`/`plan` split in `handle_tool_calls`) are the step's own work and
correct. Keep the entire control-flow shape 12_context already has.

The one thing to restore is what `log_response` used to pass into
`Logger#response` before it was inlined and stripped down to a plain
`@logger.response(text:, usage:, stop_reason:)` call at each of its three
call sites (`run`'s normal-completion branch, `wrap_up`'s success branch —
`wrap_up`'s `rescue ApiError` branch has no response to attach metadata to,
leave it alone). At each of those two sites, once §4 restores
`Logger#response`'s `task:`/`backend:` params, pass:

```ruby
@logger.response(text: text, usage: response["usage"], stop_reason: parsed[:stop_reason], task: nil, backend: @builder.backend)
```

`task: nil` (not `@context.task`) because `Context` in this merged tree has
no `task` attribute — `Tasks::Player` no longer flows through `Context`, it's
resolved once in `boukensha.rb` (§6) and only its *output* (`system`, `model`,
`provider`) reaches `Context`/`Agent`. `Logger#task_name(task)` already
handles `nil` gracefully (`nil&.respond_to?` → `nil`), so cost/provider/model
logging still works, just without a task-name label. If the project wants the
task label back, plumb `task_class` (a constant, not a `task_settings` hash)
down from `boukensha.rb` into `Agent.new` as a new keyword — that's a small
addition, not a merge conflict, and is flagged as an open question rather
than decided here (§13 open question 3).

`@builder.backend` requires `PromptBuilder#backend` to exist — confirm it
does in both trees before wiring this up (it's a one-line `attr_reader` in
11_tui's `prompt_builder.rb`; verify it survived 12_context's version, which
per §1 is otherwise a superset).

---

## 6. `boukensha.rb`

Both `.run` and `.repl` need the same set of changes, mirroring
`tui_mcp_delta` §3 but layered onto 12_context's `context_window:`/`Models`/
`agent_*` additions instead of onto 11_tui's plain shape:

1. Restore `require_relative "boukensha/tasks/player"` at the top, and the
   `Tasks::Player`-based resolution of `system`/`model`/`backend`:
   ```ruby
   cfg           = config
   task_class    = Tasks::Player
   task_settings = cfg.tasks(task_class.task_name)
   system      ||= task_class.system_prompt(task_settings, user_prompts_dir: cfg.user_prompts_dir, default_prompts_dir: Config::PROMPTS_DIR)
   model       ||= task_class.model(task_settings)
   backend     ||= task_class.provider(task_settings).to_sym
   context_window ||= Models.context_window(model)
   ```
   (`context_window` line is 12_context's addition, kept; everything else is
   11_tui's, restored.)
2. `ctx = Context.new(...)` — keep 12_context's signature
   (`system:, context_window:, working_dir:, compaction_threshold:
   cfg.agent_compaction_threshold`), drop the `task:` keyword (Context no
   longer takes one, confirmed §1).
3. Replace the `Tools::FileSystem`/`Tools::Shell`/`Tools::Mud` registration
   block and `resolved_mud = ...; Tools::Mud.register(...)` with
   `register_mcp_servers(registry, cfg)`, restored verbatim from 11_tui
   (`.run` ignores the return value; `.repl` keeps it as `servers` and passes
   `servers:` into `Repl.new`, replacing 12_context's `mud: resolved_mud`).
4. Drop `working_dir:`/`allowed_commands:`/`shell_timeout:`/`mud:` keyword
   args from both signatures; delete `mud_opts_from_config`.
5. `Logger.new(log:, snapshot: {...})` — keep 12_context's richer snapshot
   hash (`max_iterations: cfg.agent_max_iterations`, `max_turn_tokens:
   cfg.agent_max_turn_tokens`, `max_output_tokens:`, `context_window:`,
   `model:`, `provider:`) as-is; it has no `task_class`-derived fields to
   restore since 12_context replaced `task_class.max_iterations(task_settings)`
   with the `agent_*` config methods on purpose — that redesign is a step-12
   improvement worth keeping, not reverting to task-settings-derived limits
   (see also §13 open question 1 about where these two settings namespaces
   should ultimately live).
6. `Agent.new(...)` / `Repl.new(...)` — keep 12_context's `max_turn_tokens:`
   argument throughout; add nothing else here (task_settings intentionally
   does not flow into `Agent` any more, per §5).
7. Restore `quiet!`/`loud!`/`quiet?` module methods and `@quiet = false`
   module ivar (deleted in 12_context, needed by `repl.rb`'s `/quiet`/`/loud`
   in §7).
8. Restore `register_mcp_servers` class method verbatim from 11_tui.
9. Trailing `require_relative` block: drop `tools/file_system`/
   `tools/shell`/`tools/mud`, add `tools/mcp`; keep `boukensha/models` (new
   this step) positioned right after `boukensha/message` as 12_context has
   it, since `Context` doesn't need `Models` but `boukensha.rb` itself calls
   `Models.context_window` before `Context` is constructed — load order is
   fine either way since `Models` has no dependencies, but keep it early to
   match 12_context's existing placement. Keep `boukensha/tui` last.

---

## 7. `repl.rb`

Same non-mechanical shape as `tui_mcp_delta` §4, plus `/compact` layered in
without conflict:

1. Constructor: rename `mud:` keyword back to `servers:`, `@mud` → `@servers`.
   Keep everything 12_context added: `max_turn_tokens:` keyword/ivar,
   `output_cb`/public accessors (12_context already kept these — confirmed
   its diff against 11_tui shows no regression on `on_output`/
   `handle_command`/public `attr_reader`, only the `mud:`→`servers:`
   difference and the missing `/quiet`+`/loud` block).
2. `HELP` and the banner: restore the `/quiet`+`/loud` lines 12_context
   deleted, alongside the `/compact` line it added. Final `HELP`:
   ```ruby
   HELP = <<~HELP
     Commands:
       /quiet    suppress logging output
       /loud     re-enable logging output
       /clear    wipe conversation history (tools stay)
       /compact  drop oldest 40% of messages to free context
       /exit     leave the REPL
       /help     show this message
   HELP
   ```
   Same pattern in the `banner` heredoc (both `/quiet or /loud` and
   `/compact` lines present).
3. `banner`: replace 12_context's `mud_stat = mud_status_string` /
   `mud:       #{mud_stat}` line with 11_tui's `servers_stat =
   servers_status_string` / `servers:   #{servers_stat}`. Delete
   `mud_status_string`/`probe_mud` (require "socket"/"timeout" become
   unused — drop those requires too if nothing else in the file needs them).
   Restore `servers_status_string` verbatim from 11_tui.
4. `handle_command`: restore the `/quiet`/`/loud` branches from 11_tui
   (calling the module methods restored in §6-7), **keep** 12_context's
   `/compact` branch exactly as written. Order doesn't matter functionally;
   match the `HELP` ordering above for readability (`/quiet`, `/loud`,
   `/clear`, `/compact`, `/exit`).
5. Everything else (`run_turn`, `start`, `output`/`on_output`,
   `max_turn_tokens` threading into `Agent.new`) — no change, 12_context's
   version already has what 11_tui has plus its own additions.

---

## 8. `boukensha_loader.rb`

Take 11_tui's version (YAML `~/.boukensharc`, `boukensha_path`/
`boukensha_dir` resolution, `BUNDLED_LIB`, env-wins semantics, bare-string
back-compat) as the base, per `tui_mcp_delta` §5 and
`floating_artifacts/bounkensharc.md`.

12_context's loader currently does two things differently from 11_tui that
need a decision, not a mechanical copy:

- **`--no-tui` flag**: 12_context already keeps it (`no_tui =
  ARGV.delete("--no-tui")`) — good, no action needed, matches 11_tui.
- **Legacy `MUD_NAME`/`MUD_HOST`/`MUD_PORT`/`MUD_PASSWORD` env-var handling**:
  12_context still has this block, building a `mud:` hash and passing
  `working_dir: false, mud: {...}` into `Boukensha.repl`. Once §6 removes the
  `mud:`/`working_dir:` keywords from `Boukensha.repl` entirely, this block
  no longer compiles against the merged `boukensha.rb`. **Drop it**, same as
  11_tui does — a `MUD_HOST` etc. set in the calling shell still reaches the
  `mud-manager` MCP server via its own `env:` block merged over the process
  environment (`Tools::Mcp.register` → `Open3.popen3`), so no functionality
  is actually lost, just the *env-var-shortcuts-the-config-file* convenience,
  which 11_tui already decided to retire.

Net: `boukensha_loader.rb` ends up identical to 11_tui's.

---

## 9. `boukensha.gemspec`

12_context still declares `spec.add_dependency "mud_manager", "~> 0.1"`.
Drop it — MUD tools now live entirely in the `mud-manager --mcp` subprocess,
not in a Ruby dependency of this gem, same rationale as `tui_mcp_delta` §6.
Keep `spec.add_dependency "charm"` (`tui.rb` needs it). Reword the comment
block to 11_tui's phrasing ("MCP servers bring their own dependencies;
boukensha itself needs only `charm`, for the TUI").

Run `bundle lock` (not a hand-edit) after the gemspec edit to regenerate
`Gemfile.lock`.

---

## 10. Docs and examples

- **`prompts/system.md`**: add 11_tui's file verbatim (the MUD auto-connect
  paragraph — true regardless of context-management work, since it describes
  the MCP server's behavior). Consider appending one sentence noting that
  long sessions may trigger automatic compaction and the agent shouldn't be
  alarmed by "[context compacted ...]" system-style notices appearing
  mid-conversation — optional, low priority, flagged as open question 4 in
  §13 rather than mandated.
- **`examples/example.rb`**: currently 12_context's copy is the stale
  step-10 MUD demo (`working_dir: false`, implicit `mud:` from config, header
  says "Step 10"). Port 11_tui's MCP-host version
  (`Boukensha.run(task: ...)` with no tool-related keyword args, prints
  `cfg.mcp_servers.keys`). Update the header comment to say "Step 12" and
  keep 11_tui's note that the TUI lives in `bin/boukensha`.
- **`examples/mcp_mud_demo.rb`**: copy verbatim from 11_tui — a `Registry`/
  `Context`-level smoke test with no REPL/TUI/token-tracking involvement.
- **`Rakefile`**: copy verbatim from 11_tui.

---

## 11. Tests

Copy `test/helper.rb`, `test_mcp_client.rb`, `test_tools_mcp.rb`,
`test_mcp_servers_config.rb`, `test_boukensha_loader.rb` verbatim from
11_tui — confirm during implementation that none references `Repl`, `Tui`,
`Context#current_tokens`/`compact_messages!`, or anything else this merge
touches in a step-12-relevant way (the `tui_mcp_delta` audit already
confirmed this for the 10→11 direction against the same five files; re-check
quickly since `Config`'s `dig`/`mcp_servers` shape is unchanged by this
merge, so `test_mcp_servers_config.rb` should carry over unmodified).

No new tests are required for the `Context`/`Agent` compaction and reasoning
work as part of *this* delta — that's 12_context's own untested-so-far
addition, and backfilling coverage for it is a separate task from carrying
infrastructure forward.

---

## 12. `README.md`

Keep 12_context's entire "What's new" content on context tracking, colour
coding, auto-compaction, `/compact`, `Logger#compaction`, and the
`context_window:` keyword — all still true. Splice in, above or below it:

- 11_tui's "MCP host" section (`Mcp::Client`, `Tools::Mcp`, `mcp_servers:`
  table, "what went away" table) — reworded slightly since "what went away"
  now needs a second entry for `Tools::FileSystem`/`Shell`/`Mud` being
  removed *in this step* rather than a prior one, if the project wants the
  README to read as a single coherent step-12 changelog rather than
  cumulative history repeated per step (match whatever convention the other
  step READMEs already use — check `10_standard_tool_library/README.md`'s
  framing before choosing).
- 11_tui's TUI section (charm, four-zone layout, keyboard shortcuts, `Repl`
  refactor table, `Logger#subscribe`).
- The `mcp_servers:` config table and reasoning-block contract summary (new
  for this README, since neither source step documented it — pull the
  content from `backends/base.rb`'s doc comment).
- Update "Run the demo": keep 12_context's `gem build`/`gem install`
  instructions, add 11_tui's `ruby examples/mcp_mud_demo.rb --dry` line and
  the `BOUKENSHA_DIR=... boukensha` global-executable example.

---

## 13. Risks / open questions

1. **Two settings namespaces for the same kind of thing.** `Tasks::Player`
   settings live under `tasks.player.*` (`provider`, `model`,
   `prompt_override`); the new per-turn circuit breakers live under a
   sibling `agent.*` block (`max_iterations`, `max_output_tokens`,
   `max_turn_tokens`, `compaction_threshold`) that `Tasks::Base` doesn't
   know about. 11_tui's `max_iterations`/`max_output_tokens` used to be
   `tasks.player.max_iterations`/`.max_output_tokens` via
   `Tasks::Base.max_iterations`/`.max_output_tokens` — this merge keeps
   12_context's `agent.*`-block version instead (§6 point 5) since it's the
   step's own redesign, but that means the same two settings now have two
   different possible homes depending on which step of the tutorial you're
   reading. Not a bug, but worth a deliberate call on which convention wins
   going forward before step 13 branches off this one.
2. **`gemini.rb`'s commented-out `gemini-3.1-pro-preview-customtools`
   entry.** Confirm whether this reflects real in-flight work (a model not
   yet released, or one with limited-preview API access) worth keeping as a
   commented placeholder, or was scratch experimentation that should just be
   deleted when the three real 2.5-series models are restored.
3. **`Logger#response`'s restored `task:` param has nothing to pass except
   `nil`.** `Context` no longer carries a task reference (by design, in both
   trees — 12_context never had one either). If per-task cost/log labeling
   is wanted, `task_class` needs a new, explicit path from `boukensha.rb`
   into `Agent`/`Logger` — sketched but not specified in §5. Low priority:
   nothing today reads the `task` field in a log line's `execution_metadata`
   downstream (confirm before committing effort here).
4. **`prompts/system.md` and compaction.** Should the system prompt tell the
   agent it may see `[context compacted ...]` notices, so a mid-session
   compaction doesn't read to the model like a user interjection it should
   respond to? Flagged in §10, not resolved — depends on whether this has
   been observed as a real problem in testing.
5. **Verification order**, once the merge lands:
   1. `cd week1_baseline/ruby/12_context && bundle install && rake test`
   2. `ruby examples/mcp_mud_demo.rb --dry`
   3. `gem build boukensha.gemspec && gem install --local boukensha-0.12.0.gem`
   4. `BOUKENSHA_DIR=$(pwd)/../../../.boukensha BOUKENSHA_PATH=$(pwd) boukensha`
      from the repo root — confirm the TUI boots, `servers:` line in the
      banner shows `mud (26)  fs (...)`, the status bar shows
      `ctx <used>/<max> (<pct>%)` with correct colour, `/quiet`, `/loud`,
      `/compact`, `/clear` all work, a long session actually triggers
      auto-compaction and the `[context compacted ...]` line appears in the
      TUI conversation view.
   5. `boukensha --no-tui` — plain REPL, same banner content, same command
      set.
   6. Switch `tasks.player.model` in settings.yaml to a non-Anthropic model
      (e.g. `gpt-5.5`/openai) and confirm `Models.context_window` returns
      that model's real window, not the 32,000 default (this is the concrete
      regression test for §3's `models.rb` fix).
