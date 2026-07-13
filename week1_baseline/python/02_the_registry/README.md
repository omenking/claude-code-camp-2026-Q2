# 02 · The Tool Registry (Python)

## Setup

This step shares the single virtualenv at the **repo root**:

```bash
# from the repo root
python3 -m venv .venv
source .venv/bin/activate
pip install -r week1_baseline/python/02_the_registry/requirements.txt
```

The launcher at `week1_baseline/bin/python/02_the_registry` assumes `.venv`
already exists at the repo root and has these dependencies installed.

---

The Tool Registry is how BOUKENSHA manages what capabilities the agent can
use.

It has two jobs:
  1. storing tools
  2. dispatching tools when asked

## New Files

| File | Description |
|---|---|
| `boukensha/registry.py` | The Registry class — registers tools and dispatches calls |
| `boukensha/errors.py` | BOUKENSHA-specific error classes |

## How It Works

The agent NEVER calls a tool directly.
It emits a structured request (name and args) and the Registry looks up the
tool and runs it.

```
Agent:  "Hey registry call move with direction='north'"
Registry: "looking up "move" in the tool table"
Registry: "Found it now calling the block with the provided args"
Registry: "Here's the result"
Agent: "Thanks buddy"
Registry: "Thats why you pay me the big tokens"
```

## boukensha.Registry

| Method | Description |
|---|---|
| `tool(name, description, parameters=None)` | Decorator factory — registers the decorated function as a tool on the context |
| `dispatch(name, args=None)` | Looks up a tool by name and calls it with the provided args |

## boukensha.UnknownToolError

Raised when `dispatch` is called with a name that has no registered tool.
A harness needs explicit error boundaries — an unrecognised tool name should
never silently fail.

**Example:**
```
UnknownToolError: No tool registered as 'flee'
```

## Expected Output

```
=== BOUKENSHA Step 2: Tool Registry ===

Context: #<Context task=player turns=0 tools=2>
Tools:
  #<Tool name=move description="Move the player in a direction (north, south, east, west, up, down)" params=['direction']>
  #<Tool name=shout description="Shout a message so everyone in the zone can hear it" params=['message']>

Dispatching 'shout' with message='dragon spotted'...
Result: DRAGON SPOTTED

Dispatching 'move' with direction='north'...
Result: You move north into a torch-lit corridor.

UnknownToolError caught: No tool registered as 'flee'
```

## Considerations

Ruby's `dispatch` converts string keys to symbol keys before calling the
block, because Ruby blocks with keyword args expect symbols but the API
returns arguments as string-keyed JSON. Python has no such duality — a dict
of string keys can be splatted directly as keyword arguments — so
`dispatch` here calls `tool.block(**(args or {}))` with no key-translation
step.

## Run Example

```sh
./week1_baseline/bin/python/02_the_registry
```

## Considerations

We now register tools with the Registry but our code still has direct
registration and tools in context. This likely should have been reworked.

Checking the final baseline example, we did correct the issue.
The context should have reference to tools[] its currently using, and the
full table of tools registered should live on the Registry.

We'll correct this manually in a future step and we will leave things in
place.
