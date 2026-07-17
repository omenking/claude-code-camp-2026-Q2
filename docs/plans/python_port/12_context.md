# Python Port Plan — 12 · Context Management

## Goal

Port the step-12 delta into the already-copied
`week1_baseline/python/12_context` snapshot. The directory currently matches
completed Python step 11 (`11_tui`) verbatim (confirmed via `diff -rq
--exclude=__pycache__ --exclude='*.pyc'`) — this plan's job is entirely the
delta below, not the copy.

The end state: `Context` tracks real context-window pressure (not just an
output-token cap), the `Agent` auto-compacts when usage crosses a configured
threshold and stops a turn on a token-spend ceiling as well as an iteration
ceiling, every backend normalizes provider "thinking" output into a common
`reasoning` content block, the OpenAI backend moves to the `/v1/responses`
API, and the TUI/REPL surface all of this (colour-coded context gauge,
`/compact` command, a compaction notice in the conversation log).

## Source of truth and scope

Diffing `11_tui` against `12_context` directly in ruby shows a wide but
mechanical set of changes touching nearly every `lib/` file. Full diffs were
read file-by-file; this table is the complete inventory:

| Ruby file | What changed |
|---|---|
| `lib/boukensha/context.rb` | Drops `task:` entirely. Gains `context_window:` (default 200,000), `compaction_threshold:` (default 0.85), `current_tokens` (accessor), `turn_tokens` (reader). New: `update_tokens`, `reset_turn_tokens`, `add_turn_tokens`, `usage_fraction`, `usage_pct`, `needs_compaction?`, `compact_messages!`. `clear_messages!` now also resets `current_tokens`. |
| `lib/boukensha/models.rb` | **new.** `Boukensha::Models` — a static model→`context_window` table built from every backend's own `MODELS` constant. |
| `lib/boukensha/config.rb` | New: `provider_type`, `model` (dig `tasks.player.*`, currently unused elsewhere — see judgment call 1), `agent_max_iterations`, `agent_max_output_tokens`, `agent_max_turn_tokens`, `agent_compaction_threshold` (all read a new `agent:` settings block with hard-coded defaults 25/1024/60,000/0.85). `to_s` now reports provider/model instead of the tasks list. |
| `lib/boukensha/agent.rb` | `max_iterations`/`max_output_tokens` no longer resolved from `task_settings` — the constructor takes them as plain keyword args (`max_iterations` defaults to `MAX_ITERATIONS`), plus a new `max_turn_tokens:` (0 = disabled). `run` now: resets turn-token spend and compacts-if-needed before the loop; adds a `token_limit_reached?` check alongside `iteration_limit_reached?`; records usage (`context.add_turn_tokens` + `context.update_tokens`) after every response; logs reasoning blocks; logs a `plan` event for tool-call preambles instead of folding them into the placeholder response text; passes `context_window:` into `logger.prompt`; passes `tokens:` into `logger.turn_end`. `extract_text` now joins text blocks with `"\n"` instead of `""`. `log_response`/`normalized_usage` private helpers are deleted — `response["usage"]` is now passed to the logger raw (see judgment call 2 for the multi-provider fallout). |
| `lib/boukensha/errors.rb` | Whitespace-alignment only — no new error class (ruby's `TurnCancelled` doesn't exist here; see judgment call 3). |
| `lib/boukensha/logger.rb` | `prompt` gains a required `context_window:` kwarg. New: `compaction(before:, dropped:, context_window:)`, `reasoning(text:, redacted: false)`, `plan(text:)`. `response`/`execution_metadata`/usage-normalization internals are untouched. |
| `lib/boukensha/backends/base.rb` | Doc-comment only: documents the normalized response contract (`reasoning`/`text`/`tool_use` blocks, reasoning-first ordering, `signature`/`redacted` semantics). No code change. |
| `lib/boukensha/backends/anthropic.rb` | `parse_response` now normalizes native `thinking`/`redacted_thinking` blocks into `{"type"=>"reasoning",...}`. Assistant turns going back out re-denormalize them into native `thinking`/`redacted_thinking` blocks (signature round-trips). Comments only around `MODELS`, no new models. |
| `lib/boukensha/backends/openai.rb` | **Rewritten** to target `/v1/responses` instead of `/v1/chat/completions` (gpt-5.x rejects `reasoning_effort`+tools on chat completions). `to_messages`→`to_input`; system prompt becomes top-level `instructions`; tool defs flatten (no `function:` wrapper); tool results round-trip as `function_call_output` items keyed by `call_id`; payload adds `reasoning: {effort: "none"}`. `parse_response` reads `response["output"]` (`reasoning`/`message`/`function_call` items) instead of `choices[0].message`. `MODELS`: `gpt-5.4` removed, `gpt-5.4-nano` added (context 400k, $0.20/$1.25 per M), `gpt-5.4-mini` and `gpt-5.5` unchanged. |
| `lib/boukensha/backends/gemini.rb` | `parse_response` normalizes `thought`/`thoughtSignature` parts into `reasoning` blocks; `functionCall` parts also carry through `thoughtSignature`. `to_payload` adds `thinkingConfig` (`{thinkingBudget: 0}` for current models). A `thinking_config` branch for a not-yet-enabled `gemini-3.1-pro-preview-customtools` model exists but that model entry itself is commented out in `MODELS` — dead/future-proofing code, ported as-is. No live `MODELS` change. |
| `lib/boukensha/backends/ollama.rb`, `ollama_cloud.rb` | `to_payload` adds `think: false`. `parse_response` normalizes `message["thinking"]` into a `reasoning` block when present. `ollama_cloud.rb`'s `MODELS` hash is reordered only (kimi before minimax) — cosmetic, not ported. |
| `lib/boukensha.rb` | `run`/`repl` gain `context_window:` (default `Models.context_window(model)`). `Context.new` drops `task:`, gains `context_window:`/`compaction_threshold:`. All `max_iterations`/`max_output_tokens`/`max_turn_tokens` resolution moves from `task_class.max_iterations(task_settings)` to `cfg.agent_max_iterations` etc. Logger snapshot gains `max_turn_tokens`/`context_window`, drops `task`. `require_relative "boukensha/models"` added. |
| `lib/boukensha/repl.rb` | New `/compact` command (`context.compact_messages!`, reports messages dropped). `initialize` drops `task_settings:`, gains `max_turn_tokens:`. `run_turn` passes `max_turn_tokens:` into the `Agent` it builds instead of `task_settings:`. Banner/HELP text document `/compact`. |
| `lib/boukensha/tui.rb` | Drops session-level `@session_input_tokens`/`@session_output_tokens` accumulators — progress/status lines now read `@context.current_tokens`/`@context.context_window`/`@context.usage_pct` directly. Idle progress line and status bar are colour-coded (grey <70%, yellow 70–84%, red ≥85%, plus a `⚠` glyph in the status bar at ≥85%). New `compaction` event handling appends a notice to the conversation log. |
| `lib/boukensha/mcp/client.rb` | Two independent fixes: (1) spawns the MCP subprocess via `Bundler.with_unbundled_env` when running under Bundler, so a bundled boukensha process doesn't leak `BUNDLE_GEMFILE`/`RUBYOPT` into a server that isn't part of the same bundle (ruby-specific — see judgment call 4); (2) on an unexpected EOF from the server, drains and reports its stderr in the raised error instead of a bare "server closed the connection" (portable, ported). |
| `lib/boukensha/version.rb` | `0.11.1` → `0.12.0`. |
| `examples/example.rb`, `mcp_mud_demo.rb`, `test/helper.rb` | `Context.new(task: Tasks::Player, ...)` → `Context.new(...)` (drop `task:`); comment-only change in `example.rb` (step number). |
| `lib/boukensha/tasks/base.rb`, `tasks/player.rb`, `registry.rb`, `run_dsl.rb`, `client.rb`, `message.rb`, `tools/mcp.rb`, `prompt_builder.rb` (code, not comment) | **no diff.** `prompt_builder.rb` only gained a doc-comment on `parse_response`; note it still calls `@backend.to_messages(...)` in its own (unused) `to_messages` convenience method, which would now raise for the OpenAI backend (renamed to `to_input`) if ever called — see judgment call 5. |
| `README.md` | Full rewrite documenting all of the above. |

Four judgment calls, called out so they don't read as accidental deviations
in review:

**1. `Config#provider_type`/`#model` are dead code, ported for fidelity.**
Neither is called anywhere in `boukensha.rb`, `repl.rb`, or the ruby test
suite — `Tasks::Player` still owns provider/model/system-prompt resolution
end to end, unchanged from step 11. These two methods exist only to back
`Config#to_s`'s new format. Ported as plain properties on `Config` (Python's
existing convention for other no-arg config readers like `mcp_servers`) for
parity, not because anything consumes them.

**2. `record_usage` reads `response["usage"]` raw, which silently zeroes out
context tracking for Gemini/Ollama/OllamaCloud.** Step 11's `Agent` had a
`normalized_usage` helper that checked `"usage"`, then `"usageMetadata"`
(Gemini), then `prompt_eval_count`/`eval_count` (Ollama) in turn. Step 12
deletes that helper and both `record_usage` and the final `logger.response`
call now read `response["usage"]` directly — which only exists in
Anthropic's and the rewritten OpenAI Responses API's raw response shape.
Gemini's raw usage lives under `"usageMetadata"`; Ollama's under top-level
`prompt_eval_count`/`eval_count`. For those three backends this step's
`Context#update_tokens`/`#add_turn_tokens` (and therefore the compaction
trigger, the context gauge, and the logged token/cost figures) silently see
zero every turn. This is a real behavioral regression in the ruby source
itself, not a Python-specific gap — the Python port reproduces it exactly
(`response.get("usage")` passed straight through) rather than quietly
"fixing" it by keeping the old normalization helper. Call this out in review
as an inherited limitation of the step-12 ruby source, not a Python defect.

**3. Python's `cancel_event`/`TurnCancelled` cooperative-cancellation
machinery (added in the step-11 port, ruby has no equivalent — it uses
`Thread#raise(Interrupt)`) is preserved unchanged.** None of step 12's ruby
`agent.rb` diff touches cancellation at all, so there is nothing to port
here; the existing Python-only check (`if self.cancel_event is not None and
self.cancel_event.is_set(): raise TurnCancelled()` at the top of the loop)
stays exactly where step 11 put it, now sitting alongside the two new
`iteration`/`token` limit checks.

**4. `Bundler.with_unbundled_env` has no Python analogue — not ported.**
This guards against a bundled *ruby* boukensha process leaking
`BUNDLE_GEMFILE`/`RUBYOPT` into a spawned MCP server subprocess. Python's
`mcp/client.py` already builds the child's environment explicitly
(`{**os.environ, **entry_env}`) via `subprocess.Popen(..., env=spawn_env)`
rather than inheriting and mutating the parent's activated-bundle state, so
the failure mode this works around doesn't exist in Python. The stderr-on-EOF
diagnostic (the other half of that ruby diff) is unrelated to Bundler and
*is* ported, unchanged in spirit.

**5. `PromptBuilder.to_messages()` is left calling `backend.to_messages(...)`
even for OpenAI, matching ruby's latent bug.** Ruby's own
`prompt_builder.rb` still calls `@backend.to_messages(@context.messages)`
in its unused `to_messages` convenience method, even though `OpenAI#to_messages`
was renamed to `#to_input` in this same step. Neither language calls this
method anywhere in the real request path (`to_api_payload` is what's
actually used), so it's inert — but faithfully porting it as-is (not
quietly renaming the call inside `PromptBuilder.to_messages()`) matches the
source; note this explicitly so it doesn't read as a missed rename in review.

## Python API shape

```python
from boukensha import repl, run

repl()                                  # unchanged call shape
repl(context_window=128_000)            # new — override the model's default window
run(task="...", context_window=64_000)  # new — same keyword on the one-shot path
```

`Context` construction changes shape (breaking — `task=` is gone):

```python
# before (step 11)
Context(task=Player, system="...", working_dir=...)

# after (step 12)
Context(system="...", context_window=200_000, working_dir=..., compaction_threshold=0.85)
```

## Implementation plan

### 1. Bump the version

- `boukensha/__init__.py`: `__version__ = "0.12.0"`.

### 2. Rewrite `Context`

- `boukensha/context.py`: drop the `task` parameter and `self.task` entirely
  (and the `task_name` branch in `__str__`). Constructor becomes
  `__init__(self, system, context_window=200_000, working_dir=None,
  compaction_threshold=0.85)`.
- Add `self.current_tokens = 0`, `self.turn_tokens = 0`,
  `self.compaction_threshold = compaction_threshold`,
  `self.context_window = context_window`.
- Add `update_tokens(self, n)` (`self.current_tokens = int(n or 0)`),
  `reset_turn_tokens(self)`, `add_turn_tokens(self, input_tokens,
  output_tokens)`.
- Add `usage_fraction` and `usage_pct` as `@property`s.
- Add `needs_compaction(self, threshold=None)` — a method (not a property,
  since it takes an optional override) defaulting to
  `self.compaction_threshold`.
- Add `compact_messages(self, target_fraction=0.60)`: drops
  `min(ceil(len(messages) * 0.40), len(messages) - 2)` (floored at 0) oldest
  messages, resets `current_tokens` to 0, returns the drop count. Note:
  `target_fraction` is accepted but unused in the body — ruby's own method
  never references its own `target_fraction:` kwarg either; this is a
  faithfully-ported vestigial parameter, not a Python oversight.
- `clear_messages` also resets `self.current_tokens = 0`.
- Update `__str__`/`__repr__` to drop the task reference:
  `f"#<Context turns={self.turn_count} tools={self.tool_count} window={self.context_window} current={self.current_tokens}>"`.

### 3. Add `boukensha/models.py`

```python
from . import backends

DEFAULT_CONTEXT_WINDOW = 32_000
_BACKEND_CLASSES = (
    backends.Anthropic, backends.OpenAI, backends.Gemini,
    backends.Ollama, backends.OllamaCloud,
)
_table = None

def table():
    global _table
    if _table is None:
        _table = {}
        for backend_class in _BACKEND_CLASSES:
            _table.update(backend_class.MODELS)
    return _table

def context_window(model):
    info = table().get(str(model))
    return info["context_window"] if info else DEFAULT_CONTEXT_WINDOW
```

Unlike ruby (which defers `BACKEND_CLASSES` in a lambda to dodge
`require`-order issues), Python can reference the classes directly: by the
time `boukensha/__init__.py` imports `models`, `from . import backends` has
already run and every backend class is fully defined.

### 4. Add `agent:`-block readers to `Config`

- `boukensha/config.py`: add four `@property` methods (matching the existing
  no-arg-property convention already used for `mcp_servers`/`user_prompts_dir`):
  `agent_max_iterations` (default 25), `agent_max_output_tokens` (default
  1024), `agent_max_turn_tokens` (default 60,000),
  `agent_compaction_threshold` (default 0.85) — each reading
  `self.dig("agent", "<key>")` and coercing with `int`/`float`.
- Add `provider_type` (`self.dig("tasks", "player", "provider") or
  "anthropic"`) and `model` (`self.dig("tasks", "player", "model") or
  "claude-haiku-4-5"`) properties — ported for parity though currently
  unused elsewhere (judgment call 1).
- Update `__str__`: `f"#<Boukensha::Config dir={self.dir}
  provider={self.provider_type} model={self.model}>"`.

### 5. Add `boukensha/models.py`'s `Boukensha::Models`-equivalent wiring, and rewrite `Agent`

- `boukensha/agent.py`:
  - `__init__` drops `task_settings`; signature becomes `(self, context,
    registry, builder, client, max_iterations=None, max_turn_tokens=None,
    max_output_tokens=None, logger=None, cancel_event=None)`. Delete
    `_resolve_max_iterations`/`_resolve_max_output_tokens`. Resolve inline:
    `self.max_iterations = int(max_iterations) if max_iterations else
    self.MAX_ITERATIONS`; `self.max_turn_tokens = int(max_turn_tokens) if
    max_turn_tokens else 0` (0 = disabled); `self.max_output_tokens =
    max_output_tokens` (unchanged, passed straight through).
  - `run()`: at the very top, call `self.context.reset_turn_tokens()` then
    `self._compact_if_needed()`. Inside the loop, keep the existing
    `cancel_event` check first (judgment call 3), then
    `_iteration_limit_reached()`, then a new `_token_limit_reached()` check
    (mirrors the iteration one, calls `self.logger.limit_reached(kind="max_tokens",
    n=self.context.turn_tokens, max=self.max_turn_tokens)` and
    `self._wrap_up("max_tokens")`).
  - Pass `context_window=self.context.context_window` into the existing
    `self.logger.prompt(...)` call.
  - After `parsed = self.builder.parse_response(response)`, call
    `self._record_usage(response)` then `self._log_reasoning(parsed["content"])`.
  - Non-tool-use branch: replace the `self._log_response(text, response)` call
    with `self.logger.response(text=text, usage=response.get("usage"),
    stop_reason=parsed["stop_reason"], task=None, backend=self.builder.backend)`
    directly (the `_log_response` helper is deleted, matching ruby); add
    `tokens=self.context.turn_tokens` to the `turn_end` call.
  - `_extract_text`: change the join separator from `""` to `"\n"`.
  - Add `_token_limit_reached(self)`: `return self.max_turn_tokens > 0 and
    self.context.turn_tokens >= self.max_turn_tokens`.
  - Add `_record_usage(self, response)`: `usage = response.get("usage") or
    {}`; `self.context.add_turn_tokens(usage.get("input_tokens"),
    usage.get("output_tokens"))`; `self.context.update_tokens(usage.get("input_tokens"))`.
    (Judgment call 2: this only actually populates for Anthropic/OpenAI.)
  - Add `_compact_if_needed(self)`: `if not self.context.needs_compaction():
    return`; else capture `before = self.context.current_tokens`, `dropped =
    self.context.compact_messages()`, then
    `self.logger.compaction(before=before, dropped=dropped,
    context_window=self.context.context_window)`.
  - Add `_log_reasoning(self, content)`: iterate blocks, skip non-`"reasoning"`
    types, compute `redacted = block.get("redacted") is True`, `text =
    str(block.get("text") or "")`, skip if `not text.strip() and not
    redacted`, else `self.logger.reasoning(text=text, redacted=redacted)`.
  - `_handle_tool_calls`: replace the single "reasoning-or-placeholder"
    `_log_response` call with two: `preamble = self._extract_text(content)`;
    `if preamble.strip(): self.logger.plan(text=preamble)`; then always
    `self.logger.response(text=f"(tool use — {n} call{'s' if n != 1 else
    ''})", usage=response.get("usage"), stop_reason="tool_use")` — note this
    placeholder call intentionally omits `backend=`, matching ruby, so it
    carries no cost/provider metadata.
  - `_wrap_up`: on the success path, call `self._record_usage(response)`
    before logging; replace the `_log_response` call with the same inline
    `self.logger.response(...)` shape as above (`task=None,
    backend=self.builder.backend`); add `tokens=self.context.turn_tokens` to
    both `turn_end` calls (success and the `ApiError` fallback).
  - Delete `_log_response` and `_normalized_usage` entirely (matches ruby's
    removal of `log_response`/`normalized_usage`).

### 6. Extend `Logger`

- `boukensha/logger.py`:
  - `prompt(self, messages, tools, context_window)`: add `context_window` to
    the written event dict.
  - Add `compaction(self, before, dropped, context_window)`.
  - Add `reasoning(self, text, redacted=False)`.
  - Add `plan(self, text)`.
  - `response`/`_execution_metadata`/usage-normalization helpers: unchanged.

### 7. Extend `Repl`

- `boukensha/repl.py`:
  - `__init__`: drop `task_settings`, add `max_turn_tokens=None`.
  - `HELP` and the banner text: add a `/compact` line.
  - `handle_command`: add an `elif task == "/compact":` branch —
    `dropped = self.context.compact_messages()`; `self._output(f"(compacted
    context — {dropped} messages dropped)")`; `return "command"`.
  - `run_turn`: pass `max_turn_tokens=self.max_turn_tokens` into the `Agent(...)`
    it constructs; drop `task_settings=self.task_settings`.

### 8. Rewrite every backend

- `boukensha/backends/base.py`: add a class docstring documenting the
  normalized response contract (reasoning/text/tool_use block shapes,
  reasoning-first ordering, `signature`/`redacted` semantics) — matches
  ruby's new doc comment, no behavioral change.
- `boukensha/backends/anthropic.py`:
  - `to_messages`: for `msg.role == "assistant"`, emit `{"role": "assistant",
    "content": self._assistant_content(msg.content)}` instead of the bare
    passthrough.
  - `parse_response`: map each response content block through
    `_normalize_block` before returning.
  - Add `_normalize_block(self, block)`: `"thinking"` → `{"type":
    "reasoning", "text": str(block.get("thinking") or ""), "signature":
    block.get("signature")}`; `"redacted_thinking"` → `{"type": "reasoning",
    "text": "", "redacted": True, "signature": block.get("data")}`; else
    passthrough.
  - Add `_assistant_content(self, content)` / `_denormalize_block(self,
    block)` — the inverse mapping, re-emitting native
    `thinking`/`redacted_thinking` blocks so signatures round-trip.
- `boukensha/backends/openai.py`: rewrite per the ruby diff —
  `BASE_URL` → `.../v1/responses`; `MODELS` drops `gpt-5.4`, adds
  `"gpt-5.4-nano": {"context_window": 400_000, "cost_per_million": {"input":
  0.2, "output": 1.25}, "usage_unit": "tokens"}`; `to_messages(system,
  messages)` → `to_input(messages)` (system moves to `instructions` in the
  payload, not a message); `to_tools` flattens (no `function:` wrapper);
  `to_payload` builds `{"model", "instructions", "input", "tools",
  "max_output_tokens", "reasoning": {"effort": "none"}}`; `parse_response`
  reads `response["output"]` items (`"reasoning"` → summary text joined,
  `"message"` → `output_text` parts joined, `"function_call"` → deferred
  then appended as `tool_use` blocks keyed by `call_id`); rename
  `_assistant_message` → `_assistant_items`, returning a list of
  `{"role": "assistant", "content": ...}` / `{"type": "function_call",
  "call_id", "name", "arguments"}` items (reasoning blocks dropped on the
  way back out — gpt-5.x doesn't need them echoed with `effort: "none"`).
- `boukensha/backends/gemini.py`: `to_payload`'s `generationConfig` gains
  `"thinkingConfig": self._thinking_config()`; `parse_response` adds a
  `part.get("thought")` branch emitting a `reasoning` block (with
  `thoughtSignature` carried as `signature`) and threads `thoughtSignature`
  through the existing `tool_use` branch too; add `_thinking_config(self)`
  (a `gemini-3.1-pro-preview-customtools` branch returning
  `{"thinkingLevel": "LOW"}`, else `{"thinkingBudget": 0}` — the former
  branch is unreachable today since that model isn't in `MODELS`, ported
  as-is per the source); `_assistant_parts` gains a `"reasoning"` case
  emitting `{"text": ..., "thought": True, "thoughtSignature": ...}` and
  carries `thoughtSignature` through the `"tool_use"` case when present.
- `boukensha/backends/ollama.py`, `ollama_cloud.py`: `to_payload` adds
  `"think": False`; `parse_response` prepends a `{"type": "reasoning",
  "text": message["thinking"]}` block when `message.get("thinking")` is
  truthy.

### 9. Update call sites that construct `Context`

- `boukensha/__init__.py`: `run()`/`repl()` gain `context_window=None`; add
  `from . import models` alongside the existing `from . import backends`;
  resolve `if context_window is None: context_window =
  models.context_window(model)` right after `model` is resolved. Replace
  `Context(task=Player, system=system, working_dir=working_dir)` with
  `Context(system=system, context_window=context_window,
  working_dir=working_dir, compaction_threshold=cfg.agent_compaction_threshold)`
  in both functions. Replace the `Player.max_iterations(task_settings)` /
  `Player.max_output_tokens(task_settings)` resolution with
  `cfg.agent_max_iterations` / `cfg.agent_max_turn_tokens` /
  `(max_output_tokens if max_output_tokens is not None else
  cfg.agent_max_output_tokens)`, threaded into both the `Logger` snapshot
  (drop `"task"`, add `"max_turn_tokens"` and `"context_window"`) and the
  `Agent`/`Repl` constructor calls (drop `task_settings=...`, add
  `max_turn_tokens=...`).
- `examples/mcp_mud_demo.py`: `Context(task=Player, system="demo")` →
  `Context(system="demo")`.
- `test/helper.py`, `test/test_repl.py`, `test/test_agent_cancellation.py`,
  `test/test_tui.py`: same `task=Player` removal at each `Context(...)`
  call site.
- `test/helper.py`'s `FakeLogger`: add no-op `compaction(self, **kwargs)`,
  `reasoning(self, **kwargs)`, `plan(self, **kwargs)` methods (its existing
  `prompt(self, **kwargs)` already tolerates the new `context_window` kwarg
  without changes).

### 10. Update `Tui`

- `boukensha/tui.py`:
  - Drop `self._session_input_tokens`/`self._session_output_tokens` from
    `__init__` and the `"response"` branch of `_handle_event` (keep the
    existing `self._live["turn_input_tokens"/"turn_output_tokens"]`
    accumulation — that part is untouched).
  - Add `CTX_WARN_PCT = 70`, `CTX_ALERT_PCT = 85` class constants.
  - Add `_ctx_color(self, pct)` → `"red"` if `pct >= CTX_ALERT_PCT`,
    `"yellow"` if `pct >= CTX_WARN_PCT`, else `"dim"` — returned as a Rich
    markup colour name (Textual's `Static` defaults to `markup=True`, so
    wrapping text in `f"[{color}]...[/{color}]"` is sufficient; no new CSS
    classes needed, unlike the existing `#progress.active` class which stays
    as-is and is orthogonal to this).
  - `_render_progress`'s idle branch: read `self._repl.context.usage_pct`,
    `.current_tokens`, `.context_window` instead of the deleted session
    counters; render `f"[{color}]  [ready]   ctx {used} / {max_} ({pct}%)
    {turns} turns[/{color}]"`.
  - `_render_status`: same source swap; append a `" ⚠ "` (vs `" "`) segment
    when `pct >= self.CTX_ALERT_PCT`, matching ruby's `ctx_indicator`. The
    status bar itself stays uniformly white-on-panel (no per-pct colour on
    the bar, only the glyph — matches ruby, which only colours the *idle
    progress line*, not the status bar).
  - `_handle_event`: add an `elif phase == "compaction":` branch appending
    `f"[context compacted — {dropped} messages dropped to free space]"` to
    the `#conversation` `RichLog` (`dropped = event.get("dropped")`).

### 11. Port the MCP client's stderr-on-EOF diagnostic

- `boukensha/mcp/client.py`: in `_read_until`, on `line == ""`, raise
  `Error(f"server closed the connection{self._stderr_detail()}")` instead of
  the bare message. Add `_stderr_detail(self)`: `try: self._process.wait();
  output = self._process.stderr.read() except Exception: return ""`; return
  `f" — stderr: {output.strip()}"` if `output and output.strip()` else `""`.
  (Judgment call 4: the Bundler-unbundle half of the ruby diff has no Python
  analogue and is not ported.)

### 12. Add the launcher and bump the example header

- `week1_baseline/bin/python/12_context`: same shape as `bin/python/11_tui`
  (`cd` into the step dir, exec the repo venv's `python examples/example.py
  "$@"`), following the convention step 11's plan established (Python has no
  `boukensha_loader`/gem concept, so every step launches via
  `examples/example.py` directly regardless of what ruby's own launch path
  looks like for that step).
- `examples/example.py`: bump the header comment/banner text from "Step 11"
  to "Step 12" (comment-only, matching ruby's `example.rb` diff).

### 13. Rewrite the README

- Replace the copied step-11 README with step-12 documentation: accurate
  context tracking (`current_tokens` vs `context_window`), `Models`, the
  colour-coded gauge and its thresholds, auto-compaction and
  `Context.compact_messages`, the `/compact` command, `Logger.compaction`,
  the `max_turn_tokens` second circuit breaker and the `agent:` settings
  block, the reasoning/thinking normalization contract, the OpenAI
  `/v1/responses` migration, `context_window=` on `run`/`repl`. Drop the
  step-11-era "Technical Considerations" ruby-specific notes that don't
  apply to the Python port (bundler env leak, gem packaging).

## Target files

```text
week1_baseline/python/12_context/            (already copied from 11_tui)
  boukensha/
    __init__.py            version bump; context_window= wiring; agent.* config resolution
    context.py              context_window/current_tokens/turn_tokens/compaction
    config.py                agent_* + provider_type/model properties
    agent.py                  max_turn_tokens, compaction, reasoning/plan logging, usage recording
    logger.py                  context_window on prompt(); compaction/reasoning/plan events
    repl.py                    /compact command; max_turn_tokens threading
    tui.py                     context gauge colour coding; compaction event; drop session counters
    models.py                new: static model -> context_window table
    mcp/client.py              stderr-on-EOF diagnostic
    backends/
      base.py                 doc comment only
      anthropic.py             reasoning block normalize/denormalize
      openai.py                 rewritten for /v1/responses
      gemini.py                 thinkingConfig + reasoning normalize
      ollama.py, ollama_cloud.py   think:false + reasoning normalize
  examples/
    example.py               step-number comment bump
    mcp_mud_demo.py            Context(task=...) -> Context(...)
  test/
    helper.py                  Context(task=...) -> Context(...); FakeLogger gains 3 no-ops
    test_repl.py, test_agent_cancellation.py, test_tui.py   Context(task=...) -> Context(...)
  README.md                  replaced
week1_baseline/bin/python/12_context           new launcher
```

Everything else under `week1_baseline/python/12_context/` (`message.py`,
`tool.py`, `client.py`, `registry.py`, `run_dsl.py`, `prompt_builder.py`
(minus its docstring), `tasks/base.py`, `tasks/player.py`,
`tools/mcp.py`, `test/test_mcp_client.py`, `test/test_mcp_servers_config.py`,
`test/test_tools_mcp.py`) carries over from `11_tui` unchanged — there is no
ruby diff touching them.

## Verification

1. Compile every step-12 Python file; import `repl`, `run`, `Repl`, `Tui`,
   `Agent`, `Context`, `Models`/`models`, `TurnCancelled` from `boukensha`.
2. `Context` unit checks: `usage_pct`/`usage_fraction` at 0/50%/100%
   occupancy; `needs_compaction()` flips at the configured threshold;
   `compact_messages()` drops `ceil(0.40 * n)` messages (floored so at least
   2 remain) and resets `current_tokens` to 0; `clear_messages()` also
   resets `current_tokens`.
3. `models.context_window(...)`: known models from each backend resolve
   correctly (e.g. `"claude-opus-4-8"` → 1,000,000, `"gpt-5.4-nano"` →
   400,000); an unrecognized model id falls back to `DEFAULT_CONTEXT_WINDOW`
   (32,000).
4. `Agent` unit checks (extending the existing `FakeBuilder`/`FakeClient`
   pattern in `test_agent_cancellation.py`): a turn whose cumulative
   input+output tokens reach `max_turn_tokens` triggers `_wrap_up("max_tokens")`
   without needing `max_iterations` to also be hit; `Context.needs_compaction()`
   returning `True` before a turn causes `compact_messages()` to run before
   the first API call; a response containing a `"reasoning"`-typed content
   block causes `logger.reasoning(...)` to be invoked once, skipped when the
   block is empty and non-redacted.
5. `Repl.handle_command("/compact")` returns `"command"`, calls
   `context.compact_messages()`, and reports the drop count through
   `on_output`/stdout, mirroring the existing `/clear` test.
6. Backend-level checks: Anthropic `parse_response` maps a `"thinking"`
   block to `{"type": "reasoning", ...}` and a round-trip through
   `to_messages` re-emits a native `"thinking"` block with the same
   signature; OpenAI's `to_payload` targets the new URL/shape
   (`instructions`, `input`, flat tool defs, `reasoning: {"effort": "none"}`)
   and `parse_response` correctly separates `reasoning`/`message`/
   `function_call` output items; Gemini/Ollama/OllamaCloud `parse_response`
   surfaces a `reasoning` block only when the provider actually returned
   thinking content.
7. Using Textual's headless harness (already exercised in `test_tui.py`):
   drive a turn through a stubbed `Repl`/`Context` and assert the idle
   progress line and status bar render the context gauge with the expected
   colour markup at each of the three usage bands, and that a `"compaction"`
   event appends the expected notice to the conversation log.
8. Manually run `week1_baseline/bin/python/12_context` end-to-end against
   the repo's `.boukensha/settings.yaml` (adding an `agent:` block with a
   deliberately low `max_turn_tokens` or `compaction_threshold` to force the
   new paths): confirm the context gauge changes colour as usage climbs,
   `/compact` (and the auto-trigger) visibly drops history and resets the
   gauge, and — if an `OPENAI_API_KEY` is available — a live turn against
   `gpt-5.5`/`gpt-5.4-mini` still works end-to-end through the rewritten
   `/v1/responses` path.

## Acceptance criteria

- `week1_baseline/python/12_context` exists as a copy-plus-delta of
  `11_tui`, with no unrelated files changed.
- `Context` has no `task` attribute; `context_window`/`current_tokens`/
  `turn_tokens`/`compaction_threshold` all behave per the ruby source,
  including the vestigial unused `target_fraction` parameter on
  `compact_messages` (ported faithfully, not "fixed").
- `Agent` stops a turn on whichever of `max_iterations`/`max_turn_tokens`
  trips first, auto-compacts at the top of a turn when
  `Context.needs_compaction()` is true, and logs `reasoning`/`plan` events
  distinct from the tool-call placeholder response.
- Every backend's `parse_response` returns `reasoning`-typed blocks for
  provider "thinking" output per the contract documented on
  `backends/base.py`; the OpenAI backend targets `/v1/responses`.
- `Repl` supports `/compact`; `Tui` shows a colour-coded context gauge and a
  compaction notice in the conversation log, with no regression to any
  step-11 TUI behavior (spinner, keybindings, cancellation).
- The known, documented gaps (judgment calls 1–5 above — dead `Config`
  properties, raw-`usage` blind spot for non-Anthropic/OpenAI backends,
  Python-only cooperative cancellation, no Bundler-unbundle equivalent, and
  `PromptBuilder.to_messages()`'s latent OpenAI incompatibility) are
  inherited from the ruby source or from step 11's own prior judgment calls,
  not introduced by this port.
