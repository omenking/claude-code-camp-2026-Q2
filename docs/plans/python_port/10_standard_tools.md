# Python Port Plan — 10 · A Standard Tool Library

## Goal

Port the standard-tool-library delta into the already-copied
`week1_baseline/python/10_standard_tool_library` snapshot. The directory
currently matches completed Python step 8 (`08_the_repl_loop`) verbatim —
Python has no step-9 port, so this single increment must absorb everything
that changed across *both* ruby `09_global_executable` and ruby
`10_standard_tool_library`, minus the parts of step 9 that are gem-packaging
concerns with no Python equivalent.

The end state: boukensha ships **no built-in tools**. It becomes an MCP host —
every tool the agent can call arrives from an MCP server declared in
`settings.yaml`'s `mcp_servers:` block (already present at the repo's
`.boukensha/settings.yaml`, shared with ruby). Adding a capability becomes a
config edit, not a code change.

## Source of truth and scope

Ruby's `09_global_executable` step is almost entirely gem/bin packaging
(`Gemfile`, `boukensha.gemspec`, `bin/boukensha`, `boukensha_loader.rb`,
`test/test_boukensha_loader.rb`) plus a banner simplification that step 10
later reverts. None of that has a Python analogue — Python steps run via
`week1_baseline/bin/python/NN_*` launcher scripts, not an installed gem, and
there is no `boukensha_loader` concept. **Do not port
`boukensha_loader.rb` or gem packaging.**

What *does* need porting is real ruby history that landed between steps 8–10,
verified by diffing the three ruby directories directly:

| Ruby file | Step | What changed |
|---|---|---|
| `lib/boukensha/client.rb` | 08→09 | The HTTP 401 special case added in step 8 is **removed** and stays removed in step 10 |
| `lib/boukensha/config.rb` | 08→09 | The cwd-`.boukensha` fallback added in step 8 is **removed**; `resolve_dir` returns to a 2-level `BOUKENSHA_DIR` → `~/.boukensha` precedence and stays that way in step 10 |
| `lib/boukensha/config.rb` | 09→10 | `mud_host`/`mud_port`/`mud_username`/`mud_password` replaced by `mcp_servers`, parsing `mcp_servers:` into `{name => {command:, args:, env:, prefix:, required:}}` with defaults |
| `lib/boukensha/context.rb` | 09→10 | Adds `working_dir:` (expanded path, metadata only — registers nothing) |
| `lib/boukensha/registry.rb` | 09→10 | Adds `tool_names` |
| `lib/boukensha/run_dsl.rb` | 09→10 | Adds `tool_names` passthrough |
| `lib/boukensha/repl.rb` | 09→10 | Banner reverts to the step-8-style format (config existence check, provider+key-status line) and adds a `servers:` line built from a `{name => tool_count}` map |
| `lib/boukensha.rb` | 09→10 | `run`/`repl` gain `working_dir:` (default `Dir.pwd`), call a new private `register_mcp_servers(registry, cfg)` before the `configure` block runs, and thread the resulting `{name => count}` summary into the REPL banner |
| `lib/boukensha/mcp/client.rb` | new in 10 | Minimal MCP-over-stdio client: spawn, JSON-RPC handshake, `tools/list`, `tools/call` |
| `lib/boukensha/tools/mcp.rb` | new in 10 | Registers a spawned client's discovered tools into a `Registry`, with optional name-prefixing and collision detection |
| `examples/example.rb` | 10 | No tool registration in the callback at all — tools come entirely from config |
| `examples/mcp_mud_demo.rb` | new in 10 | Spawns `week0_explore/mud_manager`'s `mud-manager --mcp` daemon through the generic MCP layer, `--dry` mode against a fake MUD |
| `README.md` | 10 | Documents the MCP host model, `mcp_servers:` schema, and what got removed |
| `test/*` | new in 10 | minitest coverage for the MCP client, tool registration, and config parsing (`test_boukensha_loader.rb` excluded — no Python loader) |

The important, non-obvious thread: **two features Python step 8 already
ported (HTTP 401 detection, cwd `.boukensha` fallback) were themselves
reverted by ruby in step 9 and never came back.** Porting step 10 faithfully
means *removing* them from the Python code now, even though nothing in the
Python history added them incorrectly — ruby's own steps 8→9 added, then
un-added, these two behaviors. Call this out in code review so it doesn't
read as an accidental regression.

## Python API shape

`run` and `repl` gain one new keyword, matching ruby:

```python
from boukensha import run, repl

run(task="...", working_dir=os.getcwd())   # metadata only; no tools registered
repl(working_dir=os.getcwd())
```

`configure=` remains supported (nothing stops a caller from also registering a
plain Python-side tool), but the example no longer uses it — every tool in the
default example comes from `mcp_servers:`.

## Implementation plan

### 1. Revert the two step-8-only behaviors

- `boukensha/client.py`: delete the `status == 401` branch in `Client.call()`;
  a 401 falls through to the generic
  `f"API request failed after {attempts} attempt{plural} ({status}): ..."`
  message like any other non-2xx response. Retry behavior for the retryable
  status set is unchanged.
- `boukensha/config.py`: collapse `_resolve_dir()` back to
  `os.environ.get("BOUKENSHA_DIR") or DEFAULT_DIR`, expanded/resolved as
  before. Remove the cwd `.boukensha` branch and update the class docstring to
  describe only the two-level precedence (`BOUKENSHA_DIR` env var, then
  `~/.boukensha`).

### 2. Replace MUD config with `mcp_servers`

- `boukensha/config.py`: delete the `mud_host` / `mud_port` / `mud_username` /
  `mud_password` properties. Add a `mcp_servers` property returning
  `{name: {"command": str, "args": [str], "env": {str: str}, "prefix": str | None, "required": bool}}`,
  reading `dig("mcp_servers")`, defaulting missing `args`/`env` to `[]`/`{}`,
  stringifying env values, and defaulting `required` to `True` when absent.
  Match ruby's per-entry defaulting exactly (see `test_mcp_servers_config.rb`
  for the exact shape expected, including string coercion of env values like
  a YAML integer port).

### 3. Add `Context.working_dir`

- `boukensha/context.py`: add a `working_dir=None` constructor parameter,
  storing `os.path.expanduser(os.path.abspath(working_dir))` (Python
  equivalent of ruby's `File.expand_path`) when given, else `None`. It is
  metadata only — nothing reads it to root a tool in this step.

### 4. Add `Registry.tool_names` / `RunDSL.tool_names`

- `boukensha/registry.py`: add `tool_names(self)` returning
  `list(self.context.tools.keys())`.
- `boukensha/run_dsl.py`: add a `tool_names(self)` passthrough to
  `self._registry.tool_names()`.

### 5. Port the minimal MCP-over-stdio client

- Add `boukensha/mcp/__init__.py` (empty) and `boukensha/mcp/client.py` with a
  `Client` class mirroring `Boukensha::Mcp::Client`:
  - `Client.spawn(command, args=(), env=None)` classmethod / plain
    constructor that spawns the process with `subprocess.Popen`, merging
    `env` over a copy of `os.environ` (stdio servers should inherit the
    parent environment — matches ruby's `Open3.popen3(env, *cmd)` semantics
    where the given hash is the *complete* child environment layered by the
    OS on top of nothing; confirm against ruby: `Open3.popen3(env, *cmd)`
    replaces rather than merges — so pass `env` as the full spawn
    environment unless doing so would break the ability for a stdio server to
    reach `PATH`/etc. Preserve ruby's exact behavior: only the given `env`
    hash plus what execve inherits from the parent process is available,
    i.e. pass `env=merged` in Python using `{**os.environ, **entry_env}`
    only if ruby does the equivalent — verify via `Open3.popen3` docs
    behavior before finalizing, since silent divergence here breaks the demo).
  - Line-delimited JSON-RPC 2.0 over stdin/stdout: `initialize` handshake with
    `protocolVersion="2025-06-18"`, `clientInfo={"name": "boukensha", "version": __version__}`,
    a `notifications/initialized` notification, then `tools/list`.
  - `tools` property (list of dicts as returned by the server).
  - `call_tool(name, arguments=None)` sending `tools/call`, returning
    `{"text": str, "error": bool}` by joining `content[].text` fields and
    reading `isError`.
  - `close()` closing stdin first (EOF signal), waiting on the process, then
    closing stdout/stderr, swallowing already-closed errors.
  - A monotonically increasing request id; a read loop that skips
    non-matching ids/notifications and raises on EOF before a response
    arrives.
  - Spawning a nonexistent command raises `FileNotFoundError`
    (Python's `subprocess` equivalent of ruby's `Errno::ENOENT`) — do not
    catch and wrap it into a different exception type, so callers can
    `except FileNotFoundError` the same way ruby callers `rescue Errno::ENOENT`.

### 6. Port the MCP tool-registration layer

- Add `boukensha/tools/__init__.py` (empty) and `boukensha/tools/mcp.py`
  mirroring `Boukensha::Tools::Mcp`:
  - `SEPARATOR = "__"`; a `CollisionError(ValueError)` (ruby's is an
    `ArgumentError` subclass, matched here by subclassing the closest stdlib
    equivalent).
  - `register(registry, command, args=(), env=None, prefix=None)`: spawns an
    `mcp.client.Client`, registers an `atexit` handler to close it, calls
    `register_client`, and returns the client.
  - `register_client(registry, client, prefix=None)`: reads existing names via
    `registry.tool_names()`, and for each of `client.tools`, computes the
    (possibly prefixed) local name, raises `CollisionError` with a message
    naming the offending tool and suggesting a distinct `prefix:` if the name
    is already taken, then calls `registry.tool(local, description=..., parameters=to_boukensha_params(schema))`
    with a closure that calls `client.call_tool(remote, kwargs)` and returns
    `f"error: {text}"` on `result["error"]` else the text. Returns the tool
    count.
  - `prefixed(name, prefix)`: `f"{prefix}{SEPARATOR}{name}"` if prefix is
    non-blank else the bare name.
  - `to_boukensha_params(input_schema)`: builds
    `{name: {"type": schema.get("type", "string"), "description": desc}}` from
    `input_schema["properties"]`, appending `" (one of: a, b, c)"` to the
    description when the property schema has an `enum`. Note (do not fix in
    this step): every listed parameter is still marked `required` by every
    Python backend's payload builder, same known limitation ruby's README
    documents.

### 7. Wire `mcp_servers` registration into `run`/`repl`

- `boukensha/__init__.py`: add a private `_register_mcp_servers(registry, cfg)`
  helper used by both `run` and `repl`:
  - Iterates `cfg.mcp_servers.items()`.
  - For each, calls `tools.mcp.register(registry, command=entry["command"], args=entry["args"], env=entry["env"], prefix=entry["prefix"])`.
  - On `tools.mcp.CollisionError`, re-raise unconditionally (never excused by
    `required: false`).
  - On any other exception: if `entry["required"]` raise
    `RuntimeError(f"boukensha: MCP server '{name}' failed to start: {error}")`;
    otherwise print a warning to stderr
    (`f"[boukensha] optional MCP server '{name}' failed to start: {error} — continuing without its tools"`)
    and continue.
  - Returns `{name: tool_count}` for servers that came up, used later for the
    REPL banner.
- Add `working_dir=None` to both `run(...)` and `repl(...)` signatures,
  defaulting to `os.getcwd()` when not supplied (ruby's `Dir.pwd` default),
  and pass it through to `Context(...)`.
- Call `_register_mcp_servers(registry, cfg)` immediately after constructing
  `Context`/`Registry` and *before* invoking the `configure` callback (matches
  ruby's ordering), in both `run` and `repl`. `repl` keeps the returned
  summary to hand to `Repl(...)`.
- Extract the provider/config-resolution block shared between `run` and
  `repl` into one private helper only if doing so avoids duplicating the new
  `working_dir` / `mcp_servers` logic across both — do not otherwise refactor
  working orchestration.

### 8. Update the REPL banner

- `boukensha/repl.py`: add `servers=None` to `Repl.__init__`, storing it.
- Add a `_servers_status_string()` returning
  `"(none configured — the agent has no tools)"` when `servers` is falsy,
  else `"  ".join(f"{name} ({count})" for name, count in servers.items())`.
- Add a `servers:` line to `_banner()` alongside the existing `config:` and
  `provider:` lines (the existing Python banner format already matches ruby's
  restored step-8-style banner, so only the new line needs adding — no other
  banner rewrite is required).

### 9. Replace the example and add the MUD/MCP demo

- Rewrite `examples/example.py`: drop `register_tools`/`configure=` entirely.
  Print config, the configured `mcp_servers` names, and API-key presence, then
  call `repl()` (or `run(task=...)`, matching ruby's own example) with no
  callback — every tool comes from `.boukensha/settings.yaml`'s
  `mcp_servers:` block. Keep pointing `BOUKENSHA_DIR` at the repo-root
  `.boukensha` before importing `boukensha`, as the existing launcher
  convention does.
- Add `examples/mcp_mud_demo.py`, a straight port of
  `examples/mcp_mud_demo.rb`:
  - `--dry` mode: spawn `week0_explore/mud_manager/bin/mud-manager --mcp`
    directly (via `ruby <path-to-mud-manager> --mcp`, since the daemon itself
    is a ruby script — the Python MCP client only cares that it speaks
    stdio JSON-RPC, exactly like ruby's own comment: "exactly what the
    Python / Go / Rust / Java tracks do with their own SDKs") against a
    `MudManager::FakeMud`-equivalent. Since there is no Python
    `mud_manager` package, either (a) shell out to a small ruby one-liner
    that boots `MudManager::FakeMud` and prints its port, or (b) accept a
    `MUD_PORT`/etc set from an already-running fake MUD. Prefer (a) for a
    true one-command `--dry` smoke test; keep the process-management code
    isolated so it can be deleted without touching the MCP demo path if a
    Python `mud_manager` port ever exists.
  - Full-run mode: identical to `example.py` — call `run(...)`/`repl()` with
    no callback since `mcp_servers:` already supplies the tools.

### 10. Rewrite the README

- Replace the copied step-8 README with step-10 documentation: the MCP host
  model, `Boukensha::Mcp::Client`/`Boukensha::Tools::Mcp` equivalents,
  `mcp_servers:` schema and defaults table, what got removed (no built-in
  filesystem/shell/MUD tools), and a "Technical Considerations" section
  mirroring ruby's honestly-documented current limitations (eager server
  spawn at boot, non-text MCP content dropped silently, every backend still
  marking all parameters required). Do not carry forward ruby's
  `boukensha_loader`/`~/.boukensharc` narrative — Python has no loader.

### 11. Add the launcher and a test suite

- Add `week1_baseline/bin/python/10_standard_tool_library`, following the
  existing convention (`cd` into the step dir, exec the repo venv's
  interpreter against `examples/example.py`).
- Add a `week1_baseline/python/10_standard_tool_library/test/` package using
  the standard library's `unittest` (no prior Python step added a test
  dependency; keep that convention rather than introducing `pytest`) covering
  the ruby-equivalent scope of `test_mcp_client.rb`, `test_tools_mcp.rb`, and
  `test_mcp_servers_config.rb`. Skip a test (via `unittest.SkipTest`) when
  `week0_explore/mud_manager/bin/mud-manager` is missing, matching ruby's
  `skip` behavior. There is no Python analogue to
  `test_boukensha_loader.rb` — do not port it.
- Do not add new pip dependencies; the MCP client uses only `subprocess`,
  `json`, and `itertools`/`os` from the standard library, matching ruby's
  "open3, net/http, and json are stdlib" note.

## Target files

```text
week1_baseline/python/10_standard_tool_library/
  README.md                              replace step-8 documentation
  boukensha/
    __init__.py                         mcp_servers wiring, working_dir, version
    client.py                           remove HTTP 401 special case
    config.py                           mcp_servers property; revert resolve_dir
    context.py                          add working_dir
    registry.py                         add tool_names
    run_dsl.py                          add tool_names passthrough
    repl.py                             add servers banner line
    mcp/
      __init__.py                       new
      client.py                         new: MCP-over-stdio client
    tools/
      __init__.py                       new
      mcp.py                            new: MCP tool registration + collisions
  examples/example.py                   drop configure=, tools from config only
  examples/mcp_mud_demo.py              new: mud-manager MCP demo (--dry + full)
  test/
    __init__.py                         new
    helper.py                           new: shared MCP test fixtures
    test_mcp_client.py                  new
    test_tools_mcp.py                   new
    test_mcp_servers_config.py          new
week1_baseline/bin/python/10_standard_tool_library   add executable launcher
```

## Verification

Keep verification offline; only the MCP client tests need a real subprocess
(the `mud-manager` daemon talking to its own built-in fake MUD), never a paid
provider request.

1. Compile every step-10 Python file; import `run`, `repl`, `Repl`, `Config`,
   `Context`, `Registry`, `RunDSL`, and the MCP modules from `boukensha`.
2. Assert `Client.call()` no longer special-cases 401 — a fake 401 response
   produces the generic failure message, and retryable statuses still retry.
3. Assert `Config._resolve_dir()` only honors `BOUKENSHA_DIR` then
   `~/.boukensha` — a `.boukensha` directory in the cwd with no
   `BOUKENSHA_DIR` set must **not** be picked up (this is the regression
   check: it must now fail the old step-8 test if one existed).
4. Assert `Config.mcp_servers` parses a `mcp_servers:` block into the exact
   shape/defaults ruby's `test_mcp_servers_config.rb` checks: string-coerced
   env values, default `args=[]`/`env={}`/`prefix=None`/`required=True`, and
   an absent block returning `{}`.
5. Assert `Context(working_dir=...)` stores an expanded path and defaults to
   `None`; assert `Registry.tool_names()`/`RunDSL.tool_names()` reflect
   registered tools.
6. Spawn the real `mud-manager --mcp` daemon (skipping if the sibling
   `week0_explore/mud_manager` checkout is absent) against its own fake MUD:
   assert the handshake reports `server_info["name"] == "mud-manager"`,
   `tools/list` includes `look`/`attack` with `inputSchema` on every entry,
   `call_tool("look")` and `call_tool("attack", target="dragon")` return the
   expected text, a deliberately bad call surfaces `error=True` with the
   expected message, and spawning a bogus command raises `FileNotFoundError`.
7. Using the same daemon, assert `tools.mcp.register`: populates the registry
   1:1 with discovered tools; applies `prefix` client-side only (dispatch
   through the prefixed name reaches the daemon; the bare name does not
   exist); a `None`/blank prefix yields bare names; an `enum` schema property
   surfaces `"(one of: ...)"` in the parameter description; registering the
   same server twice under the same prefix raises `CollisionError` naming the
   colliding tool and mentioning `prefix`; colliding with a tool already
   registered directly on the registry (not via MCP) also raises.
8. Assert `_register_mcp_servers`: a required server that fails to spawn
   raises `RuntimeError` naming the server; an optional
   (`required: False`) one that fails only warns and leaves the registry
   empty; `required: False` does **not** excuse a name collision — that still
   raises `CollisionError`; the returned summary is `{name: tool_count}`.
9. Drive `repl()`/`Repl.start()` with a fake `servers` summary and assert the
   banner's new `servers:` line renders both the empty-config message and a
   populated `name (count)  name2 (count2)` line; assert the rest of the
   banner (`config:`, `provider:`) is unchanged from step 8's format.
10. Run the new launcher (and `examples/mcp_mud_demo.py --dry`) end-to-end
    against the repo's `.boukensha/settings.yaml`, which already declares
    `mud` and `filesystem` MCP entries, confirming the process boots without
    a paid provider call by exercising only the config/registration path (or
    scripting immediate `/exit` if it reaches the REPL prompt).

## Acceptance criteria

- Python step 10 has no built-in tools; every tool available to the agent
  comes from `mcp_servers:` in `settings.yaml`, registered before any
  `configure` callback runs.
- `Boukensha::Mcp::Client`/`Tools::Mcp` behavior (handshake, discovery, call,
  prefixing, collision detection) is faithfully ported and tested against the
  real `mud-manager` daemon, without adding new pip dependencies.
- The two step-8 Python features that ruby itself reverted in step 9 — HTTP
  401 detection and the cwd `.boukensha` config fallback — are removed to
  match ruby's current (step 10) behavior.
- `Context.working_dir`, `Registry.tool_names`, and `RunDSL.tool_names` exist
  and match ruby's signatures/semantics.
- The REPL banner reports configured MCP servers and their tool counts; a
  required server failing to start aborts startup with a named error, an
  optional one only warns, and a name collision is always fatal.
- The example and new MUD/MCP demo, README, launcher, and test suite
  demonstrate the Python MCP host without any gem-packaging or
  `boukensha_loader` concepts that have no Python equivalent.
