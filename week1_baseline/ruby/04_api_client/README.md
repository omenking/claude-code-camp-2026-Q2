# The API Client

The API Client takes the payload assembled by `PromptBuilder` and sends it to the API. One HTTP POST, one response. No tool loop yet — just proving the round trip works.



## New Files

| File | Description |
|---|---|
| `lib/boukensha/client.rb` | Makes the HTTP request and parses the response |
| `lib/boukensha/backends/base.rb` | Shared backend model validation and model metadata helpers |
| `lib/boukensha/tasks/base.rb` | Shared task configuration helpers for provider, model, and prompts |
| `lib/boukensha/tasks/player.rb` | Player task definition |
| `prompts/system.md` | Default system prompt used when the player task does not override it |

## Updated Files

| File | Change |
|---|---|
| `lib/boukensha/errors.rb` | Added `ApiError` for failed HTTP requests |
| `lib/boukensha/config.rb` | Reads `tasks.player` instead of top-level provider/model settings |
| `lib/boukensha/backends/*.rb` | Backends now own supported model tables with context windows and cost metadata |

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

## Boukensha::Client

| Method | Description |
|---|---|
| `call(max_output_tokens:)` | POSTs the payload and returns the parsed JSON response |

## Task Configuration

This step uses the task-based configuration introduced in the earlier baseline steps:

```yaml
tasks:
  player:
    provider: anthropic
    model: claude-haiku-4-5
    prompt_override:
      system: true
```

When `prompt_override.system` is true, Boukensha reads `.boukensha/prompts/player/system.md`.
Otherwise it falls back to this step's shipped `prompts/system.md`.

Each backend validates the configured model at construction time. Unsupported model names raise `UnsupportedModelError`, and supported models expose backend-owned metadata such as `context_window`, `usage_unit`, and token cost estimates for later logging steps.

## No Dependencies

`Client` uses Ruby's standard `net/http` library. No gems, no `bundle install`. This is intentional — the HTTP call itself is trivial and should be visible, not hidden behind a library.

## What the Response Looks Like

The raw response shape differs between backends. This is what you get back from `client.call` before any processing:

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

When the model wants to call a tool the response looks different. Anthropic uses `stop_reason: "tool_use"` and adds a `tool_use` block to `content`. Ollama adds a `tool_calls` array to `message`. Handling those differences is the job of step 5 — the Agent Loop.

## Output eaxmple

andrew ~/Sites/Claude-Code-Camp/iterations  $ ruby 03_api_client/examples/step3.rb                              
=== BOUKENSHA Step 4: API Client ===

Sending request to https://api.anthropic.com/v1/messages...

Raw response:
{"model"=>"claude-opus-4-5-20251101", "id"=>"msg_01Y3zL8dZKrdLqry6BoiyC4r", "type"=>"message", "role"=>"assistant", "content"=>[{"type"=>"text", "text"=>"I don't have a function available to list directory contents. I can only read files if you provide me with the specific file path.\n\nCould you either:\n1. Tell me which specific file(s) you'd like me to read\n2. Provide me with a list of the files in your directory\n\nIf you're working in a terminal, you can run `ls` (on Mac/Linux) or `dir` (on Windows) to see what files are available, and then let me know which ones you'd like me to look at!"}], "stop_reason"=>"end_turn", "stop_sequence"=>nil, "stop_details"=>nil, "usage"=>{"input_tokens"=>585, "cache_creation_input_tokens"=>0, "cache_read_input_tokens"=>0, "cache_creation"=>{"ephemeral_5m_input_tokens"=>0, "ephemeral_1h_input_tokens"=>0}, "output_tokens"=>118, "service_tier"=>"standard", "inference_geo"=>"not_available"}}

> The response is what we'd expect from Claude. got the message, saw the read_file tool, but told us it can't list directory contents because we only gave it a read_file tool, not a list_directory tool.

## Considerations

**The client raises `ApiError` on failure.** A non-2xx response means something went wrong — bad API key, malformed payload, server error. BOUKENSHA surfaces this explicitly rather than returning a confusing nil or partial response.

**SSL is handled automatically.** The client checks the URL scheme and enables SSL for `https` endpoints. Ollama running locally uses plain `http` so no SSL is needed.

**OpenSSL Certificate**

To keep things explainable and simpel we are using net/http.
Net HTTP has rough edges like supplying the correct SSL certificate
from your machine. 

HTTPParty can solve this but we are trying to avoid any libraries.

You will need to update the code based on your machines requirements.

ruby -e "require 'openssl'; puts OpenSSL::X509::DEFAULT_CERT_FILE"

## Run Example

```sh
./week1_baseline/bin/04_api_client 
```

## Review Considerations
- In the ollama.rb backend we harcoded the local address this should have been a env var that could default to the default ollama path, but we are going to keep it harcoded to avoid having to uplift all layers of our code.
- It looks like some generated code did not adhere to the stateless classes, there is some code that should be stateless eg. Client but will keep it the same for now.