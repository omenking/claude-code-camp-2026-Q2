# Python Port Plan — 00 · Configuration

## Goal

Port `week1_baseline/ruby/00_config` to Python as `week1_baseline/python/00_config`,
reproducing the same behaviour, directory resolution, and config schema — not
redesigning it. This is the first of a series of per-step ports; later steps
(`01_...`, `02_...`, ...) will get their own snapshot folders the same way the
Ruby side does.

## Reference files (source of truth — read these before porting)

| Ruby file | Role |
|---|---|
| `week1_baseline/ruby/00_config/README.md` | Spec/behaviour doc for this step — the design considerations, config schema, and resolution order below are ported from here |
| `week1_baseline/ruby/00_config/lib/boukensha/config.rb` | `Boukensha::Config` — dir resolution, `.env` loading, `settings.yaml` loading, `tasks`, `dig`, `mud_*` accessors |
| `week1_baseline/ruby/00_config/lib/boukensha/tasks/base.rb` | Abstract `Boukensha::Tasks::Base` — stateless class methods: `.provider`, `.model`, `.prompt_override?`, `.prompt`, `.system_prompt` |
| `week1_baseline/ruby/00_config/lib/boukensha/tasks/player.rb` | Concrete `Boukensha::Tasks::Player < Base`, defines `.task_name = "player"` |
| `week1_baseline/ruby/00_config/lib/boukensha.rb` | Top-level require, shows the public surface of the library |
| `week1_baseline/ruby/00_config/prompts/system.md` | Default system prompt shipped with the library — copy verbatim |
| `week1_baseline/ruby/00_config/examples/example.rb` | Runnable smoke-test exercising every public method — port line-for-line as the Python example |
| `week1_baseline/ruby/00_config/Gemfile` / `Gemfile.lock` | Shows the only external dependency is `dotenv` — the Python equivalent dependency list should be similarly minimal |
| `week1_baseline/bin/00_config` | Launcher script (`cd` into the step dir, run the example) — port to an equivalent Python launcher |

Non-Ruby reference for repo conventions (style only, not behaviour):

| File | Why it's relevant |
|---|---|
| `week0_explore/circlemud-world-parser/pyproject.toml`, `setup.cfg`, `requirements.txt` | Only other Python project in this repo — shows prior art for project layout, even though this step uses pip/requirements.txt rather than uv (see Design Considerations) |
| `docs/journal/README.md` | Technical journaling format — not part of this plan, but journal entries for this port should follow it |

## Design Considerations

- **Project tooling: pip + `requirements.txt`.** No `uv`/`poetry` lockfile
  tooling for this step, per user decision — despite `circlemud-world-parser`
  using `uv`. Keep a virtualenv-friendly `requirements.txt` at the project
  root, mirroring how the Ruby side has a `Gemfile`.
- **Config representation: plain `dict` + a `dig()` port.** No Pydantic
  models. `Config.settings` stays the raw dict produced by
  `yaml.safe_load`, and `dig(*keys)` walks it exactly like the Ruby version
  (checking both string and non-string key variants at each level, though in
  Python there's no symbol/string duality — see Open Questions). This keeps
  the port a close 1:1 translation rather than introducing a validation
  layer.
- **Folder layout: snapshot per step.** `week1_baseline/python/00_config/` is
  a self-contained copy, matching `week1_baseline/ruby/00_config/`. Future
  steps get their own `week1_baseline/python/01_.../` etc., each starting
  from a copy of the previous step's code plus that step's changes — same
  pattern as the Ruby side.
- **External dependencies kept minimal**, matching the Ruby side's philosophy
  of standard library first:
  - `PyYAML` — Python's stdlib has no YAML parser (Ruby's does), so this is
    an unavoidable addition, playing the same role as Ruby's built-in `yaml`.
  - `python-dotenv` — direct equivalent of the `dotenv` gem, for loading
    `.boukensha/.env`.

## Target file layout

```
week1_baseline/python/00_config/
  requirements.txt
  README.md                        # ported from the Ruby README, Python-flavoured examples
  boukensha/
    __init__.py                    # top-level package exports (mirrors lib/boukensha.rb)
    config.py                      # Config class
    tasks/
      __init__.py
      base.py                      # Tasks.Base
      player.py                    # Tasks.Player
  prompts/
    system.md                      # copied verbatim from the Ruby side
  examples/
    example.py                     # port of examples/example.rb
week1_baseline/bin/00_config_py    # launcher (name TBD, see Open Questions)
```

## Porting notes (Ruby → Python mapping)

### `Config` (`config.rb` → `config.py`)

| Ruby | Python |
|---|---|
| `DEFAULT_DIR = File.join(Dir.home, ".boukensha")` | `DEFAULT_DIR = Path.home() / ".boukensha"` |
| `PROMPTS_DIR = File.expand_path("../../prompts", __dir__)` | `PROMPTS_DIR = Path(__file__).resolve().parent.parent / "prompts"` (adjust to match target layout above) |
| `initialize` (resolve dir → load `.env` → load settings) | `__init__` doing the same three steps in the same order |
| `ENV.fetch("BOUKENSHA_DIR", nil) \|\| DEFAULT_DIR` | `os.environ.get("BOUKENSHA_DIR") or DEFAULT_DIR` |
| `Dotenv.load(env_file) if File.exist?(env_file)` | `dotenv.load_dotenv(env_file)` guarded by `env_file.exists()` |
| `YAML.safe_load(File.read(settings_file)) \|\| {}` | `yaml.safe_load(settings_file.read_text()) or {}` |
| `tasks(name = nil)` | `tasks(self, name: str \| None = None)` — same string/symbol fallback becomes just a plain string key lookup (no symbol duality in Python) |
| `dig(*keys)` | `dig(self, *keys)` — walks nested dicts; drop the `Hash#[]` string-or-symbol fallback since Python dict keys from `yaml.safe_load` are always strings |
| `to_s` / `inspect` | `__str__` / `__repr__` |

### `Tasks::Base` (`base.rb` → `tasks/base.py`)

Ruby uses class-level (`self.`) methods on an abstract class with no
instances. Port this as either:
- a class with `@classmethod`/`@staticmethod` methods and `task_name` as a
  `NotImplementedError`-raising classmethod (closest structural match), or
- a module of plain functions taking `task_name` explicitly as a parameter.

Recommend the classmethod approach to preserve `Tasks.Player.provider(settings)`-style
call sites from `example.rb`. Keep `provider`, `model`, `prompt_override?` →
`prompt_override` (Python has no `?` in identifiers — use `is_...` or drop
the suffix; pick one convention and apply it consistently), `prompt`,
`system_prompt`, and the private `fetch`/`read_user_prompt`/`read_default_prompt`/`read_file`
helpers.

### `Tasks::Player` (`player.rb` → `tasks/player.py`)

Trivial: `task_name` returns `"player"`.

### Example (`example.rb` → `examples/example.py`)

Port every `puts` line 1:1, including the `BOUKENSHA_DIR` override at the top
(`os.environ.setdefault(...)`) and the trailing `print(config)` that exercises
`__str__`. This is the acceptance test for the port — output should match the
Ruby example's shape (adjusted for real values from the user's `.boukensha/`).

### Launcher (`bin/00_config` → new Python launcher)

The Ruby launcher `cd`s into the step directory and runs
`bundle exec ruby examples/example.rb`. The Python equivalent should `cd`
into `week1_baseline/python/00_config`, ensure `requirements.txt` deps are
importable (venv activation is left to the user, per repo convention — the
Ruby launcher likewise assumes `bundle` is already set up), and run
`python examples/example.py`.

## Configuration Schema

Unchanged from the Ruby version — this port does not touch `settings.yaml`
or `.env` format:

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

## Config directory resolution (unchanged)

1. `BOUKENSHA_DIR` env var
2. `~/.boukensha` (default)

```
.boukensha/
  .env
  settings.yaml
  prompts/
    <task>/
      system.md
```

## Open Questions

1. **Launcher naming/placement.** The existing `week1_baseline/bin/00_config`
   already runs the Ruby version. Should the Python launcher live alongside
   it as `week1_baseline/bin/00_config_py` (both kept side by side), replace
   it outright, or should `bin/00_config` become a dispatcher that picks
   Ruby/Python based on a flag or env var?
- I created subfolders in bin so we have bin/python/ and bin/ruby, pleas fix the pathing for ruby and create a new bin script for running the pyhton.
2. **Virtualenv convention.** The Ruby side relies on `bundle exec` to pick
   up gems from the `Gemfile`. Should the Python launcher assume an
   already-activated venv (matching Ruby's assumption that `bundle install`
   already ran), or should it manage/create a `.venv` itself (e.g.
   `python -m venv .venv && .venv/bin/pip install -r requirements.txt`)
   before running the example?
- Create an python enviroment and add that to the Python's README at the top, we should
expect the user to create teh enviroment base on our instructions and assume the enivomrent will be there, maybe the venv should be loaded at root of the project because we will be creating iterations in future folders and having a single python env in a single place will make things easier.
3. **`prompt_override?` naming.** Ruby's `?` suffix convention has no direct
   Python equivalent. Preference between `prompt_override` (drop the
   suffix, relies on the boolean return type being obvious from context) or
   `is_prompt_override` (explicit)? This naming choice should probably be
   fixed here and then applied consistently in all later ports.
- do what you have to to make it work.
4. **Package name.** Keep the Python package named `boukensha` (matching the
   Ruby module name), or something more Pythonic/distinct since it will live
   inside a directory already called `00_config`?
- it should have the same name
5. **Testing.** The Ruby step has no formal test suite, just the
   `examples/example.rb` smoke test. Do you want an actual `pytest` suite for
   the Python port (even though `circlemud-world-parser` has one and it'd be
   consistent), or should the Python port also stay at the smoke-test-only
   level to stay a faithful 1:1 port for now?
- no test suites, just example file we should have and we can test that way.
</content>
