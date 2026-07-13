# The Tool Registry

The Tool Registry is how BOUKENSHA manages what capabilities the agent can use. 

It has two jobs: 
  1. storing tools
  2. dispatching tools when asked


## New Files

| File | Description |
|---|---|
| `lib/boukensha/registry.rb` | The Registry class — registers tools and dispatches calls |
| `lib/boukensha/errors.rb` | BOUKENSHA-specific error classes |

## How It Works

The agent NEVER calls a tool directly. 
It emits a structured request (name and args) and the Registry looks up the tool and runs it. 

```
Agent:  "Hey registry call move with direction='north'"
Registry: "looking up "move" in the tool table"
Registry: "Found it now calling the block with the provided args"
Registry: "Here's the result"
Agent: "Thanks buddy"
Registry: "Thats why you pay me the big tokens"
```

## Boukensha::Registry

| Method | Description |
|---|---|
| `tool(name, description:, parameters:, &block)` | Registers a new tool on the context |
| `dispatch(name, args)` | Looks up a tool by name and calls it with the provided args |

## Boukensha::UnknownToolError

Raised when `dispatch` is called with a name that has no registered tool. 
A harness needs explicit error boundaries an unrecognised tool name should never silently fail.

**Example:**
```
UnknownToolError: No tool registered as 'flee'
```

## Expected Output

```
=== BOUKENSHA Step 2: Tool Registry ===

Context: #<Context turns=0 tools=2 budget=8192>
Tools:
  #<Tool name=move description="Move the player in a direction (north, south, east, west, up, down)" params=[:direction]>
  #<Tool name=shout description="Shout a message so everyone in the zone can hear it" params=[:message]>

Dispatching 'shout' with message='dragon spotted'...
Result: DRAGON SPOTTED

Dispatching 'move' with direction='north'...
Result: You move north into a torch-lit corridor.

UnknownToolError caught: No tool registered as 'flee'
```

## Considerations

`dispatch` converts string keys to symbol keys before calling the block. 
The API returns arguments as string-keyed JSON but Ruby blocks expect symbols. 
This translation is a real gotcha in production harnesses, BOUKENSHA makes it visible for learning purposes

## Run Example

```sh
./week1_baseline/bin/01_the_registry 
```

## Considerations

We now register tools with the Registry but our code still has direct registration and tools in context. This likely should have been reworked.

Checking the final baseline example, we did correct the issue.
The context should have reference to tools[] its currently using, and the full table of tools registered should live on the Registry. 

We'll correct this manually in a future step and we will leave things place.