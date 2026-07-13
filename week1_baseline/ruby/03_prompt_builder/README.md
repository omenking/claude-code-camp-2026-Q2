# The Prompt Builder

Because LLM access, cost and quality are cosntantly changing, we want to be able to switch between multiple LLMs that will drive the agent loop.

There are serveral SDKs that provide access to many LLMs but in practice we only really need to focus on top-tier models:
- anthropic family
- openai family
- gemini family
- ollama cloud eg. kimi, minimax, llama

The Prompt Builder serializes `Context` for the exact format each API expects. 
The `PromptBuilder` delegates to whichever backend you pass in.

PromptBuilder does not call the API, we are simply preparing the format for API calls.

Configuration is task-based here, carried forward from the registry step. The
`player` task owns its provider, model, and prompt override settings, and the
context records the task that the prompt is being built for.

## New Files

| File | Description |
|---|---|
| `lib/boukensha/prompt_builder.rb` | Delegates serialization to the active backend |
| `lib/boukensha/tasks/base.rb` | Abstract task helper for provider/model and prompt resolution |
| `lib/boukensha/tasks/player.rb` | The concrete player task used by the main loop |
| `prompts/system.md` | Default system prompt used when a task does not override it |
| `lib/boukensha/backends/base.rb` | Shared backend contract for model validation and model metadata |
| `lib/boukensha/backends/anthropic.rb` | Serializes context into the Anthropic API format |
| `lib/boukensha/backends/ollama.rb` | Serializes context into the Ollama API format |
| `lib/boukensha/backends/ollama_cloud.rb` | Serializes context into the Ollama Cloud API format |
| `lib/boukensha/backends/openai.rb` | Serializes context into the OpenAI Chat Completions format |
| `lib/boukensha/backends/gemini.rb` | Serializes context into the Gemini `generateContent` format |

## How It Works

```
Context (Ruby objects)
        ↓
PromptBuilder
        ↓
Backend (Anthropic, OpenAI, Gemini, or Ollama)
        ↓
API Payload (plain hashes and arrays)
        ↓
POST to API
```

## Boukensha::PromptBuilder

| Method | Description |
|---|---|
| `to_messages` | Delegates message serialization to the backend |
| `to_tools` | Delegates tool serialization to the backend |
| `to_api_payload` | Assembles the complete payload ready to POST |
| `headers` | Returns the correct headers for the backend |
| `url` | Returns the correct endpoint URL for the backend |

## Backends

Each API has its own conventions for how data is expected. Anthropic and Gemini are the most alike (system prompt as a top-level field), while OpenAI and Ollama share the same `function`-wrapped tool schema.

Backends also own their supported model table. A backend refuses to initialize
with an unknown model, so `settings.yaml` cannot silently select an unsupported
or misspelled model. Each model entry carries:

| Key | Meaning |
|---|---|
| `context_window` | The model's known token context window |
| `cost_per_million.input` | USD input token price per million tokens, when known |
| `cost_per_million.output` | USD output token price per million tokens, when known |
| `usage_unit` | `:tokens`, `:local_compute`, or `:ollama_cloud_usage` |
| `usage_level` | Ollama Cloud usage tier, when applicable |

Backend instances expose `context_window`, `input_token_cost_per_million`,
`output_token_cost_per_million`, `usage_unit`, `usage_level`, and
`estimate_cost(input_tokens:, output_tokens:)`.
For local Ollama models, token API cost is `0.0`. For Ollama Cloud, public
pricing is plan/usage based rather than token based, so `estimate_cost` returns
`nil`.

The prices in this step are static tutorial data, current as of June 16, 2026,
and should be reviewed whenever the selected model set changes.

### Boukensha::Backends::Anthropic

Talks to `https://api.anthropic.com/v1/messages`. 
Requires an `ANTHROPIC_API_KEY`. Supported models are listed in
`Boukensha::Backends::Anthropic::MODELS`.

### Boukensha::Backends::Ollama

Talks to `http://localhost:11434/api/chat`. 
Requires `ollama serve` running locally. No API key needed. Supported models are
listed in `Boukensha::Backends::Ollama::MODELS`.

### Boukensha::Backends::OllamaCloud

Talks to `https://ollama.com/api/chat`. Requires an `OLLAMA_API_KEY`. Supported
models are listed in `Boukensha::Backends::OllamaCloud::MODELS`.

### Boukensha::Backends::OpenAI

Talks to `https://api.openai.com/v1/chat/completions`. 
Requires an `OPENAI_API_KEY`. Supported models are listed in
`Boukensha::Backends::OpenAI::MODELS`.

### Boukensha::Backends::Gemini

Talks to `https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent`.
Requires a `GEMINI_API_KEY`. Supported models are listed in
`Boukensha::Backends::Gemini::MODELS`.

### System Prompt

Anthropic and Gemini send the system prompt as a top-level field, separate from the messages array. Ollama and OpenAI put it inside the messages array as a `role: system` message.

```json
// Anthropic
{ "system": "You are a MUD player assistant.", "messages": [ ... ] }

// Gemini
{ "systemInstruction": { "parts": [{ "text": "You are a MUD player assistant." }] }, "contents": [ ... ] }

// Ollama / OpenAI
{ "messages": [ { "role": "system", "content": "You are a MUD player assistant." }, ... ] }
```

### Tool Results

Anthropic wraps tool results in a user message. Ollama and OpenAI use their own `role: tool` message type (with slightly different identifier fields). Gemini wraps results in a `functionResponse` part on a `user` message.

```json
// Anthropic
{ "role": "user", "content": [{ "type": "tool_result", "tool_use_id": "toolu_01X", "content": "A damp stone corridor stretches north. Torches flicker on the walls." }] }

// Ollama
{ "role": "tool", "tool_name": "look", "content": "A damp stone corridor stretches north. Torches flicker on the walls." }

// OpenAI
{ "role": "tool", "tool_call_id": "toolu_01X", "content": "A damp stone corridor stretches north. Torches flicker on the walls." }

// Gemini
{ "role": "user", "parts": [{ "functionResponse": { "name": "toolu_01X", "response": { "content": "A damp stone corridor stretches north. Torches flicker on the walls." } } }] }
```

### Tool Definitions

Anthropic uses `input_schema`. Ollama and OpenAI wrap everything in a `function` envelope with `parameters`. Gemini wraps tools in a `functionDeclarations` array.

```json
// Anthropic
{ "name": "move", "description": "Move the player in a direction (north, south, east, west, up, down)", "input_schema": { "type": "object", "properties": { "direction": { "type": "string", "description": "The direction to move" } }, "required": ["direction"] } }

// Ollama / OpenAI
{ "type": "function", "function": { "name": "move", "description": "Move the player in a direction (north, south, east, west, up, down)", "parameters": { "type": "object", "properties": { "direction": { "type": "string", "description": "The direction to move" } }, "required": ["direction"] } } }

// Gemini
{ "functionDeclarations": [ { "name": "move", "description": "Move the player in a direction (north, south, east, west, up, down)", "parameters": { "type": "object", "properties": { "direction": { "type": "string", "description": "The direction to move" } }, "required": ["direction"] } } ] }
```

### Message Roles

Anthropic, Ollama, and OpenAI all use `assistant` for the model's turn. Gemini calls it `model`.

```json
// Anthropic / Ollama / OpenAI
{ "role": "assistant", "content": "Let me take a look around first." }

// Gemini
{ "role": "model", "parts": [{ "text": "Let me take a look around first." }] }
```

## Considerations

**The conversation is stateless.** The model has no memory between turns. Every API call includes the entire history from the beginning. BOUKENSHA is responsible for carrying that state.

**Tool results are user messages on Anthropic.** This feels counterintuitive the result came from BOUKENSHA, not the human but it reflects how the Anthropic API models the conversation. Ollama, OpenAI, and Gemini all handle this with dedicated message/part types instead.

**The agent only sees schemas.** The `description` field on each tool is the only thing the agent uses to decide which tool to call. The actual block never leaves BOUKENSHA.

## Run Example

```sh
./week1_baseline/bin/03_prompt_builder 
```
