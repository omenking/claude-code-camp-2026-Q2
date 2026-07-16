# Python Port Plan — 05 · The Agent Loop

## Goal

Port the step-5 delta from `week1_baseline/ruby/05_agent_loop` into the
already-copied `week1_baseline/python/05_agent_loop` snapshot. The Python
directory currently matches the completed Python step 4, so do not recopy or
re-port earlier work.

The main addition is `boukensha/agent.py`, but the loop depends on a small
protocol added across every backend: raw provider responses are normalized to
one content-block shape, normalized assistant tool calls can be serialized
back into provider-specific history, and tools can be explicitly disabled for
the terminal wind-down request.

## Source of truth

Read these Ruby files before implementation:

| Ruby file | Step-5 responsibility |
|---|---|
| `README.md` | Loop behavior, normalized response contract, limits, and example output |
| `lib/boukensha/agent.rb` | New agent loop, tool dispatch, limit handling, and wind-down behavior |
| `lib/boukensha/backends/{anthropic,ollama,ollama_cloud,openai,gemini}.rb` | Response normalization, assistant-message replay, and tool overrides |
| `lib/boukensha/client.rb` | Passes an optional tool override into payload construction |
| `lib/boukensha/prompt_builder.rb` | Delegates response parsing and tool overrides to the backend |
| `lib/boukensha/tasks/base.rb` | Adds configurable iteration and output-token limits |
| `lib/boukensha/errors.rb` | Adds `LoopError` |
| `lib/boukensha.rb` | Exposes `Agent` |
| `examples/example.rb` | End-to-end agent-loop example |

Use the actual Ruby `04_api_client` → `05_agent_loop` diff to determine scope.
The Ruby `config.rb` changes are not required Python behavior: the one-line
method rewrites are syntax-only, and the changed `PROMPTS_DIR` traversal points
outside the step directory. Keep Python's existing, correct prompt path.

## Normalized response contract

All backend `parse_response(response)` methods must return:

```python
{
    "stop_reason": "tool_use" or "end_turn",
    "content": [
        {"type": "text", "text": "..."},
        {
            "type": "tool_use",
            "id": "...",
            "name": "...",
            "input": {...},
        },
    ],
}
```

The `Agent` must only consume this normalized shape; it must not branch on the
active provider or inspect raw provider response structures.

Provider-specific rules:

- Anthropic already uses compatible content blocks. Map only an exact raw
  `stop_reason == "tool_use"` to normalized `tool_use`; treat all other stop
  reasons as `end_turn`.
- Ollama and Ollama Cloud read text from `message.content` and calls from
  `message.tool_calls`. They do not supply call IDs, so use the function name
  for both `id` and `name`.
- OpenAI reads `choices[0].message`, preserves each tool call's real ID, and
  JSON-decodes `function.arguments` into the normalized `input` dict.
- Gemini reads `candidates[0].content.parts`, converts `text` and
  `functionCall` parts, and uses the function name as the synthetic call ID.
- Empty or missing response nodes should normalize to an empty content list
  and `end_turn`, matching the defensive Ruby lookups.

## Implementation plan

### 1. Add task limits and public exports

- Add `DEFAULT_MAX_ITERATIONS = 25` and
  `DEFAULT_MAX_OUTPUT_TOKENS = 1024` to `boukensha/tasks/base.py`.
- Add `max_iterations(settings)` and `max_output_tokens(settings)` class
  methods. Both read their setting through `_fetch`, fall back only when the
  value is `None`, and coerce configured values with `int(...)` so strings
  such as `"25"` behave like Ruby's `Integer(value)`.
- Add `LoopError` to `boukensha/errors.py` and export it from
  `boukensha/__init__.py`. The current Ruby loop winds down instead of raising
  it, but the exception is still part of the step-5 public surface.
- Export the new `Agent` class from `boukensha/__init__.py` and include both
  additions in `__all__`.

### 2. Thread tool overrides through request construction

- Change `PromptBuilder.to_api_payload` to accept `tools=None` and pass it to
  `backend.to_payload(...)`.
- Add `PromptBuilder.parse_response(response)` as a direct backend delegate.
- Change `Client.call` to accept `tools=None` and pass it through while
  preserving all existing retry/error behavior.
- Update all five backend `to_payload` methods to accept `tools=None`.
  `None` means serialize `context.tools`; any explicitly supplied value,
  especially `[]`, must be used verbatim. Do not use truthiness here because
  an empty list intentionally disables tools during wind-down.

### 3. Normalize and replay backend messages

- Implement `parse_response` on each provider according to the contract above.
- Update Ollama, Ollama Cloud, OpenAI, and Gemini message serialization so an
  assistant `Message.content` may be either the old string form or the new
  normalized list of content blocks.
- For Ollama/Ollama Cloud, rebuild an assistant message with concatenated text
  in `content` and provider-shaped `tool_calls` using dict arguments.
- For OpenAI, rebuild `tool_calls` with `id`, `type: "function"`, and JSON text
  in `function.arguments`; use `json.dumps`/`json.loads` for the Ruby
  `to_json`/`JSON.parse` equivalents.
- For Gemini, rebuild model `parts` as `{"text": ...}` or
  `{"functionCall": {"name": ..., "args": ...}}` entries.
- Anthropic needs no replay helper because its normalized blocks are already
  valid Messages API assistant content.
- Preserve text and tool blocks in provider order when parsing. When replaying
  Ollama/OpenAI, match Ruby's wire shape: concatenate text blocks first and
  attach tool calls separately.

### 4. Add `boukensha/agent.py`

Port `Boukensha::Agent` with these constants and constructor inputs:

- `MAX_ITERATIONS = 25`
- `WRAP_UP_OUTPUT_TOKENS = 400`
- the Ruby `WRAP_UP_DIRECTIVE` text
- `context`, `registry`, `builder`, `client`, plus optional `task_settings`,
  `max_iterations`, and `max_output_tokens`

Resolution precedence must match Ruby:

1. An explicit constructor value wins, including zero.
2. If task settings exist and the context task exposes the matching method,
   resolve through the task class.
3. Fall back to `MAX_ITERATIONS` for iterations and `None` for output tokens.

Implement `run()` as follows:

1. Before starting each model round-trip, check the iteration threshold.
2. A positive limit is enabled; zero or a negative value disables it.
3. Increment and print the iteration counter.
4. Call the client with configured output tokens when present.
5. Normalize via `builder.parse_response`.
6. On `tool_use`, append the complete normalized assistant content to history
   before any results, dispatch every tool-use block through the registry, and
   append each stringified result as a `tool_result` with the matching ID.
7. Otherwise concatenate all text blocks in order and return the final text.

At the threshold, make exactly one terminal call outside the counted loop:

- append the wrap-up directive as a user message;
- call with `tools=[]` and `max_output_tokens=400`;
- normalize and return its text;
- if the returned text is blank, or the call raises `ApiError`, return the
  deterministic fallback message;
- do not increment the iteration count, dispatch tools, or recursively check
  the limit during wind-down.

Use Python's normal `print` formatting while keeping the example-visible Ruby
messages recognizable. Keep internal helpers private by convention with
leading underscores.

### 5. Update the example and documentation

- Rewrite `examples/example.py` to import and construct `Agent` after the
  context, registry, builder, and client are available.
- Resolve tool paths relative to the step directory (`base_dir`), not the
  caller's current working directory. This matches the Ruby step-5 safety and
  reproducibility improvement.
- Register `read_file` and `list_directory`, seed the README-summary request,
  print provider/model/limit configuration, call `agent.run()`, and print the
  final response instead of raw JSON.
- Remove the now-unused `json` import.
- Replace the copied step-4 `README.md` with a Python step-5 README describing
  setup, the normalized protocol, configuration, loop/wind-down behavior,
  provider ID differences, and the Python run command.
- Add `week1_baseline/bin/python/05_agent_loop`, following the existing Python
  launcher convention and executable mode, if it is not already present.
- Do not add dependencies; this step remains standard-library-only.

## Target files

```text
week1_baseline/python/05_agent_loop/
  README.md                              update
  boukensha/
    __init__.py                         update exports
    agent.py                            add
    client.py                           pass tools override
    errors.py                           add LoopError
    prompt_builder.py                   parsing + tools delegate
    tasks/base.py                       loop configuration
    backends/anthropic.py               normalize + tools override
    backends/ollama.py                  normalize/replay + tools override
    backends/ollama_cloud.py            normalize/replay + tools override
    backends/openai.py                  normalize/replay + tools override
    backends/gemini.py                  normalize/replay + tools override
  examples/example.py                   run the Agent
week1_baseline/bin/python/05_agent_loop  add launcher
```

`context.py`, `message.py`, `registry.py`, and `tool.py` need no code changes:
their existing dynamic content storage and dispatch APIs already support
normalized block lists and tool-result IDs despite `Message.content`'s narrow
annotation. If type checking is introduced later, widen that annotation; do
not add runtime complexity solely for it in this step.

## Verification

Because the baseline has no formal test suite, use deterministic offline
checks with fake builders/clients plus syntax/import smoke tests:

1. Compile every Python file with `python -m compileall` and import `Agent`
   and `LoopError` from `boukensha`.
2. For each backend, feed representative text-only and tool-call raw responses
   to `parse_response`; assert the exact normalized shape, including real IDs
   for Anthropic/OpenAI and name-derived IDs for Ollama/Gemini.
3. Serialize a normalized assistant message back through each non-Anthropic
   backend and assert its provider-specific tool-call shape. Include mixed text
   plus multiple tool calls and legacy string content.
4. Assert `to_payload(..., tools=None)` includes registered tools while
   `to_payload(..., tools=[])` emits an empty tool list for all providers.
5. Run an agent with a fake client sequence of `tool_use` then `end_turn`;
   verify the tool runs, assistant history precedes tool results, multiple calls
   in one response all dispatch, and final text is concatenated in order.
6. Verify explicit constructor limits override task settings, task settings
   accept numeric strings, configured output tokens reach normal client calls,
   and a zero iteration limit disables the ceiling.
7. Force the limit and verify exactly one tools-disabled 400-token wind-down
   request occurs. Cover successful text, blank text, and `ApiError` fallback.
8. Run the launcher far enough to validate imports/configuration without
   requiring a paid network request. Perform a real provider smoke test only
   when the matching credentials or local Ollama service are intentionally
   available.

## Acceptance criteria

- The Python agent can complete one or more tool-call rounds and return the
  provider's final text without provider-specific logic in `Agent`.
- Conversation history preserves assistant tool calls before corresponding
  tool results and supports multiple calls per model turn.
- Every backend both normalizes responses and can replay normalized assistant
  calls in its required wire format.
- Reaching the configured positive iteration limit produces one bounded,
  tools-disabled wind-down call and a useful deterministic fallback on API
  failure.
- The example and README describe and run step 5, the launcher exists, and no
  unrelated step-4 behavior or dependencies regress.
