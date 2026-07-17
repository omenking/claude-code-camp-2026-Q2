# Carrying the MCP-host rewrite from step 10 into step 11 (the TUI)

## Context

`10_standard_tool_library` was reworked after `11_tui` branched off it: boukensha
stopped shipping `Tools::FileSystem` / `Tools::Shell` / `Tools::Mud` and became a
pure **MCP host** — every tool now arrives from a server declared in
`settings.yaml`'s `mcp_servers:` block (see the repo-root `.boukensha/settings.yaml`,
which already has `mud` and `filesystem` entries). Step 10's `boukensha_loader.rb`
was also fixed to restore the YAML `~/.boukensharc` support that a prior rewrite had
silently dropped (see
[`docs/plans/floating_artifacts/bounkensharc.md`](../floating_artifacts/bounkensharc.md)
— read that before touching `boukensha_loader.rb`).

`11_tui` still has the **old** direct-tool-registration model
(`working_dir:`/`allowed_commands:`/`shell_timeout:`/`mud:` keywords,
`Tools::FileSystem`/`Tools::Shell`/`Tools::Mud`) and the **old** loader (bare
single-line `~/.boukensharc`, no `boukensha_dir` support). It does have the one
thing step 10 never grew: `Boukensha::Tui` plus the `Repl` refactor that made
`Tui` possible (`on_output`, `handle_command`, `Logger#subscribe`).

**Goal:** make `11_tui` an MCP host exactly like step 10, without losing the TUI.
This is a merge, not an overwrite — `repl.rb` in particular changed for two
unrelated reasons in each branch and both changes need to survive together.

**Non-goal:** no new features. If step 10 didn't do it, this plan doesn't either.

---

## 1. File-by-file delta

Confirmed via `diff -q` across every file in both trees. Anything not listed
below is byte-identical between `10_standard_tool_library` and `11_tui` today
(`agent.rb`, `client.rb`, `context.rb`, `errors.rb`, `logger.rb`, `message.rb`,
`prompt_builder.rb`, `tool.rb`, `tasks/*`, all of `backends/*`, `bin/boukensha`).

| File | Action | Why |
|---|---|---|
| `lib/boukensha/mcp/client.rb` | **add** (copy verbatim from step 10) | the stdio MCP client — server-agnostic, no TUI dependency |
| `lib/boukensha/tools/mcp.rb` | **add** (copy verbatim from step 10) | registers a server's tools into a `Registry`/`RunDSL` |
| `lib/boukensha/tools/file_system.rb` | **delete** | replaced by a filesystem MCP server |
| `lib/boukensha/tools/shell.rb` | **delete** | replaced by a shell MCP server (none configured yet — fine, nothing requires one) |
| `lib/boukensha/tools/mud.rb` | **delete** | replaced by the `mud-manager --mcp` daemon |
| `lib/boukensha/config.rb` | **merge** | drop `mud_host`/`mud_port`/`mud_username`/`mud_password`, add `mcp_servers` (§2) |
| `lib/boukensha/registry.rb` | **merge (additive)** | add `tool_names` — step 10 needs it for collision detection in `Tools::Mcp` |
| `lib/boukensha/run_dsl.rb` | **merge (additive)** | add `tool_names` passthrough, same reason |
| `lib/boukensha.rb` | **merge** | replace direct tool registration with `register_mcp_servers`; add `quiet!`/`loud!`/`quiet?`; **keep** the `tui:` keyword and the `Tui.new(repl).start` branch (§3) |
| `lib/boukensha/repl.rb` | **merge, careful** | step 10 added `/quiet`+`/loud` and swapped `mud:`→`servers:`; `11_tui` added `on_output`/`handle_command`/public accessors for `Tui`. Both survive (§4) |
| `lib/boukensha_loader.rb` | **merge** | take step 10's YAML rc/`boukensha_dir` resolution; **keep** the `--no-tui` ARGV flag (step 10 dropped it because step 10 has no TUI) (§5) |
| `boukensha.gemspec` | **merge** | drop the `mud_manager` dependency; **keep** `charm` (11_tui still needs it) (§6) |
| `Gemfile` | **no change** | already correct — `gem "charm"` must stay, unlike step 10 which dropped it |
| `Gemfile.lock` | **regenerate** | `bundle lock` after the gemspec edit, don't hand-edit |
| `lib/boukensha/version.rb` | **bump** | `0.11.0` → `0.11.1` (delta, not a new step) |
| `prompts/system.md` | **append** | the MUD auto-connect paragraph from step 10 (§7) |
| `examples/example.rb` | **rewrite** | currently a stale step-9/10-era MUD demo with `working_dir: false`; port step 10's version, keep the "Step 10" banner comment updated to reference this step and mention the TUI lives in `bin/boukensha` instead (§7) |
| `examples/mcp_mud_demo.rb` | **add** (copy verbatim from step 10) | dry-run smoke test against the daemon, no TUI involved |
| `Rakefile` | **add** (copy verbatim from step 10) | `rake test` |
| `test/*.rb` | **add** (copy verbatim from step 10: `helper.rb`, `test_mcp_client.rb`, `test_tools_mcp.rb`, `test_mcp_servers_config.rb`, `test_boukensha_loader.rb`) | none of these touch `Repl`/`Tui`, so they carry over unmodified (§8) |
| `README.md` | **rewrite** | merge step 10's "MCP host" section with 11_tui's existing TUI section — both stay, TUI section unchanged (§9) |
| `lib/boukensha/tui.rb`, `patches/*` | **no change** | untouched by this delta |

---

## 2. `config.rb`

Delete:

```ruby
def mud_host; dig(:mud, :host) || "localhost"; end
def mud_port; dig(:mud, :port) || 4000; end
def mud_username; dig(:mud, :username); end
def mud_password; dig(:mud, :password); end
```

Add step 10's `mcp_servers` verbatim (parses `mcp_servers:` from `settings.yaml`,
applies `command`/`args`/`env`/`prefix`/`required` defaults, stringifies `env`
values). No 11_tui-specific adaptation needed — nothing else in this tree calls
the four deleted methods except `boukensha.rb` (§3), confirmed by a repo-wide
grep.

---

## 3. `boukensha.rb`

Both `.run` and `.repl` currently do:

```ruby
if working_dir
  Tools::FileSystem.register(registry, working_dir: working_dir)
  Tools::Shell.register(registry, working_dir: working_dir,
                        timeout: shell_timeout, allowed_commands: allowed_commands)
end

resolved_mud = mud == false ? nil : (mud || mud_opts_from_config(cfg))
Tools::Mud.register(registry, **resolved_mud) if resolved_mud
```

Replace both call sites with step 10's:

```ruby
servers = register_mcp_servers(registry, cfg)
```

(`.run` doesn't need the return value; `.repl` passes it to `Repl.new(servers: servers, ...)` — see §4.)

Drop the `working_dir:`/`allowed_commands:`/`shell_timeout:`/`mud:` keyword
arguments from both method signatures, and delete `mud_opts_from_config`. Add
step 10's `register_mcp_servers` class method verbatim (iterates
`cfg.mcp_servers`, raises on a required server's spawn failure or any
`CollisionError`, warns and continues on an optional server's spawn failure,
returns `{name => tool_count}`).

Add the `quiet!`/`loud!`/`quiet?` module methods from step 10 (a `@quiet` flag
— nothing in the TUI reads it yet, but `Repl#run_turn`/`handle_command` will,
per §4).

**Do not** port step 10's removal of the `tui:` keyword or the
`Tui.new(repl).start` / `repl.start` branch at the end of `.repl` — that
branch is the entire point of this step and step 10 never had it. Keep:

```ruby
if tui && defined?(Tui)
  Tui.new(repl).start
else
  repl.start
end
```

Update the trailing `require_relative` block: drop
`tools/file_system`/`tools/shell`/`tools/mud`, add `tools/mcp`, keep
`boukensha/tui` last (load order matters — `Tui` references `Repl::PROMPT`,
which must already be defined).

---

## 4. `repl.rb` — the one non-mechanical merge

Two changes landed on this file for unrelated reasons and both need to be in
the merged version:

- **Step 10** (MCP): `mud:` keyword → `servers:`; `mud_status_string`/`probe_mud`
  deleted, replaced by `servers_status_string` (just formats the
  `{name => count}` hash — no TCP probing, since "the client already did a
  `tools/list` handshake" is a stronger liveness check than a bare socket
  connect); adds `/quiet` and `/loud` to the command switch and the `HELP`/
  banner text, wired to `Boukensha.quiet!`/`Boukensha.loud!`.
- **11_tui** (TUI): added `on_output`/`@output_cb` so all REPL output can be
  captured into `Tui`'s conversation viewport instead of going to stdout;
  split `handle_command` out as its own public method returning
  `:quit`/`:command`/`nil` (Tui calls it directly for slash input and for
  `Ctrl+L`); made `banner`, `run_turn`, `logger`, `context`, `model`, `version`
  public (Tui reads/calls all of them). Step 10, having no Tui, quietly
  **undid** all of this — inlined the command switch into `start`, made
  `banner`/`run_turn` private, dropped the `attr_reader` line entirely.

The merge keeps 11_tui's shape (public accessors, `on_output`, `handle_command`
as a standalone method, `start` delegating to `handle_command`) and layers
step 10's content into it:

1. Constructor: rename the `mud:` keyword to `servers:`, `@mud` → `@servers`.
   Keep `@output_cb`.
2. `attr_reader :logger, :context, :model, :version` — **keep**, do not delete.
3. `banner`: replace the `mud:` line with `servers:` using step 10's
   `servers_status_string` (delete `mud_status_string`/`probe_mud` entirely —
   nothing else calls them). Add step 10's `/quiet or /loud   toggle logging`
   line to the banner and to `HELP`.
4. `handle_command`: keep the existing `case`/`output(...)`/return-symbol
   structure (do **not** inline it into `start` the way step 10 did — Tui
   depends on calling this method directly). Add two branches from step 10:
   ```ruby
   when "/quiet"
     Boukensha.quiet!
     output("(logging suppressed — type /loud to re-enable)")
     :command
   when "/loud"
     Boukensha.loud!
     output("(logging enabled)")
     :command
   ```
5. `run_turn`: unchanged control flow from 11_tui (still routes through
   `output(...)`, not a bare `puts`) — this is what lets `Tui#start`'s
   `on_output` callback append the agent's reply to `@conversation`. Do not
   adopt step 10's `puts result` — that would silently break the TUI's
   conversation viewport.
6. `start`: unchanged from 11_tui (still checks `@output_cb` before printing
   the prompt, still calls `handle_command` then `run_turn`).
7. Keep `output`/`on_output` as private/public exactly as they are in 11_tui
   today.

Net effect: `Repl` gains `/quiet`+`/loud` and MCP-server-aware banner text
without losing anything `Tui` depends on. `Tui` itself needs **no changes** —
it only calls `on_output`, `handle_command`, `run_turn`, `banner`, `logger`,
`context`, `model`, `version`, none of whose signatures move.

---

## 5. `boukensha_loader.rb`

Take step 10's version (YAML `~/.boukensharc` parsing, independent
`boukensha_path`/`boukensha_dir` resolution, `BUNDLED_LIB`, env-var-wins
semantics, bare-string backward compat) as the base — this is the "improved
loading" the user asked for and matches the decision already recorded in
`floating_artifacts/bounkensharc.md`.

One deliberate deviation from a straight copy: step 10's
`load_and_start_repl` dropped both the `--no-tui` ARGV flag and the legacy
`MUD_NAME`/`MUD_HOST`/`MUD_PORT`/`MUD_PASSWORD` env-var handling, then calls
bare `Boukensha.repl`. For 11_tui:

- **Keep** the `--no-tui` flag — it's this step's own feature, orthogonal to
  the loader rewrite, and `Boukensha.repl` still accepts `tui:`:
  ```ruby
  no_tui = ARGV.delete("--no-tui")
  Boukensha.repl(tui: !no_tui)
  ```
- **Drop** the legacy `MUD_NAME`/`MUD_HOST`/`MUD_PORT`/`MUD_PASSWORD` special
  case, same as step 10 — there's no `mud:` keyword left on `Boukensha.repl`
  to populate (§3). A `MUD_HOST` etc. set in the calling shell still reaches
  the `mud-manager` MCP server, because `Tools::Mcp.register` spawns it via
  `Open3.popen3` with the current environment merged under the server's own
  `env:` block — config wins where it used to lose, per step 10's comment in
  `register_mcp_servers`. No code path in the loader needs to know this.

---

## 6. `boukensha.gemspec`

Step 10 dropped both `mud_manager` and `charm` as dependencies (it has no MUD
code and no TUI). 11_tui only drops `mud_manager` — the MUD's tools now live
entirely in the `mud-manager` subprocess, not in a Ruby dependency of this
gem — but **must keep** `charm` (`spec.add_dependency "charm"`), since
`lib/boukensha/tui.rb` requires `bubbletea`/`lipgloss`/`bubbles` which come
from it. Reword the dependency comment along step 10's lines ("MCP servers
bring their own dependencies; boukensha itself needs only `charm`, for the
TUI").

After editing the gemspec, run `bundle lock` (not a hand-edit) to regenerate
`Gemfile.lock` — expect `mud_manager` to disappear from the lockfile and
`charm`/`bubbletea`/`lipgloss`/`bubbles`/`bubblezone`/`glamour`/`gum`/
`harmonica`/`ntcharts` to remain, unlike step 10's lockfile which has none of
those.

---

## 7. Docs and examples

- **`prompts/system.md`**: append step 10's paragraph explaining the MUD
  session auto-connects on first gameplay action — this is true regardless of
  TUI vs. plain REPL, since it describes the MCP server's behavior, not the
  frontend.
- **`examples/example.rb`**: currently stale (still step-9/10-era: hardcodes
  `ENV["BOUKENSHA_DIR"]`, passes `working_dir: false`, no `mud:` needed
  because it never had one either — this file was apparently never updated
  past the original MUD demo). Port step 10's rewritten version
  (`Boukensha.run(task: ...)` with no keyword args, prints `cfg.mcp_servers.keys`).
  Update its header comment to say this is the one-shot (`Boukensha.run`) demo
  and that the interactive TUI is launched separately via `bin/boukensha`
  (matching step 10 README's existing note that the TUI isn't exercised by
  `example.rb`).
- **`examples/mcp_mud_demo.rb`**: copy verbatim — it's a `Boukensha::Registry`/
  `Boukensha::Context`-level smoke test with no REPL or TUI involvement, so
  nothing about it is step-specific.
- **`README.md`**: keep 11_tui's entire "What's new" TUI section (charm, four-
  zone layout, keyboard shortcuts, `Repl` refactor table, `Logger#subscribe`)
  — all of it stays true. Splice in step 10's "MCP host" section above it
  (`Mcp::Client`, `Tools::Mcp`, `mcp_servers:` table, "what went away" table)
  and its "Tests" / "Technical Considerations" sections. Update the "Run the
  demo" section: it currently says the TUI is the way to exercise this step
  (still true) — add step 10's `ruby examples/mcp_mud_demo.rb --dry` line
  alongside it.

---

## 8. Tests

Copy `test/helper.rb`, `test_mcp_client.rb`, `test_tools_mcp.rb`,
`test_mcp_servers_config.rb`, `test_boukensha_loader.rb` verbatim — confirmed
by reading all five that none references `Repl`, `Tui`, or anything this
delta changes in a TUI-relevant way (`test_boukensha_loader.rb` exercises
`BoukenshaLoader.resolve` only, not `load_and_start_repl`, so the kept
`--no-tui` branch in §5 is untested either way — that's already true in step
10 for its own loader).

No new tests are needed for the `Repl` merge itself (§4) unless the project
wants one; nothing in step 10's suite covers `Repl`/`Tui` today, so there's no
existing coverage to preserve there, and adding it is beyond this delta's
scope (a pure carry-over, not a feature).

Copy `Rakefile` verbatim (`rake test`, `t.libs << "test" << "lib"`).

**Verification, in order:**

1. `cd week1_baseline/ruby/11_tui && bundle install && rake test` — the five
   copied test files green.
2. `ruby examples/mcp_mud_demo.rb --dry` — daemon info, 26 tools, `tbamud__`
   names, `[dry run OK ...]`.
3. `gem build boukensha.gemspec && gem install --local boukensha-0.11.1.gem`.
4. `BOUKENSHA_DIR=$(pwd)/../../../.boukensha BOUKENSHA_PATH=$(pwd) boukensha`
   from the repo root (so the settings.yaml `mud-manager` relative-ish args
   resolve) — confirm the TUI boots, the status line's server line shows
   `mud (26)  fs (...)` instead of a `mud:` reachability probe, `/quiet` and
   `/loud` work from the input box, `Ctrl+L` still clears history through
   `handle_command`.
5. `boukensha --no-tui` — plain REPL still works, same banner content, same
   `/quiet`/`/loud`/`/clear`/`/exit` commands.
6. Diff `~/.boukensharc` behavior against
   `docs/plans/floating_artifacts/bounkensharc.md`'s documented cases (YAML
   mapping, legacy bare string, `boukensha_dir` key) to confirm the incident
   doesn't reappear in this step.

---

## 9. Risks / open questions

1. **`Repl` is the one file where a careless copy breaks something silently.**
   A naive "just take step 10's repl.rb" would compile and run fine standalone
   but would silently disable the TUI's conversation viewport (`run_turn`
   would `puts` instead of routing through `on_output`) and remove
   `handle_command`/public accessors that `Tui` calls directly, breaking at
   TUI boot with a `NoMethodError` on the first `/clear` or `Ctrl+L`. §4 above
   exists specifically to prevent that — treat it as the load-bearing section
   of this plan.
2. **No shell MCP server is configured yet** in the repo-root
   `.boukensha/settings.yaml` (only `mud` and `filesystem`). `Tools::Shell` is
   being deleted with nothing configured to replace it. That mirrors step
   10's own state (its README lists `Tools::Shell` under "what went away" with
   "a shell MCP server of your choosing" as the replacement, unconfigured) —
   not a regression introduced by this delta, just worth calling out before
   someone goes looking for `run_command` and doesn't find it.
3. **`examples/example.rb`'s current content predates both branches' MCP
   work** — it's not clear if it was ever updated after step 9. Confirm there
   isn't a reason it was left alone (e.g., a TUI-specific demo need) before
   overwriting it; nothing found in this investigation suggests one.
4. **Version bump number (`0.11.1`) is a suggestion**, not load-bearing —
   whatever scheme the project wants for "step 11, revision 2" is fine as
   long as the gemspec/lockfile/README stay consistent with it.
