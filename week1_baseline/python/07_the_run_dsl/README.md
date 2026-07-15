# Step 7 — The `run` DSL

This step adds `boukensha.run`, a high-level entry point that constructs and
connects the player agent. Provide a task, optionally register tools in a
setup callback, and receive the agent's final string.

```python
from pathlib import Path

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
print(result)
```

`RunDSL` intentionally exposes only `tool`. Its decorator delegates to the
existing registry, so tool parameters and dispatch work exactly as in earlier
steps. Omit `configure` for a tool-free run.

## Options and defaults

`task` is required. The remaining keyword options are:

| Option | Default | Purpose |
|---|---|---|
| `configure` | `None` | Callback receiving one `RunDSL` |
| `system` | player task config | System prompt |
| `model` | player task config | Model name |
| `backend` | player task config | Provider name |
| `api_key` | provider environment variable | Credential override |
| `ollama_host` | `http://localhost:11434` | Local Ollama base URL |
| `log` | generated session path | Explicit JSONL path |
| `max_output_tokens` | player task config | Per-response output limit |

Supported providers are `anthropic`, `openai`, `gemini`, `ollama`, and
`ollama_cloud`. Credentials default to `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`,
`GEMINI_API_KEY`, and `OLLAMA_API_KEY` respectively; local Ollama requires no
key. Configuration and `.env` values are loaded from `BOUKENSHA_DIR` (or
`~/.boukensha`) before these defaults are resolved.

Each run automatically writes structured events beneath
`.boukensha/sessions`, unless `log` overrides the destination. The logger is
closed whether the agent finishes normally or raises an exception.

## Less plumbing

Earlier steps required callers to construct `Context`, `Registry`, a backend,
`PromptBuilder`, `Client`, `Logger`, and `Agent`, then add the first user
message. `run` now performs that common wiring in one call. Those lower-level
classes remain public for advanced construction.

## Run the example

Configure a provider and its credentials, then run:

```sh
./week1_baseline/bin/python/07_the_run_dsl
```
