# Step 6 — The Logger

`boukensha.Logger` records each agent run as structured JSON Lines. It is a
session log for inspection and tooling, not user-facing display output.

## Session logs

Each logger owns one session ID and appends to one file:

```text
.boukensha/sessions/<session-id>.jsonl
```

Every line is an independently valid JSON object containing `phase`,
`session_id`, a timezone-aware ISO-8601 `at` timestamp, and phase-specific
fields. Writes are flushed immediately, making the file useful with `tail` and
after an interrupted run.

```json
{"phase":"session_start","session_id":"20260528T143011Z-a1b2c3d4","at":"2026-05-28T10:30:11-04:00"}
{"phase":"iteration","n":1,"max":25,"session_id":"20260528T143011Z-a1b2c3d4","at":"2026-05-28T10:30:11-04:00"}
```

The logger records `session_start`, `iteration`, `prompt`, `response`,
`tool_call`, `tool_result`, `limit_reached`, `turn_end`, and (in debug mode)
`raw` phases. Response events retain provider usage and also normalize input
and output token counts for Anthropic, OpenAI, Gemini, Ollama, and Ollama Cloud.
They include task, provider, model, usage unit/level, and estimated USD cost
when those values are available.

## Usage

An agent creates a logger automatically, or one can be injected explicitly:

```python
from boukensha import Agent, Logger

logger = Logger()
agent = Agent(
    context=ctx,
    registry=registry,
    builder=builder,
    client=client,
    logger=logger,
)
```

The constructor supports controlled destinations and initial session data:

```python
Logger(session_id="manual-session")
Logger(dir="/tmp/boukensha-sessions")
Logger(log="/tmp/specific.jsonl", snapshot={"campaign": "demo"})
```

An explicit `log` file takes precedence over `dir`. `Logger` can also be used
as a context manager, and `close()` is safe to call repeatedly.

Raw provider payloads are omitted by default. Enable them immediately before a
run with the package-wide live debug state:

```python
import boukensha

boukensha.debug()
```

The package also exposes `quiet()`, `loud()`, and `is_quiet()`. Quiet state is
public runtime state in this step; it does not suppress agent output yet.

## Task configuration

Provider, model, prompts, and loop limits come from the player task settings:

```yaml
tasks:
  player:
    provider: anthropic
    model: claude-haiku-4-5
    prompt_override:
      system: true
    max_iterations: 25
    max_output_tokens: 1024
```

When `prompt_override.system` is true, the task reads
`.boukensha/prompts/player/system.md`; otherwise it uses this step's shipped
`prompts/system.md`.

## Run the example

Configure the selected provider and its credentials, then run:

```sh
./week1_baseline/bin/python/06_the_logger
```
