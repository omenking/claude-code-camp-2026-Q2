# Step 10 — A Standard Tool Library

Boukensha now ships two built-in tool modules. Instead of manually registering tools, a real coding harness gives the agent a standard library of capabilities out of the box.

## What's new

### `Boukensha::Tools::FileSystem`

The evolution of step 9's `WorkingDirectory` — same five tools plus one new one. Registers automatically when `working_dir:` is set:

| Tool | Description |
|------|-------------|
| `pwd` | Return the working directory |
| `list_directory` | List files at a path (default `.`) |
| `read_file` | Read a file's contents |
| `write_file` | Write (or create) a file |
| `delete_file` | Delete a file |
| `search_files` | **New** — grep for a regex pattern across the working tree, returns `path:line:content` matches |

All paths are **relative to the working directory**. Absolute paths and `..` traversals that escape the root are rejected with an error string.

### `Boukensha::Tools::Shell`

New module. Registers automatically when `working_dir:` is set:

| Tool | Description |
|------|-------------|
| `run_command` | Run a shell command inside the working directory |

Commands run with a configurable timeout and an optional allow-list of permitted executables.

### New `Boukensha.run` / `Boukensha.repl` keyword arguments

```ruby
Boukensha.run(
  task:             "...",
  working_dir:      "/my/project",
  allowed_commands: ["ruby", "git", "bundle"],  # nil = allow all (default)
  shell_timeout:    30                           # seconds, default 30
)
```

`allowed_commands: nil` permits any executable. Pass an explicit list to lock the agent down:

```ruby
# Only allow ruby and git — rm, curl, etc. will be rejected
Boukensha.run(task: "...", allowed_commands: ["ruby", "git"])
```

### Direct registration

Both modules can be registered manually if you need finer control:

```ruby
Boukensha::Tools::FileSystem.register(registry, working_dir: "/my/project")
Boukensha::Tools::Shell.register(registry, working_dir: "/my/project",
                              timeout: 10, allowed_commands: ["ruby"])
```

## Run the demo

```sh
ruby examples/demo.rb

# or via the global executable pointed at this step:
BOUKENSHA_PATH=~/Sites/boukensha/10_standard_tool_library boukensha
```

## Technical Considerations
This is just observations we dont want to fix these right now just to perserve current future layers.
- There could be a case where if a sessions is already is in used for a user they are prompted with Yes or No to kill the session and our agent's/mud_manager doesn't have a way to handle that case.
- It seems like we need more tool work, as there might not be enough tools to accomplish tasks efficently and mostly are mapping the same task to primitives.