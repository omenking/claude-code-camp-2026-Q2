# One gem, one binary — folding `mud_manager_mcp` into `mud_manager`

Third in the series. [`generic_interfacing.md`](generic_interfacing.md) asked
where the one stateful `Session` lives and answered: a Ruby daemon behind an MCP
facade. [`generic_mcp_client.md`](generic_mcp_client.md) then moved the *client*
half out of the MUD's gem and into boukensha, because it was never MUD-specific.

This plan finishes the cleanup on the *server* side:

> Why do we ship two gems? A bootcamper who wants to play a MUD should
> `gem install mud_manager` and get a `mud-manager` binary. One install, one
> binary, no `mud_manager` + `mud_manager_mcp` pair to keep version-locked.

The answer is that there is no reason. This is a packaging accident, and the code
was already written anticipating the merge — `mud_manager_mcp.gemspec` says so in
a comment, and so does its README's "Packaging" section:

> Because the daemon is just an interface over `mud_manager`, it can equally be
> folded into that gem and shipped as its own `mud-manager` executable (plan
> open-Q #5); the code is organized to make that move mechanical.

This plan cashes that in. **It is a move-and-rename. No behavior changes.**

---

## 1. Why two gems was defensible, and why it isn't anymore

The split encoded a real design boundary from `generic_interfacing.md` §1:
`mud_manager` is the *domain* (a stateful telnet session + a table of command
primitives); `mud_manager_mcp` is one *interface* over that domain. Keeping
interfaces out of domain gems is usually right — it lets the domain gem stay
dependency-free and lets a second interface (a web API, a gRPC server) arrive
without bloating it.

That argument fails here on three specific grounds:

1. **There will never be a second consumer of `mud_manager` alone.** The domain
   gem exists to serve the daemon. Nobody in the bootcamp `require "mud_manager"`
   directly except the daemon and the week-0 lesson examples — and the Ruby track
   now goes through MCP like everyone else (`generic_mcp_client.md` §3).
2. **The split taxes exactly the people it was meant to help.** The whole point
   of the daemon is that a Rust or Go bootcamper never touches Ruby. Making them
   install two gems and keep the versions compatible is a Ruby packaging problem
   we invented and then handed to someone who doesn't have a Ruby toolchain.
3. **The version dependency is fiction.** `spec.add_dependency "mud_manager", "~> 0.1"`
   implies the two evolve independently. They don't — `ToolSpec` reads
   `MudManager::Primitives` constants *live* (`tool_spec.rb:34`), so adding a
   direction or a spell enum to the domain gem silently changes the MCP tool
   schemas. They are one unit with one release cadence, described as two.

Point 3 is the strongest. The gems aren't loosely coupled; they're one program
with a constraint boundary drawn through its middle.

**What we keep:** the boundary is still worth *seeing* — it's a lesson. It just
belongs in the directory layout (`lib/mud_manager/mcp/`), not in the packaging.
A namespace teaches "these are separable" without charging anyone rent.

---

## 2. Decisions taken (settled — do not re-litigate)

### 2a. The merged gem lives at `week0_explore/mud_manager/`

The daemon folds **down** into the existing gem; `week1_baseline/mud_manager_mcp/`
is deleted.

```
week0_explore/mud_manager/       # THE gem — domain + daemon + binary
  mud_manager.gemspec
  primitives.json
  bin/mud-manager
  lib/mud_manager.rb
  lib/mud_manager/session.rb
  lib/mud_manager/primitives.rb
  lib/mud_manager/version.rb     # new (see 2c)
  lib/mud_manager/fake_mud.rb
  lib/mud_manager/mcp/{config,errors,tool_spec,spec,session_pool,dispatcher,json_line_server,server,client}.rb
  examples/{simple.rb,live_session_test.rb,boukensha_mcp_demo.rb}
  test/...
week1_baseline/mud_manager_mcp/  # deleted
```

Consequence worth stating plainly: **`week0_explore/mud_manager` stops being a
week-0 lesson snapshot and becomes a living shipped artifact.** If the other
`week0_explore/` directories are pinned teaching material that bootcampers read
as "here is where we were in week 0", this one now drifts ahead of them. That is
a real cost and it is accepted — the alternative (a frozen copy plus a real copy)
means two `Session` implementations, which is the exact thing every plan in this
series exists to prevent. See §7 risk 1.

### 2b. Namespace: `MudManager::Mcp::*`

```ruby
MudManager::Session          # unchanged
MudManager::Primitives       # unchanged
MudManager::VERSION          # new
MudManager::FakeMud          # was MudManagerMcp::FakeMud
MudManager::Mcp::Server      # was MudManagerMcp::McpServer
MudManager::Mcp::Client      # was MudManagerMcp::McpClient
MudManager::Mcp::Config      # was MudManagerMcp::Config
MudManager::Mcp::SessionPool # was MudManagerMcp::SessionPool
MudManager::Mcp::Dispatcher  # was MudManagerMcp::Dispatcher
MudManager::Mcp::ToolSpec    # was MudManagerMcp::ToolSpec
MudManager::Mcp::Spec        # was MudManagerMcp::Spec
MudManager::Mcp::JsonLineServer
MudManager::Mcp::Errors      # ProtocolError etc.
```

Two notes on the shape:

- `McpServer` → `Mcp::Server` and `McpClient` → `Mcp::Client` drop the stutter
  and mirror `Boukensha::Mcp::Client` from the previous plan. The two stdio
  clients stay deliberately duplicated (`generic_mcp_client.md` §5d) — that
  decision is unaffected here, and the daemon still must not depend on boukensha.
- **`FakeMud` sits at `MudManager::FakeMud`, not under `Mcp`.** It's a fake
  *MUD server* — a telnet endpoint doing the login dance. It's a domain test
  double that predates MCP conceptually and is consumed by boukensha's tests
  through the MCP boundary, not as part of it. Filing it under `Mcp` would be
  wrong on the merits, and it's the one constant here whose new home isn't a
  mechanical translation of its old one.

`Config` is the rename that earns the nesting: `MudManager::Config` unqualified
would read like "config for the gem", when it is specifically *MCP daemon
connection config*. `MudManager::Mcp::Config` says what it is.

### 2c. `MudManager::VERSION` becomes the single version

`mud_manager.gemspec` hardcodes `"0.1.0"`; `mud_manager_mcp` has a
`version.rb`. The merged gem gets `lib/mud_manager/version.rb` and the gemspec
reads it (as `mud_manager_mcp.gemspec` already does).

**Bump to `0.2.0`.** The gem grows a binary and a dependency-free daemon; that's
a minor bump, and it makes "which mud_manager has the MCP server?" answerable
(`>= 0.2`). `MudManager::Mcp::VERSION` does **not** exist — one gem, one version.

`Mcp::Server` reports it in `serverInfo` and `Spec` stamps it into
`primitives.json`; both just change constant.

---

## 3. What actually moves

Every file below moves **verbatim except for its module wrapper and its
requires**. If a diff contains a logic change, it does not belong in this plan.

| From | To | Notes |
| --- | --- | --- |
| `mud_manager_mcp/lib/mud_manager_mcp/config.rb` | `mud_manager/lib/mud_manager/mcp/config.rb` | body unchanged |
| `.../errors.rb` | `.../mcp/errors.rb` | body unchanged |
| `.../tool_spec.rb` | `.../mcp/tool_spec.rb` | `require "mud_manager"` → `require_relative "../primitives"` |
| `.../spec.rb` | `.../mcp/spec.rb` | version constant |
| `.../session_pool.rb` | `.../mcp/session_pool.rb` | `require "mud_manager"` → `require_relative "../session"` |
| `.../dispatcher.rb` | `.../mcp/dispatcher.rb` | body unchanged |
| `.../json_line_server.rb` | `.../mcp/json_line_server.rb` | body unchanged |
| `.../mcp_server.rb` | `.../mcp/server.rb` | class rename |
| `.../mcp_client.rb` | `.../mcp/client.rb` | class rename |
| `.../fake_mud.rb` | `.../fake_mud.rb` | **not** under `mcp/` (§2b) |
| `.../version.rb` | `.../version.rb` | module rename, bump to 0.2.0 |
| `mud_manager_mcp/bin/mud-manager` | `mud_manager/bin/mud-manager` | `require "mud_manager_mcp"` → `require "mud_manager"`; constants |
| `mud_manager_mcp/primitives.json` | `mud_manager/primitives.json` | regenerated, not edited (§5) |
| `mud_manager_mcp/Rakefile` | `mud_manager/Rakefile` | unchanged (mud_manager has none today) |
| `mud_manager_mcp/test/*` | `mud_manager/test/*` | helper paths + constants |
| `mud_manager_mcp/examples/boukensha_mcp_demo.rb` | `mud_manager/examples/` | joins `simple.rb`, `live_session_test.rb` |
| `mud_manager_mcp/README.md` | merged into `mud_manager/README.md` | §6 |

The `require "mud_manager"` → `require_relative` swaps in `tool_spec.rb:1` and
`session_pool.rb:1` are the only load-path–significant edits: they're what make
the daemon work from a source checkout with no installed gem and no
`$LOAD_PATH` juggling. That's the whole win, concretely.

### The gemspec

`mud_manager_mcp.gemspec` is deleted. `mud_manager.gemspec` absorbs the binary
and loses the fiction:

```ruby
require_relative "lib/mud_manager/version"

Gem::Specification.new do |spec|
  spec.name        = "mud_manager"
  spec.version     = MudManager::VERSION
  spec.summary     = "MudManager — CircleMUD sessions, command primitives, and an MCP daemon"
  # ... description merged from both, describing one thing ...

  spec.required_ruby_version = ">= 3.0"
  spec.files       = Dir["lib/**/*.rb"] + ["bin/mud-manager", "primitives.json", "README.md"]
  spec.bindir      = "bin"
  spec.executables = ["mud-manager"]

  # No external dependencies — socket, thread, json, open3, yaml are stdlib.
end
```

`add_dependency "mud_manager", "~> 0.1"` disappears, and with it the version-lock
maintenance. The merged gem is still **dependency-free**, which is what makes the
"one `gem install`, no toolchain archaeology" promise real for a Go student.

---

## 4. Consumers to update

The daemon's *wire behavior* does not change, so anything talking MCP is
unaffected. Only things that reference Ruby constants or filesystem paths move.

**boukensha** (`week1_baseline/ruby/10_standard_tool_library/`) — it depends on
the daemon only as a subprocess and a test fixture, exactly as designed:

- `test/helper.rb:11` — `MUD_MANAGER_ROOT` repoints from
  `../../../mud_manager_mcp` to `week0_explore/mud_manager` (now a cross-week
  path; see §7 risk 2). Line 21's `require "mud_manager_mcp/fake_mud"` →
  `require "mud_manager/fake_mud"`, and `MudManagerMcp::FakeMud` →
  `MudManager::FakeMud`.
- `examples/mcp_mud_demo.rb:25,37,38,52` — same load-path and constant swaps.
- `test/test_mcp_client.rb:27` — `assert_equal "mud-manager", client.server_info["name"]`
  **stays green untouched.** The binary's advertised name doesn't change. This
  assertion is a useful canary: if it breaks, the merge changed the wire.
- `boukensha.gemspec:25` — comment mentions `mud_manager`; reword.
- `Boukensha::Mcp::Client` and `Tools::Mcp` — **untouched**. They know a command,
  args, and env. That's the payoff of the previous plan.

**`.boukensha/settings.yaml:33`** — `args: [week1_baseline/mud_manager_mcp/bin/mud-manager, --mcp]`
becomes `week0_explore/mud_manager/bin/mud-manager`. Worth taking the moment to
document `command: mud-manager` (bare, from PATH) as the once-installed form —
which is now honest, because one `gem install` provides it.

**`docs/mud_manager_mcp_integration.md`** — §6.

---

## 5. Test plan

The 21 daemon tests + boukensha's MCP tests are the safety net, and the bar is
higher than usual: **a pure move should leave every assertion intact.**

**Group 1 — pass with constant/path edits only.** The daemon's own suite
(`test_spec.rb`, `test_mcp_server.rb`, `test_json_line_server.rb`,
`test_mcp_client_e2e.rb`, `test_boukensha_integration.rb`) and `test/helper.rb`.
They construct `MudManagerMcp::Config`, `MudManagerMcp::SessionPool`, etc.
Renaming those constants is the *only* sanctioned edit. `test_spec.rb:14` already
asserts `MudManager::Primitives::DIRECTIONS` — that line doesn't change at all,
which is a nice illustration that the domain half was never in question.

**Group 2 — pass completely untouched.** Every assertion about *behavior*: the
MCP handshake, `tools/list` returning 26 tools, dispatch results, error shapes.
If one of these needs an edit, the merge changed behavior. Stop and re-read.

**`primitives.json` must be byte-identical.** Regenerate via
`rake spec` (`ruby bin/mud-manager --dump-spec`) rather than moving the file, then
`git diff` it. Expect **exactly one** change: the version string `0.1.0` → `0.2.0`
if it's stamped, and the `$schema_note` text if it names `MudManagerMcp::ToolSpec`
(`spec.rb:66` does). Any other diff — a renamed tool, a changed enum, a dropped
`required` — means a constant rename silently altered the spec, and the language-
neutral contract other tracks generate from just broke. **This diff is the single
highest-value check in the plan.** It is the artifact five language tracks share.

**Manual verification:**

- `cd week0_explore/mud_manager && rake test` — the daemon suite green in its new home.
- `cd week1_baseline/ruby/10_standard_tool_library && rake test` — boukensha green.
- `ruby examples/mcp_mud_demo.rb --dry` — still prints daemon info, 26 tools, and
  `[dry run OK …]` with `tbamud__` names.
- `gem build mud_manager.gemspec && gem install --local mud_manager-0.2.0.gem && mud-manager --list-tools`
  — **the actual deliverable.** One install, `mud-manager` on PATH, tools out.
  Nothing before this step proves the thing the plan is for.

---

## 6. Docs

- **`week0_explore/mud_manager/README.md`** — absorbs `mud_manager_mcp/README.md`.
  The "Packaging" section (which anticipated this merge) is rewritten as fact:
  one gem, one binary, `gem install mud_manager`. Keep the `Session` /
  `Primitives` split explanation from `generic_interfacing.md` §1 — the namespace
  boundary is still the lesson, packaging just stopped charging for it.
- **`docs/mud_manager_mcp_integration.md`** — update the constants and the install
  story. Its core claims survive: the fake MUD is a test double, MCP is a real
  terminal interface. The claim "mud_manager unchanged" needs revisiting — it's
  now "unchanged *in behavior*; it grew a daemon".
- **`generic_interfacing.md` open-Q #5** ("why can't we just make it a binary that
  starts an MCP server?") — this plan is that answer. Worth a one-line pointer
  back so the series reads in order.

---

## 7. Risks

1. **`week0_explore/` stops being a snapshot** (§2a). The gem now evolves inside
   a directory whose siblings are frozen lesson artifacts, so the tree implies a
   pin it no longer honors. Mitigation: say so in the README's first lines. If
   that reads as a lie to bootcampers, the fix is a top-level `mud_manager/`
   — a directory move this plan makes trivial, having already done the hard part.
2. **boukensha's tests now reach across weeks** (`week1_baseline/ruby/...` →
   `week0_explore/mud_manager`). `helper.rb:19` already skips cleanly when the
   daemon isn't found, so the failure mode is graceful. But a cross-week source
   path is a smell pointing at risk 1.
3. **Constant renames are mechanical and therefore easy to fumble.** `Spec` (9
   uses), `McpClient` (8), `FakeMud` (7) are the hot ones. A blind
   `MudManagerMcp::` → `MudManager::Mcp::` sweep is *wrong* for `FakeMud` (§2b).
   Do `FakeMud` first and by hand, then sweep the rest.
4. **Scope creep.** Touching every file in the daemon will surface things worth
   fixing. None of them are this plan. A green, assertion-identical suite is the
   whole proof that this was a move — a logic change forfeits it.

---

## 8. Open questions

1. **Top-level `mud_manager/` instead?** Risk 1 argues for it. Deferred, not
   dismissed: the merge is the hard part, the `git mv` after is not.
2. **Does `week0_explore/mud_manager/examples/live_session_test.rb` still earn
   its place** next to the daemon, or is it now a `test/` citizen? It's the only
   thing that talks to a real MUD.
3. **Do we tag/release `0.2.0`** to a gem server, or is `gem install --local` the
   bootcamp distribution story? §5's final check assumes local; a real install
   ("`gem install mud_manager` and you're playing") is a materially better week-1
   experience and may be worth the release plumbing.
