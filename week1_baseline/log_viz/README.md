# Log Viz

A small Sinatra app that turns `.boukensha/sessions/*.jsonl` logs (written by
`Boukensha::Logger`) into a human-readable transcript in the browser.

## What it does

- **`/`** — lists every session log (start time, session id, logged task,
  provider/model mix, iteration count, token totals, and cost).
- **`/sessions/:id`** — renders one session as a chat-style transcript:
  - the user's task
  - assistant replies, with input/output token counts, provider/model, and
    per-call cost when the logger recorded it
  - cost and token breakdowns grouped by task, provider, and model
  - each tool call and its result, grouped by agent iteration
  - raw MUD output (including ANSI color codes) is converted to colored HTML
    so room descriptions, exits, and status lines look the way they would in
    a terminal

It only reads the `.jsonl` files — nothing is written back.

## Run it

```sh
bundle install
bundle exec ruby bin/log_viz
```

Then open <http://localhost:4567>.

## Configuration

| Env var | Default | Purpose |
|---|---|---|
| `LOG_VIZ_SESSIONS_DIR` | `<repo root>/.boukensha/sessions` | Directory of `.jsonl` session logs to read |
| `PORT` | `4567` | Port to listen on |
| `BIND` | `localhost` | Address to bind to |

## How it works

- `lib/log_viz/session.rb` — streams a `.jsonl` file and turns the raw
  `session_start` / `turn` / `iteration` / `prompt` / `response` /
  `tool_call` / `tool_result` events into an ordered list of transcript
  entries (`user`, `assistant`, `tool`). Response events are treated as the
  source of truth for task/provider/model/cost so one session can mix models.
- `lib/log_viz/ansi.rb` — converts ANSI SGR escape codes in tool results into
  `<span>` elements styled via `public/style.css`.
- `lib/log_viz/app.rb` — the Sinatra app and view helpers.
- `views/` — ERB templates for the session list and transcript pages.
