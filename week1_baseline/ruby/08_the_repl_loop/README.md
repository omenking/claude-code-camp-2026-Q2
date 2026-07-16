# Step 7 — The REPL Loop

## What this step adds

| | Step 6 | Step 7 |
|---|---|---|
| Entry point | `Boukensha.run(task: "…")` | `Boukensha.repl` |
| Turns | one | many |
| History | discarded | accumulates across turns |
| User interaction | none | stdin prompt |

## New primitives

### `Boukensha::Repl`

The interactive session loop. Built-in commands:

| Command | Effect |
|---|---|
| `/clear` | Wipe conversation history (tools stay registered) |
| `/help` | Print the command list |
| `/exit` / `/quit` | Leave the REPL |
| Ctrl-D | EOF — leave the REPL |
| Ctrl-C | Interrupt — leave the REPL gracefully |

### `Boukensha.repl`

Same signature as `Boukensha.run`, minus `task:`. Register tools in the block; then
the REPL loop takes over.

```ruby
Boukensha.repl(model: "claude-haiku-4-5") do
  tool "read_file",
    description: "Read a file from disk",
    parameters:  { path: { type: "string", description: "File path" } } do |path:|
    File.read(path)
  end
end
```

## Changes from step 6

### `Context#clear_messages!`
Wipes `@messages` while keeping tools registered. Used by the REPL `/clear` command.

### `Agent#run` — persists the final reply
Before step 7, the agent returned the final text without adding it to the
context. That was fine for one-shot runs (context is thrown away anyway), but
a REPL needs the full transcript so subsequent turns see the prior exchange.

```
# step 6 — final text returned but NOT in context
return text

# step 7 — final text added to context, then returned
@context.add_message(:assistant, text)
return text
```

### `Logger#turn`
New method that prints a `╔══ turn N ══╗` header at the start of each REPL
turn, making it easy to see where one conversation turn ends and the next
begins.

## Running it

```
cd 07_the_repl_loop
ANTHROPIC_API_KEY=your_key ruby examples/step7.rb
```

```
╔══════════════════════════════════════╗
║  BOUKENSHA REPL  —  MUD assistant   ║
║  type a command and press Enter     ║
╚══════════════════════════════════════╝

boukensha> list the files in the lib directory
…
boukensha> now read lib/boukensha/agent.rb and explain the loop
…
boukensha> /quiet
(logging suppressed — type /loud to re-enable)
boukensha> what was the first file I asked you about?
…
boukensha> /exit
Goodbye.
```

The last question demonstrates persistent history: the agent answers from the
accumulated transcript, not just the last message.

## Technical Considerations
We are not fixing these now to perserve future layers but making not of things we observered that might need fixing.

- We need to determine of quiet and loud are legacy logging or if they actually provided details logs.
- It looks like REPL loop we initialize on every turn an agent. It seems like to we should initalize only once.