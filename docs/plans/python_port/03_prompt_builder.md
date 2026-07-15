# Python Port Plan — 03 · The Prompt Builder

## Goal

Port `week1_baseline/ruby/03_prompt_builder` to Python as
`week1_baseline/python/03_prompt_builder`, preserving the Ruby step's public
surface and example behaviour.

`week1_baseline/python/03_prompt_builder` already exists but is currently just
an unmodified copy of the completed `week1_baseline/python/02_the_registry`
port (confirmed via `diff -rq` — zero differences other than generated
`__pycache__` directories, which are already `.gitignore`d and untracked).
This plan is therefore only for the **step 3 delta**: compare Ruby
`02_the_registry` to Ruby `03_prompt_builder`, then apply only those new
changes to the existing Python `03_prompt_builder` folder.

This step adds a `Boukensha::PromptBuilder` that serializes `Context` into the
exact JSON shape each LLM API expects, plus five `Boukensha::Backends::*`
classes (`Base`, `Anthropic`, `Gemini`, `Ollama`, `OllamaCloud`, `OpenAI`) that
own per-provider model tables, message/tool serialization, headers, and URLs.
No network calls are made anywhere in this step — `PromptBuilder`/backends only
build the payload that would be POSTed, they never POST it.

Two Ruby-side items already got ahead of themselves during the step 2 port and
need no further action here:
- `Config.PROMPTS_DIR` was already added to `week1_baseline/python/*/boukensha/config.py`
  (it's the Ruby step-3 delta, but the Python port already has it).
- `boukensha/tasks/base.py` and `boukensha/tasks/player.py` already match the
  Ruby `03_prompt_builder` versions exactly (confirmed via diff — no drift).

## Reference files (source of truth — read these before porting)

| Ruby file | Role |
|---|---|
| `week1_baseline/ruby/03_prompt_builder/README.md` | Behaviour/spec doc for this step |
| `week1_baseline/ruby/03_prompt_builder/lib/boukensha/prompt_builder.rb` | New `Boukensha::PromptBuilder` — delegates serialization to a backend |
| `week1_baseline/ruby/03_prompt_builder/lib/boukensha/backends/base.rb` | New `Boukensha::Backends::Base` — model-table contract shared by all backends |
| `week1_baseline/ruby/03_prompt_builder/lib/boukensha/backends/anthropic.rb` | New `Boukensha::Backends::Anthropic` |
| `week1_baseline/ruby/03_prompt_builder/lib/boukensha/backends/gemini.rb` | New `Boukensha::Backends::Gemini` |
| `week1_baseline/ruby/03_prompt_builder/lib/boukensha/backends/ollama.rb` | New `Boukensha::Backends::Ollama` |
| `week1_baseline/ruby/03_prompt_builder/lib/boukensha/backends/ollama_cloud.rb` | New `Boukensha::Backends::OllamaCloud` |
| `week1_baseline/ruby/03_prompt_builder/lib/boukensha/backends/openai.rb` | New `Boukensha::Backends::OpenAI` |
| `week1_baseline/ruby/03_prompt_builder/lib/boukensha/errors.rb` | Adds `Boukensha::UnsupportedModelError` |
| `week1_baseline/ruby/03_prompt_builder/lib/boukensha/config.rb` | Adds `PROMPTS_DIR` (already present in Python — compare only) |
| `week1_baseline/ruby/03_prompt_builder/lib/boukensha.rb` | Adds `require_relative` lines for `prompt_builder` and all five `backends/*` files |
| `week1_baseline/ruby/03_prompt_builder/examples/example.rb` | Rewritten to register a `look` + `move` tool, seed conversation history, pick a backend by `provider`, and print a pretty-printed API payload — port this as the Python acceptance example |
| `week1_baseline/bin/ruby/03_prompt_builder` | Ruby launcher shape; create the analogous Python launcher |

Unchanged from step 2 (compare only, do not re-port unless drift is found):

| Ruby file | Note |
|---|---|
| `lib/boukensha/registry.rb`, `lib/boukensha/tool.rb`, `lib/boukensha/message.rb` | No diff between Ruby `02_the_registry` and `03_prompt_builder` |
| `lib/boukensha/tasks/base.rb` | No diff |
| `lib/boukensha/context.rb` | Only a stray one-word comment (`# This isn'`) was removed above `register_tool`, and a trailing newline was added at EOF — neither is a Python-side change (the comment was never ported in step 2; Python files aren't missing trailing newlines) |

Existing Python snapshot to modify:

| Python file | Role |
|---|---|
| `week1_baseline/python/03_prompt_builder/` | Currently an unmodified copy of the `02_the_registry` Python port; apply the step 3 delta here |
| `week1_baseline/python/03_prompt_builder/boukensha/config.py`, `context.py`, `message.py`, `registry.py`, `tool.py`, `tasks/` | Existing ports; should remain unchanged — no Ruby step 3 delta touches their behaviour |
| `week1_baseline/python/03_prompt_builder/README.md` | Currently the step-2 README; replace with the step-3 content |
| `week1_baseline/python/03_prompt_builder/examples/example.py` | Currently the step-2 example; replace with the step-3 prompt-builder example |
| `week1_baseline/bin/python/02_the_registry` | Launcher convention to follow for the new `03_prompt_builder` launcher |

## Design Considerations

- **The snapshot already exists.** Do not copy `python/02_the_registry` again.
  Treat `week1_baseline/python/03_prompt_builder/` as the working snapshot and
  only add/update the files required by the Ruby step 3 delta.
- **New subpackage: `boukensha/backends/`.** Ruby nests these under the
  `Boukensha::Backends` module, accessed as `Boukensha::Backends::Anthropic`
  etc. — never flattened into the top-level `Boukensha` namespace. Mirror this
  with a `boukensha/backends/` subpackage whose `__init__.py` re-exports the
  five backend classes, and have the top-level `boukensha/__init__.py` expose
  it as `from . import backends`, so call sites read
  `backends.Anthropic(...)`, matching Ruby's module-qualified style.
- **`Base.models`/`model_info`/`validate_model!` class methods.** Ruby uses
  `const_get(:MODELS)` with a `rescue NameError` to enforce that subclasses
  define a `MODELS` constant. The direct Python equivalent is a classmethod
  that does `cls.MODELS` inside a `try/except AttributeError`, re-raising
  `NotImplementedError`. `validate_model!`'s trailing `!` (Ruby's convention
  for "raises/mutates") has no Python equivalent — port it as plain
  `validate_model` (classmethod).
- **Name collision: Ruby's class-level and instance-level `model_info`.**
  Ruby defines *two* separate methods sharing the name `model_info`: a class
  method `Base.model_info(model)` (table lookup by name, used internally by
  `validate_model!`) and an instance method `model_info` (no args, returns the
  resolved `@model_info` hash for `self.model`). These coexist in Ruby because
  class methods and instance methods live in separate tables; in Python a
  `@classmethod` and a same-named instance method in one class body would
  collide (the second definition simply overwrites the first). Resolve by
  **not** giving the instance side a public `model_info` accessor at all: the
  Ruby README's documented public backend surface
  (`context_window`, `input_token_cost_per_million`,
  `output_token_cost_per_million`, `usage_unit`, `usage_level`,
  `estimate_cost`) never lists instance-level `model_info` as something
  external code calls — it's only used internally by those other methods. So
  in Python, keep `model_info` as the one public classmethod
  (`Base.model_info(model)`), and store the resolved table entry in a private
  instance attribute `self._model_info`, read directly by the property
  methods instead of through a same-named wrapper. Flagged as an open
  question below since it's a real (not cosmetic) naming decision.
- **Ollama's constructor parameter order.** Ruby's
  `initialize(host: "http://localhost:11434", model:)` puts the defaulted
  keyword arg first — legal in Ruby because keyword args are unordered.
  Python requires non-default positional-or-keyword params before defaulted
  ones, so the Python signature must be `__init__(self, model, host="http://localhost:11434")`
  (`model` first). This is purely a parameter-ordering fix with no behavioural
  difference, since every call site in this codebase passes both as keywords
  anyway.
- **`estimate_cost` and other keyword-only Ruby methods.** Ruby declares
  `estimate_cost(input_tokens:, output_tokens:)` with required keyword args.
  Following the convention already established in this port (e.g. `Context.__init__`,
  `Tool`), use plain positional-or-keyword Python parameters
  (`estimate_cost(self, input_tokens, output_tokens)`) rather than forcing
  keyword-only (`*, input_tokens, ...`) — nothing in this codebase currently
  calls `estimate_cost`, so this is a forward-looking signature choice, not
  something exercised by the smoke test.
- **`PromptBuilder.to_messages` has a latent arity bug in Ruby — preserve it,
  don't fix it.** `PromptBuilder#to_messages` calls
  `@backend.to_messages(@context.messages)` — always exactly one argument.
  That matches `Anthropic#to_messages(messages)` and `Gemini#to_messages(messages)`,
  but `Ollama`, `OllamaCloud`, and `OpenAI` all define
  `to_messages(system, messages)` (two required positional args, because those
  three backends inline the system prompt as a `role: system` message instead
  of a separate payload field). Calling `builder.to_messages` with an Ollama/
  OpenAI/OllamaCloud backend would raise Ruby's `ArgumentError: wrong number
  of arguments`. This bug is never exercised: `example.rb` only ever calls
  `builder.to_api_payload`, never `builder.to_messages` directly, and
  `to_payload` on those three backends correctly calls
  `to_messages(context.system, context.messages)` internally (2 args) rather
  than going through `PromptBuilder#to_messages`. Port `PromptBuilder.to_messages`
  faithfully as `self.backend.to_messages(self.context.messages)` (always one
  arg) — this will raise Python's `TypeError: missing 1 required positional
  argument` for the three-arg backends, mirroring Ruby's `ArgumentError`
  exactly. Do not "fix" this by threading `context.system` through
  uniformly; that would diverge from the Ruby step 3 behaviour the same way
  the `02_the_registry` plan preserved the known Context/Registry ownership
  gotcha instead of correcting it.
- **`MODELS` table values: Ruby symbols → Python strings/`None`.** Ruby's
  `cost_per_million: { input: nil, output: nil }` and
  `usage_unit: :ollama_cloud_usage` use `nil` and symbols. Port `nil` → `None`
  and every symbol value (`:tokens`, `:local_compute`, `:ollama_cloud_usage`,
  `:medium`, `:high`) → the equivalent plain string (`"tokens"`,
  `"local_compute"`, `"ollama_cloud_usage"`, `"medium"`, `"high"`). Keys stay
  strings either way (Ruby symbol keys `context_window:` etc. are just
  Python dict string keys).
- **No network calls in this step.** `PromptBuilder`/backends only build the
  payload dict, headers, and URL — they never issue an HTTP request. Running
  the smoke test therefore does not need a real/working API key, only *some*
  string value present in the environment so `ENV.fetch("ANTHROPIC_API_KEY")`
  (Ruby) / `os.environ["ANTHROPIC_API_KEY"]` (Python) doesn't raise, and a
  `model` value that exists in the selected backend's `MODELS` table so
  `validate_model!`/`validate_model` doesn't raise `UnsupportedModelError`.
- **No formal test suite.** Per the decision recorded in `00_config`, keep
  this to smoke-test examples, same as steps 0–2.
- **Shared root virtualenv, no new dependencies.** Ruby's `Gemfile`/`Gemfile.lock`
  are unchanged between `02_the_registry` and `03_prompt_builder` (confirmed —
  zero diff), since `PromptBuilder` only builds plain hashes/dicts and never
  actually performs HTTP I/O. Python's `requirements.txt` needs no additions
  either — `json` and `os` are stdlib.

## Target file layout

```
week1_baseline/python/03_prompt_builder/
  requirements.txt
  README.md
  boukensha/
    __init__.py
    config.py
    context.py
    errors.py                      # updated: + UnsupportedModelError
    message.py
    prompt_builder.py               # new
    registry.py
    tool.py
    backends/                       # new
      __init__.py
      base.py
      anthropic.py
      gemini.py
      ollama.py
      ollama_cloud.py
      openai.py
    tasks/
      __init__.py
      base.py
      player.py
  prompts/
    system.md
  examples/
    example.py
week1_baseline/bin/python/03_prompt_builder
```

`requirements.txt`, `config.py`, `context.py`, `message.py`, `registry.py`,
`tool.py`, `tasks/`, and `prompts/system.md` are already present, carried over
unchanged from the copied `02_the_registry` port.

## Porting notes (Ruby → Python mapping)

### `Errors` (`errors.rb` → `errors.py`)

Ruby adds one new error class alongside the existing one:

```ruby
module Boukensha
  class UnknownToolError < StandardError; end
  class UnsupportedModelError < StandardError; end
end
```

Python target:

```python
class UnknownToolError(Exception):
    pass


class UnsupportedModelError(Exception):
    pass
```

### `Backends::Base` (`backends/base.rb` → `backends/base.py`)

Ruby:

```ruby
require_relative "../errors"

module Boukensha
  module Backends
    class Base
      attr_reader :model

      def self.models
        const_get(:MODELS)
      rescue NameError
        raise NotImplementedError, "#{self} must define MODELS"
      end

      def self.model_info(model)
        models[model.to_s]
      end

      def self.validate_model!(model)
        model = model.to_s
        return model if model_info(model)

        supported = models.keys.sort.join(", ")
        raise UnsupportedModelError, "#{name} does not support model #{model.inspect}. Supported models: #{supported}"
      end

      def model_info
        @model_info
      end

      def context_window
        model_info.fetch(:context_window)
      end

      def input_token_cost_per_million
        model_info.fetch(:cost_per_million).fetch(:input)
      end

      def output_token_cost_per_million
        model_info.fetch(:cost_per_million).fetch(:output)
      end

      def usage_unit
        model_info.fetch(:usage_unit)
      end

      def usage_level
        model_info[:usage_level]
      end

      def estimate_cost(input_tokens:, output_tokens:)
        return nil unless input_token_cost_per_million && output_token_cost_per_million

        ((input_tokens * input_token_cost_per_million) +
          (output_tokens * output_token_cost_per_million)) / 1_000_000.0
      end

      private

      def configure_model(model)
        @model = self.class.validate_model!(model)
        @model_info = self.class.model_info(@model)
      end
    end
  end
end
```

Python target:

```python
from ..errors import UnsupportedModelError


class Base:
    @classmethod
    def models(cls):
        try:
            return cls.MODELS
        except AttributeError:
            raise NotImplementedError(f"{cls.__name__} must define MODELS")

    @classmethod
    def model_info(cls, model):
        return cls.models().get(str(model))

    @classmethod
    def validate_model(cls, model):
        model = str(model)
        if cls.model_info(model):
            return model

        supported = ", ".join(sorted(cls.models().keys()))
        raise UnsupportedModelError(
            f"{cls.__name__} does not support model {model!r}. Supported models: {supported}"
        )

    @property
    def context_window(self):
        return self._model_info["context_window"]

    @property
    def input_token_cost_per_million(self):
        return self._model_info["cost_per_million"]["input"]

    @property
    def output_token_cost_per_million(self):
        return self._model_info["cost_per_million"]["output"]

    @property
    def usage_unit(self):
        return self._model_info["usage_unit"]

    @property
    def usage_level(self):
        return self._model_info.get("usage_level")

    def estimate_cost(self, input_tokens, output_tokens):
        if self.input_token_cost_per_million is None or self.output_token_cost_per_million is None:
            return None

        return (
            (input_tokens * self.input_token_cost_per_million)
            + (output_tokens * self.output_token_cost_per_million)
        ) / 1_000_000.0

    def _configure_model(self, model):
        self.model = self.__class__.validate_model(model)
        self._model_info = self.__class__.model_info(self.model)
```

- `.fetch(:key)` (raises `KeyError` on Ruby side if missing) → plain `[...]`
  indexing in Python (also raises `KeyError` if missing) — same failure mode.
- `model_info[:usage_level]` (Ruby `[]`, returns `nil` if absent) →
  `self._model_info.get("usage_level")` (returns `None` if absent) — same
  "optional" semantics, unlike the other fields which use `.fetch`/`[...]`
  and are required.
- `attr_reader :model` → plain `self.model` instance attribute, set in
  `_configure_model`.
- See Design Considerations above for why the instance side has no public
  `model_info` accessor.

### `Backends::Anthropic` (`backends/anthropic.rb` → `backends/anthropic.py`)

```python
from .base import Base


class Anthropic(Base):
    BASE_URL = "https://api.anthropic.com/v1/messages"
    MODELS = {
        "claude-haiku-4-5": {
            "context_window": 200_000,
            "cost_per_million": {"input": 1.0, "output": 5.0},
            "usage_unit": "tokens",
        },
        "claude-haiku-4-5-20251001": {
            "context_window": 200_000,
            "cost_per_million": {"input": 1.0, "output": 5.0},
            "usage_unit": "tokens",
        },
        "claude-sonnet-4-6": {
            "context_window": 1_000_000,
            "cost_per_million": {"input": 3.0, "output": 15.0},
            "usage_unit": "tokens",
        },
        "claude-opus-4-8": {
            "context_window": 1_000_000,
            "cost_per_million": {"input": 5.0, "output": 25.0},
            "usage_unit": "tokens",
        },
    }

    def __init__(self, api_key, model):
        self.api_key = api_key
        self._configure_model(model)

    def to_messages(self, messages):
        result = []
        for msg in messages:
            if msg.role == "tool_result":
                result.append({
                    "role": "user",
                    "content": [{
                        "type": "tool_result",
                        "tool_use_id": msg.tool_use_id,
                        "content": msg.content,
                    }],
                })
            else:
                result.append({"role": msg.role, "content": msg.content})
        return result

    def to_tools(self, tools):
        return [
            {
                "name": tool.name,
                "description": tool.description,
                "input_schema": {
                    "type": "object",
                    "properties": tool.parameters,
                    "required": list(tool.parameters.keys()),
                },
            }
            for tool in tools.values()
        ]

    def to_payload(self, context, max_output_tokens=1024):
        return {
            "model": self.model,
            "system": context.system,
            "max_tokens": max_output_tokens,
            "tools": self.to_tools(context.tools),
            "messages": self.to_messages(context.messages),
        }

    def headers(self):
        return {
            "Content-Type": "application/json",
            "x-api-key": self.api_key,
            "anthropic-version": "2023-06-01",
        }

    def url(self):
        return self.BASE_URL
```

- `msg.role.to_s` → Python `Message.role` is already a plain string (set from
  whatever the caller passes, e.g. `"user"`/`:tool_result`); the example
  passes plain strings (see below), so no `.to_s`-equivalent coercion is
  needed on the Python side.
- `tool.parameters.keys.map(&:to_s)` → `list(tool.parameters.keys())`
  (`Tool.parameters` is already a plain string-keyed dict in Python).
- `headers`/`url` ported as **zero-arg methods**, not `@property`, to stay
  consistent with `to_messages`/`to_tools`/`to_payload` all being regular
  methods on the same class (mixing property and method style within one
  class would be inconsistent) — see Open Questions.

### `Backends::Gemini` (`backends/gemini.rb` → `backends/gemini.py`)

```python
from .base import Base


class Gemini(Base):
    BASE_URL = "https://generativelanguage.googleapis.com/v1beta/models"
    MODELS = {
        "gemini-3.5-flash": {
            "context_window": 1_048_576,
            "cost_per_million": {"input": 1.5, "output": 9.0},
            "usage_unit": "tokens",
        },
        "gemini-3.1-flash-lite": {
            "context_window": 1_048_576,
            "cost_per_million": {"input": 0.25, "output": 1.5},
            "usage_unit": "tokens",
        },
        "gemini-2.5-pro": {
            "context_window": 1_048_576,
            "cost_per_million": {"input": 1.25, "output": 10.0},
            "usage_unit": "tokens",
        },
        "gemini-2.5-flash": {
            "context_window": 1_048_576,
            "cost_per_million": {"input": 0.30, "output": 2.50},
            "usage_unit": "tokens",
        },
        "gemini-2.5-flash-lite": {
            "context_window": 1_048_576,
            "cost_per_million": {"input": 0.10, "output": 0.40},
            "usage_unit": "tokens",
        },
    }

    def __init__(self, api_key, model):
        self.api_key = api_key
        self._configure_model(model)

    def to_messages(self, messages):
        result = []
        for msg in messages:
            if msg.role == "assistant":
                result.append({"role": "model", "parts": [{"text": msg.content}]})
            elif msg.role == "tool_result":
                result.append({
                    "role": "user",
                    "parts": [{
                        "functionResponse": {
                            "name": msg.tool_use_id,
                            "response": {"content": msg.content},
                        }
                    }],
                })
            else:
                result.append({"role": msg.role, "parts": [{"text": msg.content}]})
        return result

    def to_tools(self, tools):
        if not tools:
            return []

        return [{
            "functionDeclarations": [
                {
                    "name": tool.name,
                    "description": tool.description,
                    "parameters": {
                        "type": "object",
                        "properties": tool.parameters,
                        "required": list(tool.parameters.keys()),
                    },
                }
                for tool in tools.values()
            ]
        }]

    def to_payload(self, context, max_output_tokens=1024):
        return {
            "systemInstruction": {"parts": [{"text": context.system}]},
            "contents": self.to_messages(context.messages),
            "tools": self.to_tools(context.tools),
            "generationConfig": {"maxOutputTokens": max_output_tokens},
        }

    def headers(self):
        return {
            "Content-Type": "application/json",
            "x-goog-api-key": self.api_key,
        }

    def url(self):
        return f"{self.BASE_URL}/{self.model}:generateContent"
```

- `tools.empty?` → `if not tools:` (`context.tools` is a dict; an empty dict
  is falsy).

### `Backends::Ollama` (`backends/ollama.rb` → `backends/ollama.py`)

```python
from .base import Base


class Ollama(Base):
    MODELS = {
        "gemma4": {
            "context_window": 128_000,
            "cost_per_million": {"input": 0.0, "output": 0.0},
            "usage_unit": "local_compute",
        },
        "gemma4:e2b": {
            "context_window": 128_000,
            "cost_per_million": {"input": 0.0, "output": 0.0},
            "usage_unit": "local_compute",
        },
        "gemma4:e4b": {
            "context_window": 128_000,
            "cost_per_million": {"input": 0.0, "output": 0.0},
            "usage_unit": "local_compute",
        },
        "gemma4:12b": {
            "context_window": 256_000,
            "cost_per_million": {"input": 0.0, "output": 0.0},
            "usage_unit": "local_compute",
        },
        "gemma4:26b": {
            "context_window": 256_000,
            "cost_per_million": {"input": 0.0, "output": 0.0},
            "usage_unit": "local_compute",
        },
        "gemma4:31b": {
            "context_window": 256_000,
            "cost_per_million": {"input": 0.0, "output": 0.0},
            "usage_unit": "local_compute",
        },
        "qwen3:30b": {
            "context_window": 256_000,
            "cost_per_million": {"input": 0.0, "output": 0.0},
            "usage_unit": "local_compute",
        },
        "qwen3:8b": {
            "context_window": 40_000,
            "cost_per_million": {"input": 0.0, "output": 0.0},
            "usage_unit": "local_compute",
        },
        "deepseek-r1:8b": {
            "context_window": 128_000,
            "cost_per_million": {"input": 0.0, "output": 0.0},
            "usage_unit": "local_compute",
        },
    }

    def __init__(self, model, host="http://localhost:11434"):
        self.host = host
        self._configure_model(model)

    def to_messages(self, system, messages):
        system_message = [{"role": "system", "content": system}]
        conversation = []
        for msg in messages:
            if msg.role == "tool_result":
                conversation.append({"role": "tool", "tool_name": msg.tool_use_id, "content": msg.content})
            else:
                conversation.append({"role": msg.role, "content": msg.content})
        return system_message + conversation

    def to_tools(self, tools):
        return [
            {
                "type": "function",
                "function": {
                    "name": tool.name,
                    "description": tool.description,
                    "parameters": {
                        "type": "object",
                        "properties": tool.parameters,
                        "required": list(tool.parameters.keys()),
                    },
                },
            }
            for tool in tools.values()
        ]

    def to_payload(self, context, max_output_tokens=1024):
        return {
            "model": self.model,
            "stream": False,
            "messages": self.to_messages(context.system, context.messages),
            "tools": self.to_tools(context.tools),
        }

    def headers(self):
        return {"Content-Type": "application/json"}

    def url(self):
        return f"{self.host}/api/chat"
```

- Constructor param order flipped (`model` first, `host` defaulted second) —
  see Design Considerations.
- `max_output_tokens` is accepted (matching the Ruby signature and the other
  four backends) but intentionally unused in the payload — this is a direct,
  faithful port: Ollama's local `/api/chat` payload in `to_payload` never
  references it in Ruby either. Don't "fix" this by wiring it in; that would
  be scope creep beyond the Ruby step 3 behaviour.

### `Backends::OllamaCloud` (`backends/ollama_cloud.rb` → `backends/ollama_cloud.py`)

```python
from .base import Base


class OllamaCloud(Base):
    BASE_URL = "https://ollama.com"
    MODELS = {
        "gemma4:31b-cloud": {
            "context_window": 256_000,
            "cost_per_million": {"input": None, "output": None},
            "usage_unit": "ollama_cloud_usage",
            "usage_level": "medium",
        },
        "minimax-m3:cloud": {
            "context_window": 512_000,
            "advertised_context_window": 1_000_000,
            "cost_per_million": {"input": None, "output": None},
            "usage_unit": "ollama_cloud_usage",
            "usage_level": "high",
        },
        "kimi-k2.5:cloud": {
            "context_window": 256_000,
            "cost_per_million": {"input": None, "output": None},
            "usage_unit": "ollama_cloud_usage",
            "usage_level": "high",
        },
    }

    def __init__(self, api_key, model):
        self.api_key = api_key
        self._configure_model(model)

    def to_messages(self, system, messages):
        system_message = [{"role": "system", "content": system}]
        conversation = []
        for msg in messages:
            if msg.role == "tool_result":
                conversation.append({"role": "tool", "tool_name": msg.tool_use_id, "content": msg.content})
            else:
                conversation.append({"role": msg.role, "content": msg.content})
        return system_message + conversation

    def to_tools(self, tools):
        return [
            {
                "type": "function",
                "function": {
                    "name": tool.name,
                    "description": tool.description,
                    "parameters": {
                        "type": "object",
                        "properties": tool.parameters,
                        "required": list(tool.parameters.keys()),
                    },
                },
            }
            for tool in tools.values()
        ]

    def to_payload(self, context, max_output_tokens=1024):
        return {
            "model": self.model,
            "stream": False,
            "messages": self.to_messages(context.system, context.messages),
            "tools": self.to_tools(context.tools),
        }

    def headers(self):
        return {
            "Content-Type": "application/json",
            "Authorization": f"Bearer {self.api_key}",
        }

    def url(self):
        return f"{self.BASE_URL}/api/chat"
```

- Same `max_output_tokens`-unused note as `Ollama` applies here.
- `advertised_context_window` on `minimax-m3:cloud` is carried over verbatim
  even though nothing in `Base` reads it — it's inert tutorial data on the
  Ruby side too, port it as-is rather than dropping it.

### `Backends::OpenAI` (`backends/openai.rb` → `backends/openai.py`)

```python
from .base import Base


class OpenAI(Base):
    BASE_URL = "https://api.openai.com/v1/chat/completions"
    MODELS = {
        "gpt-5.5": {
            "context_window": 1_000_000,
            "cost_per_million": {"input": 5.0, "output": 30.0},
            "usage_unit": "tokens",
        },
        "gpt-5.4": {
            "context_window": 1_000_000,
            "cost_per_million": {"input": 2.5, "output": 15.0},
            "usage_unit": "tokens",
        },
        "gpt-5.4-mini": {
            "context_window": 400_000,
            "cost_per_million": {"input": 0.75, "output": 4.5},
            "usage_unit": "tokens",
        },
    }

    def __init__(self, api_key, model):
        self.api_key = api_key
        self._configure_model(model)

    def to_messages(self, system, messages):
        system_message = [{"role": "system", "content": system}]
        conversation = []
        for msg in messages:
            if msg.role == "tool_result":
                conversation.append({"role": "tool", "tool_call_id": msg.tool_use_id, "content": msg.content})
            else:
                conversation.append({"role": msg.role, "content": msg.content})
        return system_message + conversation

    def to_tools(self, tools):
        return [
            {
                "type": "function",
                "function": {
                    "name": tool.name,
                    "description": tool.description,
                    "parameters": {
                        "type": "object",
                        "properties": tool.parameters,
                        "required": list(tool.parameters.keys()),
                    },
                },
            }
            for tool in tools.values()
        ]

    def to_payload(self, context, max_output_tokens=1024):
        return {
            "model": self.model,
            "messages": self.to_messages(context.system, context.messages),
            "tools": self.to_tools(context.tools),
            "max_completion_tokens": max_output_tokens,
        }

    def headers(self):
        return {
            "Content-Type": "application/json",
            "Authorization": f"Bearer {self.api_key}",
        }

    def url(self):
        return self.BASE_URL
```

- Note `tool_call_id` (not `tool_name`, unlike Ollama/OllamaCloud) — this is
  the one field-name divergence between the three "inline system message"
  backends; port exactly as shown.

### `boukensha/backends/__init__.py` (new — no direct Ruby equivalent, needed for the module-qualified access pattern)

```python
from .anthropic import Anthropic
from .base import Base
from .gemini import Gemini
from .ollama import Ollama
from .ollama_cloud import OllamaCloud
from .openai import OpenAI

__all__ = [
    "Anthropic",
    "Base",
    "Gemini",
    "Ollama",
    "OllamaCloud",
    "OpenAI",
]
```

### `PromptBuilder` (`prompt_builder.rb` → `prompt_builder.py`)

Ruby:

```ruby
module Boukensha
  class PromptBuilder
    def initialize(context, backend)
      @context = context
      @backend = backend
    end

    def to_messages
      @backend.to_messages(@context.messages)
    end

    def to_tools
      @backend.to_tools(@context.tools)
    end

    def to_api_payload(max_output_tokens: 1024)
      @backend.to_payload(@context, max_output_tokens: max_output_tokens)
    end

    def headers
      @backend.headers
    end

    def url
      @backend.url
    end
  end
end
```

Python target:

```python
class PromptBuilder:
    def __init__(self, context, backend):
        self.context = context
        self.backend = backend

    def to_messages(self):
        return self.backend.to_messages(self.context.messages)

    def to_tools(self):
        return self.backend.to_tools(self.context.tools)

    def to_api_payload(self, max_output_tokens=1024):
        return self.backend.to_payload(self.context, max_output_tokens=max_output_tokens)

    def headers(self):
        return self.backend.headers()

    def url(self):
        return self.backend.url()
```

See the "`PromptBuilder.to_messages` has a latent arity bug" note in Design
Considerations — port `to_messages` exactly as shown (single arg passed
through), do not adapt it to work with all five backends.

### Top-level exports (`lib/boukensha.rb` → `boukensha/__init__.py`)

Ruby adds requires for `prompt_builder` and all five `backends/*` files:

```ruby
require_relative "boukensha/config"
require_relative "boukensha/tool"
require_relative "boukensha/message"
require_relative "boukensha/context"
require_relative "boukensha/errors"
require_relative "boukensha/registry"
require_relative "boukensha/prompt_builder"
require_relative "boukensha/backends/base"
require_relative "boukensha/backends/anthropic"
require_relative "boukensha/backends/gemini"
require_relative "boukensha/backends/ollama"
require_relative "boukensha/backends/ollama_cloud"
require_relative "boukensha/backends/openai"
```

Python target — add `PromptBuilder`, `UnsupportedModelError`, and the
`backends` subpackage while preserving the existing exports:

```python
from . import backends
from .config import Config
from .context import Context
from .errors import UnknownToolError, UnsupportedModelError
from .message import Message
from .prompt_builder import PromptBuilder
from .registry import Registry
from .tasks.player import Player
from .tool import Tool

__all__ = [
    "Config",
    "Context",
    "Message",
    "Player",
    "PromptBuilder",
    "Registry",
    "Tool",
    "UnknownToolError",
    "UnsupportedModelError",
    "backends",
]
```

### `Config` (`config.rb` → `config.py`)

No action needed — `PROMPTS_DIR` already exists in
`week1_baseline/python/03_prompt_builder/boukensha/config.py` (added ahead of
schedule during the `02_the_registry` port). Confirm it still matches:

```python
PROMPTS_DIR = Path(__file__).resolve().parent.parent / "prompts"
```

### `Context` (`context.rb` → `context.py`)

No action needed. The only Ruby diff (removing the stray `# This isn'`
comment, adding a trailing EOF newline) has no Python-side equivalent to
apply — the comment was already excluded during the `02_the_registry` port,
and the Python file isn't missing a trailing newline.

### Example (`examples/example.rb` → `examples/example.py`)

Port the Ruby example as the smoke test:

```ruby
ENV["BOUKENSHA_DIR"] ||= File.expand_path("../../../../.boukensha", __dir__)
require_relative "../lib/boukensha"
require "json"

config          = Boukensha::Config.new
player_settings = config.tasks(:player)
system_prompt   = Boukensha::Tasks::Player.system_prompt(
  player_settings,
  user_prompts_dir: config.user_prompts_dir,
  default_prompts_dir: Boukensha::Config::PROMPTS_DIR
)

ctx      = Boukensha::Context.new(task: Boukensha::Tasks::Player, system: system_prompt)
registry = Boukensha::Registry.new(ctx)

registry.tool("look",
  description: "Look around the current room for details",
  parameters: {}
) do
  "A damp stone corridor stretches north. Torches flicker on the walls."
end

registry.tool("move",
  description: "Move the player in a direction (north, south, east, west, up, down)",
  parameters: { direction: { type: "string", description: "The direction to move" } }
) do |direction:|
  "You move #{direction} into a torch-lit corridor."
end

ctx.add_message(:user, "I just arrived in the dungeon. What's around me, and can you move north?")
ctx.add_message(:assistant, "Let me take a look around first.")
ctx.add_message(:tool_result, "A damp stone corridor stretches north. Torches flicker on the walls.", tool_use_id: "toolu_01X")

puts "=== BOUKENSHA Step 3: Prompt Builder ==="
provider = Boukensha::Tasks::Player.provider(player_settings)
model    = Boukensha::Tasks::Player.model(player_settings)

backend =
case provider
when "anthropic"
  Boukensha::Backends::Anthropic.new(api_key: ENV.fetch("ANTHROPIC_API_KEY"), model: model)
when "ollama"
  Boukensha::Backends::Ollama.new(model: model)
when "ollama_cloud"
  Boukensha::Backends::OllamaCloud.new(api_key: ENV.fetch("OLLAMA_API_KEY"), model: model)
when "openai"
  Boukensha::Backends::OpenAI.new(api_key: ENV.fetch("OPENAI_API_KEY"), model: model)
when "gemini"
  Boukensha::Backends::Gemini.new(api_key: ENV.fetch("GEMINI_API_KEY"), model: model)
else
  raise ArgumentError, "Unsupported provider for player task: #{provider}"
end

builder = Boukensha::PromptBuilder.new(ctx, backend)

puts
puts "Config: #{config}"
puts "Provider: #{provider}"
puts "Model: #{model}"
puts JSON.pretty_generate(builder.to_api_payload)
```

Notice two intentional drifts vs. the step 2 example, both carried into
Python:
- `move`'s `direction` parameter regains the per-argument `description` key
  that step 2 had dropped — port with the description restored.
- A new zero-arg `look` tool is registered (no keyword-arg block, empty
  `parameters: {}`) — this maps to a zero-arg Python function under the
  `@registry.tool` decorator.
- Unlike step 2, this example never calls `registry.dispatch` — it only
  registers tools and builds a payload showing their schemas, so `look`'s and
  `move`'s function bodies are never actually invoked by the smoke test.

Python target (`examples/example.py`):

```python
import json
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from boukensha import Config, Context, Player, PromptBuilder, Registry, backends

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
    "look",
    description="Look around the current room for details",
    parameters={},
)
def look():
    return "A damp stone corridor stretches north. Torches flicker on the walls."


@registry.tool(
    "move",
    description="Move the player in a direction (north, south, east, west, up, down)",
    parameters={"direction": {"type": "string", "description": "The direction to move"}},
)
def move(direction):
    return f"You move {direction} into a torch-lit corridor."


ctx.add_message("user", "I just arrived in the dungeon. What's around me, and can you move north?")
ctx.add_message("assistant", "Let me take a look around first.")
ctx.add_message(
    "tool_result",
    "A damp stone corridor stretches north. Torches flicker on the walls.",
    tool_use_id="toolu_01X",
)

print("=== BOUKENSHA Step 3: Prompt Builder ===")
provider = Player.provider(player_settings)
model = Player.model(player_settings)

if provider == "anthropic":
    backend = backends.Anthropic(api_key=os.environ["ANTHROPIC_API_KEY"], model=model)
elif provider == "ollama":
    backend = backends.Ollama(model=model)
elif provider == "ollama_cloud":
    backend = backends.OllamaCloud(api_key=os.environ["OLLAMA_API_KEY"], model=model)
elif provider == "openai":
    backend = backends.OpenAI(api_key=os.environ["OPENAI_API_KEY"], model=model)
elif provider == "gemini":
    backend = backends.Gemini(api_key=os.environ["GEMINI_API_KEY"], model=model)
else:
    raise ValueError(f"Unsupported provider for player task: {provider}")

builder = PromptBuilder(ctx, backend)

print()
print(f"Config: {config}")
print(f"Provider: {provider}")
print(f"Model: {model}")
print(json.dumps(builder.to_api_payload(), indent=2))
```

- `ENV.fetch("ANTHROPIC_API_KEY")` (raises if unset) → `os.environ["ANTHROPIC_API_KEY"]`
  (also raises `KeyError` if unset) — same failure mode, not `os.environ.get`.
- `:user`/`:assistant`/`:tool_result` Ruby symbols → plain Python strings
  `"user"`/`"assistant"`/`"tool_result"`, matching `Context.add_message`'s
  existing Python signature (already ported, unchanged) and matching how the
  backends compare `msg.role` against plain strings.
- `JSON.pretty_generate(builder.to_api_payload)` → `json.dumps(builder.to_api_payload(), indent=2)`.
- Keep the existing Python ordering established in step 2 (import first, then
  `os.environ.setdefault`, then `Config()`) rather than mimicking Ruby's
  reordering — same reasoning as the `02_the_registry` plan.

### README

Replace the copied step-2 README with step-3 content, following the Ruby
README's structure (New Files / How It Works / `Boukensha::PromptBuilder`
table / Backends section incl. model tables and per-backend subsections /
System Prompt / Tool Results / Tool Definitions / Message Roles /
Considerations / Run Example), translated to `boukensha.PromptBuilder` /
`boukensha.backends.*` naming and Python code snippets. Two corrections to
make relative to the Ruby source doc:
- Fix the run command to point at the actual Python launcher path
  (`./week1_baseline/bin/python/03_prompt_builder`) — the Ruby README's own
  run command has the same stale-path bug flagged in the `02_the_registry`
  plan (`./week1_baseline/bin/03_prompt_builder`, missing the `ruby/`
  segment). Don't reproduce that typo.
- The Ruby README has no "Expected Output" section (unlike step 2's), because
  the payload's exact content depends on which provider/model the reader has
  configured in their own `~/.boukensha/settings.yaml` and requires a
  provider-appropriate env var to be set. Follow the same omission in Python
  rather than fabricating a hardcoded payload — instead, briefly note in the
  README that running this step requires `tasks.player.provider`/`model` set
  in `settings.yaml` (one of the supported values for that provider's
  backend) and the matching API key env var present (any non-empty string
  works, since no network call is made — see Design Considerations).

Keep the root-venv setup block already present in the copied README (same as
steps 0–2), updating the `pip install -r` path to
`week1_baseline/python/03_prompt_builder/requirements.txt`.

### Launcher

Add:

```text
week1_baseline/bin/python/03_prompt_builder
```

Same style as `week1_baseline/bin/python/02_the_registry`:

```bash
#!/usr/bin/env bash

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$SCRIPT_DIR/../../.."

cd "$SCRIPT_DIR/../../python/03_prompt_builder"
"$REPO_ROOT/.venv/bin/python" examples/example.py
```

Make it executable.

## Configuration Schema

Unchanged from steps 0–2.

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

`provider` must be one of `anthropic` / `ollama` / `ollama_cloud` / `openai` /
`gemini`, and `model` must be a key present in that backend's `MODELS` table
(e.g. `claude-haiku-4-5` for `anthropic`), or the example raises
`UnsupportedModelError` at backend construction time.

## Implementation Steps

1. Confirm the existing `week1_baseline/python/03_prompt_builder` snapshot is
   the copied Python `02_the_registry` port (README/example still say
   "Step 2").
2. Update `boukensha/errors.py` to add `UnsupportedModelError`.
3. Add `boukensha/backends/base.py` (`Base` with `models`/`model_info`/
   `validate_model` classmethods and the property-based instance API).
4. Add `boukensha/backends/anthropic.py`, `gemini.py`, `ollama.py`,
   `ollama_cloud.py`, `openai.py`.
5. Add `boukensha/backends/__init__.py` re-exporting all five backend classes
   plus `Base`.
6. Add `boukensha/prompt_builder.py` (`PromptBuilder`).
7. Update `boukensha/__init__.py` to export `PromptBuilder`,
   `UnsupportedModelError`, and `backends`.
8. Replace `examples/example.py` with the step 3 prompt-builder example.
9. Replace `README.md` with the step 3 content (with the two corrections
   noted above).
10. Add `week1_baseline/bin/python/03_prompt_builder` and make it executable.
11. Ensure `~/.boukensha/settings.yaml` has a supported `tasks.player.provider`/`model`
    pair and the matching API key env var is set (any placeholder value —
    no network call is made), then run the smoke test through the launcher.

## Verification

Run:

```bash
./week1_baseline/bin/python/03_prompt_builder
```

Preconditions: `~/.boukensha/settings.yaml` has `tasks.player.provider` set to
one of `anthropic`/`ollama`/`ollama_cloud`/`openai`/`gemini` with a `model`
value present in that backend's `MODELS` table, and (for every provider
except `ollama`, which needs no key) the corresponding API key env var is set
to any non-empty string.

Expected checks:

- exits with status 0
- prints `=== BOUKENSHA Step 3: Prompt Builder ===`
- prints `Config:`, `Provider:`, and `Model:` lines matching the configured
  task settings
- prints a pretty-printed JSON payload whose shape matches the configured
  provider (`system`/`messages`/`tools` top-level keys for Anthropic;
  `systemInstruction`/`contents`/`tools` for Gemini; a `messages` array with a
  leading `role: system` entry for Ollama/OllamaCloud/OpenAI)
- the payload's `tools` entries include both `look` (empty `properties`/
  `required`) and `move` (`direction` in both `properties` and `required`)
- switching `tasks.player.provider` in `settings.yaml` to a value not in
  `{anthropic, ollama, ollama_cloud, openai, gemini}` causes the script to
  raise `ValueError: Unsupported provider for player task: <value>` and exit
  non-zero (mirroring Ruby's `raise ArgumentError`)
- setting `tasks.player.model` to a value absent from the selected backend's
  `MODELS` table causes `UnsupportedModelError` to be raised during backend
  construction

No `pytest` suite is required for this step.

## Open Questions

1. **Preserving the `PromptBuilder.to_messages` arity bug.** This plan
   recommends porting `PromptBuilder.to_messages` faithfully (always passing
   exactly `context.messages`), which means calling it with an Ollama/OpenAI/
   OllamaCloud backend raises a Python `TypeError` — mirroring Ruby's
   `ArgumentError` for the same call. The bug is unexercised by
   `example.py` (which only calls `to_api_payload`), so it doesn't block the
   smoke test either way. Confirm faithful preservation is correct here,
   consistent with how the `02_the_registry` plan preserved the
   Context/Registry ownership gotcha instead of fixing it.
   - in future steps we use errors so dont worry about this issue.
2. **`model_info` naming collision resolution.** Ruby has both a class method
   `Base.model_info(model)` and a same-named instance method
   `model_info` — impossible to replicate literally in Python under one name.
   This plan proposes keeping `model_info` as the public classmethod only,
   and using a private `self._model_info` instance attribute (read directly
   by `context_window`/`input_token_cost_per_million`/etc.) instead of a
   public instance-level `model_info` method. Confirm this is acceptable,
   since the Ruby README's documented public backend surface never lists
   instance-level `model_info` as something callers use directly.
   - do what you have to make it work.
3. **`headers`/`url` as zero-arg methods, not `@property`.** Ruby's parens-
   optional method calls make `backend.headers`/`backend.url` read like
   attribute access even though they're regular methods. This plan ports them
   as plain zero-arg Python methods (`backend.headers()`, `backend.url()`) to
   stay stylistically consistent with `to_messages`/`to_tools`/`to_payload` on
   the same class, rather than mixing in `@property` (which `Context`/`Config`
   use elsewhere in this codebase for computed no-arg values). Confirm this
   consistency argument is preferred over matching `Context`'s `@property`
   convention.
   - I see no issue here.
