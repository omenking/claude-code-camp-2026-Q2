# The Agent Loop

The Agent Loop is the heart of BOUKENSHA. Everything built before this — the structs, the registry, the prompt builder, the client — was setup. The loop is where the agent actually does work.

## New Files

| File | Description |
|---|---|
| `lib/boukensha/agent.rb` | The agent loop — sends requests, dispatches tools, and knows when to stop |
| `lib/boukensha/backends/base.rb` | Shared backend model validation and model metadata helpers |
| `lib/boukensha/tasks/base.rb` | Shared task configuration helpers for provider, model, and prompts |
| `lib/boukensha/tasks/player.rb` | Player task definition |
| `lib/boukensha/backends/openai.rb` | OpenAI Chat Completions backend |
| `lib/boukensha/backends/gemini.rb` | Google Gemini backend |
| `lib/boukensha/backends/ollama_cloud.rb` | Ollama Cloud backend (hosted Ollama, authenticated with an API key) |
| `prompts/system.md` | Default system prompt used when the player task does not override it |

## Updated Files

| File | Change |
|---|---|
| `lib/boukensha/errors.rb` | Added `LoopError` for runaway agents |
| `lib/boukensha/config.rb` | Reads `tasks.player` instead of top-level provider/model settings |
| `lib/boukensha/context.rb` | Carries the active task object alongside messages and tools |
| `lib/boukensha/prompt_builder.rb` | Added `parse_response`, delegating to the backend |
| `lib/boukensha/backends/anthropic.rb` | Model is configurable and validated via backend-owned metadata; added `parse_response` |
| `lib/boukensha/backends/ollama.rb` | Model is configurable and validated via backend-owned metadata; added `parse_response` and `assistant_message` |
| `lib/boukensha/backends/*.rb` | Backends own supported model tables with context windows and cost metadata |

## How It Works

```
send messages to API
        ↓
stop_reason == "tool_use"?
    yes → extract tool calls
        → dispatch each tool via Registry
        → inject results as tool_result messages
        → go back to top
    no  → return final text response
```

## Boukensha::Agent

| Method | Description |
|---|---|
| `run` | Starts the loop and returns the final text response when the agent is done |

## Every Backend Speaks the Same Normalized Shape

Five providers means five different response formats — Anthropic nests tool calls inside `content`, Ollama puts them in `message.tool_calls`, OpenAI nests them under `choices[0].message.tool_calls`, and Gemini calls them `functionCall` parts. Rather than teach the Agent loop about each of these, every backend implements `parse_response`, converting its raw response into one common shape:

```ruby
{
  stop_reason: "tool_use" | "end_turn",
  content: [
    { "type" => "text", "text" => "..." },
    { "type" => "tool_use", "id" => "...", "name" => "...", "input" => { ... } }
  ]
}
```

`Boukensha::Agent` only ever sees this shape — it calls `@builder.parse_response(response)`, which delegates to the backend, and never inspects a raw provider response. That's what let `agent.rb` shrink from a handful of private helpers juggling two response shapes down to a single `if parsed[:stop_reason] == "tool_use"` branch.

The conversion also runs in reverse. When the conversation history is replayed on the next request, Ollama, Ollama Cloud, OpenAI, and Gemini each rebuild a provider-specific assistant message from the normalized `content` blocks via a private `assistant_message` (or `assistant_parts`) method — the inverse of `parse_response`. Anthropic's `content` array doubles as both the normalized shape and the wire format, so it needs no extra conversion.

**Tool call IDs aren't universal.** Anthropic and OpenAI assign every tool call a unique `id`, echoed back in the `tool_result`. Ollama, Ollama Cloud, and Gemini don't assign call ids at all — those backends reuse the tool's `name` as its `id` and match the `tool_result` back to the call by name.

## Task Configuration

This step uses the task-based configuration introduced in the earlier baseline steps:

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

When `prompt_override.system` is true, Boukensha reads `.boukensha/prompts/player/system.md`.
Otherwise it falls back to this step's shipped `prompts/system.md`.
`max_iterations` controls model round-trips per turn before wind-down, and `max_output_tokens` is passed to each model reply.

Every backend still takes a `model:` keyword argument; `examples/example.rb` now gets both provider and model from `tasks.player`, then builds the matching backend. The backend validates the model at construction time and exposes metadata such as `context_window`, `usage_unit`, and token cost estimates for later logging steps.

| Provider | Backend | Requires |
|---|---|---|
| `anthropic` | `Boukensha::Backends::Anthropic` | `ANTHROPIC_API_KEY` |
| `openai` | `Boukensha::Backends::OpenAI` | `OPENAI_API_KEY` |
| `gemini` | `Boukensha::Backends::Gemini` | `GEMINI_API_KEY` |
| `ollama` | `Boukensha::Backends::Ollama` | a local Ollama server (`host:` defaults to `http://localhost:11434`) |
| `ollama_cloud` | `Boukensha::Backends::OllamaCloud` | `OLLAMA_API_KEY` |

```ruby
# Anthropic
backend = Boukensha::Backends::Anthropic.new(
  api_key: ENV.fetch("ANTHROPIC_API_KEY"),
  model:   "claude-sonnet-4-5"
)

# Ollama running locally
backend = Boukensha::Backends::Ollama.new(model: "gemma4")

# Ollama Cloud
backend = Boukensha::Backends::OllamaCloud.new(
  api_key: ENV.fetch("OLLAMA_API_KEY"),
  model:   "kimi-k2.5:cloud"
)
```

## What the Loop Looks Like

Running the example produces output like this:

```
=== BOUKENSHA Step 5: Agent Loop ===

[iteration 1]
  tool call → list_directory({:path=>"."})
  tool result → README.md, examples, lib

[iteration 2]
  tool call → read_file({:path=>"lib/boukensha.rb"})
  tool result → module Boukensha...

=== FINAL RESPONSE ===
Here are the files in the current directory: README.md, examples, lib.
The contents of lib/boukensha.rb are...
```

## Considerations

**The assistant message must be stored before the tool result.** The Anthropic API requires the assistant's tool_use block to appear in the message history before its corresponding tool_result. BOUKENSHA handles this in `handle_tool_calls` — get the order wrong and the API rejects the request.

**The model can call multiple tools in one turn.** The loop handles this by iterating over all tool_use blocks in a single response before making the next API call.

**`MAX_ITERATIONS` is a turn ceiling.** A poorly prompted agent can loop forever if the model keeps calling tools. BOUKENSHA stops starting new work after 25 iterations by default and makes one short wrap-up call with tools disabled. This keeps the turn bounded while still returning a useful final response.

**The agent has no way to stop itself.** The model signals it is done via `stop_reason: "end_turn"`. BOUKENSHA watches for that signal and exits the loop. The agent never decides unilaterally to stop.


## Run Example

```sh
./week1_baseline/bin/05_agent_loop 
```
