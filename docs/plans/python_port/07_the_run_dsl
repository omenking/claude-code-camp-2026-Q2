# Python Port Plan — 07 · The `run` DSL

## Goal

Port the step-7 delta from `week1_baseline/ruby/07_the_run_dsl` into the
already-copied `week1_baseline/python/07_the_run_dsl` snapshot. The Python
directory currently matches the completed Python step 6, so preserve the agent
loop and structured logging behavior while adding a single high-level entry
point that constructs and connects the existing primitives.

The intended user experience is: provide a task, optionally register tools in
a small setup callback, and receive the agent's final string. Callers should no
longer need to manually construct `Context`, `Registry`, a backend,
`PromptBuilder`, `Client`, `Logger`, or `Agent` for the common player-task path.

## Source of truth and scope

Use the actual Ruby `06_the_logger` → `07_the_run_dsl` diff to determine the
step delta, with these files as the behavioral source of truth:

| Ruby file | Step-7 responsibility |
|---|---|
| `lib/boukensha.rb` | Top-level `run`, configuration/default resolution, backend construction, logger snapshot, cleanup, and component wiring |
| `lib/boukensha/run_dsl.rb` | Restricted tool-registration host object |
| `lib/boukensha/logger.rb` | `turn` events and synchronous event subscribers |
| `lib/boukensha/errors.rb` | Reintroduces the public `LoopError` type |
| `examples/example.rb` | Replaces manual plumbing with the new entry point |
| `README.md` | Explains the high-level API and before/after usage |

The Ruby `config.rb` delta restores MUD accessors that Python step 6 already
has; no Python config change is needed. The Ruby `context.rb` delta is
formatting-only. Do not alter backends, the client, prompt builder, registry,
agent behavior, task settings, dependencies, or prompt contents unless
implementation exposes a concrete incompatibility.

Ruby's README title and prose call this “Step 6” and its option table mentions
stale `token_budget`/`max_tokens` names. The directory and example establish
that this is step 7, while the implementation accepts `max_output_tokens`.
Document the implemented API rather than copying those inconsistencies.

## Python DSL shape

Ruby uses `instance_eval` and a block whose `self` becomes a `RunDSL`. Python
has no direct equivalent, so expose an explicit setup callback:

```python
from boukensha import run


def register_tools(dsl):
    @dsl.tool(
        "read_file",
        description="Read a file from disk",
        parameters={"path": {"type": "string"}},
    )
    def read_file(path):
        return Path(path).read_text()


result = run(task="Summarise README.md", configure=register_tools)
```

Implement `run` with `task` required and `configure=None`, plus keyword options
`system=None`, `model=None`, `backend=None`, `api_key=None`,
`ollama_host="http://localhost:11434"`, `log=None`, and
`max_output_tokens=None`. `configure`, when supplied, receives exactly one
`RunDSL` instance. The callback may use `@dsl.tool(...)`; the method simply
delegates to the existing `Registry.tool` decorator and returns it unchanged.

`RunDSL` intentionally publishes only `tool`. Its registry reference remains
an implementation detail (a leading-underscore attribute); this is API
containment, not a security boundary.

## Implementation plan

### 1. Add `RunDSL`

- Create `boukensha/run_dsl.py` with a `RunDSL` class initialized from a
  `Registry`.
- Implement `tool(name, description, parameters=None)` as a transparent
  delegate to `registry.tool(...)`, preserving the existing decorator calling
  convention and the registry's `{}` default behavior.
- Export `RunDSL` from `boukensha/__init__.py` and include it in `__all__` so
  the small DSL object can be imported and tested independently.

### 2. Implement the top-level `run(...)`

- Add `run(...)` to `boukensha/__init__.py` and export it. Keep orchestration
  in a private helper/module if needed to avoid making the initializer hard to
  read, but preserve lazy package configuration and avoid circular imports.
- Resolve the cached `config()` first so its `.env` file is loaded before API
  key lookup. Use `Player` as the task class and obtain
  `config().tasks(Player.task_name())`.
- Resolve omitted values through the player task:
  `Player.system_prompt(...)` with the user and shipped prompt directories,
  `Player.model(settings)`, and `Player.provider(settings)`. Treat only `None`
  as omitted so explicit Python values are not accidentally replaced by
  truthiness checks.
- Resolve a missing API key from the provider-specific environment variable:
  `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `GEMINI_API_KEY`, or
  `OLLAMA_API_KEY`; local Ollama needs no key.
- Create `Context(task=Player, system=...)` and `Registry`, then invoke
  `configure(RunDSL(registry))` before backend construction, matching Ruby's
  registration order.
- Construct the selected backend for all five existing providers. Pass
  `ollama_host` only to local `Ollama`; pass the selected model and applicable
  API key to the other constructors. Accept the same canonical provider
  strings used by task configuration.
- Raise a clear `ValueError` for an unknown provider and list
  `anthropic`, `openai`, `gemini`, `ollama`, and `ollama_cloud` in the message.
- Construct `PromptBuilder`, `Client`, and an effective iteration limit from
  `Player.max_iterations(settings)`. Resolve the effective output limit from
  the explicit argument when it is not `None`, otherwise from
  `Player.max_output_tokens(settings)`.
- Create `Logger(log=log, snapshot=...)` with task name, effective iteration
  and output limits, model, and provider. The normal default must still write
  beneath `.boukensha/sessions`.
- Create `Agent` with all constructed dependencies, the task settings, and
  both effective limits; append the supplied task as the first user message
  and return `agent.run()` unchanged.
- Close the logger in `finally` after it has been created so it closes on
  success and on exceptions from the agent/client. Do not hide the original
  exception. Failures that occur before logger creation require no cleanup.

### 3. Extend logger events and public errors

- Add `Logger.turn(n)` and write `{"phase": "turn", "n": n}` through the
  existing event pipeline. It is part of the Ruby step delta even though
  `run` and `Agent` do not call it yet.
- Add `Logger.subscribe(callback)`, retain callbacks in registration order,
  and notify each synchronously after the event has been written and flushed.
- Pass subscribers the phase-specific event dict, matching Ruby: do not add
  the persisted `session_id` or `at` fields to the callback payload and do not
  mutate the caller's event. Session-start events emitted by `__init__` occur
  before callers can subscribe.
- Preserve callback order and normal exception propagation; do not add a new
  background thread, buffering scheme, or error-swallowing policy.
- Re-add `LoopError` to `boukensha/errors.py`, import it from the package, and
  include it in `__all__`. It remains unused by the current agent, matching
  the Ruby step-7 public surface.

### 4. Replace the example with DSL usage

- Set `BOUKENSHA_DIR` before importing `boukensha`, using a path derived from
  `__file__`, so the cached configuration sees the intended repository-local
  directory.
- Import only the high-level API needed by the example (plus standard-library
  path helpers), print the step-7 banner and cached config, and remove all
  manual component/backend selection code.
- Define a setup callback that registers `read_file` and `list_directory`
  through `RunDSL.tool` decorators. Continue resolving requested paths against
  the step directory so behavior is independent of the launcher's working
  directory.
- Call `run(task=..., configure=...)`, then print its returned final response.
  Keep comments explaining that task defaults and credentials come from the
  Boukensha config and may be overridden with `run` keyword arguments.

### 5. Update documentation and launcher

- Replace the copied logger README with a Python step-7 README centered on the
  `run` entry point, the `RunDSL` callback/decorator syntax, supported options
  and providers, config/env defaults, automatic session logging, cleanup, and
  the before/after reduction in plumbing.
- Mention that callers can omit `configure` for tool-free runs and can still
  use the lower-level classes directly for advanced construction.
- Add `week1_baseline/bin/python/07_the_run_dsl` following the existing Python
  launcher convention, targeting the step-7 directory and virtualenv Python,
  with executable mode.
- Do not add dependencies; this step composes existing functionality.

## Target files

```text
week1_baseline/python/07_the_run_dsl/
  README.md                              replace step-6 documentation
  boukensha/
    __init__.py                         export RunDSL/LoopError/run + orchestration
    errors.py                           re-add LoopError
    logger.py                           turn events + subscribers
    run_dsl.py                          add callback host
  examples/example.py                   use run + setup callback
week1_baseline/bin/python/07_the_run_dsl add launcher
```

## Verification

Keep verification offline by replacing or monkeypatching the agent/backend
boundary where a real API call would otherwise occur:

1. Compile every step-7 Python file and import `run`, `RunDSL`, and `LoopError`
   from `boukensha`.
2. Build a `RunDSL` around a real context/registry, register a decorated tool,
   and assert its schema is stored and dispatch returns the decorated
   function's result.
3. Exercise `Logger.turn` and multiple subscribers in a temporary directory;
   assert the JSONL event contains session metadata, callbacks run in order
   after the line is visible, and callback payloads contain only the original
   event fields.
4. Replace constructed agents/backends with deterministic fakes and run the
   top-level function once per provider. Assert the correct backend class and
   constructor arguments, including the local Ollama host and each environment
   key mapping.
5. With isolated configuration, assert omitted system/model/provider/limits
   resolve through `Player`, while explicit system/model/backend/API key/output
   limit values win. Include an explicit output limit of `0` to guard against
   truthiness fallback.
6. Assert the setup callback runs once before the agent, all registered tools
   reach its context, the task becomes the initial user message, the logger
   snapshot contains the five expected values, and `run` returns the agent's
   final string.
7. Make the fake agent raise and assert the logger is still closed; also cover
   a run without a setup callback.
8. Assert an unsupported provider raises the documented `ValueError` without
   attempting a network request.
9. Run the new launcher far enough to validate its directory/import/config
   setup without sending a paid request. Use a real backend only when matching
   credentials or a deliberately running local Ollama service are available.

## Acceptance criteria

- A caller can execute the configured player agent with one `run(...)` call
  and an optional tool-registration callback.
- All five existing providers are constructed with the correct model,
  credential, and local-host behavior, and explicit run options override task
  defaults.
- The logger's session-start snapshot describes the effective run and the log
  is closed on both successful and exceptional agent exits.
- `RunDSL` exposes the existing registry decorator without leaking orchestration
  responsibilities into tool definitions.
- Logger subscribers observe flushed events synchronously, and `turn` and
  `LoopError` match the Ruby step-7 surface.
- The example and README demonstrate the Python DSL, and the new launcher
  targets step 7 without regressing step-6 logging or agent behavior.
