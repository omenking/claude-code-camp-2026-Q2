## Mud Monitor

We want to create a single app that gives us unified observability:
- week0_preview provides us world data visualizer
- week1_baseline/log_vis provide us agent session logs
- we will need to expand now the agent session logs to show:
  - timestamp and duration between each command
  - realtime update so we can sit on the page.
- we have no logging in mud manager to see the raw commands send to a mud
- in the future we will want to extend mud agent to show:
  - build a map based on the agent's knowledge of the world stored in the future SQLITE file
  - show constant stats, inventory about the player
  - agent's internal future information like goals and tasks.

We have a mix of tech stack implementation and we want to unify it.

Mud Monitor will live in week_2/mud_monitor

## New Stack
- typescript / react frontend just like log_vis
- backend: ruby on rails API only that is configured for SQLITE (for our future SQLITE file)

## Tech Spec

### 0. Corrections to the premise

Two facts from the existing code that change the shape of the work:

1. **`week1_baseline/log_viz` is not TypeScript/React.** It is Sinatra + ERB
   (`log_viz/lib/log_viz/app.rb`, `views/*.erb`), rendering server-side with no
   JS at all — the sparkline is hand-written inline SVG. The TS/React app in this
   repo is `week0_explore/preview/web` (Vite 6 + React 18 + react-router 7 +
   `@xyflow/react`). So "typescript/react frontend just like log_vis" reads as:
   *the content of log_viz, on the stack of preview*. All of log_viz's rendering
   logic (`Session#parse!`, cost model, ANSI→HTML, context chips) is being
   **ported**, not reused.

2. **Session timestamps are whole-second resolution.**
   `Boukensha::Logger#write_log` stamps `Time.now.iso8601`
   (`boukensha/lib/boukensha/logger.rb:101`) — no subsecond digits. "Duration
   between each command" cannot be computed from existing logs to better than
   ±1s. Fixing this is a prerequisite (§4.1), and it is not backward-compatible
   in the useful direction: old sessions keep their 1s quantization forever.

Directory naming: the plan says `week_2/mud_monitor`; the repo convention is
`week2_capable/`. This spec uses **`week2_capable/mud_monitor`**.

---

### 1. Architecture

```
                    ┌───────────────────────────────────────┐
                    │  mud_monitor/web  (Vite/React/TS)     │
                    │  :5173 dev, static build in prod      │
                    └───────────┬───────────────────────────┘
                       /api/*   │  (vite proxy → :3000)
                    ┌───────────▼───────────────────────────┐
                    │  mud_monitor/api  (Rails 8, API-only) │
                    │  :3000, puma                          │
                    │   ├─ SessionLog  (reads .jsonl)       │
                    │   ├─ WireLog     (reads .jsonl)       │
                    │   ├─ World       (reads world JSON)   │
                    │   └─ Knowledge   (2nd DB, read-only)  │
                    └───────────┬───────────────────────────┘
        ┌───────────────────────┼───────────────────────┬─────────────────┐
        ▼                       ▼                       ▼                 ▼
 .boukensha/sessions/   .boukensha/wire/        week0_explore/     .boukensha/
   *.jsonl                *.jsonl                preview/data/       knowledge.sqlite3
 (Boukensha::Logger)    (NEW, §4.2)               world/**          (future, §8)
```

**Files stay the source of truth.** Rails does not ingest session logs into its
own DB — it parses them on request and streams tails. SQLite is present because
(a) Rails needs a primary DB for its own small tables and (b) the *future* agent
knowledge file is SQLite and will be attached as a second, read-only connection.
Inverting this (ingesting jsonl into Postgres-style tables) buys nothing today:
the logs are small, append-only, and already the artifact the bootcamp cares
about.

**One Rails app, one Vite app, one process manager.** No Sinatra, no second
Node service.

---

### 2. Layout

```
week2_capable/mud_monitor/
├── README.md
├── Procfile.dev                 # api + web, driven by bin/dev
├── bin/
│   ├── setup                    # bundle + npm ci + db:prepare + world bundles
│   └── dev                      # foreman start -f Procfile.dev
├── api/                         # rails new mud_monitor_api --api -d sqlite3 -T
│   ├── app/
│   │   ├── controllers/api/v1/
│   │   │   ├── sessions_controller.rb
│   │   │   ├── events_controller.rb       # incremental + SSE
│   │   │   ├── wire_controller.rb
│   │   │   ├── world_controller.rb
│   │   │   └── health_controller.rb
│   │   ├── models/
│   │   │   └── knowledge/                 # §8, ActiveRecord on 2nd DB
│   │   └── serializers/                   # plain PORO -> Hash, no gem
│   ├── lib/
│   │   ├── session_log/
│   │   │   ├── store.rb         # dir listing, path resolution, mtime
│   │   │   ├── parser.rb        # jsonl -> Event structs (port of log_viz)
│   │   │   ├── transcript.rb    # Events -> entries + turns + usage series
│   │   │   ├── timing.rb        # NEW: deltas, tool latency, gaps
│   │   │   ├── pricing.rb       # MODEL_PRICES + cost math
│   │   │   └── follower.rb      # offset-based tail
│   │   ├── wire_log/
│   │   │   ├── store.rb
│   │   │   └── parser.rb
│   │   ├── ansi.rb              # port of log_viz/lib/log_viz/ansi.rb
│   │   └── world/
│   │       └── store.rb         # §7
│   ├── config/database.yml      # primary + knowledge
│   └── test/                    # minitest (Rails default)
└── web/                         # vite + react + ts (mirrors preview/web)
    ├── package.json
    ├── vite.config.ts           # server.proxy /api -> localhost:3000
    ├── src/
    │   ├── main.tsx  App.tsx  index.css
    │   ├── api/
    │   │   ├── client.ts        # fetch wrappers, typed
    │   │   ├── types.ts         # hand-written, mirrors serializers
    │   │   └── useEventStream.ts# EventSource hook w/ reconnect
    │   ├── components/
    │   │   ├── Layout.tsx  Ansi.tsx  Duration.tsx  TokenChip.tsx
    │   │   ├── Sparkline.tsx  CostTable.tsx  LiveBadge.tsx
    │   │   └── (ported from preview: EntityTable, JsonView, links, …)
    │   └── pages/
    │       ├── Dashboard.tsx
    │       ├── Sessions.tsx  SessionDetail.tsx
    │       ├── Wire.tsx
    │       └── (ported from preview: Rooms, RoomDetail, Mobs, WorldMap, …)
    └── public/data/             # generated world bundles (§7)
```

Ruby is 4.0.5 here; Rails is **not currently installed** (`gem list rails` is
empty) — `bin/setup` must install it. Node is 20.20.2, fine for Vite 6.

---

### 3. HTTP API

All under `/api/v1`, all JSON, all read-only (no POST/PUT/DELETE in scope).
Errors: `{ "error": { "code": "not_found", "message": "…" } }` with the matching
status.

#### 3.1 Sessions

```
GET /api/v1/sessions
```
```jsonc
{
  "sessions": [
    {
      "id": "20260722T162321Z-a6188b70",
      "started_at": "2026-07-22T16:23:21.144Z",
      "ended_at": "2026-07-22T16:41:07.902Z",   // last event's `at`
      "duration_ms": 1066758,
      "live": true,                              // mtime within LIVE_WINDOW (10s)
      "task": "explore the temple",              // first user entry
      "models": ["anthropic / claude-haiku-4-5"],
      "turns": 3,
      "iterations": 27,
      "tool_calls": 41,
      "input_tokens": 184203, "output_tokens": 5120,
      "cost_usd": 0.2137,                        // null when unpriced
      "end_reason": "completed",
      "stopped": false,
      "bytes": 918234
    }
  ]
}
```
Sorted newest-first by filename (ids are `%Y%m%dT%H%M%SZ`-prefixed, so lexical
sort == chronological — same trick `log_viz` uses).

```
GET /api/v1/sessions/:id
```
Full transcript. `:id` is passed through `File.basename` and joined to the
configured dir; anything that escapes the dir → 404 (log_viz already does the
basename guard; keep it and add a realpath prefix check).

```jsonc
{
  "session": { /* the summary object above */ },
  "snapshot": { "model": "claude-haiku-4-5", "max_iterations": 20,
                "max_turn_tokens": 120000, "context_window": 200000 },
  "turns": [ { "n": 0, "iterations": 9, "tokens": 41233, "reason": "completed",
               "started_at": "…", "ended_at": "…", "duration_ms": 122400 } ],
  "usage_series": [ { "turn": 0, "iteration": 1, "input": 8123, "output": 210,
                      "cache_read": 0, "cache_creation": 8000, "running": 8333,
                      "at": "…", "task": "player", "provider": "anthropic",
                      "model": "claude-haiku-4-5", "cost_usd": 0.0021 } ],
  "cost_breakdown": [ { "task": "room_inspector", "provider": "anthropic",
                        "model": "claude-haiku-4-5", "calls": 12,
                        "input": 60000, "output": 900,
                        "cost": 0.0645, "cost_known": true } ],
  "entries": [ /* §3.2 */ ]
}
```

#### 3.2 Entry shape

One array, ordered, discriminated on `type` — a direct port of
`LogViz::Session::Entry` plus the timing fields. Every entry carries `seq`
(0-based index into the parsed stream; **the cursor for incremental fetch**) and
`at`.

```jsonc
{
  "seq": 42,
  "type": "tool",            // user | assistant | reasoning | plan | tool
                             // | compaction | turn_end | limit_reached
  "turn": 1, "iteration": 6,
  "at": "2026-07-22T16:25:03.412Z",
  "dt_ms": 1840,             // since previous entry (null on seq 0)
  "duration_ms": 1611,       // type-specific, see §4.3; null when unknowable

  // type: tool
  "tool_name": "tbamud__move", "tool_args": { "direction": "north" },
  "tool_result": "The Temple Of Midgaard\n…",
  "tool_ok": true, "tool_error": null,
  "result_html": "<span class=\"ansi-fg-36\">…</span>",   // server-rendered ANSI
  "wire": [ 91, 92 ],        // wire-log seqs correlated to this call (§4.2)

  // type: assistant
  "text": "…", "stop_reason": "tool_use",
  "usage": { "input_tokens": 8123, "output_tokens": 210,
             "cache_read_input_tokens": 0, "cache_creation_input_tokens": 8000 },
  "running_turn_tokens": 8333,
  "task": "player", "provider": "anthropic", "model": "claude-haiku-4-5",
  "cost_usd": 0.0021
}
```

**ANSI is converted server-side.** `log_viz/lib/log_viz/ansi.rb` already does
SGR→`<span class="ansi-…">`; porting it to `api/lib/ansi.rb` and emitting
`result_html` keeps one implementation and keeps the React side from shipping an
ANSI parser. The client renders it with `dangerouslySetInnerHTML` — the input is
local MUD output, and the converter escapes HTML before wrapping (verify
`Ansi.escape_html` is applied on every path during the port; if not, fix it
there, since it is now crossing a JSON boundary into innerHTML).

#### 3.3 Incremental + realtime

```
GET /api/v1/sessions/:id/events?after=<seq>&limit=500
→ { "entries": [...], "next_seq": 128, "eof": true, "live": true }

GET /api/v1/sessions/:id/stream?after=<seq>      (text/event-stream)
```

SSE frames:

```
event: entry
id: 128
data: {"seq":128,"type":"tool",…}

event: session
data: {"input_tokens":…, "cost_usd":…, "iterations":…}   // rolled-up summary

event: heartbeat
data: {"at":"2026-07-22T16:41:20.001Z"}                  // every 15s

event: eof
data: {"reason":"session_end"}                           // logger closed
```

- `ActionController::Live` + `SSE`, **not ActionCable** — the feed is one-way,
  per-session, and ActionCable in an API-only app drags in a subscription
  adapter and a second protocol for no gain. `Last-Event-ID` (or `?after=`) is
  the resume cursor; the client replays from there after a reconnect, so no
  event is lost across a dropped connection.
- **Tailing is offset polling, not inotify.** `Follower` remembers a byte offset
  per (path, connection), `sleep 0.25`, re-`read` from the offset, splits on
  `\n`, buffers a trailing partial line until its newline arrives (the logger
  `puts`+`flush`es per event, so partials are rare but not impossible). WSL2's
  inotify is unreliable across the Windows filesystem boundary, which is where
  this repo may live — polling is the boring, portable choice at this scale
  (a handful of files, a few events/sec).
- **Puma must have threads to spare.** Each open SSE connection holds a thread
  for its lifetime. Set `threads 5, 16` in `puma.rb` and cap concurrent streams
  at `MUD_MONITOR_MAX_STREAMS` (default 8), returning 503 beyond it. Every
  stream is wrapped in `ensure { sse.close }`, and `IOError`/`Errno::EPIPE` on
  write terminates the loop cleanly.

#### 3.4 Wire log

```
GET /api/v1/wire?session=<id>&after=<seq>&limit=500
GET /api/v1/wire/stream?session=<id>&after=<seq>
```
Same envelope and SSE mechanics as §3.3. `session` is optional; omitted means
the whole wire log (the daemon is not always driven by one agent session).

#### 3.5 World & health

```
GET /api/v1/world/index          → counts + id/name nav lists
GET /api/v1/world/rooms          → id-keyed bundle
GET /api/v1/world/rooms/:id
… mobs | objects | zones | shops | triggers | quests
GET /api/v1/health               → { ok, sessions_dir, wire_dir, world_ready,
                                     knowledge_attached, live_sessions }
```
See §7 for whether these are served by Rails at all in phase 1.

---

### 4. Changes to existing code

These are the parts of the work that are *not* in the new app.

#### 4.1 Millisecond timestamps — `boukensha/lib/boukensha/logger.rb`

```ruby
-  @log_io.puts JSON.generate(event.merge(session_id: @session_id, at: Time.now.iso8601))
+  now = Time.now
+  @log_io.puts JSON.generate(event.merge(
+    session_id: @session_id,
+    at:         now.iso8601(3),
+    mono_ms:    (Process.clock_gettime(Process::CLOCK_MONOTONIC) * 1000).round
+  ))
```

`at` gains milliseconds (still valid ISO8601, still `Time.parse`-able, so
`log_viz` keeps working). `mono_ms` is added because wall-clock deltas are
vulnerable to NTP steps and DST, and the durations we care about are
sub-second — the parser prefers `mono_ms` deltas and falls back to `at` when the
field is absent (i.e. for every session logged before this change).

The parser must therefore handle three vintages: `at` at 1s resolution, `at` at
ms resolution, and `at`+`mono_ms`. `Timing` reports which via
`"timing_source": "monotonic" | "wallclock" | "wallclock_coarse"` on the session
summary, and the UI greys out sub-second durations when the source is coarse
rather than showing a fake `0ms`.

#### 4.2 Wire logging — `mud_manager`

New `MudManager::WireLog`, wired into `SessionPool` at the three places that
touch the socket (`run_command`, `run_raw`, `poll`) — that is the narrowest cut
that sees every byte in both directions, and it is where the request/response
pairing is already implicit.

```ruby
# lib/mud_manager/wire_log.rb
class WireLog
  def self.from_env
    dir = ENV["MUD_WIRE_LOG_DIR"] and new(dir: dir)   # nil => disabled, zero cost
  end
  def command(session_id:, command:, response:, elapsed_ms:, mode:, correlation_id: nil)
end
```

Format — `.boukensha/wire/<YYYYMMDD>.jsonl`, one line per exchange:

```jsonc
{ "seq": 91, "at": "2026-07-22T16:25:03.101Z", "session": "default",
  "mode": "command",                    // command | raw | poll
  "correlation_id": "a6188b70-41",      // links to a session tool_call, §4.4
  "sent": "north",
  "received": "The Temple Of Midgaard\n[36m…",   // raw, ANSI intact
  "bytes_in": 412, "elapsed_ms": 1611,
  "error": null }
```

Notes:
- **Off by default.** `WireLog.from_env` returns nil without
  `MUD_WIRE_LOG_DIR`, and the pool guards every call with `@wire&.`. The daemon
  is a hot path in the agent loop; logging must be opt-in and allocation-free
  when off.
- **Passwords never reach the log.** The login dance happens inside
  `Session#login`, below the pool, and is deliberately *not* instrumented. If
  login logging is ever wanted, it redacts by writing `mode: "login"` with
  `sent: "<username>"` and nothing else.
- `elapsed_ms` is monotonic, measured around the send→read pair.
- Daily files, not per-session, because the daemon outlives any one agent run.
- Writes are `puts` + `flush` under the pool's existing mutex, so the tailer
  never sees interleaved lines.

Config: the `mud:` MCP server block in `.boukensha/settings.yaml` gains
`MUD_WIRE_LOG_DIR: .boukensha/wire` in its `env:` so the daemon inherits it.

#### 4.3 What `duration_ms` means per entry type

| type | duration | derived from |
|---|---|---|
| `tool` | time from the `tool_call` event to its `tool_result` | the two events' timestamps (the parser already pairs them via `pending_calls`) |
| `assistant` | model latency: previous `iteration`/`tool_result` → this `response` | timestamps |
| `turn_end` | wall time of the whole turn | `turn` event → `turn_end` event |
| `user`, `plan`, `reasoning`, `compaction` | `null` | instantaneous marks |

Plus, on every entry, `dt_ms` = gap since the previous entry — this is the
"duration between each command" the plan asks for, and it is what surfaces
*think time* vs *MUD time* when read alongside the tool durations.

`Timing` also computes, for the session summary: `p50/p95 tool_ms`,
`p50/p95 model_ms`, `total_idle_ms` (sum of gaps > 5s, which in practice means
"the human was reading"), and `wall_ms` vs `busy_ms`.

#### 4.4 Correlating agent tool calls to wire commands

Without a shared id this is timestamp-nearest-match, which is fine for a demo
and wrong under concurrency (the `room_inspector` subagent drives the *same*
MUD session as the player — see `.boukensha/settings.yaml`). Two-step:

- **Phase 3 (ship this):** the boukensha MCP client sends
  `_meta: { correlation_id: "<session_id>-<event_seq>" }` on `tools/call`;
  `mud_manager`'s MCP server reads `params._meta.correlation_id` and threads it
  into `WireLog#command`. `_meta` is the MCP-sanctioned passthrough slot, so
  this needs no protocol extension and non-boukensha clients simply omit it.
- **Fallback when absent:** nearest preceding wire entry within 2s of the
  `tool_call`, marked `"correlation": "inferred"` so the UI can render it dashed.

`entry.wire` in §3.2 is populated by whichever path applied.

---

### 5. Frontend

Stack copied from `week0_explore/preview/web` verbatim so the port is mechanical:
Vite 6, React 18, `react-router` 7, TS 5.7, `@xyflow/react` + `dagre` (for the
future map, §8). No component library, no CSS framework — `index.css` and the
existing `preview` styles, extended with the log_viz `public/style.css` rules for
ANSI spans and chips.

Routes:

| route | content |
|---|---|
| `/` | Dashboard: live sessions, recent sessions, world counts, daemon health |
| `/sessions` | the log_viz index table |
| `/sessions/:id` | the transcript (§5.1) |
| `/wire` | raw wire log, filterable by session, live-tailing |
| `/world/*` | the preview app's routes, unchanged paths where possible |

#### 5.1 Transcript page

Port of `views/session.erb`, plus:

- **Timing gutter.** Each entry gets a left gutter: absolute time (hover → full
  ISO), `+dt` since previous, and for tools/assistant a duration pill colour-
  ramped by magnitude. When `timing_source == "wallclock_coarse"`, pills render
  as `~1s` in muted text — never a precise-looking `0ms`.
- **Live mode.** If `session.live`, open the SSE stream from the last-loaded
  `seq`. New entries append with a brief highlight; a `LiveBadge` shows
  connected/reconnecting/ended. **Autoscroll sticks only when already at the
  bottom** — scrolling up to read must not be yanked back, which is the single
  most common way a live log UI becomes unusable.
- **Wire pane.** Toggleable right rail, or inline-expandable under each tool
  entry, showing the correlated raw exchange (`sent`, `received`, `elapsed_ms`).
  This is where "we have no logging in mud manager" gets answered visually: the
  agent's `tbamud__move{direction:"north"}` sits directly above the literal
  `north` that went down the socket and the bytes that came back.
- **Sparkline + cost table.** Ported from the ERB helpers; the SVG sparkline
  becomes a small `Sparkline.tsx` (same math, `points` from `usage_series`).

`useEventStream.ts` owns: `EventSource` lifecycle, exponential backoff reconnect
(250ms → 5s), cursor tracking via `Last-Event-ID`, dedupe by `seq` on replay, and
teardown on unmount/navigation.

---

### 6. Rails configuration

`config/database.yml`:

```yaml
default: &default
  adapter: sqlite3
  pool: <%= ENV.fetch("RAILS_MAX_THREADS", 16) %>
  timeout: 5000

development:
  primary:
    <<: *default
    database: storage/development.sqlite3
  knowledge:
    <<: *default
    database: <%= ENV.fetch("MUD_KNOWLEDGE_DB", "../../../.boukensha/knowledge.sqlite3") %>
    replica: true          # ActiveRecord will refuse writes on this connection
    migrations_paths: []   # this DB is owned by the agent, not by Rails
```

`replica: true` is the important line: mud_monitor must never migrate or write
the agent's knowledge file. In phase 1 the file does not exist yet — the
connection is declared but only established lazily, and `/api/v1/health` reports
`knowledge_attached: false` rather than the app failing to boot.

Environment:

| var | default | purpose |
|---|---|---|
| `MUD_MONITOR_SESSIONS_DIR` | `<repo>/.boukensha/sessions` | session jsonl (same default as `LOG_VIZ_SESSIONS_DIR`) |
| `MUD_MONITOR_WIRE_DIR` | `<repo>/.boukensha/wire` | wire jsonl |
| `MUD_MONITOR_WORLD_DIR` | `<repo>/week0_explore/preview/data/world` | parsed world JSON |
| `MUD_KNOWLEDGE_DB` | `<repo>/.boukensha/knowledge.sqlite3` | future agent memory |
| `MUD_MONITOR_MAX_STREAMS` | `8` | concurrent SSE cap |
| `MUD_MONITOR_LIVE_WINDOW` | `10` | seconds of mtime freshness → `live: true` |
| `PORT` | `3000` | Rails |

CORS: `rack-cors` allowing `localhost:5173` in development only; in production
the Vite build is served as static files from the same origin and CORS is off.

---

### 7. World data — deliberately *not* a Rails concern in phase 1

`preview/web/scripts/build-data.mjs` already aggregates
`data/world/{wld,mob,obj,zon,shp,trg,qst}/*.json` into six id-keyed bundles in
`public/data/` (~4MB total), and `src/data/load.ts` fetches + memoizes them. That
pipeline works, is build-time, and costs the server nothing.

**Phase 1: copy the script and the bundles wholesale.** `mud_monitor/web` runs
the same `npm run build:data` against `MUD_MONITOR_WORLD_DIR`, and the world
pages keep fetching `/data/*.json` as static assets. `/api/v1/world/*` is
specified in §3.5 but **not implemented** until something needs server-side
world access — which is §8's map, where world rooms must be joined against agent
knowledge rows and the join genuinely belongs on the server.

This ordering matters: it makes the world port a file-move plus a path constant,
and keeps phase 1's risk concentrated in the parts that are actually new (SSE,
timing, wire log).

---

### 8. Future hooks (designed for, not built)

The plan's forward-looking items, and the seam each one lands on:

- **Map from agent knowledge.** `Knowledge::Room`, `Knowledge::Exit` models on
  the `knowledge` connection; `GET /api/v1/map` joins them against the world
  bundles server-side and returns nodes/edges; the client renders with
  `@xyflow/react` + `dagre` — already dependencies, already used by
  `preview/src/pages/WorldMap.tsx`, so the renderer is a port too. The
  interesting half is the diff: rooms the agent *knows* vs rooms that *exist*,
  which is the actual measure of exploration.
- **Player stats/inventory.** These are already flowing past us as
  `tbamud__check(kind: score|inventory|equipment|gold)` tool results. A
  `StatsExtractor` over the transcript gives a last-known-value panel with an
  `as_of` timestamp — no new logging needed, and it degrades honestly (stale
  values are labelled stale rather than silently wrong).
- **Goals and tasks.** When boukensha grows them, they arrive as new
  `phase:` values in the same jsonl. The parser's `case event["phase"]` must
  therefore **ignore unknown phases silently** (log_viz's already does, by
  virtue of `case`/no-else) — and the API must pass through an `unknown` entry
  type rather than dropping it, so a new agent feature is visible in the monitor
  before the monitor is taught about it.

---

### 9. Phasing

| # | Deliverable | Done when |
|---|---|---|
| 0 | Scaffold: `rails new --api -d sqlite3 -T`, Vite app, `bin/setup`, `bin/dev`, `/api/v1/health` green | `bin/dev` serves both, health returns `ok: true` |
| 1 | Read-only session API + React transcript (port of log_viz) | every log_viz page has an equivalent, side-by-side output matches on a real session |
| 2 | ms timestamps (§4.1) + `Timing` + gutter UI | new sessions show sub-second tool/model durations; old sessions render as coarse without lying |
| 3 | SSE tail + live transcript | a running agent's tool calls appear within ~500ms; kill/restart the API and the client resumes without gaps or dupes |
| 4 | `MudManager::WireLog` + `/api/v1/wire` + wire pane | every agent tool call shows the literal socket exchange beneath it |
| 5 | Correlation ids via MCP `_meta` (§4.4) | correlations are `exact`, not `inferred`, when boukensha is the client |
| 6 | World pages ported (§7) | `/world/*` matches preview's output |
| 7 | Retire `week1_baseline/log_viz` and `week0_explore/preview/web` as *running* apps | README in each points at mud_monitor; code stays in the tree as the week's artifact |

Phases 1–4 are the plan's stated asks. 5 is the correctness fix that makes 4
trustworthy under the two-agent (player + room_inspector) setup that already
exists in `settings.yaml`.

---

### 10. Testing

**Rails (minitest, `-T` skipped only for the generated stubs — we do write
tests):**
- `SessionLog::Parser` against fixture jsonl covering all three timestamp
  vintages, unknown phases, truncated final line (a live file mid-write), and
  an empty file.
- `SessionLog::Timing` — deltas, tool pairing when calls interleave, monotonic
  vs wallclock fallback.
- `Pricing` — known model, unknown model → `nil` (not `0.0`; a fake zero cost is
  worse than an absent one).
- `Ansi` — HTML escaping before SGR wrapping, unterminated escape sequences.
- Request tests: index, show, 404, **path traversal** (`../../etc/passwd` as
  `:id`), `?after=` paging, `limit` clamping.
- SSE: a controller test that appends to a temp file and asserts frames arrive
  in order with correct `id:` cursors, plus that `after=` replays exactly the
  missing range.

**mud_manager (existing minitest suite):**
- `WireLog` off by default; on when `MUD_WIRE_LOG_DIR` set.
- `SessionPool` emits one wire entry per `run_command`/`run_raw`/`poll`, with
  `elapsed_ms > 0` and errors captured.
- No credential ever appears in wire output — assert against a full login+command
  cycle driven by `MudManager::FakeMud`.

**boukensha:**
- Logger emits `at` with ms and a `mono_ms` field; `log_viz` still parses the new
  format (guard against breaking the app we're replacing before it's replaced).

**web:** `tsc -b --noEmit` in CI (same as preview's `lint` script). Component
tests are out of scope; the transcript is verified against real session files by
eye during phase 1.

---

### 11. Risks

- **SSE thread exhaustion.** Mitigated by the stream cap and puma thread config
  (§3.3), but a browser left open on 8 tabs will hit it. The 503 must be a clear
  error the UI surfaces, not a silent dead feed.
- **Old sessions look broken.** 1-second timestamps mean most durations render as
  `0ms` or `~1s`. Handled by `timing_source` and muted rendering — but it is worth
  saying out loud that **the first genuinely useful timing data starts at phase
  2**; nothing recovers it for the 9 sessions already in `.boukensha/sessions/`.
- **Correlation before phase 5 is a guess.** With `player` and `room_inspector`
  sharing one MUD session, timestamp-nearest matching will mis-attribute wire
  entries during concurrent activity. The `inferred` flag exists so the UI never
  presents a guess as a fact.
- **Wire log growth.** Full room descriptions on every `look`; a long session is
  megabytes. Daily rotation only. If it bites, add a `bytes_in`-only mode that
  drops `received` for `poll` — but not before it actually bites.
- **Three apps become four.** Until phase 7, `log_viz` and `preview` still exist
  and still work. That is intentional (they are the week 0/1 artifacts) but the
  READMEs must say which one is current, or the next person runs the wrong app.