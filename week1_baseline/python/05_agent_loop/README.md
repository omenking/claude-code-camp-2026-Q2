# The Agent Loop

Step 5 turns the one-shot Python API client into an agent: it sends a request,
executes any requested tools, records their results, and continues until the
model returns a final answer.

## Setup

The step uses only Python's standard library. Configuration is read from
`.boukensha/settings.yaml`; the player task selects `anthropic`, `openai`,
`gemini`, `ollama`, or `ollama_cloud` and a model supported by that backend.
Hosted providers require their corresponding API key environment variable.
Local Ollama defaults to `http://localhost:11434`.

```yaml
tasks:
  player:
    provider: anthropic
    model: claude-haiku-4-5
    max_iterations: 25
    max_output_tokens: 1024
```

## One protocol for every provider

Each backend converts its raw response to the same shape:

```python
{
    "stop_reason": "tool_use",  # or "end_turn"
    "content": [
        {"type": "text", "text": "I'll inspect that."},
        {"type": "tool_use", "id": "call-id", "name": "read_file", "input": {"path": "README.md"}},
    ],
}
```

The agent only handles this normalized protocol. On the following request,
each backend converts normalized assistant blocks back to its own wire format.
Anthropic and OpenAI preserve provider-issued tool-call IDs. Ollama, Ollama
Cloud, and Gemini do not provide IDs, so the tool name is used as the ID.

## Loop and wind-down behavior

Before each normal model call, the agent checks the positive
`max_iterations` threshold. Zero or a negative number disables the ceiling.
Tool calls are saved as an assistant message before their stringified tool
results, and multiple calls in one response are all dispatched.

At the limit, the agent makes exactly one short terminal request with tools
disabled and a 400-token budget. It asks the model to summarize completed and
unfinished work. An API failure or blank response produces a deterministic
message inviting the user to continue.

`max_output_tokens` controls normal responses. Both limits accept numeric
strings in configuration, and explicit `Agent` constructor values take
precedence over task settings.

## Run the example

The example registers safe, step-relative `read_file` and `list_directory`
tools and asks the agent to summarize this README.

```sh
./week1_baseline/bin/python/05_agent_loop
```
