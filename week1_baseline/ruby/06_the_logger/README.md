# Step 6 - The Logger

`Boukensha::Logger` records each agent run as structured JSON Lines. 
It is a file logger, not user-facing display output.


## Session Logs

Each `Boukensha::Logger` instance creates a session id and writes one log file for that session:

```text
.boukensha/sessions/<session-id>.jsonl
```

Every line is a complete JSON object with `session_id`, `at`, and `phase` fields, plus phase-specific data. This keeps logs grep/tail friendly and machine readable.

```json
{"phase":"session_start","session_id":"20260528T143011Z-a1b2c3d4","at":"2026-05-28T10:30:11-04:00"}
{"phase":"iteration","n":1,"session_id":"20260528T143011Z-a1b2c3d4","at":"2026-05-28T10:30:11-04:00"}
```

Model response lines include the active task, provider, model, normalized token counts, and estimated USD cost when the backend has token pricing data:

```json
{"phase":"response","task":"player","provider":"anthropic","model":"claude-haiku-4-5","input_tokens":1000,"output_tokens":100,"cost_usd":0.0015}
```

## Logger API

A plain object with one method per phase:

| Method | Phase | Logs |
|---|---|---|
| `iteration(n:)` | `iteration` | loop counter |
| `prompt(messages:, tools:, budget:)` | `prompt` | messages, tools, token budget |
| `tool_call(name:, args:)` | `tool_call` | tool name and arguments |
| `tool_result(name:, result:)` | `tool_result` | tool result |
| `response(text:, usage:, task:, backend:)` | `response` | response text, token usage, task/provider/model, estimated cost |
| `raw(data:)` | `raw` | raw provider response when debug is enabled |

## Task Configuration

Step 6 uses the task-based settings shape:

```yaml
tasks:
  player:
    provider: anthropic
    model: claude-haiku-4-5
    prompt_override:
      system: true
```

When `prompt_override.system` is true, the player task reads `.boukensha/prompts/player/system.md`. Otherwise it falls back to this step's shipped `prompts/system.md`.

Default usage:

```ruby
logger = Boukensha::Logger.new
agent = Boukensha::Agent.new(context: ctx, registry: registry,
                             builder: builder, client: client,
                             logger: logger)
```

You can also provide a session id or override the destination directory:

```ruby
Boukensha::Logger.new(session_id: "manual-session")
Boukensha::Logger.new(dir: "/tmp/boukensha-sessions")
```

For compatibility, `log:` still accepts an explicit file path, but normal iteration usage should write under `.boukensha/sessions`.

## Debug Events

Call `Boukensha.debug!` before running the agent to include raw provider responses:

```ruby
Boukensha.debug!
```

## Run Example

```sh
./week1_baseline/bin/06_the_logger 
```
