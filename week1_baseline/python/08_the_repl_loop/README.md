# Step 8 — The REPL loop

This step adds `boukensha.repl`, an interactive counterpart to the one-shot
`run(task=...)` API. A REPL session registers tools once and preserves every
user and final assistant message, so later tasks can refer to earlier turns.

```python
from pathlib import Path
from boukensha import repl

def register_tools(dsl):
    @dsl.tool("read_file", description="Read a file from disk",
              parameters={"path": {"type": "string"}})
    def read_file(path):
        return Path(path).read_text()

repl(configure=register_tools)
```

`configure` is called once. Each entered task gets a fresh `Agent`, resetting
its action counter, while context, tools, provider client, and JSONL logger
remain shared for the whole session.

## Commands

| Command | Effect |
|---|---|
| `/help` | Show command help |
| `/quiet` | Toggle the existing quiet state on |
| `/loud` | Toggle the existing quiet state off |
| `/clear` | Clear messages and reset turn numbering; tools remain |
| `/exit`, `/quit` | Print `Goodbye.` and exit |
| Ctrl-D | Exit cleanly at EOF |
| Ctrl-C | Print `Interrupted.` and exit cleanly |

Built-in commands never enter the conversation or call the provider. An
unknown slash-prefixed line is an ordinary task. `/quiet` and `/loud` currently
only toggle package state: the JSONL logger does not read that flag, and final
answers remain visible.

Recoverable loop and API errors are printed and return to the prompt. HTTP 401
responses identify an authentication failure; unexpected programming errors
still propagate while the logger is closed.

## Configuration and options

The banner displays version `0.8.0`, resolved configuration directory,
provider/model, and API-key status. Directory precedence is an explicit
`BOUKENSHA_DIR`, an existing `.boukensha` in the current directory, then
`~/.boukensha`.

`repl` accepts the same optional keywords as `run`, except `task`:
`configure`, `system`, `model`, `backend`, `api_key`, `ollama_host`, `log`, and
`max_output_tokens`. Providers are `anthropic`, `openai`, `gemini`, `ollama`,
and `ollama_cloud`, with the same credential environment variables as `run`.
Local Ollama needs no key, so its banner may show the key as unset.

Use `run(task="...")` for one result and `repl()` for a persistent transcript.

## Run the example

```sh
./week1_baseline/bin/python/08_the_repl_loop
```
