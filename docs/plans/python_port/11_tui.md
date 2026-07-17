# Python Port Plan — 11 · A Terminal UI

## Goal

Port the step-11 delta into the already-copied
`week1_baseline/python/11_tui` snapshot. The directory currently matches
completed Python step 10 (`10_standard_tool_library`) verbatim (confirmed via
`diff -rq`) — this plan's job is entirely the delta below, not the copy.

The end state: `Boukensha.repl()` gains a `tui:` keyword (default `True`) that
wraps the existing plain-text REPL in a structured, full-screen terminal UI —
a scrollable conversation viewport, a live progress line while the agent is
working, a single-line input box, and an always-on status bar. The REPL keeps
owning all session logic (turn counting, slash commands, agent dispatch); the
TUI only replaces how it reads input and writes output.

## Source of truth and scope

Diffing `10_standard_tool_library` against `11_tui` directly in ruby shows a
small, contained set of changes:

| Ruby file | What changed |
|---|---|
| `Gemfile`, `boukensha.gemspec`, `Gemfile.lock` | add the `charm` gem (bubbletea + lipgloss + bubbles + friends), a per-platform native dependency |
| `lib/boukensha/version.rb` | `0.10.0` → `0.11.1` |
| `lib/boukensha/tui.rb` | **new.** `Boukensha::Tui` — wraps a `Repl`, drives a bubbletea event loop, four-zone layout |
| `lib/boukensha/repl.rb` | `Repl` refactored for composability: `on_output(&block)` (redirect output through a callback instead of `puts`), `handle_command(input)` (slash-command dispatch extracted from `start`, now public), `run_turn(input)` (was private `run_turn`, now public and routed through `output`); `banner`, `logger`, `context`, `model`, `version` exposed as `attr_reader` |
| `lib/boukensha.rb` | `run`/`repl` gain `tui:` default `true`; when true and `Tui` is defined, `Tui.new(repl).start` instead of `repl.start` |
| `lib/boukensha_loader.rb` | CLI gains `--no-tui`, threading `tui: !no_tui` into `Boukensha.repl` |
| `examples/example.rb` | comment-only: clarifies it's the one-shot `Boukensha.run` demo and the TUI is launched separately via `bin/boukensha` |
| `README.md` | documents the TUI, `Repl`'s new public surface, `Logger#subscribe` (see below), `tui:`/`--no-tui` |
| `patches/bubbletea/*` | **new, do not port.** A C-extension patch for a burst-input bug in the `bubbletea` gem's Go FFI binding (multi-byte `read()` chunks lost all but the first key). This is a bug in ruby's *native-extension binding* to a separate Go runtime — it has no Python analogue because the library this plan uses is pure Python with no FFI boundary of that shape. |
| `lib/boukensha/logger.rb`, `lib/boukensha/context.rb`, `lib/boukensha/agent.rb` | **no diff** between the two ruby step directories. `Logger#subscribe`, `Context#tool_count`, and `Agent::MAX_ITERATIONS` all predate step 11 and are already ported in Python (`logger.py:subscribe`, `context.py:tool_count`, `agent.py:MAX_ITERATIONS`) — nothing to do here beyond consuming them from `Tui`. |
| `test/*` | **no diff.** Ruby ships no automated test coverage for `Tui` itself — porting has no reference test suite to match line-for-line. |

Three judgment calls this plan makes, called out so they don't read as
accidental deviations in review:

**1. `charm` (bubbletea/lipgloss/bubbles) → Textual.** There is no Python
binding to Bubble Tea. Per your choice, this port targets
[Textual](https://github.com/Textualize/textual) rather than `prompt_toolkit`
or `urwid`: it's the closest conceptual match to bubbletea's reactive
model/update/view loop (async event loop, timers, a scrollable log widget,
CSS-like styling standing in for lipgloss), it's pure Python with no native
per-platform build step (unlike `charm`'s native gems, which is exactly why
ruby needed the `patches/bubbletea` workaround in the first place), and it
ships a headless test harness (`App.run_test()` / `Pilot`) that ruby's charm
setup has no equivalent of. Add `textual` to `requirements.txt` (it pulls in
`rich` transitively).

**2. `Thread#raise(Interrupt)` for Esc-cancel → cooperative cancellation.**
Ruby's Esc handler does `@turn_thread.raise(Interrupt)`, asynchronously
injecting an exception into the background thread wherever it currently is —
including mid-blocking-I/O, since MRI checks for pending thread interrupts
around blocking reads. Python has no safe equivalent: injecting an async
exception into another thread (`ctypes.pythonapi.PyThreadState_SetAsyncExc`)
only fires the next time that thread returns to Python bytecode, so it cannot
cut short a blocking HTTP call already in flight the way ruby's can — it
would only take effect once that call returns anyway, i.e. too late to matter.
Rather than ship a fragile ctypes hack that *looks* like ruby's behavior but
silently doesn't deliver it during the one case that matters (a long-running
model call), this plan adds a small, honest cooperative-cancellation hook to
`Agent` instead: an optional `cancel_event` (a `threading.Event`) checked at
the top of each loop iteration, raising a lightweight `TurnCancelled`
exception. **Accepted gap:** Esc still won't interrupt a single in-flight
backend call, only takes effect at the next iteration/tool-call boundary —
call this out in code review as a deliberate, documented divergence, not a
missed port.

**3. Where the TUI launches from.** In ruby, `examples/example.rb` is the
one-shot `Boukensha.run` demo, and the interactive TUI is reached only through
the installed gem's `bin/boukensha` executable (via `boukensha_loader.rb`,
which step 10's plan already excluded from the Python port — there is no
Python gem/loader concept). Every Python step's launcher script
(`week1_baseline/bin/python/NN_*`) has instead always run
`examples/example.py` directly, and since step 8 that file has called
`repl()` interactively — Python never had ruby's one-shot/interactive split at
the example layer. This plan keeps that existing Python convention: fold
`--no-tui` argv handling directly into `examples/example.py` (checking
`"--no-tui" in sys.argv` before calling `repl(...)`), rather than inventing a
Python `boukensha_loader` just to host a CLI flag. This is a one-line
divergence in *where* the flag is parsed, not in what it does.

## Python API shape

`repl` gains one new keyword, matching ruby; `run` does not (the TUI only
wraps interactive sessions):

```python
from boukensha import repl

repl()                # default — launches the Textual TUI
repl(tui=False)        # plain terminal REPL, unchanged from step 10
```

## Implementation plan

### 1. Bump the version and add the dependency

- `boukensha/__init__.py`: `__version__ = "0.11.1"`.
- `requirements.txt`: add `textual`.

### 2. Refactor `Repl` for composability

- `boukensha/repl.py`:
  - Add `self._output_cb = None` in `__init__`.
  - Add `on_output(self, callback)` storing `callback`.
  - Add a private `_output(self, s)`: call `self._output_cb(str(s))` if set,
    else `print(s)`.
  - Extract the slash-command `if/elif` chain out of `start()` into a public
    `handle_command(self, task)` returning `"quit"`, `"command"`, or `None`
    (not a command), using `_output` instead of `print` for every message it
    emits (`"Goodbye."`, `HELP`, the quiet/loud/clear confirmations).
  - Rename `_run_turn` to a public `run_turn(self, task)`; replace its two
    `print()` calls (the blank line + result, and both error branches) with
    `_output`.
  - Rewrite `start()` to: print the banner through `_output`; only print the
    literal `PROMPT` to stdout when `self._output_cb` is `None` (matches
    ruby's `unless @output_cb` — Textual will drive input itself, no
    stdout prompt needed); read a line; call `handle_command`; break on
    `"quit"`, `continue` on `"command"`; otherwise call `run_turn`.
  - No change needed to make `context`, `model`, `version`, `logger` public —
    Python attributes already have no `attr_reader` equivalent to add; they
    were public all along. (Ruby needed this step because its instance
    variables are private by default; Python's aren't.)

### 3. Add cooperative cancellation to `Agent`

- `boukensha/agent.py`: add `cancel_event=None` to `Agent.__init__`, stored as
  `self.cancel_event`.
- Add a `TurnCancelled(Exception)` to `boukensha/errors.py`.
- At the top of the `while True` loop in `Agent.run()` (alongside the existing
  `_iteration_limit_reached()` check), raise `TurnCancelled()` if
  `self.cancel_event is not None and self.cancel_event.is_set()`.
- `Repl.run_turn` constructs its `cancel_event` (a fresh `threading.Event`
  per turn, exposed as `self._cancel_event` so a driving TUI can `.set()` it)
  and passes it into the `Agent(...)` it builds; catches `TurnCancelled`
  alongside `LoopError`/`ApiError` and routes an `"(interrupted)"` message
  through `_output`.

### 4. Port `Tui` as a Textual `App`

Add `boukensha/tui.py` with a `Tui` class wrapping a `Repl`, mirroring
`Boukensha::Tui`'s structure zone-for-zone:

- **Layout** (`compose()`): a `RichLog` (`wrap=True, markup=True,
  auto_scroll=True`) for the conversation viewport; a `Static` for the
  progress/status-when-idle line; an `Input` (single-line — ruby's
  `TextArea` is pinned to `height = 1` here, so `Input` is the more faithful
  match, not the multi-line `TextArea` widget) with
  `placeholder="Type a message…"` for the prompt box; a `Static` for the
  always-on status bar.
- **Startup** (`on_mount`): append `self._repl.banner` to the log; call
  `self._repl.on_output(self._on_repl_output)`; call
  `self._repl.logger.subscribe(self._on_event)`; start a
  `self.set_interval(0.06, self._tick)` (ruby's `TICK_MS = 60`) driving the
  spinner frame and elapsed-time counter while a turn is active, and
  refreshing the status clock either way.
- **Event queue**: both `_on_repl_output` and `_on_event` (the logger
  subscriber) are called from the *background turn thread*, not the Textual
  event loop — mirror ruby's `Queue` + drain-on-tick pattern exactly rather
  than calling Textual widget-mutating APIs directly from that thread: push
  onto a `queue.Queue`, and have `_tick` drain it (non-blocking `get_nowait()`
  loop) and apply the updates. This is not just style-parity with ruby; it's
  the correct thing to do under Textual too, since only the app's own
  event-loop thread should mutate widget state.
- **Live progress state**: a plain dict (`spinner_idx`, `start_time`,
  `elapsed`, `current_action`, `iteration`, `tool_call_count`,
  `turn_input_tokens`, `turn_output_tokens`), rebuilt fresh in
  `_launch_turn` exactly like ruby's `@live` hash. Render it into the
  progress `Static` on every `_tick` (spinner frame from the same 10-glyph
  Braille set ruby uses) when active, else the idle
  `"[ready]  ctx <k>  <n> turns"` line — same two branches, same content, as
  `render_progress`/`servers_status_string`-adjacent logic in ruby.
- **Status bar**: `" boukensha v{version} · {model} · ctx {used} ·
  {tools} tools · {clock} "`, left-padded/justified to the terminal width —
  reuse `self._repl.context.tool_count`, `self._repl.model`,
  `self._repl.version` (all already public per step 2).
- **Keybindings** (Textual `BINDINGS` + `on_input_submitted`):
  - `ctrl+c`, `ctrl+d` → `action_quit` (`self.exit()`).
  - `escape` → if a turn thread is running, `self._cancel_event.set()`
    (see step 3) instead of ruby's `Thread#raise` — this is the one
    documented behavioral gap (accepted above).
  - `ctrl+l` → `self._repl.handle_command("/clear")`, reset `turn_count`.
  - `pageup`/`pagedown` → scroll the `RichLog` (`scroll_up`/`scroll_down`, or
    equivalent proportional scroll — Textual's `RichLog` supports
    programmatic scrolling natively).
  - `Input.Submitted` (Textual's enter-key event, replacing ruby's manual
    `"enter"` case in `handle_key`): read `event.value`, clear the input; if
    it starts with `/`, call `self._repl.handle_command(...)`, exit on
    `"quit"`; else append `"> {input}"` to the log and call
    `self._launch_turn(input)`.
- **Agent thread** (`_launch_turn`): identical shape to ruby's —
  `threading.Thread(target=self._run_turn_thread, args=(input,),
  daemon=True).start()`, where the thread body calls `self._repl.run_turn`,
  catches `TurnCancelled` and any other `Exception`, and always enqueues a
  `{"phase": "turn_complete"}` event in a `finally` block so the progress
  line always clears even on an unexpected error.
- **Styling**: Textual CSS (`Tui.CSS` class attribute or a `.tcss` file) for
  the four ANSI colors ruby's `ANSI_COLORS`/`lip()` helper hard-codes
  (cyan progress line, dim/idle line, bold-green prompt, white-on-gray status
  bar) — same four roles, expressed as Textual CSS selectors instead of
  per-call `Lipgloss::Style` construction.

### 5. Wire `tui=` into `boukensha/__init__.py`

- Add `from .tui import Tui` (guard the import — see below) and `tui=True` to
  `repl(...)`'s signature.
- Change the tail of `repl()` from constructing `Repl(...)` and immediately
  calling `.start()` to constructing it, then:
  ```python
  if tui:
      Tui(repl_instance).run()   # Textual App.run(), not .start()
  else:
      repl_instance.start()
  ```
  (Textual's convention names the entry point `run()`; keep `Tui.start`
  disallowed/absent so there's exactly one way to launch it, rather than
  carrying ruby's `start` name where it no longer fits Textual's API.)
- `run()` (the one-shot, non-interactive function) is untouched — ruby's own
  `Tui` only ever wraps `Repl`, never `Agent.run` directly.

### 6. Update the example and launcher

- `examples/example.py`: check `"--no-tui" in sys.argv` and call
  `repl(tui=False)` vs `repl()` accordingly (see judgment call 3 above); keep
  the existing config/servers/api-key print block unchanged.
- `week1_baseline/bin/python/11_tui`: same launcher shape as every prior
  step (`cd` into the step dir, exec the repo venv's `python`
  `examples/example.py "$@"` — forward argv so `--no-tui` reaches the
  example).

### 7. Rewrite the README

- Replace the copied step-10 README with step-11 documentation: the Textual
  TUI's four-zone layout (reuse ruby's ASCII diagram — the shape is
  identical), the keybinding table, `repl(tui=...)`, `Repl`'s new public
  surface (`on_output`, `handle_command`, `run_turn`), and a short
  "Technical Considerations" note on the Esc/cancellation gap from judgment
  call 2. Do not carry forward ruby's `charm`/native-gem/patch narrative —
  Textual has no analogous native-extension concern.

## Target files

```text
week1_baseline/python/11_tui/                (already copied from 10_standard_tool_library)
  requirements.txt                          add textual
  README.md                                 replace step-10 documentation
  boukensha/
    __init__.py                             __version__ bump; tui= wiring in repl()
    agent.py                                add cancel_event / TurnCancelled check
    errors.py                               add TurnCancelled
    repl.py                                 on_output, handle_command, run_turn (public)
    tui.py                                  new: Textual App wrapping Repl
  examples/example.py                       --no-tui argv handling
week1_baseline/bin/python/11_tui             new launcher, forwards argv
```

Everything else under `week1_baseline/python/11_tui/` (config.py, context.py,
registry.py, run_dsl.py, logger.py, client.py, backends/, mcp/, tools/,
tasks/, message.py, prompt_builder.py, tool.py, examples/mcp_mud_demo.py,
test/) carries over from `10_standard_tool_library` unchanged — there is no
ruby diff touching them.

## Verification

Ruby ships no automated `Tui` test suite to match, so verification here leans
more on direct interaction than step 10's did:

1. Compile every step-11 Python file; import `repl`, `Repl`, `Tui`, `Agent`,
   `TurnCancelled` from `boukensha`.
2. Assert `Repl.handle_command` returns `"quit"` for `/exit`/`/quit`,
   `"command"` for `/help`/`/quiet`/`/loud`/`/clear` (and performs their
   side effects), and `None` for a non-command string — with no stdout
   printing when `on_output` is registered, only calls to the callback.
3. Assert `Repl.run_turn`, given a fake client/backend, routes its result (or
   `LoopError`/`ApiError`/`TurnCancelled` message) through a registered
   `on_output` callback instead of `print`.
4. Assert `Agent.run()` raises `TurnCancelled` promptly once `cancel_event` is
   set, at the next iteration boundary, without needing a real backend call
   to complete first.
5. Using Textual's headless test harness (`async with app.run_test() as
   pilot`), drive the TUI without a real terminal: type into the input and
   press enter, assert a fake/stubbed `Repl` receives the input and the
   conversation log grows; press `ctrl+l` and assert `/clear` fires; press
   `escape` mid-turn and assert the cancel event gets set; press `ctrl+c`/
   `ctrl+d` and assert the app exits. This is more coverage than ruby has for
   its own `Tui`, made possible by Textual's harness — call this out as a net
   improvement, not scope creep.
6. Manually run `week1_baseline/bin/python/11_tui` end-to-end against the
   repo's `.boukensha/settings.yaml`: confirm the four zones render, typing
   is not dropped under fast/pasted input (the very bug ruby needed a native
   patch for — Textual should not exhibit it, but check), the progress line
   animates during a real turn, `PgUp`/`PgDn` scroll history, and `--no-tui`
   (`week1_baseline/bin/python/11_tui --no-tui`) falls back to the identical
   plain-text REPL from step 10.

## Acceptance criteria

- `week1_baseline/python/11_tui` exists as a copy-plus-delta of
  `10_standard_tool_library`, with no unrelated files changed.
- `repl(tui=True)` (the default) launches a Textual-based four-zone TUI;
  `repl(tui=False)` / `--no-tui` is byte-for-byte the same plain REPL step 10
  shipped.
- `Repl` exposes `on_output`, `handle_command`, and a public `run_turn`,
  matching ruby's refactor; nothing in `Repl`'s own turn/session logic moved
  into `Tui`.
- Esc interrupts a running turn at the next iteration/tool-call boundary via
  cooperative cancellation (`Agent(cancel_event=...)` / `TurnCancelled`) — the
  one intentional, documented behavioral gap versus ruby's
  `Thread#raise(Interrupt)`, which can (rarely) cut off mid-network-call.
- No `patches/`-equivalent exists or is needed — Textual is pure Python with
  no native-extension input-buffering bug to work around.
- `requirements.txt` gains exactly one new dependency (`textual`); no gem-
  packaging, native-build, or `boukensha_loader` concepts are introduced.
