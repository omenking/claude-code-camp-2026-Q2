# Python Port Plan — 01 · Struct Skeleton

## Goal

Port `week1_baseline/ruby/01_struct_skeleton` to Python as
`week1_baseline/python/01_struct_skeleton`, preserving the Ruby step's public
surface and example behaviour.

`week1_baseline/python/01_struct_skeleton` has already been created by copying
the completed `week1_baseline/python/00_config` port. This plan is therefore
only for the **step 1 delta**: compare Ruby `00_config` to Ruby
`01_struct_skeleton`, then apply only those new changes to the existing Python
`01_struct_skeleton` folder.

This step is intentionally small: it adds lightweight data structures for the
objects that will be passed through the agent loop in later steps:

- `boukensha.Tool`
- `boukensha.Message`
- `boukensha.Context`

Do not introduce API clients, runtime loops, formal tests, validation
frameworks, or a packaging system in this step.

## Reference files (source of truth — read these before porting)

| Ruby file | Role |
|---|---|
| `week1_baseline/ruby/01_struct_skeleton/README.md` | Behaviour/spec doc for this step and the expected example output shape |
| `week1_baseline/ruby/01_struct_skeleton/lib/boukensha/tool.rb` | `Boukensha::Tool` struct and Ruby-style `to_s` |
| `week1_baseline/ruby/01_struct_skeleton/lib/boukensha/message.rb` | `Boukensha::Message` struct and Ruby-style `to_s` |
| `week1_baseline/ruby/01_struct_skeleton/lib/boukensha/context.rb` | `Boukensha::Context`, tool registry, message history, counters, `to_s` |
| `week1_baseline/ruby/01_struct_skeleton/lib/boukensha.rb` | Top-level require list; defines the public exports added in this step |
| `week1_baseline/ruby/01_struct_skeleton/examples/example.rb` | Runnable smoke-test for the step; port this as the Python acceptance example |
| `week1_baseline/ruby/01_struct_skeleton/lib/boukensha/config.rb` | Same config behaviour as step 0; compare only for drift from the Python port |
| `week1_baseline/ruby/01_struct_skeleton/lib/boukensha/tasks/*.rb` | Same task behaviour as step 0; compare only for drift from the Python port |
| `week1_baseline/bin/ruby/01_struct_skeleton` | Ruby launcher shape; create the analogous Python launcher |

Existing Python snapshot to modify:

| Python file | Role |
|---|---|
| `week1_baseline/python/01_struct_skeleton/` | Already-copied Python snapshot from `00_config`; apply the step 1 delta here |
| `week1_baseline/python/01_struct_skeleton/boukensha/config.py` and `boukensha/tasks/` | Existing Python config/task port; should remain unchanged unless a Ruby step 1 delta requires it |
| `week1_baseline/python/01_struct_skeleton/README.md` | Existing copied README; update only for the new struct-skeleton content |
| `week1_baseline/python/01_struct_skeleton/examples/example.py` | Existing copied example; replace with the step 1 example |
| `week1_baseline/bin/python/00_config` | Python launcher conventions: repo-root `.venv`, run the step example |

## Design Considerations

- **The snapshot already exists.** Do not copy `python/00_config` again. Treat
  `week1_baseline/python/01_struct_skeleton/` as the working snapshot and only
  add/update files required by the Ruby step 1 delta.
- **Keep the step 0 port intact.** `config.py`, `tasks/`, `requirements.txt`,
  and `prompts/system.md` were already ported for step 0. Leave them alone
  unless Ruby `01_struct_skeleton` changed that behaviour compared with Ruby
  `00_config`.
- **Use Python dataclasses for Ruby structs.** Ruby uses `Struct.new` because
  the values are lightweight records. The direct Python equivalent should be
  `@dataclass`, not a validation model or heavier class hierarchy.
- **Keep Ruby-style display strings.** `__str__` should intentionally emit
  strings such as `#<Tool ...>`, `#<Message ...>`, and `#<Context ...>` so the
  example remains close to the Ruby output and future step docs can compare
  snapshots easily.
- **Keep dictionary-shaped parameters.** Ruby's tool parameters are a hash
  keyed by symbols. In Python, use a normal `dict` with string keys:
  `{"direction": {"type": "string", "description": "The direction to move"}}`.
- **Callable tool blocks are stored only.** The Ruby example stores a lambda in
  `Tool.block`, but this step does not execute tools yet. The Python port
  should store a callable in `Tool.block` without adding invocation semantics.
- **No formal test suite.** Per the decision recorded in `00_config`, keep this
  to smoke-test examples. Verification is running the example through the bin
  script.
- **Shared root virtualenv.** Continue assuming `.venv` at the repo root, with
  dependencies installed from the step's `requirements.txt`.

## Target file layout

```
week1_baseline/python/01_struct_skeleton/
  requirements.txt
  README.md
  boukensha/
    __init__.py
    config.py
    context.py
    message.py
    tool.py
    tasks/
      __init__.py
      base.py
      player.py
  prompts/
    system.md
  examples/
    example.py
week1_baseline/bin/python/01_struct_skeleton
```

`requirements.txt`, `config.py`, `tasks/`, and `prompts/system.md` are already
present from the copied step 0 Python port. At the time of writing, the Ruby
step 1 delta is isolated to `Tool`, `Message`, `Context`, top-level exports,
README, example, and launcher.

## Porting notes (Ruby → Python mapping)

### `Tool` (`tool.rb` → `tool.py`)

Ruby:

```ruby
Tool = Struct.new(:name, :description, :parameters, :block) do
  def to_s
    "#<Tool name=#{name} description=#{description.to_s[0..40]} params=#{parameters.keys}>"
  end
end
```

Python target:

- `@dataclass`
- fields:
  - `name: str`
  - `description: str`
  - `parameters: dict`
  - `block: Callable[..., Any] | None = None`
- `__str__` returns:
  - `#<Tool name=move description=Move the player in a direction (north, sout params=['direction']>`
  - Exact list formatting can be Pythonic (`['direction']`), but keep the
    information and truncation intent the same.
- `__repr__ = __str__` is acceptable for matching Ruby's inspect-ish output.

### `Message` (`message.rb` → `message.py`)

Ruby:

```ruby
Message = Struct.new(:role, :content, :tool_use_id) do
  def to_s
    id_tag = tool_use_id ? " [#{tool_use_id}]" : ""
    "#<Message role=#{role}#{id_tag} content=#{content.to_s[0..60]}...>"
  end
end
```

Python target:

- `@dataclass`
- fields:
  - `role: str`
  - `content: str`
  - `tool_use_id: str | None = None`
- `__str__` includes the optional ` [tool_use_id]` tag only when present.
- Truncate content to the same approximate preview length and append `...`.
- Accept role strings like `"user"` and `"assistant"`; do not introduce enums
  yet because the Ruby step does not validate roles.

### `Context` (`context.rb` → `context.py`)

Ruby behaviour:

- initialized with `task:` and optional `system:`
- owns:
  - `task`
  - `system`
  - `messages = []`
  - `tools = {}`
- `register_tool(tool)` stores by `tool.name`
- `add_message(role, content, tool_use_id: nil)` appends a `Message`
- `tool_count` returns `tools.size`
- `turn_count` returns `messages.size`
- `to_s` returns `#<Context task=player turns=2 tools=1>`

Python target:

- regular class or dataclass with custom defaults; either is fine as long as
  mutable defaults are not shared between instances.
- constructor signature:
  - `Context(task, system=None)`
  - keyword usage in the example should read naturally:
    `Context(task=Player, system=system_prompt)`
- properties:
  - `task`
  - `system`
  - `messages: list[Message]`
  - `tools: dict[str, Tool]`
- methods/properties:
  - `register_tool(self, tool)`
  - `add_message(self, role, content, tool_use_id=None)`
  - `tool_count`
  - `turn_count`
- `__str__` should call `task.task_name()` when available so
  `Context(task=Player, ...)` prints `task=player`.

### Top-level exports (`lib/boukensha.rb` → `boukensha/__init__.py`)

Add exports for the new structures while preserving the step 0 exports:

```python
from boukensha.config import Config
from boukensha.context import Context
from boukensha.message import Message
from boukensha.tool import Tool
from boukensha.tasks.player import Player
```

Expose these through `__all__` if the step 0 port already uses it; otherwise
keep the existing style.

### Example (`examples/example.rb` → `examples/example.py`)

Port the Ruby example as the smoke test. It should:

1. Insert the step root into `sys.path`, matching `00_config`.
2. Set `BOUKENSHA_DIR` to the repo's committed `.boukensha` only when the
   environment variable is not already set.
3. Load `Config`, get `player_settings`, and resolve the system prompt exactly
   as step 0 does.
4. Build:
   - `ctx = Context(task=Player, system=system_prompt)`
   - one `Tool` named `"move"`
   - two messages:
     - role `"user"`, content `"Explore north and tell me what you find."`
     - role `"assistant"`, content `"Sure, let me head north and take a look."`
5. Print:

```text
=== Boukensha Step 1: Struct Skeleton ===

Config:   #<Boukensha::Config ...>
Context:  #<Context task=player turns=2 tools=1>
Tool:     #<Tool name=move ...>
Messages:
  #<Message role=user content=Explore north and tell me what you find....>
  #<Message role=assistant content=Sure, let me head north and take a look....>
```

The exact config directory and prompt/settings values come from the user's
`.boukensha`, so do not hardcode those.

### README

Update the existing `week1_baseline/python/01_struct_skeleton/README.md` with
the Ruby step 1 README content plus the Python setup convention already present
from the copied `00_config` README.

The README should include:

- root `.venv` setup/update instructions:

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r week1_baseline/python/01_struct_skeleton/requirements.txt
```

- the three data structures and their fields
- Python examples using `Tool(...)`, `Message(...)`, and `Context(...)`
- run command:

```bash
./week1_baseline/bin/python/01_struct_skeleton
```

Do not add future runtime-loop behaviour to this README.

### Launcher

Add if absent:

```text
week1_baseline/bin/python/01_struct_skeleton
```

Use the same style as `week1_baseline/bin/python/00_config`:

```bash
#!/usr/bin/env bash

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$SCRIPT_DIR/../../.."

cd "$SCRIPT_DIR/../../python/01_struct_skeleton"
"$REPO_ROOT/.venv/bin/python" examples/example.py
```

Make it executable.

## Configuration Schema

Unchanged from step 0. This step consumes the existing `tasks.player` and
`mud` config only to demonstrate that `Context` can hold a resolved system
prompt.

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

1. Confirm the existing `week1_baseline/python/01_struct_skeleton` snapshot is
   the copied Python `00_config` port.
2. Compare Ruby `00_config` and Ruby `01_struct_skeleton` to identify the
   actual step 1 delta. Expected new source files are `tool.rb`,
   `message.rb`, and `context.rb`; expected changed files are top-level
   exports, README, example, and launcher.
3. Add `boukensha/tool.py`, `boukensha/message.py`, and
   `boukensha/context.py`.
4. Update `boukensha/__init__.py` to export `Tool`, `Message`, and `Context`.
5. Replace the copied example with the step 1 struct-skeleton example.
6. Update the copied README with the step 1 README, keeping the root-venv
   setup instructions.
7. Add `week1_baseline/bin/python/01_struct_skeleton` and make it executable
   if it does not already exist.
8. Run the smoke test through the launcher.

## Verification

Run:

```bash
./week1_baseline/bin/python/01_struct_skeleton
```

Expected checks:

- exits with status 0
- prints `=== Boukensha Step 1: Struct Skeleton ===`
- prints a config string
- prints `#<Context task=player turns=2 tools=1>`
- prints the registered `move` tool
- prints two messages, one `user` and one `assistant`

No `pytest` suite is required for this step.

## Considerations

- Python's `str(list(parameters.keys()))` will not look identical to Ruby's
  symbol-array output (`[:direction]`). That is acceptable for now; the key
  requirement is that the tool's registered parameter names are visible.
- Ruby symbols should become simple Python strings in examples and data
  structures.
- `Context` stores `system` but does not print it in `__str__`, matching the
  actual Ruby implementation even though the Ruby README shows more elaborate
  illustrative context descriptions.
- Do not execute `Tool.block` in this step. Tool invocation belongs to a later
  runtime-loop step.
