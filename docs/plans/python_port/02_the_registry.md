# Python Port Plan — 02 · The Registry

## Goal

Port `week1_baseline/ruby/02_the_registry` to Python as
`week1_baseline/python/02_the_registry`, preserving the Ruby step's public
surface and example behaviour.

`week1_baseline/python/02_the_registry` already exists but is currently just
an unmodified copy of the completed `week1_baseline/python/01_struct_skeleton`
port (its README still says "Step 1: Struct Skeleton" and its example still
registers a single tool directly on `Context`, with no registry at all). This
plan is therefore only for the **step 2 delta**: compare Ruby
`01_struct_skeleton` to Ruby `02_the_registry`, then apply only those new
changes to the existing Python `02_the_registry` folder.

This step adds one new concept: a `Boukensha::Registry` that owns tool
registration and dispatch, plus a `Boukensha::UnknownToolError` for the
error boundary when an unrecognised tool name is dispatched.

Do not introduce API clients, a runtime/agent loop, formal tests, or the
Context/Registry data-ownership rework the Ruby README flags as still
outstanding (see Considerations below) — that rework is explicitly deferred
to a future step on the Ruby side, so the Python port should faithfully
reproduce the same not-yet-fixed state, not get ahead of it.

## Reference files (source of truth — read these before porting)

| Ruby file | Role |
|---|---|
| `week1_baseline/ruby/02_the_registry/README.md` | Behaviour/spec doc for this step, including the known Context/Registry ownership gotcha called out twice at the end |
| `week1_baseline/ruby/02_the_registry/lib/boukensha/registry.rb` | New `Boukensha::Registry` — `tool(name, description:, parameters:, &block)` and `dispatch(name, args)` |
| `week1_baseline/ruby/02_the_registry/lib/boukensha/errors.rb` | New `Boukensha::UnknownToolError < StandardError` |
| `week1_baseline/ruby/02_the_registry/lib/boukensha/context.rb` | Unchanged behaviour vs. step 1 — only a stray one-word comment (`# This isn'`) was added above `register_tool`; do not port that comment, it's an editing artifact with no meaning |
| `week1_baseline/ruby/02_the_registry/lib/boukensha.rb` | Adds `require_relative` lines for `errors` and `registry` |
| `week1_baseline/ruby/02_the_registry/examples/example.rb` | Rewritten to register tools through the registry, dispatch two of them, and demonstrate the `UnknownToolError` path — port this as the Python acceptance example |
| `week1_baseline/bin/ruby/02_the_registry` | Ruby launcher shape; create the analogous Python launcher |

Unchanged from step 1 (compare only, do not re-port unless drift is found):

| Ruby file | Note |
|---|---|
| `lib/boukensha/config.rb`, `lib/boukensha/tasks/*.rb` | No diff between Ruby `01_struct_skeleton` and `02_the_registry` |
| `lib/boukensha/tool.rb`, `lib/boukensha/message.rb` | No diff |

Existing Python snapshot to modify:

| Python file | Role |
|---|---|
| `week1_baseline/python/02_the_registry/` | Currently an unmodified copy of the `01_struct_skeleton` Python port; apply the step 2 delta here |
| `week1_baseline/python/02_the_registry/boukensha/config.py`, `boukensha/tasks/`, `boukensha/tool.py`, `boukensha/message.py`, `boukensha/context.py` | Existing ports; should remain unchanged — no Ruby step 2 delta touches their behaviour |
| `week1_baseline/python/02_the_registry/README.md` | Currently the step-1 README; replace with the step-2 content |
| `week1_baseline/python/02_the_registry/examples/example.py` | Currently the step-1 example; replace with the step-2 registry example |
| `week1_baseline/bin/python/01_struct_skeleton` | Launcher convention to follow for the new `02_the_registry` launcher |

## Design Considerations

- **The snapshot already exists.** Do not copy `python/01_struct_skeleton`
  again. Treat `week1_baseline/python/02_the_registry/` as the working
  snapshot and only add/update the files required by the Ruby step 2 delta.
- **New module: `boukensha/registry.py`.** A plain class holding a reference
  to the `Context` it was built with, mirroring `Registry.new(context)` in
  Ruby.
- **New module: `boukensha/errors.py`.** `UnknownToolError(Exception)` —
  Python's `Exception` is the direct equivalent of Ruby's `StandardError`
  here; no custom base error class exists on the Ruby side to mirror.
- **Ruby blocks → Python decorator.** The Ruby example switched from
  constructing a `Tool` directly to a trailing-block call style:
  `registry.tool("move", description: ..., parameters: ...) do |direction:| ... end`.
  The closest Pythonic equivalent to "call a method, then attach a block of
  code to run later" is a decorator:
  ```python
  @registry.tool("move", description="...", parameters={"direction": {"type": "string"}})
  def move(direction):
      return f"You move {direction} into a torch-lit corridor."
  ```
  `Registry.tool(...)` returns a decorator function that builds the `Tool`,
  registers it on the context, and returns the original function unchanged
  (so it stays usable/testable on its own). This is recommended over passing
  a `lambda`/`block=` keyword positionally, since it reads closest to the
  Ruby call shape. Flagged as an open question below in case a different
  convention is preferred.
- **No symbol/string key translation needed in `dispatch`.** Ruby's
  `dispatch` does `args.transform_keys(&:to_sym)` because Ruby blocks with
  keyword args (`|direction:|`) require symbol keys, but JSON/API args
  arrive as strings. Python has no such duality — `tool.block(**args)` works
  directly against a string-keyed dict. Port the *intent* (turn a dict of
  args into keyword arguments for the call) without the symbol conversion
  step, and keep a one-line comment noting why the step is unnecessary in
  Python (this is the one Ruby comment worth preserving in spirit, even
  though the literal Ruby comment beside it is the stray artifact noted
  above).
- **`Context` is intentionally left alone.** The Ruby README's closing
  "Considerations" sections both flag that `Context` and `Registry` still
  have overlapping/duplicated tool storage and that this will be "corrected
  manually in a future step." Do not fix this in the Python port — replicate
  the same imperfect state so the Python port matches Ruby step 2 exactly.
  Do not port the `README`'s aspirational `Context` output shown in its
  "Expected Output" block (`#<Context turns=0 tools=2 budget=8192>`) — that
  string does not match what `context.rb`'s actual `to_s` produces (no
  `budget` field, and it's missing `task=`). The Ruby README itself is out of
  sync with the Ruby code here. Python's `README.md` and `example.py` should
  reflect the **real** printed output of the ported code (i.e.
  `#<Context task=player turns=0 tools=2>`), not the aspirational one — see
  Open Questions.
- **No formal test suite.** Per the decision recorded in `00_config`, keep
  this to smoke-test examples.
- **Shared root virtualenv.** Continue assuming `.venv` at the repo root, no
  new dependencies are introduced by this step.

## Target file layout

```
week1_baseline/python/02_the_registry/
  requirements.txt
  README.md
  boukensha/
    __init__.py
    config.py
    context.py
    errors.py                      # new
    message.py
    registry.py                    # new
    tool.py
    tasks/
      __init__.py
      base.py
      player.py
  prompts/
    system.md
  examples/
    example.py
week1_baseline/bin/python/02_the_registry
```

`requirements.txt`, `config.py`, `tasks/`, `tool.py`, `message.py`,
`context.py`, and `prompts/system.md` are already present, carried over
unchanged from the copied `01_struct_skeleton` port.

## Porting notes (Ruby → Python mapping)

### `Registry` (`registry.rb` → `registry.py`)

Ruby:

```ruby
require_relative "errors"

module Boukensha
  class Registry
    def initialize(context)
      @context = context
    end

    def tool(name, description:, parameters: {}, &block)
      tool = Tool.new(name.to_s, description, parameters, block)
      @context.register_tool(tool)
      tool
    end

    def dispatch(name, args = {})
      tool = @context.tools[name.to_s]
      raise UnknownToolError, "No tool registered as '#{name}'" unless tool
      tool.block.call(**args.transform_keys(&:to_sym))
    end
  end
end
```

Python target:

```python
from .errors import UnknownToolError
from .tool import Tool


class Registry:
    def __init__(self, context):
        self.context = context

    def tool(self, name, description, parameters=None):
        def decorator(block):
            registered = Tool(str(name), description, parameters or {}, block)
            self.context.register_tool(registered)
            return block
        return decorator

    def dispatch(self, name, args=None):
        tool = self.context.tools.get(str(name))
        if tool is None:
            raise UnknownToolError(f"No tool registered as '{name}'")
        return tool.block(**(args or {}))
```

- `name.to_s` → `str(name)` (defensive, matches Ruby coercing the key to a
  string before storing/looking up).
- `parameters: {}` default → `parameters=None` then `parameters or {}` in the
  body (avoid a mutable default argument).
- `args = {}` default → `args=None` then `args or {}` in the body, same
  reasoning.
- `raise ... unless tool` → `if tool is None: raise ...`.

### `Errors` (`errors.rb` → `errors.py`)

```python
class UnknownToolError(Exception):
    pass
```

### `Context` (`context.rb` → `context.py`)

No behavioural change. Do not port the stray `# This isn'` comment — it is
an incomplete/accidental edit on the Ruby side, not a functional or
documented change.

### Top-level exports (`lib/boukensha.rb` → `boukensha/__init__.py`)

Add exports for `Registry` and `UnknownToolError` while preserving the
existing exports:

```python
from .config import Config
from .context import Context
from .errors import UnknownToolError
from .message import Message
from .registry import Registry
from .tasks.player import Player
from .tool import Tool

__all__ = [
    "Config",
    "Context",
    "Message",
    "Player",
    "Registry",
    "Tool",
    "UnknownToolError",
]
```

### Example (`examples/example.rb` → `examples/example.py`)

Port the Ruby example as the smoke test:

```ruby
ENV["BOUKENSHA_DIR"] ||= File.expand_path("../../../../.boukensha", __dir__)
require_relative "../lib/boukensha"

config          = Boukensha::Config.new
player_settings = config.tasks(:player)
system_prompt   = Boukensha::Tasks::Player.system_prompt(
  player_settings,
  user_prompts_dir: config.user_prompts_dir
)

ctx      = Boukensha::Context.new(task: Boukensha::Tasks::Player, system: system_prompt)
registry = Boukensha::Registry.new(ctx)

registry.tool("move",
  description: "Move the player in a direction (north, south, east, west, up, down)",
  parameters: { direction: { type: "string" } }
) do |direction:|
  "You move #{direction} into a torch-lit corridor."
end

registry.tool("shout",
  description: "Shout a message so everyone in the zone can hear it",
  parameters: { message: { type: "string" } }
) do |message:|
  message.upcase
end

puts "=== BOUKENSHA Step 2: Tool Registry ==="
puts
puts "Config:  #{config}"
puts "Context: #{ctx}"
puts "Tools:"
ctx.tools.each_value { |t| puts "  #{t}" }
puts

puts "Dispatching 'shout' with message='dragon spotted'..."
result = registry.dispatch("shout", { "message" => "dragon spotted" })
puts "Result: #{result}"
puts

puts "Dispatching 'move' with direction='north'..."
result = registry.dispatch("move", { "direction" => "north" })
puts "Result: #{result}"
puts

begin
  registry.dispatch("flee")
rescue Boukensha::UnknownToolError => e
  puts "UnknownToolError caught: #{e.message}"
end
```

Notice two intentional parameter drifts vs. the step 1 example, both of
which should be carried into Python:
- The `parameters` dict no longer includes a per-argument `description` key
  (step 1's `move` tool had one, step 2's does not) — port exactly as shown,
  don't restore the extra key.
- `move`'s `parameters` key changes from a string `"direction"` (step 1
  Python) to matching Ruby's symbol-turned-string; keep it a plain string
  key in Python either way, no change needed there.

Python target (`examples/example.py`):

```python
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from boukensha import Config, Context, Player, Registry, UnknownToolError

os.environ.setdefault(
    "BOUKENSHA_DIR", str(Path(__file__).resolve().parent.parent.parent.parent.parent / ".boukensha")
)

config = Config()
player_settings = config.tasks("player")
system_prompt = Player.system_prompt(
    player_settings,
    user_prompts_dir=config.user_prompts_dir,
    default_prompts_dir=Config.PROMPTS_DIR,
)

ctx = Context(task=Player, system=system_prompt)
registry = Registry(ctx)


@registry.tool(
    "move",
    description="Move the player in a direction (north, south, east, west, up, down)",
    parameters={"direction": {"type": "string"}},
)
def move(direction):
    return f"You move {direction} into a torch-lit corridor."


@registry.tool(
    "shout",
    description="Shout a message so everyone in the zone can hear it",
    parameters={"message": {"type": "string"}},
)
def shout(message):
    return message.upper()


print("=== BOUKENSHA Step 2: Tool Registry ===")
print()
print(f"Config:  {config}")
print(f"Context: {ctx}")
print("Tools:")
for t in ctx.tools.values():
    print(f"  {t}")
print()

print("Dispatching 'shout' with message='dragon spotted'...")
result = registry.dispatch("shout", {"message": "dragon spotted"})
print(f"Result: {result}")
print()

print("Dispatching 'move' with direction='north'...")
result = registry.dispatch("move", {"direction": "north"})
print(f"Result: {result}")
print()

try:
    registry.dispatch("flee")
except UnknownToolError as e:
    print(f"UnknownToolError caught: {e}")
```

Note: unlike Ruby, the `BOUKENSHA_DIR` env var does not need to be set
*before* `import boukensha` — Python's `boukensha/__init__.py` performs no
env-dependent work at import time, only `Config()` construction reads it.
Keep the existing Python ordering (import first, then `os.environ.setdefault`,
then `Config()`) rather than mimicking Ruby's reordering; the two are
equivalent in effect for this codebase.

### README

Replace the copied step-1 README with step-2 content, following the Ruby
README's structure (New Files / How It Works / `Boukensha::Registry` table /
`Boukensha::UnknownToolError` / Considerations), translated to
`boukensha.Registry` / `boukensha.UnknownToolError` naming and Python code
snippets. Two corrections to make relative to the Ruby source doc:
- Use the **real** `Context` output in the "Expected Output" section
  (`#<Context task=player turns=0 tools=2>`), not the Ruby README's
  aspirational `#<Context turns=0 tools=2 budget=8192>` (see Design
  Considerations above for why).
- Fix the run command to point at the actual Python launcher path
  (`./week1_baseline/bin/python/02_the_registry`) — the Ruby README's own
  run command has a stale/wrong path (`./week1_baseline/bin/01_the_registry`,
  missing the `ruby/` segment and using the wrong step number). Don't
  reproduce that typo.

Keep the root-venv setup block already present in the copied README (same as
step 0/1).

### Launcher

Add:

```text
week1_baseline/bin/python/02_the_registry
```

Same style as `week1_baseline/bin/python/01_struct_skeleton`:

```bash
#!/usr/bin/env bash

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$SCRIPT_DIR/../../.."

cd "$SCRIPT_DIR/../../python/02_the_registry"
"$REPO_ROOT/.venv/bin/python" examples/example.py
```

Make it executable.

## Configuration Schema

Unchanged from steps 0/1.

```yaml
tasks:
  player:
    provider: anthropic
    model: claude-haiku-4-5
    prompt_override:
      system: true
mud:
  host: localhost
  port: 4000
  username: dummy
  password: helloworld
```

## Implementation Steps

1. Confirm the existing `week1_baseline/python/02_the_registry` snapshot is
   the copied Python `01_struct_skeleton` port (README/example still say
   "Step 1").
2. Add `boukensha/errors.py` (`UnknownToolError`).
3. Add `boukensha/registry.py` (`Registry` with `tool` decorator-factory and
   `dispatch`).
4. Update `boukensha/__init__.py` to export `Registry` and
   `UnknownToolError`.
5. Replace `examples/example.py` with the step 2 registry example.
6. Replace `README.md` with the step 2 content (with the two corrections
   noted above).
7. Add `week1_baseline/bin/python/02_the_registry` and make it executable.
8. Run the smoke test through the launcher.

## Verification

Run:

```bash
./week1_baseline/bin/python/02_the_registry
```

Expected checks:

- exits with status 0
- prints `=== BOUKENSHA Step 2: Tool Registry ===`
- prints a config string and `#<Context task=player turns=0 tools=2>`
- lists both registered tools (`move`, `shout`)
- prints `Result: DRAGON SPOTTED` for the `shout` dispatch
- prints `Result: You move north into a torch-lit corridor.` for the `move`
  dispatch
- prints `UnknownToolError caught: No tool registered as 'flee'` and does
  **not** crash the script (the exception must be caught, matching Ruby's
  `rescue`)

No `pytest` suite is required for this step.

## Open Questions

1. **Decorator vs. direct block/lambda for `Registry.tool`.** This plan
   recommends `@registry.tool(name, description=..., parameters=...)` as a
   decorator, since it's the closest Pythonic match to Ruby's trailing-block
   call syntax. An alternative is keeping a Ruby-struct-like positional
   `block=` argument (`registry.tool("move", description=..., parameters=...,
   block=lambda direction: ...)`), which is less idiomatic Python but a more
   literal argument-for-argument port. Confirm the decorator approach is
   acceptable, since it sets the convention for tool registration in later
   steps.
2. **README fidelity vs. correctness.** This plan corrects two things the
   Ruby README gets wrong relative to its own code (the `budget=8192` /
   missing `task=` in the sample `Context` output, and the stale run-command
   path). Confirm it's fine for the Python README to silently fix these
   rather than reproducing the Ruby doc's mistakes — the recommendation is to
   fix them, since the README doubles as this step's runnable
   spec/verification reference.
3. **Duplicate "## Considerations" headings.** The Ruby README has two
   separate `## Considerations` sections (one about symbol/string key
   translation in `dispatch`, one about the Context/Registry ownership gotcha
   added at the very end). Recommend preserving both as separate sections in
   the Python README (faithful port of content) rather than merging them,
   even though it reads as an editing artifact — confirm, or say to merge
   them into one section instead.
