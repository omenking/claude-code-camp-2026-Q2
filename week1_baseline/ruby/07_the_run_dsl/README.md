# Step 6 — The Boukensha.run DSL

## What this step adds

A single top-level entry point: `Boukensha.run`.

Every previous step required you to manually create and wire together a `Context`, `Registry`, `Backend`, `PromptBuilder`, `Client`, `Logger`, and `Agent`. Step 6 hides all of that behind one method call and a block. It is the "hello world" entry point described in the plan.

## The new primitive

### `Boukensha::RunDSL`

A tiny host object. `Boukensha.run` does `instance_eval(&block)` against it, so `self` inside the block becomes a `RunDSL` — exposing only one method: `tool`. This keeps the DSL surface intentionally small and prevents callers from reaching internal state.

### `Boukensha.run`

Accepts keyword arguments that describe *what* to do. All plumbing is handled internally.

| Option | Default | Description |
|---|---|---|
| `task:` | *(required)* | The user message handed to the agent |
| `system:` | generic coding-assistant prompt | System prompt |
| `model:` | `"claude-haiku-4-5"` | Model name |
| `backend:` | `:anthropic` | `:anthropic` or `:ollama` |
| `api_key:` | `ENV["ANTHROPIC_API_KEY"]` | Anthropic API key |
| `ollama_host:` | `"http://localhost:11434"` | Ollama base URL |
| `log:` | `nil` | Optional path override; by default logs go to `.boukensha/sessions/<session-id>.jsonl` |
| `token_budget:` | `8192` | Max context tokens |
| `max_tokens:` | `1024` | Max tokens per API response |

## Before and after

**Step 5 — 20 lines of manual plumbing:**

```ruby
ctx      = Boukensha::Context.new(system: "You are a MUD player assistant.")
registry = Boukensha::Registry.new(ctx)
backend  = Boukensha::Backends::Anthropic.new(api_key: ENV["ANTHROPIC_API_KEY"], model: "claude-haiku-4-5")
builder  = Boukensha::PromptBuilder.new(ctx, backend)
client   = Boukensha::Client.new(builder)
logger   = Boukensha::Logger.new
agent    = Boukensha::Agent.new(context: ctx, registry: registry, builder: builder, client: client, logger: logger)

registry.tool("read_file", description: "Read a file", parameters: { path: { type: "string" } }) do |path:|
  File.read(path)
end

ctx.add_message(:user, "Read lib/boukensha.rb")
agent.run
```

**Step 6 — just describe what you want:**

```ruby
Boukensha.run(task: "Read lib/boukensha.rb") do
  tool "read_file",
    description: "Read a file",
    parameters:  { path: { type: "string", description: "File path" } } do |path:|
    File.read(path)
  end
end
```

## Run Example

```sh
./bin/ruby/07_the_run_dsl 
```

The example registers two tools (`read_file`, `list_directory`) and asks the agent to list the directory then read `lib/boukensha.rb`. The logger prints each phase to stdout and writes a session JSONL file under `.boukensha/sessions`.