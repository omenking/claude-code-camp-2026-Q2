# Python Port Plan — 04 · The API Client

## Goal

Port `week1_baseline/ruby/04_api_client` to Python as
`week1_baseline/python/04_api_client`, preserving the Ruby step's public
surface and example behaviour.

`week1_baseline/python/04_api_client` already exists but is currently just an
unmodified copy of the completed `week1_baseline/python/03_prompt_builder`
port (confirmed via `diff -rq` — zero differences other than generated
`__pycache__` directories, which are already `.gitignore`d and untracked).
This plan is therefore only for the **step 4 delta**: compare Ruby
`03_prompt_builder` to Ruby `04_api_client` (`diff -rq`), then apply only
those new changes to the existing Python `04_api_client` folder.

This step adds a `Boukensha::Client` that takes the payload assembled by
`PromptBuilder`, POSTs it to the backend's API endpoint using only Ruby's
standard library (`net/http`, no gems), retries on transient network errors
and retryable HTTP status codes, and raises `Boukensha::ApiError` on
persistent failure. It's a single request/response round trip — no tool-call
handling or agent loop yet (that's step 5).

## Reference files (source of truth — read these before porting)

| Ruby file | Role |
|---|---|
| `week1_baseline/ruby/04_api_client/README.md` | Behaviour/spec doc for this step |
| `week1_baseline/ruby/04_api_client/lib/boukensha/client.rb` | New `Boukensha::Client` — HTTP POST with retry logic |
| `week1_baseline/ruby/04_api_client/lib/boukensha/errors.rb` | Adds `Boukensha::ApiError` |
| `week1_baseline/ruby/04_api_client/lib/boukensha/config.rb` | `PROMPTS_DIR` comment change (see Design Considerations — do not port the path arithmetic change) |
| `week1_baseline/ruby/04_api_client/lib/boukensha/tasks/base.rb` | `settings.yml` → `settings.yaml` message fix; `fetch` now guards non-`Hash` `settings` |
| `week1_baseline/ruby/04_api_client/lib/boukensha.rb` | Adds `require_relative "boukensha/client"` |
| `week1_baseline/ruby/04_api_client/prompts/system.md` | New default system prompt text |
| `week1_baseline/ruby/04_api_client/examples/example.rb` | Rewritten: `read_file`/`list_directory` tools replace `look`/`move`, builds a `Client`, POSTs, prints the raw response |
| `week1_baseline/bin/ruby/04_api_client` | Ruby launcher shape; create the analogous Python launcher |

Unchanged from step 3 (confirmed via `diff -rq` — zero diff, compare only, do
not re-port):

| Ruby file | Note |
|---|---|
| `lib/boukensha/registry.rb`, `lib/boukensha/tool.rb`, `lib/boukensha/message.rb`, `lib/boukensha/context.rb` | No diff |
| `lib/boukensha/prompt_builder.rb` | No diff |
| `lib/boukensha/backends/*.rb` (all five + `base.rb`) | No diff — model tables/serialization unchanged |
| `lib/boukensha/tasks/player.rb` | No diff |
| `Gemfile` / `Gemfile.lock` | No diff — still just `dotenv`, confirming `Client` adds no new gem dependency |

Existing Python snapshot to modify:

| Python file | Role |
|---|---|
| `week1_baseline/python/04_api_client/` | Currently an unmodified copy of the `03_prompt_builder` Python port; apply the step 4 delta here |
| `week1_baseline/python/04_api_client/boukensha/context.py`, `message.py`, `registry.py`, `tool.py`, `prompt_builder.py`, `backends/` | Existing ports; should remain unchanged — no Ruby step 4 delta touches their behaviour |
| `week1_baseline/python/04_api_client/README.md` | Currently the step-3 README; replace with the step-4 content |
| `week1_baseline/python/04_api_client/examples/example.py` | Currently the step-3 example; replace with the step-4 client example |
| `week1_baseline/bin/python/03_prompt_builder` | Launcher convention to follow for the new `04_api_client` launcher |

## Design Considerations

- **The snapshot already exists.** Do not copy `python/03_prompt_builder`
  again. Treat `week1_baseline/python/04_api_client/` as the working snapshot
  and only add/update the files required by the Ruby step 4 delta.
- **No new dependencies — stdlib only, matching Ruby's "no gems" stance.**
  Ruby's README is explicit: *"`Client` uses Ruby's standard `net/http`
  library. No gems, no `bundle install`. This is intentional — the HTTP call
  itself is trivial and should be visible, not hidden behind a library."*
  Port with Python's stdlib `urllib.request` / `urllib.error` / `json` / `ssl`
  / `socket` / `time`, not `requests` or `httpx`. `requirements.txt` needs no
  additions.
- **Ruby's `Net::HTTP` never raises on non-2xx responses; Python's
  `urllib.request.urlopen` does.** This is the one real semantic gap to
  bridge carefully. In Ruby, `http.request(request)` always returns a
  response object — `retryable_response?`/`response.is_a?(Net::HTTPSuccess)`
  inspect its status code afterward. In Python, `urllib.request.urlopen`
  raises `urllib.error.HTTPError` for any 4xx/5xx status (it's a subclass of
  both `URLError` and `OSError`, and also acts as a file-like response
  object). Catch `HTTPError` explicitly and pull `status`/`response_body` off
  it (via `.code` and `.read()`) so the retry/status-check logic downstream
  can treat it identically to a normal response — do not let it propagate as
  an uncaught exception.
- **Mapping Ruby's `TRANSIENT_ERRORS` list to Python.** Ruby lists concrete
  low-level exceptions it retries on: `EOFError`, `Errno::ECONNRESET`,
  `Errno::ECONNREFUSED`, `Net::OpenTimeout`, `Net::ReadTimeout`,
  `OpenSSL::SSL::SSLError`, `SocketError`, `Timeout::Error`. Python's
  `urllib.request.urlopen` wraps most connect-time failures (DNS failure,
  connection refused, TLS handshake failure, timeout) in
  `urllib.error.URLError` (with the original exception on `.reason`), while
  some read-time failures (e.g. a reset connection mid-read) can surface as
  raw `ConnectionResetError`/`TimeoutError`/`ssl.SSLError`. Catch a tuple that
  covers both wrapped and raw cases:
  `(urllib.error.URLError, TimeoutError, ConnectionError, ssl.SSLError, EOFError, socket.gaierror)`
  — placed **after** the `HTTPError` except clause (since `HTTPError` is a
  `URLError` subclass and represents a real, non-transient HTTP response, not
  a network failure). `ConnectionError` is Python's builtin base class
  covering both `ConnectionResetError` and `ConnectionRefusedError`, so it
  subsumes Ruby's two separate `Errno::` entries in one clause.
- **SSL verification needs no explicit setup.** Ruby's `client.rb` comment
  explains it deliberately omits `http.ca_file =
  OpenSSL::X509::DEFAULT_CERT_FILE` because that macOS-specific path doesn't
  exist on Linux/WSL2, and omitting it lets OpenSSL find system certs
  automatically. Python's `urllib.request.urlopen` already uses
  `ssl.create_default_context()` for `https://` URLs by default, which
  verifies against the system trust store the same way — no `ssl.SSLContext`
  needs to be constructed or passed. Port `Client` without any SSL
  configuration at all; this is the direct Python equivalent of Ruby's
  "omit `ca_file`" fix, not a gap to fill in.
- **Retry loop shape.** Port the `attempts`/`while True` structure directly:
  increment `attempts` first, try the request, catch transient errors (retry
  with backoff up to `MAX_RETRIES`, else raise `ApiError`), then check if the
  *response itself* (success or `HTTPError`) has a retryable status code
  (retry with backoff up to `MAX_RETRIES`, else fall through), then break.
  After the loop, raise `ApiError` if the final status isn't 2xx, otherwise
  `json.loads` the body and return it.
- **`retry_delay`/backoff formula ported exactly.** `BASE_RETRY_DELAY * (2 **
  (attempt - 1))` — same constant (`0.5`) and same exponent, giving delays of
  `0.5, 1.0, 2.0` seconds for attempts 1–3, matching Ruby exactly.
- **`Client.call`'s `max_output_tokens` keyword.** Ruby declares
  `call(max_output_tokens: 1024)` (required-looking but defaulted keyword
  arg). Following the convention already established in this port (plain
  positional-or-keyword params instead of Python's keyword-only `*,` syntax
  — see the `03_prompt_builder` plan's `estimate_cost`/`to_api_payload`
  precedent), port as `def call(self, max_output_tokens=1024):`.
- **`Client.headers()`/`url()` calls.** `PromptBuilder.headers()`/`url()`
  are already zero-arg methods (not properties) from the step 3 port — call
  them as `self.builder.headers()` / `self.builder.url()`, consistent with
  that existing convention.
- **Flagged Ruby-side bug: do not port the `config.rb` `PROMPTS_DIR` path
  change.** Ruby's diff changes `PROMPTS_DIR` from
  `File.expand_path("../../prompts", __dir__)` to
  `File.expand_path("../../../prompts", __dir__)` (2-up → 3-up from
  `lib/boukensha/`), while also changing the comment from *"Default prompts
  shipped alongside the gem/library code."* to *"Default prompts shipped
  alongside this step."* The comment states clear intent (point at this
  step's own `prompts/` dir), but the added `../` actually breaks that intent
  — verified by computing the path: it now resolves to
  `week1_baseline/ruby/prompts` (one level *above* `04_api_client/`), which
  doesn't exist (`week1_baseline/ruby/04_api_client/prompts/system.md` is
  where the file actually lives). Because `Tasks::Base.read_default_prompt`
  silently returns `nil` when the path doesn't exist (`File.exist?(path) ?
  File.read(path).strip : nil` — no exception raised), this bug doesn't crash
  the Ruby example, it just silently drops the default system prompt
  whenever `prompt_override.system` isn't set to `true`, sending `system:
  null`/no system message to the API instead of the intended prompt. This
  mirrors the "flag it, don't reproduce it" precedent set in the
  `03_prompt_builder` plan for the README's stale run-command path. Action:
  leave Python's `PROMPTS_DIR` path arithmetic exactly as it already is
  (`Path(__file__).resolve().parent.parent / "prompts"`, which correctly
  resolves to `week1_baseline/python/04_api_client/prompts` — the Python
  equivalent of Ruby's *original, working* 2-up formula), and only update the
  comment text to match Ruby's new wording. Flagged as an Open Question below
  in case the bug should be reproduced faithfully instead.
- **`tasks/base.rb`'s `fetch` guard is a real, portable fix — apply it.**
  Unlike the `PROMPTS_DIR` change, `fetch(settings, key)` gaining `return nil
  unless settings.is_a?(Hash)` is a genuine defensive fix (guards against
  `config.tasks("player")` returning `nil` when no `tasks.player` key exists,
  which previously would raise `NoMethodError` on `nil[key]`). Python's
  current `Base._fetch` is `return settings.get(key)`, which would raise
  `AttributeError` the same way if `settings` were `None`. Port the guard as
  `if not isinstance(settings, dict): return None` at the top of `_fetch`.
- **`settings.yml` → `settings.yaml` typo fix — apply it.** Both of Python's
  existing error messages in `tasks/base.py` (`provider`/`model` required)
  still say `settings.yml`; Ruby's step 4 diff fixes this to `settings.yaml`
  (matching the actual filename `Config` reads,
  `os.path.join(self.dir, "settings.yaml")`). Apply the same text fix on the
  Python side.
- **`errors.rb`'s ordering.** Ruby inserts `ApiError` between
  `UnknownToolError` and `UnsupportedModelError`. Mirror that ordering in
  `errors.py` for easy side-by-side diffing, though it has no functional
  effect.
- **`lib/boukensha.rb` drops the explicit `require_relative
  "boukensha/backends/base"` line.** This is a Ruby-only cleanup (each
  `backends/*.rb` file already does its own `require_relative "base"`
  internally, making the top-level require redundant) with no Python
  equivalent to apply — Python's `boukensha/backends/__init__.py` already
  imports `Base` directly and nothing needs to change there.
- **README's "New Files"/"Updated Files" tables list files that already
  exist from step 3** (`backends/base.rb`, `tasks/base.rb`, `tasks/player.rb`,
  `prompts/system.md` as "new"; `backends/*.rb` as "updated" despite
  `diff -rq` showing zero diff). This looks like leftover copy/paste
  drift in the Ruby doc rather than an accurate description of *this* diff.
  Write the Python README's own New/Updated Files tables from the actual step
  4 delta (`client.py`, `errors.py`'s `ApiError`, `config.py`'s comment,
  `tasks/base.py`'s two fixes, `prompts/system.md`'s new text), not a literal
  translation of the Ruby table.
- **Example reorders the provider `case`/`if` branches** (Anthropic → OpenAI
  → Gemini → Ollama → OllamaCloud, vs. step 3's Anthropic → Ollama →
  OllamaCloud → OpenAI → Gemini) and reformats each branch's keyword args
  onto multiple lines. This is purely cosmetic — no behavioural difference —
  so port the Python `if`/`elif` chain in whatever order is clearer; there's
  no strong reason to match Ruby's new ordering exactly, but doing so costs
  nothing either. This plan reorders to match Ruby for easy diffing.
- **No formal test suite.** Per the decision recorded in `00_config`, keep
  this to smoke-test examples, same as steps 0–3.

## Target file layout

```
week1_baseline/python/04_api_client/
  requirements.txt                  # unchanged
  README.md                         # replaced
  boukensha/
    __init__.py                     # updated: + Client, ApiError
    client.py                       # new
    config.py                       # updated: comment only
    context.py
    errors.py                       # updated: + ApiError
    message.py
    prompt_builder.py
    registry.py
    tool.py
    backends/
      __init__.py
      base.py
      anthropic.py
      gemini.py
      ollama.py
      ollama_cloud.py
      openai.py
    tasks/
      __init__.py
      base.py                       # updated: yml->yaml message, Hash guard
      player.py
  prompts/
    system.md                       # replaced
  examples/
    example.py                      # replaced
week1_baseline/bin/python/04_api_client
```

## Porting notes (Ruby → Python mapping)

### `Errors` (`errors.rb` → `errors.py`)

Ruby:

```ruby
module Boukensha
  class UnknownToolError < StandardError; end
  class ApiError         < StandardError; end
  class UnsupportedModelError < StandardError; end
end
```

Python target:

```python
class UnknownToolError(Exception):
    pass


class ApiError(Exception):
    pass


class UnsupportedModelError(Exception):
    pass
```

### `Client` (`client.rb` → `client.py`)

Ruby:

```ruby
require "net/http"
require "json"
require "openssl"

module Boukensha
  class Client
    RETRYABLE_STATUS_CODES = [408, 409, 429, 500, 502, 503, 504].freeze
    TRANSIENT_ERRORS = [
      EOFError,
      Errno::ECONNRESET,
      Errno::ECONNREFUSED,
      Net::OpenTimeout,
      Net::ReadTimeout,
      OpenSSL::SSL::SSLError,
      SocketError,
      Timeout::Error
    ].freeze
    MAX_RETRIES = 3
    BASE_RETRY_DELAY = 0.5

    def initialize(builder)
      @builder = builder
    end

    def call(max_output_tokens: 1024)
      uri          = URI(@builder.url)
      http         = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.verify_mode = OpenSSL::SSL::VERIFY_PEER

      request      = Net::HTTP::Post.new(uri, @builder.headers)
      request.body = @builder.to_api_payload(max_output_tokens: max_output_tokens).to_json

      attempts = 0
      response = nil

      loop do
        attempts += 1

        begin
          response = http.request(request)
        rescue *TRANSIENT_ERRORS => e
          raise ApiError, "API request failed after #{attempts} attempts: #{e.class}: #{e.message}" if attempts > MAX_RETRIES

          sleep retry_delay(attempts)
          next
        end

        if retryable_response?(response) && attempts <= MAX_RETRIES
          sleep retry_delay(attempts)
          next
        end

        break
      end

      unless response.is_a?(Net::HTTPSuccess)
        raise ApiError, "API request failed after #{attempts} attempt#{'s' unless attempts == 1} (#{response.code}): #{response.body}"
      end

      JSON.parse(response.body)
    end

    private

    def retryable_response?(response)
      RETRYABLE_STATUS_CODES.include?(response.code.to_i)
    end

    def retry_delay(attempt)
      BASE_RETRY_DELAY * (2**(attempt - 1))
    end
  end
end
```

Python target:

```python
import json
import socket
import ssl
import time
import urllib.error
import urllib.request

from .errors import ApiError


class Client:
    RETRYABLE_STATUS_CODES = {408, 409, 429, 500, 502, 503, 504}
    TRANSIENT_ERRORS = (
        urllib.error.URLError,
        TimeoutError,
        ConnectionError,
        ssl.SSLError,
        EOFError,
        socket.gaierror,
    )
    MAX_RETRIES = 3
    BASE_RETRY_DELAY = 0.5

    def __init__(self, builder):
        self.builder = builder

    def call(self, max_output_tokens=1024):
        url = self.builder.url()
        headers = self.builder.headers()
        body = json.dumps(
            self.builder.to_api_payload(max_output_tokens=max_output_tokens)
        ).encode("utf-8")

        attempts = 0
        status = None
        response_body = None

        while True:
            attempts += 1
            request = urllib.request.Request(url, data=body, headers=headers, method="POST")

            try:
                with urllib.request.urlopen(request) as response:
                    status = response.status
                    response_body = response.read()
            except urllib.error.HTTPError as e:
                status = e.code
                response_body = e.read()
            except self.TRANSIENT_ERRORS as e:
                if attempts > self.MAX_RETRIES:
                    raise ApiError(
                        f"API request failed after {attempts} attempts: {type(e).__name__}: {e}"
                    )
                time.sleep(self._retry_delay(attempts))
                continue

            if self._retryable_response(status) and attempts <= self.MAX_RETRIES:
                time.sleep(self._retry_delay(attempts))
                continue

            break

        if not (200 <= status < 300):
            plural = "" if attempts == 1 else "s"
            raise ApiError(
                f"API request failed after {attempts} attempt{plural} "
                f"({status}): {response_body.decode('utf-8', errors='replace')}"
            )

        return json.loads(response_body)

    def _retryable_response(self, status):
        return status in self.RETRYABLE_STATUS_CODES

    def _retry_delay(self, attempt):
        return self.BASE_RETRY_DELAY * (2 ** (attempt - 1))
```

- `URI(@builder.url)` / manual `Net::HTTP.new(host, port)` construction has no
  Python equivalent needed — `urllib.request.urlopen` parses the URL and
  opens the connection (including TLS) internally from a `Request` object.
- `request.body = ...to_json` → `body = json.dumps(...).encode("utf-8")`
  passed as `Request(..., data=body, ...)`. `urllib.request.Request` requires
  `data` to be `bytes`, not `str`.
- `@builder.headers` (Ruby, parens-optional) → `self.builder.headers()`
  (Python, explicit zero-arg method call — see `03_prompt_builder`'s Open
  Question precedent on why `headers`/`url` stayed as methods, not
  properties).
- Ruby's `response.code` is a `String` (hence `.to_i` in
  `retryable_response?` and direct string interpolation in the error
  message); Python's `response.status` / `HTTPError.code` are already `int`,
  so no `str`→`int` conversion is needed, and the f-string formats it
  directly.
- `response.body` (Ruby) is always a `String`; Python's `response.read()` /
  `HTTPError.read()` return `bytes` — decode with `.decode("utf-8",
  errors="replace")` only where building the human-readable `ApiError`
  message; `json.loads` accepts `bytes` directly for the success path, no
  decode needed there.
- `"s" unless attempts == 1` (Ruby's inline conditional appending a
  pluralizing `s`) → `"" if attempts == 1 else "s"` (same three-state
  outcome, inverted condition to fit Python's ternary order).

### Top-level exports (`lib/boukensha.rb` → `boukensha/__init__.py`)

Ruby adds one require for `client` (and drops the now-redundant
`backends/base` require, per Design Considerations):

```ruby
require_relative "boukensha/config"
require_relative "boukensha/tool"
require_relative "boukensha/message"
require_relative "boukensha/context"
require_relative "boukensha/errors"
require_relative "boukensha/registry"
require_relative "boukensha/prompt_builder"
require_relative "boukensha/backends/anthropic"
require_relative "boukensha/backends/gemini"
require_relative "boukensha/backends/ollama"
require_relative "boukensha/backends/ollama_cloud"
require_relative "boukensha/backends/openai"
require_relative "boukensha/client"
```

Python target — add `Client` and `ApiError` while preserving the existing
exports:

```python
from . import backends
from .client import Client
from .config import Config
from .context import Context
from .errors import ApiError, UnknownToolError, UnsupportedModelError
from .message import Message
from .prompt_builder import PromptBuilder
from .registry import Registry
from .tasks.player import Player
from .tool import Tool

__all__ = [
    "ApiError",
    "Client",
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

Ruby changes only the comment (the path arithmetic change is a flagged bug —
see Design Considerations, not ported):

```python
class Config:
    """The .boukensha config directory is resolved in this order:
    1. BOUKENSHA_DIR environment variable (set before loading .env)
    2. ~/.boukensha  (default)
    """

    DEFAULT_DIR = Path.home() / ".boukensha"

    # Default prompts shipped alongside this step.
    PROMPTS_DIR = Path(__file__).resolve().parent.parent / "prompts"
```

Only the comment line changes (`the library code.` → `this step.`); the
`PROMPTS_DIR` assignment itself is untouched.

### `Tasks::Base` (`tasks/base.rb` → `tasks/base.py`)

Two fixes, both applied:

```python
@classmethod
def provider(cls, settings):
    value = cls._fetch(settings, "provider")
    if value is None:
        raise ValueError(f"tasks.{cls.task_name()}.provider is required in settings.yaml")
    return value

@classmethod
def model(cls, settings):
    value = cls._fetch(settings, "model")
    if value is None:
        raise ValueError(f"tasks.{cls.task_name()}.model is required in settings.yaml")
    return value

...

@classmethod
def _fetch(cls, settings, key):
    if not isinstance(settings, dict):
        return None
    return settings.get(key)
```

Everything else in `tasks/base.py` (`is_prompt_override`, `prompt`,
`system_prompt`, `_read_user_prompt`, `_read_default_prompt`, `_read_file`)
is untouched — no Ruby diff touches them.

### `prompts/system.md`

Ruby replaces the single-line system prompt:

```
You are Boukensha, an autonomous player exploring a CircleMUD world.

Use available tools to observe the world, act deliberately, and explain only what matters for the current turn.
```

Port verbatim into `week1_baseline/python/04_api_client/prompts/system.md`.

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

registry.tool("read_file",
  description: "Read the contents of a file from disk",
  parameters: { path: { type: "string", description: "The file path to read" } }
) do |path:|
  File.read(path)
end

registry.tool("list_directory",
  description: "List files in a directory",
  parameters: { path: { type: "string", description: "The directory path to list" } }
) do |path:|
  Dir.entries(path).reject { |f| f.start_with?(".") }.join("\n")
end

ctx.add_message(:user, "What files are in the current directory?")

provider = Boukensha::Tasks::Player.provider(player_settings)
model    = Boukensha::Tasks::Player.model(player_settings)

backend =
case provider
when "anthropic"
  Boukensha::Backends::Anthropic.new(
    api_key: ENV.fetch("ANTHROPIC_API_KEY"),
    model:   model
  )
when "openai"
  Boukensha::Backends::OpenAI.new(
    api_key: ENV.fetch("OPENAI_API_KEY"),
    model:   model
  )
when "gemini"
  Boukensha::Backends::Gemini.new(
    api_key: ENV.fetch("GEMINI_API_KEY"),
    model:   model
  )
when "ollama"
  Boukensha::Backends::Ollama.new(
    model: model
  )
when "ollama_cloud"
  Boukensha::Backends::OllamaCloud.new(
    api_key: ENV.fetch("OLLAMA_API_KEY"),
    model:   model
  )
else
  raise ArgumentError, "Unsupported provider for player task: #{provider}"
end

builder = Boukensha::PromptBuilder.new(ctx, backend)
client  = Boukensha::Client.new(builder)

puts "=== BOUKENSHA Step 4: API Client ==="
puts
puts "Config: #{config}"
puts "Provider: #{provider}"
puts "Model: #{model}"
puts "Sending request to #{builder.url}..."
puts

response = client.call
puts "Raw response:"
puts JSON.pretty_generate(response)
```

Notice the intentional drifts vs. the step 3 example, all carried into
Python:
- `look`/`move` are replaced by `read_file`/`list_directory` — real
  filesystem-touching tools instead of scripted-string tools, since the
  point of this step is showing a real round trip.
- Only one seed message is added (`user`: "What files are in the current
  directory?") — no scripted `assistant`/`tool_result` turns like step 3 had,
  since this step lets the actual API respond rather than pre-seeding a fake
  exchange.
- `registry.dispatch` still isn't called — same as step 3, `read_file`'s and
  `list_directory`'s bodies are registered but never invoked by the smoke
  test (the API is only ever shown the tool *schemas*, and per the README,
  in this smoke test's case it has no `list_directory`-capable prior turn to
  act on, so a `tool_use` response isn't expected either way — see the
  Ruby README's own captured "Output example" section, where Claude declines
  to call any tool and just asks for clarification).
- `"=== BOUKENSHA Step 4: API Client ==="` banner moved to print *after*
  `client`/`builder` construction (was before `provider`/`model` resolution
  in step 3) — purely a print-ordering change, no behavioural difference.

Python target (`examples/example.py`):

```python
import json
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from boukensha import Client, Config, Context, Player, PromptBuilder, Registry, backends

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
    "read_file",
    description="Read the contents of a file from disk",
    parameters={"path": {"type": "string", "description": "The file path to read"}},
)
def read_file(path):
    return Path(path).read_text()


@registry.tool(
    "list_directory",
    description="List files in a directory",
    parameters={"path": {"type": "string", "description": "The directory path to list"}},
)
def list_directory(path):
    return "\n".join(sorted(f.name for f in Path(path).iterdir() if not f.name.startswith(".")))


ctx.add_message("user", "What files are in the current directory?")

provider = Player.provider(player_settings)
model = Player.model(player_settings)

if provider == "anthropic":
    backend = backends.Anthropic(api_key=os.environ["ANTHROPIC_API_KEY"], model=model)
elif provider == "openai":
    backend = backends.OpenAI(api_key=os.environ["OPENAI_API_KEY"], model=model)
elif provider == "gemini":
    backend = backends.Gemini(api_key=os.environ["GEMINI_API_KEY"], model=model)
elif provider == "ollama":
    backend = backends.Ollama(model=model)
elif provider == "ollama_cloud":
    backend = backends.OllamaCloud(api_key=os.environ["OLLAMA_API_KEY"], model=model)
else:
    raise ValueError(f"Unsupported provider for player task: {provider}")

builder = PromptBuilder(ctx, backend)
client = Client(builder)

print("=== BOUKENSHA Step 4: API Client ===")
print()
print(f"Config: {config}")
print(f"Provider: {provider}")
print(f"Model: {model}")
print(f"Sending request to {builder.url()}...")
print()

response = client.call()
print("Raw response:")
print(json.dumps(response, indent=2))
```

- `File.read(path)` → `Path(path).read_text()` (raises the same
  `FileNotFoundError`/`OSError`-family exception on a bad path as Ruby's
  `Errno::ENOENT`-raising `File.read`, matching failure mode).
- `Dir.entries(path).reject { |f| f.start_with?(".") }.join("\n")` →
  `"\n".join(sorted(f.name for f in Path(path).iterdir() if not
  f.name.startswith(".")))`. Note: `Dir.entries` returns unsorted OS-order
  entries (and *includes* `.`/`..`, which the `reject` filters out via the
  leading-dot check — same as any other dotfile); `Path.iterdir()` never
  yields `.`/`..` in the first place, so the dotfile filter here only
  excludes real hidden files, a harmless behavioural narrowing versus Ruby
  (Ruby's `.`/`..` entries get filtered out by the same `start_with?(".")`
  check anyway, so the visible output is identical either way). Sorting is
  added since `iterdir()` order isn't guaranteed either — pick a stable,
  readable order rather than leaving it OS-dependent; this doesn't change
  Ruby's behavior in any way that the smoke test's assertions depend on.
- `ENV.fetch("...")` (raises if unset) → `os.environ["..."]` (also raises
  `KeyError` if unset) — same failure mode as established in step 3.
- `client.call` (Ruby, parens-optional zero-arg call) → `client.call()`
  (Python, explicit call with the `max_output_tokens` default applying).

### README

Replace the copied step-3 README with step-4 content, following the Ruby
README's structure (New Files / Updated Files / How It Works / `Client`
method table / Task Configuration / No Dependencies / What the Response
Looks Like / Considerations / Run Example), translated to `boukensha.Client`
naming and Python code snippets, with these adjustments:
- Write the New/Updated Files tables from the *actual* Python step 4 delta
  (`boukensha/client.py`; `errors.py`'s `ApiError`; `config.py`'s comment;
  `tasks/base.py`'s message-text and `Hash`/`dict`-guard fixes;
  `prompts/system.md`'s new text) rather than literally translating Ruby's
  table, which lists files that were already ported in step 3 as if new to
  this step — see Design Considerations.
- Under "No Dependencies", state the Python equivalent: `Client` uses only
  Python's standard library (`urllib.request`, `json`, `ssl`) — no
  third-party HTTP libraries like `requests`.
- Drop the Ruby README's OpenSSL certificate troubleshooting subsection
  (`ruby -e "require 'openssl'; ..."` and the macOS `ca_file` note) — it's
  Ruby/OpenSSL-specific plumbing with no Python analog, since
  `urllib.request` already verifies against the system trust store by
  default with no per-platform cert-path workaround needed (see Design
  Considerations).
- Omit the Ruby README's "Output eaxmple" section verbatim (it has a typo in
  its own heading, references a stale path `03_api_client/examples/step3.rb`
  that doesn't match this repo's actual structure, and hardcodes one
  particular Anthropic response). Keep the same *point* — that the exact
  response shape depends on the configured provider/model and the tools
  registered, and that a text-only reply is expected here since the model
  is never given a matching tool for a directory listing follow-up — but
  state it in prose instead of reproducing the stale path.
- Drop the Ruby README's "Review Considerations" section (the Ollama
  hardcoded-host note and the "some generated code did not adhere to
  stateless classes" note) — these are meta-commentary on the Ruby
  tutorial's own code review process, not spec content to port.

Keep the root-venv setup block already present in the copied README (same as
steps 0–3), updating the `pip install -r` path to
`week1_baseline/python/04_api_client/requirements.txt`, and keep the existing
`~/.boukensha/settings.yaml` precondition note from step 3's README (provider/
model/API-key requirements), since `Client` now genuinely needs a *working*
key — unlike step 3, this step performs a real network call and a bad or
placeholder key will surface as an `ApiError` (401/403), not silently
succeed.

### Launcher

Add:

```text
week1_baseline/bin/python/04_api_client
```

Same style as `week1_baseline/bin/python/03_prompt_builder`:

```bash
#!/usr/bin/env bash

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$SCRIPT_DIR/../../.."

cd "$SCRIPT_DIR/../../python/04_api_client"
"$REPO_ROOT/.venv/bin/python" examples/example.py
```

Make it executable.

## Configuration Schema

Unchanged from steps 0–3.

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
`gemini`, and `model` must be a key present in that backend's `MODELS` table.
Unlike step 3, the API key env var for the selected provider must now be a
**real, working key** (except `ollama`, which needs none) — `Client` performs
an actual HTTP request, and an invalid key surfaces as `ApiError` from a
401/403 response.

## Implementation Steps

1. Confirm the existing `week1_baseline/python/04_api_client` snapshot is the
   copied Python `03_prompt_builder` port (README/example still say
   "Step 3").
2. Update `boukensha/errors.py` to add `ApiError` (between
   `UnknownToolError` and `UnsupportedModelError`).
3. Add `boukensha/client.py` (`Client` with the retry/backoff loop, ported
   per the Design Considerations mapping of Ruby's `TRANSIENT_ERRORS`/
   `RETRYABLE_STATUS_CODES` to `urllib`).
4. Update `boukensha/config.py`'s `PROMPTS_DIR` comment text only (do not
   change the path arithmetic — see Design Considerations).
5. Update `boukensha/tasks/base.py`: fix the two `settings.yml` →
   `settings.yaml` error-message strings, and add the `isinstance(settings,
   dict)` guard to `_fetch`.
6. Replace `prompts/system.md` with the step 4 text.
7. Update `boukensha/__init__.py` to export `Client` and `ApiError`.
8. Replace `examples/example.py` with the step 4 client example
   (`read_file`/`list_directory` tools, `Client` construction and `.call()`).
9. Replace `README.md` with the step 4 content (with the adjustments noted
   above).
10. Add `week1_baseline/bin/python/04_api_client` and make it executable.
11. Ensure `~/.boukensha/settings.yaml` has a supported
    `tasks.player.provider`/`model` pair and a **real** matching API key env
    var is set (or `provider: ollama` with `ollama serve` running locally),
    then run the smoke test through the launcher.

## Verification

Run:

```bash
./week1_baseline/bin/python/04_api_client
```

Preconditions: `~/.boukensha/settings.yaml` has `tasks.player.provider` set
to one of `anthropic`/`ollama`/`ollama_cloud`/`openai`/`gemini` with a
`model` value present in that backend's `MODELS` table, and (for every
provider except `ollama`) a **working** API key in the corresponding env
var — this step makes a real network call, so a placeholder key will fail
with a 401/403 `ApiError` rather than silently succeeding as it did in step
3.

Expected checks:

- exits with status 0 on a successful call
- prints `=== BOUKENSHA Step 4: API Client ===`
- prints `Config:`, `Provider:`, `Model:`, and `Sending request to
  <url>...` lines matching the configured task settings
- prints `Raw response:` followed by a pretty-printed JSON response from the
  live API, shaped per-provider as documented in the README (e.g. Anthropic's
  `content`/`stop_reason`/`usage` keys)
- since the smoke test registers `read_file`/`list_directory` as tool
  schemas but seeds only a `user` message asking about "the current
  directory" with no prior turn establishing which tool applies, the typical
  response is a text-only reply (possibly asking for clarification or
  suggesting an alternative), not a `tool_use`/`tool_calls` response — this
  matches the Ruby README's own captured example
- an invalid/placeholder API key causes `client.call()` to raise
  `boukensha.ApiError` with the HTTP status code and response body in the
  message, and the script exits non-zero
- switching `tasks.player.provider` in `settings.yaml` to a value not in
  `{anthropic, ollama, ollama_cloud, openai, gemini}` still raises
  `ValueError: Unsupported provider for player task: <value>` (unchanged
  from step 3)
- transient failures (simulate by pointing at an unreachable host, e.g. a
  bogus `ollama` host) retry up to 3 times with `0.5s`/`1.0s`/`2.0s` delays
  before raising `ApiError`

No `pytest` suite is required for this step.

## Open Questions

1. **Not reproducing the Ruby `PROMPTS_DIR` path regression.** Ruby's step 4
   diff changes `config.rb`'s `PROMPTS_DIR` from a working 2-up path to a
   3-up path that resolves to a nonexistent directory
   (`week1_baseline/ruby/prompts`), silently breaking default system-prompt
   loading whenever `prompt_override.system` isn't explicitly `true` (no
   exception — `Tasks::Base.read_default_prompt` just returns `nil` for a
   missing file). This plan recommends leaving Python's already-correct
   `PROMPTS_DIR` untouched (only updating the comment text) rather than
   reproducing what looks like an accidental regression. Confirm this is the
   right call — the alternative is reproducing the bug faithfully for
   line-for-line parity with Ruby, at the cost of Python's default example
   silently losing its system prompt too.
- the pathing should work, in both the ruby and the python so if it needs fixing, fix it.
2. **`TRANSIENT_ERRORS` tuple composition.** Ruby's list of retryable
   low-level exceptions has no 1:1 Python equivalent because
   `urllib.request.urlopen` wraps most connect-time failures in
   `urllib.error.URLError` rather than raising the underlying socket/SSL
   exception directly. This plan's proposed tuple
   (`URLError, TimeoutError, ConnectionError, ssl.SSLError, EOFError,
   socket.gaierror`) is broader than a mechanical transcription in order to
   catch both the wrapped (connect-time) and raw (read-time) forms of the
   same underlying failures. Confirm this mapping is an acceptable "spirit,
   not letter" port, consistent with how the `03_prompt_builder` plan handled
   Ruby idioms with no direct Python equivalent.
- do something.