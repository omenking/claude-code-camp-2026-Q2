# Python Port Plan — 08 · The REPL Loop

## Goal

Port the step-8 delta from `week1_baseline/ruby/08_the_repl_loop` into the
already-copied `week1_baseline/python/08_the_repl_loop` snapshot. The Python
directory currently matches the completed Python step 7, so preserve the
one-shot `run(...)` API while adding an interactive, multi-turn `repl(...)`
entry point with persistent conversation history and built-in commands.

The intended user experience is: optionally register tools once through the
existing setup callback, enter multiple tasks at a `boukensha> ` prompt, and
let every later task see the earlier user and assistant messages. The same
configuration, provider selection, limits, and JSONL session logger used by
`run(...)` should remain active for the lifetime of the REPL.

## Source of truth and scope

Use the actual Ruby `07_the_run_dsl` → `08_the_repl_loop` directory diff to
determine the increment, with these files as the behavioral source of truth:

| Ruby file | Step-8 responsibility |
|---|---|
| `lib/boukensha/repl.rb` | Prompt loop, commands, banner, turn execution, and recoverable errors |
| `lib/boukensha.rb` | Public `repl` orchestration, version wiring, interrupt handling, and logger cleanup |
| `lib/boukensha/agent.rb` | Persists every final assistant reply in the shared context |
| `lib/boukensha/context.rb` | Clears messages without removing tools or the system prompt |
| `lib/boukensha/client.rb` | Gives HTTP 401 a concise authentication error |
| `lib/boukensha/config.rb` | Adds a current-directory `.boukensha` fallback |
| `lib/boukensha/version.rb` | Introduces the public step version used by the banner |
| `examples/example.rb` | Replaces the one-shot example with an interactive session |
| `README.md` | Documents multi-turn behavior and REPL commands |

The Ruby README calls this “Step 7,” refers to a non-existent `/quiet` example
launcher path, and describes `Logger#turn` as new even though Python step 7
already implements it. Treat the directory name as step 8, document the actual
commands, and do not duplicate already-ported logger work.

Ruby's `/quiet` and `/loud` commands only toggle the existing package flag; the
current logger writes JSONL rather than detailed terminal output and does not
read that flag. Preserve that behavior for parity and call it out as a current
limitation instead of inventing a new console logging system in this increment.

## Python API shape

Keep the callback convention established by Python step 7:

```python
from boukensha import repl


def register_tools(dsl):
    @dsl.tool(
        "read_file",
        description="Read a file from disk",
        parameters={"path": {"type": "string"}},
    )
    def read_file(path):
        return Path(path).read_text()


repl(configure=register_tools)
```

Expose `repl` with the same keyword options as `run`, except for `task`:
`configure=None`, `system=None`, `model=None`, `backend=None`, `api_key=None`,
`ollama_host="http://localhost:11434"`, `log=None`, and
`max_output_tokens=None`. Export both `repl` and `Repl` from the package.

## Implementation plan

### 1. Add conversation-history primitives

- Add `Context.clear_messages()` to empty the existing message list while
  preserving the task, system prompt, registry, and registered tools. Prefer
  clearing the list in place so any existing reference to `context.messages`
  continues to observe the live history.
- Update every final-result path in `Agent.run()` to append an assistant
  message before returning:
  - the normal no-tool completion;
  - a successful iteration-limit wrap-up;
  - the fallback text returned when the wrap-up API call raises `ApiError`.
- Store exactly the text returned to the caller. Do not add another assistant
  message for intermediate tool-use responses because those are already added
  by `_handle_tool_calls`.
- Keep the one-shot `run(...)` result unchanged. It now retains the final reply
  briefly in its private context, which is required for behavior shared with
  the REPL and has no public one-shot regression.

### 2. Implement the `Repl` loop

- Create `boukensha/repl.py` with a public `Repl` class and
  `PROMPT = "boukensha> "` plus a help string listing the supported commands.
- Accept the already-constructed context, registry, builder, client, logger,
  task settings, effective limits, config directory, provider, model, version,
  and API key. Initialize the conversation turn counter to zero.
- In `start()`, print the startup banner once, prompt repeatedly, flush the
  prompt before reading, treat EOF/Ctrl-D as a clean exit, strip input, and
  ignore blank lines.
- Handle commands locally without adding them to context or invoking the API:
  - `/exit` and `/quit`: print `Goodbye.` and stop;
  - `/help`: print the command list;
  - `/quiet`: call the existing `quiet()` toggle and acknowledge it;
  - `/loud`: call the existing `loud()` toggle and acknowledge it;
  - `/clear`: call `context.clear_messages()`, reset the displayed/logged turn
    counter to zero, and acknowledge it.
- Treat unrecognized slash-prefixed input as a normal user task, matching the
  Ruby implementation.
- For each task, increment the turn counter, emit `logger.turn(n)`, append the
  user message, create an `Agent` over the shared dependencies and effective
  settings, run it, and print the returned final response. Constructing a new
  agent per turn intentionally resets the agent's per-turn iteration counter;
  the context, tools, client, backend, and logger remain shared.
- Catch `LoopError` and `ApiError` around an individual turn, print the Ruby-
  equivalent friendly error, and return to the prompt. Do not swallow other
  programming or tool errors beyond the handling the existing agent already
  provides.
- Build a banner containing the version, resolved configuration directory,
  provider/model, and whether a non-blank API key is present. A missing local
  Ollama API key may therefore display as unset, matching the Ruby behavior.

### 3. Add the top-level `repl(...)` entry point

- Add `repl(...)` to `boukensha/__init__.py`, export it in `__all__`, and also
  export `Repl` plus a public version constant such as `__version__ = "0.8.0"`.
- Resolve config, player task settings, system prompt, model, provider, and the
  provider-specific environment key exactly as `run(...)` does. Preserve
  Python's `is None` override semantics, including an explicit output limit of
  `0`.
- Create one `Context` and `Registry`, invoke `configure(RunDSL(registry))`
  exactly once, and then construct the selected backend, `PromptBuilder`,
  `Client`, effective limits, and `Logger` using the same five-provider mapping
  and session snapshot as `run(...)`.
- Pass those shared objects and banner metadata to `Repl(...).start()` and
  return its result (normally `None`).
- Catch `KeyboardInterrupt` at the public entry point, print `Interrupted.`,
  and exit cleanly. Always close a successfully created logger in `finally`,
  on normal exit, EOF, interrupt, or an unexpected exception, without masking
  the original error.
- Avoid changing the working `run(...)` orchestration beyond any small private
  helper extraction that prevents the provider/configuration logic from
  drifting between the two entry points.

### 4. Port the supporting Ruby deltas

- Update `Client.call()` so a final HTTP 401 raises
  `ApiError("authentication failed (401) — check your API key")`. Keep existing
  retry behavior for retryable statuses and the current detailed error for all
  other non-2xx responses.
- Change `Config._resolve_dir()` precedence to:
  1. an explicit `BOUKENSHA_DIR`;
  2. a `.boukensha` directory in the current working directory, if it exists;
  3. `~/.boukensha`.
- Update the `Config` docstring to describe the three-level precedence. Do not
  change `.env`, YAML, prompt, or MUD-setting behavior.
- Do not modify `Logger`: Python step 7 already has `turn(n)`, synchronous
  subscribers, session metadata, and flushing required by this increment.

### 5. Replace the example, README, and launcher

- Replace the copied step-7 example with `repl(configure=register_tools)`.
  Continue setting `BOUKENSHA_DIR` before importing `boukensha` so configuration
  caching is deterministic, and keep `read_file` and `list_directory` rooted in
  a deliberate step directory rather than the launcher's current directory.
- Replace the copied run-DSL README with Python step-8 documentation covering
  the one-shot versus multi-turn distinction, persistent history, command
  behavior, banner/config defaults, error handling, and the callback/decorator
  syntax. Note that `/quiet` and `/loud` currently only toggle state.
- Add `week1_baseline/bin/python/08_the_repl_loop` following the existing Python
  launcher convention, targeting the step-8 directory and its virtualenv
  interpreter, with executable mode.
- Do not add dependencies; stdin/stdout handling uses the standard library and
  this step composes the existing primitives.

## Target files

```text
week1_baseline/python/08_the_repl_loop/
  README.md                              replace step-7 documentation
  boukensha/
    __init__.py                         export/version/repl orchestration
    agent.py                            persist final assistant messages
    client.py                           friendly HTTP 401 error
    config.py                           cwd config-directory fallback
    context.py                          clear_messages
    repl.py                             add interactive loop
  examples/example.py                   use repl + setup callback
week1_baseline/bin/python/08_the_repl_loop add executable launcher
```

## Verification

Keep verification offline by using in-memory input/output and deterministic
fake agents/clients/backends rather than making a real provider request:

1. Compile every step-8 Python file and import `repl`, `Repl`, and the version
   constant from `boukensha`; confirm the step-7 `run` import still works.
2. Assert `Context.clear_messages()` removes all messages but preserves the
   system prompt, task, tools, and the identity of the message list.
3. Exercise normal completion, successful wrap-up, and failed wrap-up with a
   fake client; assert each returned final string is appended once as an
   assistant message and tool-use messages are not duplicated.
4. Drive `Repl.start()` with scripted input covering blank lines, `/help`,
   `/quiet`, `/loud`, `/clear`, `/exit`, `/quit`, EOF, and an unknown slash
   command. Assert commands do not reach the agent, prompts/output are correct,
   and clear resets both history and the next logged turn number.
5. Run two normal scripted turns and assert tools are registered once, a fresh
   agent gets a reset iteration count each turn, the shared context contains
   both complete user/assistant exchanges, and logger turn events are `1`, `2`.
6. Make individual turns raise `LoopError` and `ApiError`; assert the friendly
   messages are printed and the REPL accepts the next input. Make an unexpected
   exception and assert it still propagates.
7. Replace backend and REPL construction with fakes and exercise top-level
   `repl(...)` for all five providers. Assert constructor arguments, environment
   key mapping, explicit overrides (including output limit `0`), one configure
   callback call, logger snapshot contents, and logger closure.
8. Raise `KeyboardInterrupt` during the loop and assert `Interrupted.` is
   printed and the logger closes. Also assert logger closure on EOF, `/exit`,
   and unexpected exceptions.
9. Feed `Client.call()` final 401 and non-401 HTTP errors; assert only 401 uses
   the authentication-specific message and retryable behavior is unchanged.
10. Test config resolution in isolated directories for explicit environment,
    current-directory `.boukensha`, and home fallback precedence.
11. Run the new launcher with scripted `/exit` input to validate its path,
    imports, configuration, banner, and clean shutdown without a paid request.

## Acceptance criteria

- A caller can start an interactive session with `repl(...)` and an optional
  tool-registration callback, while `run(...)` remains available unchanged.
- Multiple tasks share the complete user/assistant transcript and registered
  tools; `/clear` removes only conversation history and resets the turn count.
- All built-in commands, EOF, and Ctrl-C terminate or continue exactly as
  documented, and recoverable per-turn errors do not kill the session.
- Provider/configuration defaults and explicit overrides match the run DSL,
  all activity uses one session logger, and that logger always closes.
- Final assistant replies are persisted exactly once across normal and wrap-up
  paths, enabling later turns to reason from prior answers.
- HTTP 401 and config-directory fallback behavior match the Ruby step-8 delta.
- The example, README, and executable launcher demonstrate the Python REPL
  without adding dependencies or unrelated logging behavior.
