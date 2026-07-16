# Python Port Plan — 06 · The Logger

## Goal

Port the step-6 delta from `week1_baseline/ruby/06_the_logger` into the
already-copied `week1_baseline/python/06_the_logger` snapshot. The Python
directory currently contains the completed step-5 agent loop, so implementation
must preserve that behavior and add only the new structured logging behavior.

The result should create one JSON Lines file per agent session, record the
agent's prompts, responses, tool activity, limits, and completion, and include
raw provider responses only when debug logging is explicitly enabled.

## Source of truth and scope

Use the actual Ruby `05_agent_loop` → `06_the_logger` diff to determine the
step delta, with these files as the behavioral source of truth:

| Ruby file | Step-6 responsibility |
|---|---|
| `lib/boukensha/logger.rb` | Session IDs, JSONL persistence, phase methods, usage normalization, execution metadata, and cost estimates |
| `lib/boukensha/agent.rb` | Logger injection and events around iterations, prompts, responses, tools, limits, and turn completion |
| `lib/boukensha.rb` | Package-wide config caching plus quiet/debug state and logger export |
| `lib/boukensha/prompt_builder.rb` | Public backend accessor needed by response metadata |
| `examples/example.rb` | Logger construction and step-6 example output |
| `README.md` | Session-log contract, logger API, debug behavior, and usage documentation |

The Ruby formatting-only changes in `config.rb` and `context.rb` are not Python
behavior and should not be copied. The removed Ruby MUD config accessors are
also unrelated cleanup; retain the Python accessors to avoid an unnecessary
step-6 regression. Backend provider implementations and model metadata require
no changes because Python step 5 already exposes `model`, usage metadata, and
`estimate_cost` through `Base`.

Ruby step 6 removes the unused `LoopError`. Mirror that public-surface change in
Python by removing its package export and definition if it is not referenced
elsewhere in the step. Do not otherwise re-port or restructure step-5 code.

## JSONL event contract

Each logger instance owns a `session_id` and appends to exactly one file. By
default the path is:

```text
<Config.dir>/sessions/<session-id>.jsonl
```

Support explicit `session_id`, destination `dir`, legacy explicit `log` path,
and an initial `snapshot` dict. The constructor must create parent directories,
open in append mode, and immediately write `session_start` merged with the
snapshot. An explicit `log` path takes precedence over `dir`.

Every written line must be a standalone JSON object containing:

- `phase`, with phase-specific fields;
- `session_id`, always set from the logger rather than caller data;
- `at`, as a timezone-aware ISO-8601 timestamp;
- JSON-compatible nested messages, tool arguments/results, raw responses, and
  metadata.

Writes must flush immediately so `tail` and crash-time inspection see complete
events. `close()` must be safe to call, and the implementation should support a
context manager if it can be added without changing the Ruby-visible contract.

The phase methods and their fields are:

| Method | Phase and fields |
|---|---|
| `iteration(n, max)` | `iteration`, `n`, `max` |
| `limit_reached(kind, n, max)` | `limit_reached`, `kind`, `n`, `max` |
| `turn_end(reason, iterations, tokens=None)` | `turn_end`, `reason`, `iterations`, `tokens` |
| `prompt(messages, tools)` | `prompt`, message count and serialized role/content pairs, tool count and names |
| `tool_call(name, args)` | `tool_call`, name and arguments |
| `tool_result(name, result, ok=True, error=None)` | `tool_result`, string result, status, and optional error |
| `response(text, usage=None, stop_reason=None, task=None, backend=None)` | `response`, stripped text, raw usage, stop reason, and execution metadata |
| `raw(data)` | `raw`, full provider response, but only in debug mode |

Keep `None` fields in the base event where Ruby emits JSON `null` (for example
`usage`, `stop_reason`, and tool-result `error`). Omit unavailable execution
metadata fields, matching Ruby's `compact` behavior.

## Implementation plan

### 1. Add package runtime state

- Extend `boukensha/__init__.py` with lazily cached `config()`, `quiet()`,
  `loud()`, `is_quiet()`, `debug()`, and `is_debug()` functions, using private
  module state as the Python equivalent of the Ruby module singleton methods.
- Keep debug disabled and quiet disabled by default.
- Export the public state helpers and `Logger` through `__all__`.
- Order imports so `Logger` can consult package debug/config state without a
  circular-import failure.
- Quiet state is part of the Ruby step-6 API but is not consumed by the logger
  or agent yet; preserve it without inventing output-suppression behavior.
- Remove the now-unused `LoopError` from `errors.py`, package imports, and
  `__all__`, after confirming no step-6 Python code references it.

### 2. Implement `boukensha/logger.py`

- Add `Logger.DEFAULT_SESSION_DIR = "sessions"` and read-only/publicly
  accessible `session_id` and `path` attributes.
- Generate default IDs as UTC `YYYYMMDDTHHMMSSZ-<8 lowercase hex chars>` using
  `datetime` and `secrets`, equivalent to Ruby's timestamp plus four random
  bytes.
- Resolve the default directory through the cached package `config().dir`,
  create parent directories with `pathlib`, and open the log as UTF-8 text in
  append mode.
- Serialize each event compactly with `json.dumps`, append one newline, and
  flush after every event. Use a JSON fallback only where necessary to retain
  useful string representations of otherwise non-serializable tool results;
  do not silently corrupt ordinary dict/list/provider payloads.
- Serialize prompt messages as `{"role": ..., "content": ...}` and omit
  `tool_use_id`, matching Ruby step 6.
- Treat context tools as the existing name-keyed dict: log its length and keys
  in insertion order.
- Implement task names using `task.task_name()` when available, otherwise
  `str(task)`. Derive provider names from backend class names by converting
  CamelCase to snake_case (including `OllamaCloud` → `ollama_cloud`).
- Normalize usage counts from Anthropic (`input_tokens`, `output_tokens`),
  OpenAI (`prompt_tokens`, `completion_tokens`), Gemini
  (`promptTokenCount`, `candidatesTokenCount`), and Ollama
  (`prompt_eval_count`, `eval_count`). Accept string or numeric integer values,
  ignore invalid values, and support either string-like/provider dict keys as
  applicable in Python.
- When both normalized counts exist and the backend supports
  `estimate_cost(input_tokens, output_tokens)`, log the estimate; otherwise
  omit `cost_usd`. Also include available task, provider, model, usage-unit,
  usage-level, input-token, and output-token metadata.
- Gate `raw()` on the package's live debug state, not a value captured when the
  logger was created, so enabling debug immediately before a run works.

### 3. Instrument `Agent`

- Add an optional `logger` constructor argument. When omitted, construct a new
  `Logger`, matching Ruby's default dependency while allowing tests and callers
  to inject a fake logger.
- Before the terminal wind-down, log `limit_reached` with the current and
  configured iteration counts.
- For every normal iteration, log `iteration` and the complete prompt before
  calling the client; then pass the raw response to `logger.raw()` before
  parsing it.
- Remove the step-5 console iteration/tool diagnostics. Step 6 records these as
  structured events rather than user-facing display output.
- On an ordinary final response, log the response and then a `turn_end` event
  with reason `completed` and the number of counted iterations.
- On a tool-use response, extract all tool blocks and log a response event
  before adding the assistant history. Use response text when present, or the
  exact descriptive placeholder `(tool use — N call[s])` when reasoning text
  is blank.
- Log every tool call. Wrap each registry dispatch in `try/except Exception` as
  the Python equivalent of Ruby `StandardError`: successful calls log `ok=True`;
  failures become `ERROR: <ExceptionClass>: <message>`, log `ok=False` and the
  error message, and are appended as tool results so one failed tool does not
  terminate the agent loop.
- Preserve the step-5 ordering guarantee: response log, assistant tool-use
  history, then each tool-call/tool-result event and corresponding context
  message.
- During wind-down, log the final/fallback response when an API response exists,
  log `turn_end` for both successful and `ApiError` paths, and keep the existing
  one-call/tools-disabled/400-token behavior. As in Ruby, an `ApiError` fallback
  has no response event because there is no provider response to describe.
- Add helpers to log responses and normalize the provider's usage container:
  prefer `response["usage"]`, then Gemini `usageMetadata`, then collect Ollama's
  top-level prompt/evaluation counts. Pass the raw top-level `stop_reason`, task,
  and `builder.backend` into the logger.

### 4. Update supporting API and example

- `PromptBuilder.backend` is already publicly readable in Python; retain it and
  add no redundant accessor.
- Construct and inject `Logger` in `examples/example.py`, with comments noting
  the default `.boukensha/sessions` location and debug opt-in.
- Change the example banner to `Step 6: The Logger`; preserve provider/model and
  limit display plus final response output.
- Replace the copied step-5 README with Python step-6 documentation covering
  session paths, JSONL shape, phase methods, response metadata/costs, logger
  construction overrides, debug state, task configuration, and the Python run
  command.
- Add `week1_baseline/bin/python/06_the_logger` using the established Python
  launcher convention and executable mode.
- Do not add dependencies. The logger uses only the standard library; retain
  the existing project requirements for configuration/API behavior.

## Target files

```text
week1_baseline/python/06_the_logger/
  README.md                              replace step-5 documentation
  boukensha/
    __init__.py                         runtime state + Logger export
    agent.py                            structured event instrumentation
    errors.py                           remove unused LoopError
    logger.py                           add JSONL session logger
  examples/example.py                   construct logger + step-6 banner
week1_baseline/bin/python/06_the_logger  add launcher
```

No backend, client, context, message, registry, task, or tool implementation
changes are expected. If implementation reveals a provider response shape not
covered by the existing agent normalization, address it in the narrowest file
and document why it is necessary rather than broadening the port.

## Verification

Use temporary directories and fake clients/backends so verification remains
offline and does not require API keys:

1. Compile all step-6 Python files and import `Logger`, `Agent`, and runtime
   state helpers from `boukensha`; confirm `LoopError` is no longer exported.
2. Create a logger with fixed session ID/path/snapshot and assert the file is
   created, `session_start` is the first valid JSON line, all lines contain the
   fixed session ID and ISO timestamp, and events are visible before close.
3. Exercise every logger phase and assert exact fields, message/tool
   serialization, stringified tool results, explicit null fields, and safe
   repeated `close()` behavior.
4. Verify default path resolution under an isolated `BOUKENSHA_DIR`, explicit
   `dir`, explicit `log` precedence, and generated session-ID format.
5. Feed Anthropic, OpenAI, Gemini, and Ollama usage samples into `response()`;
   assert normalized counts, provider/task/model metadata, snake-case provider
   naming, cost estimates, and omission when usage is incomplete or invalid.
6. Confirm `raw()` writes nothing by default, writes after `debug()` is called,
   and stops being emitted only according to the exposed debug-state contract.
7. Run an agent with fake client responses for tool-use then completion; assert
   event ordering, prompt snapshots, response text/placeholder behavior, tool
   result history, usage normalization, and final `turn_end`.
8. Make a fake registry tool raise an exception; assert the error is logged and
   converted into a tool-result message, and the next model response completes
   normally.
9. Force the iteration threshold and cover successful, blank, and `ApiError`
   wind-down paths; assert one `limit_reached`, exactly one terminal request,
   correct response logging where applicable, and exactly one `turn_end`.
10. Run the new launcher far enough to validate its path/import setup without
    making a network call. Use a real provider only when credentials or a local
    Ollama service are intentionally available.

## Acceptance criteria

- Creating an `Agent` without a logger automatically creates a session JSONL
  log under the configured Boukensha directory.
- Every normal agent path records enough ordered events to reconstruct prompts,
  provider responses, tool execution, limits, and turn completion.
- Response events normalize token usage across all five supported backends and
  calculate costs when model pricing and both counts are available.
- Tool exceptions are logged and returned to the model instead of crashing the
  run.
- Raw provider payloads appear only after debug mode is explicitly enabled.
- Logs are valid, line-delimited JSON and are flushed after every event.
- Existing step-5 agent behavior remains intact apart from replacing its
  console diagnostics with structured logging.
- README and example describe and demonstrate the Python step-6 API, and the
  Python launcher starts the correct directory.
