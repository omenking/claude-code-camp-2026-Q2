# 04 · The API Client (Python)

## Setup

This step shares the single virtualenv at the **repo root**:

```bash
# from the repo root
python3 -m venv .venv
source .venv/bin/activate
pip install -r week1_baseline/python/04_api_client/requirements.txt
```

The launcher at `week1_baseline/bin/python/04_api_client` assumes `.venv`
already exists at the repo root and has these dependencies installed.

Running the example requires `~/.boukensha/settings.yaml` to set
`tasks.player.provider` to one of `anthropic` / `ollama` / `ollama_cloud` /
`openai` / `gemini`, with `tasks.player.model` set to a model present in that
backend's `MODELS` table. Unlike step 3, this step makes a **real** network
call, so (except for `ollama`, which needs no key) the matching API key
environment variable must be set to a genuine, working key — a placeholder
value will surface as an `ApiError` from a 401/403 response instead of
silently succeeding.

---

The API Client takes the payload assembled by `PromptBuilder` and sends it to
the API. One HTTP POST, one response. No tool loop yet — just proving the
round trip works.

## New Files

| File | Description |
|---|---|
| `boukensha/client.py` | Makes the HTTP request and parses the response |

## Updated Files

| File | Change |
|---|---|
| `boukensha/errors.py` | Added `ApiError` for failed HTTP requests |
| `boukensha/config.py` | `PROMPTS_DIR` comment updated to reflect that prompts ship alongside this step |
| `boukensha/tasks/base.py` | Error messages now reference `settings.yaml` (was `settings.yml`); `_fetch` now guards against non-dict `settings` |
| `prompts/system.md` | New default system prompt |
| `examples/example.py` | Registers `read_file`/`list_directory` tools, builds a `Client`, and prints the raw API response |

## How It Works

```
PromptBuilder
      ↓
Client
      ↓
POST to API endpoint
      ↓
Raw JSON response
```

## boukensha.Client

| Method | Description |
|---|---|
| `call(max_output_tokens=1024)` | POSTs the payload and returns the parsed JSON response |

## Task Configuration

This step uses the task-based configuration introduced in the earlier
baseline steps:

```yaml
tasks:
  player:
    provider: anthropic
    model: claude-haiku-4-5
    prompt_override:
      system: true
```

When `prompt_override.system` is true, Boukensha reads
`.boukensha/prompts/player/system.md`. Otherwise it falls back to this step's
shipped `prompts/system.md`.

Each backend validates the configured model at construction time. Unsupported
model names raise `UnsupportedModelError`, and supported models expose
backend-owned metadata such as `context_window`, `usage_unit`, and token cost
estimates for later logging steps.

## No Dependencies

`Client` uses only Python's standard library — `urllib.request`,
`urllib.error`, `json`, and `ssl`. No third-party HTTP libraries like
`requests` or `httpx`. This is intentional — the HTTP call itself is trivial
and should be visible, not hidden behind a library.

`urllib.request.urlopen` verifies TLS certificates against the system trust
store automatically for `https://` URLs, so no certificate configuration is
needed on any platform.

## What the Response Looks Like

The raw response shape differs between backends. This is what you get back
from `client.call()` before any processing:

### Anthropic
```json
{
  "id": "msg_01XY",
  "type": "message",
  "role": "assistant",
  "content": [
    { "type": "text", "text": "Sure, let me read that file." }
  ],
  "stop_reason": "end_turn",
  "usage": { "input_tokens": 42, "output_tokens": 18 }
}
```

### Ollama
```json
{
  "model": "llama3.2",
  "message": {
    "role": "assistant",
    "content": "Sure, let me read that file."
  },
  "done_reason": "stop",
  "done": true
}
```

When the model wants to call a tool the response looks different. Anthropic
uses `stop_reason: "tool_use"` and adds a `tool_use` block to `content`.
Ollama adds a `tool_calls` array to `message`. Handling those differences is
the job of step 5 — the Agent Loop.

The smoke test in this step only registers `read_file`/`list_directory` as
tool schemas and seeds a single `user` message asking what files are in "the
current directory" — with no prior turn narrowing that down to a specific
path, the typical response is a text-only reply (often asking for
clarification), not a `tool_use`/`tool_calls` response.

## Considerations

**The client raises `ApiError` on failure.** A non-2xx response means
something went wrong — bad API key, malformed payload, server error.
BOUKENSHA surfaces this explicitly rather than returning a confusing `None`
or partial response.

**Transient failures are retried with backoff.** Network-level failures
(timeouts, connection resets, DNS failures, TLS errors) and a fixed set of
retryable HTTP status codes (`408`, `409`, `429`, `500`, `502`, `503`, `504`)
are retried up to 3 times with exponential backoff (`0.5s`, `1.0s`, `2.0s`)
before `Client` gives up and raises `ApiError`.

**SSL is handled automatically.** `Client` lets `urllib.request` decide
whether to use TLS based on the URL scheme. Ollama running locally uses plain
`http://` so no TLS is involved; every other backend uses `https://` and gets
certificate verification for free.

## Run Example

```sh
./week1_baseline/bin/python/04_api_client
```
