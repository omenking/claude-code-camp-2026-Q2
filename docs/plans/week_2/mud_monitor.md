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

Three facts from the existing code that shape the work:

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

3. **"Logging the commands sent to the MUD" is three logs, not one** (§0.1).
   This is the central design decision of the spec.

Directory naming: the plan says `week_2/mud_monitor`; the repo convention is
`week2_capable/`. This spec uses **`week2_capable/mud_monitor`**.

---

### 0.1 Three observation layers, three logs

There are three distinct observers in this system, and they see different
things. Each gets its own log, written by exactly one component, **each carrying
its own complete payload**:

| Layer | Log | Writer | Answers |
|---|---|---|---|
| Telnet | `.boukensha/telnet/<YYYYMMDD>.jsonl` | `MudManager::Session` reader thread + `send_command` | what actually crossed the socket |
| Manager | `.boukensha/manager/<YYYYMMDD>.jsonl` | `MudManager::Mcp::SessionPool` | what mud_manager executed and returned upward |
| Agent | `.boukensha/sessions/<id>.jsonl` | `Boukensha::Logger` | what the agent saw and reasoned about |

**Why not one log with cross-references.** An earlier draft had the manager log
store only pointers (sequence numbers) into the telnet log, to avoid storing the
same bytes twice. That was the wrong trade. Independent logs mean: one writer per
layer with no cross-layer coupling; each file greppable and tailable standing
alone; and no log rendered useless because another was disabled, rotated, or
truncated. Storage duplication is ~2–3×, which at these volumes (§11) is
irrelevant.

**The duplication is the feature.** Because each layer records honestly and
independently, loss between layers becomes a *derivation* rather than something
the code must remember to report:

- **telnet − manager** = bytes that arrived but never reached the tool layer.
  This is the `drain` loss (§0.2).
- **manager − agent** = output the tool layer truncated or reshaped before the
  LLM saw it.

Both diffs are computed by mud_monitor at read time (§3.6). Nothing instruments
its own losses — a self-reported "I dropped this" field is wrong the moment
someone adds a fourth code path that also drops. Comparing two independent
records cannot go stale that way.

### 0.2 The loss this is designed to expose

`SessionPool#run_command` is `drain` → `send` → `read_until_prompt`
(`session_pool.rb:62-69`). **`drain`'s return value is discarded.** Everything
the MUD said since the previous command is destroyed before the next one goes
out. Four distinct leaks:

| Leak | Location | Lost |
|---|---|---|
| Pre-command `drain` | `session_pool.rb:64` | all async chatter between commands |
| `read_until` leftover | `session.rb:147` — returns up to the *first* `"> "` | tail of multi-prompt output, discarded by the next drain |
| Login dance | `Session#login`, below the pool | connect banner, menu, MOTD |
| `poll` coverage | only when the agent chooses to call it | measured below |

Measured across the nine sessions in `.boukensha/sessions/`: the agent issued
**74 `move`, 28 `look`, 14 `check` — and 8 `poll`.** Of those 8 polls, **6
returned real content**:

```
"The newbie monster barely pierces you.
 You're stunned, but will probably regain consciousness..."
"The janitor has arrived.  The cityguard leaves east."
"The Mayor has arrived."
```

A near-death stun surfaced only because a poll happened to land on it. The
overwhelming majority of combat rounds, mob arrivals and departures were drained
into the void. A log written at the manager layer alone would faithfully record
only what the agent already saw — useless for the question that matters: *what
did the agent miss?* Only the telnet log sees it.

**Scope boundary:** this spec makes the loss visible and measurable. *Fixing* it
(capture-and-forward instead of discard) changes agent perception and belongs to
`inspect_command_expanded.md`, which already flags it as "Main thing to fix."
Doing it in this order means that fix gets prioritized on measured evidence.

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
                    │   ├─ TelnetLog   ─┐                   │
                    │   ├─ ManagerLog  ─┼─ Diff (derived)   │
                    │   ├─ SessionLog  ─┘                   │
                    │   ├─ World       (reads world JSON)   │
                    │   └─ Knowledge   (2nd DB, read-only)  │
                    └───────────┬───────────────────────────┘
        ┌──────────────┬────────┴───────┬──────────────┬──────────────┐
        ▼              ▼                ▼              ▼              ▼
 .boukensha/    .boukensha/      .boukensha/    week0_explore/  .boukensha/
   telnet/        manager/         sessions/     preview/data/   knowledge
   *.jsonl        *.jsonl          *.jsonl         world/**      .sqlite3
   (NEW §4.2)     (NEW §4.3)     (existing)                     (future §8)
```

**Files stay the source of truth.** Rails does not ingest logs into its own
tables — it parses them on request and streams tails. SQLite is present because
(a) Rails needs a primary DB for its own small tables and (b) the *future* agent
knowledge file is SQLite and will be attached as a second, read-only connection.
Inverting this buys nothing today: the logs are small, append-only, and already
the artifact the bootcamp cares about.

**One Rails app, one Vite app, one process manager.** No Sinatra, no second Node
service.

---

### 2. Layout

```
week2_capable/mud_monitor/
├── README.md
├── Procfile.dev                 # api + web, driven by bin/dev
├── bin/
│   ├── setup                    # bundle + npm ci + db:prepare + world bundles
│   └── dev                      # foreman start -f Procfile.dev
├── api/                         # rails new mud_monitor_api --api -d sqlite3
│   ├── app/
│   │   ├── controllers/api/v1/
│   │   │   ├── sessions_controller.rb
│   │   │   ├── events_controller.rb       # incremental + SSE
│   │   │   ├── telnet_controller.rb
│   │   │   ├── manager_controller.rb
│   │   │   ├── diffs_controller.rb        # §3.6
│   │   │   ├── world_controller.rb
│   │   │   └── health_controller.rb
│   │   ├── models/knowledge/              # §8, ActiveRecord on 2nd DB
│   │   └── serializers/                   # plain POROs -> Hash, no gem
│   ├── lib/
│   │   ├── log_file/
│   │   │   ├── reader.rb        # shared: jsonl scan, seq, limit, after
│   │   │   └── follower.rb      # shared: offset-based tail
│   │   ├── session_log/
│   │   │   ├── store.rb  parser.rb  transcript.rb
│   │   │   ├── timing.rb        # deltas, tool latency, gaps
│   │   │   └── pricing.rb       # MODEL_PRICES + cost math
│   │   ├── telnet_log/
│   │   │   └── store.rb  parser.rb
│   │   ├── manager_log/
│   │   │   └── store.rb  parser.rb
│   │   ├── diff/
│   │   │   ├── telnet_manager.rb   # what drain ate      (§3.6)
│   │   │   └── manager_agent.rb    # what got reshaped   (§3.6)
│   │   ├── ansi.rb              # port of log_viz/lib/log_viz/ansi.rb
│   │   └── world/store.rb       # §7
│   ├── config/database.yml      # primary + knowledge
│   └── test/                    # minitest
└── web/                         # vite + react + ts (mirrors preview/web)
    ├── package.json  vite.config.ts       # proxy /api -> localhost:3000
    ├── src/
    │   ├── main.tsx  App.tsx  index.css
    │   ├── api/ client.ts  types.ts  useEventStream.ts
    │   ├── components/
    │   │   ├── Layout.tsx  Ansi.tsx  Duration.tsx  TokenChip.tsx
    │   │   ├── Sparkline.tsx  CostTable.tsx  LiveBadge.tsx
    │   │   ├── DroppedStrip.tsx           # §5.1
    │   │   └── (ported from preview: EntityTable, JsonView, links, …)
    │   └── pages/
    │       ├── Dashboard.tsx
    │       ├── Sessions.tsx  SessionDetail.tsx
    │       ├── Telnet.tsx  Manager.tsx
    │       └── (ported from preview: Rooms, RoomDetail, Mobs, WorldMap, …)
    └── public/data/             # generated world bundles (§7)
```

Ruby is 4.0.5 here; Rails is **not currently installed** (`gem list rails` is
empty) — `bin/setup` must install it. Node is 20.20.2, fine for Vite 6.

`LogFile::Reader` and `LogFile::Follower` are shared because all three logs are
the same physical shape: append-only jsonl, one JSON object per line, ordered.
Only the record schemas differ.

---

### 3. HTTP API

All under `/api/v1`, all JSON, all read-only (no POST/PUT/DELETE in scope).
Errors: `{ "error": { "code": "not_found", "message": "…" } }`.

Every log endpoint shares one envelope and one cursor convention — `seq` is the
0-based record index within a file, `?after=<seq>` is exclusive, `limit` is
clamped to 1000:

```jsonc
{ "entries": [ … ], "next_seq": 1843, "eof": true, "live": true }
```

#### 3.1 Sessions (agent layer)

```
GET /api/v1/sessions
```
```jsonc
{
  "sessions": [
    {
      "id": "20260722T162321Z-a6188b70",
      "started_at": "2026-07-22T16:23:21.144Z",
      "ended_at": "2026-07-22T16:41:07.902Z",
      "duration_ms": 1066758,
      "live": true,                              // mtime within LIVE_WINDOW
      "task": "explore the temple",
      "models": ["anthropic / claude-haiku-4-5"],
      "turns": 3, "iterations": 27, "tool_calls": 41,
      "input_tokens": 184203, "output_tokens": 5120,
      "cost_usd": 0.2137,                        // null when unpriced
      "end_reason": "completed", "stopped": false,
      "timing_source": "monotonic",              // §4.1
      "bytes": 918234
    }
  ]
}
```
Sorted newest-first by filename (ids are `%Y%m%dT%H%M%SZ`-prefixed, so lexical
sort == chronological — the same trick log_viz uses).

```
GET /api/v1/sessions/:id
```
`:id` goes through `File.basename` and is joined to the configured dir; a
realpath prefix check rejects anything escaping it → 404.

```jsonc
{
  "session":  { /* the summary object above */ },
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

One ordered array, discriminated on `type` — a direct port of
`LogViz::Session::Entry` plus timing and cross-layer links.

```jsonc
{
  "seq": 42,
  "type": "tool",            // user | assistant | reasoning | plan | tool
                             // | compaction | turn_end | limit_reached | unknown
  "turn": 1, "iteration": 6,
  "at": "2026-07-22T16:25:03.412Z",
  "dt_ms": 1840,             // since previous entry (null on seq 0)
  "duration_ms": 1611,       // type-specific, §4.4; null when unknowable

  // type: tool
  "tool_name": "tbamud__move", "tool_args": { "direction": "north" },
  "tool_result": "The Temple Of Midgaard\n…",
  "tool_ok": true, "tool_error": null,
  "result_html": "<span class=\"ansi-fg-36\">…</span>",   // server-rendered ANSI
  "manager_seq": 812,        // link into the manager log, §4.5
  "correlation": "exact",    // exact | inferred | none

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
SGR→`<span class="ansi-…">`; porting it to `api/lib/ansi.rb` keeps one
implementation and keeps an ANSI parser out of the client bundle. The client
renders `result_html` via `dangerouslySetInnerHTML` — verify `Ansi.escape_html`
is applied on every path during the port, since the output now crosses a JSON
boundary into innerHTML.

**Unknown phases pass through** as `type: "unknown"` with the raw event
attached, rather than being dropped. When boukensha grows goals/tasks (§8) they
appear in the monitor before the monitor is taught about them.

#### 3.3 Incremental + realtime

```
GET /api/v1/sessions/:id/events?after=<seq>&limit=500
GET /api/v1/sessions/:id/stream?after=<seq>          (text/event-stream)
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
data: {"reason":"session_end"}
```

- `ActionController::Live` + `SSE`, **not ActionCable** — the feed is one-way and
  per-file; ActionCable in an API-only app drags in a subscription adapter and a
  second protocol for no gain. `Last-Event-ID` (or `?after=`) is the resume
  cursor, so a dropped connection loses no events.
- **Tailing is offset polling, not inotify.** `LogFile::Follower` keeps a byte
  offset per (path, connection), sleeps 250ms, re-reads from the offset, splits
  on `\n`, and buffers a trailing partial line until its newline arrives (all
  three writers `puts`+`flush` per record, so partials are rare but possible).
  WSL2's inotify is unreliable across the Windows filesystem boundary, which is
  where this repo may live — polling is the portable choice at this scale.
- **Puma must have threads to spare.** Each open SSE connection holds a thread.
  Set `threads 5, 16` in `puma.rb`; cap concurrent streams at
  `MUD_MONITOR_MAX_STREAMS` (default 8) and return 503 beyond it, surfaced as a
  visible UI error rather than a silent dead feed. Every stream is wrapped in
  `ensure { sse.close }`; `IOError`/`Errno::EPIPE` on write ends the loop.

The same `/events` + `/stream` pair exists for the telnet and manager logs
(§3.4, §3.5) with identical semantics.

#### 3.4 Telnet log

```
GET /api/v1/telnet?date=20260722&session=default&dir=in&after=<seq>&limit=500
GET /api/v1/telnet/stream?date=…&session=…&after=<seq>
```
All filters optional. `dir` is `in`|`out`. `date` defaults to today; the store
resolves across day-rotated files so `after` cursors remain monotonic within a
day. Record schema in §4.2.

#### 3.5 Manager log

```
GET /api/v1/manager?date=…&session=…&mode=command&after=<seq>&limit=500
GET /api/v1/manager/stream?date=…&session=…&after=<seq>
```
`mode` is `command`|`raw`|`poll`|`login`. Record schema in §4.3.

#### 3.6 Diffs — the derived views

The reason for three independent logs. Both are computed at read time; nothing
in `mud_manager` or `boukensha` reports on itself.

```
GET /api/v1/diffs/dropped?session=default&from=<iso>&to=<iso>
```
**telnet − manager: what `drain` ate.** Concatenate, in order, the telnet log's
`dir:"in"` text for the session and window → stream A. Concatenate the manager
log's `received` payloads over the same window → stream B. Because the manager
never invents bytes, **B is a sequence of contiguous runs of A**. Greedily align
B's runs into A; the unmatched gaps in A are exactly what was discarded.

```jsonc
{ "dropped": [
    { "at": "2026-07-22T12:23:29.881-04:00",
      "telnet_seqs": [1839, 1840],
      "text": "\r\nThe Mayor has arrived.\r\n20H 100M 84V (news) (motd) > ",
      "bytes": 59,
      "between": { "after_manager_seq": 811, "before_manager_seq": 812 },
      "cause": "pre_command_drain" }     // pre_command_drain | post_prompt_leftover | login
  ],
  "summary": { "dropped_bytes": 4820, "dropped_runs": 37,
               "received_bytes": 61204, "drop_ratio": 0.073 } }
```
`cause` is inferred from position: a gap ending immediately before a `dir:"out"`
chunk is `pre_command_drain`; a gap following a prompt sentinel inside a
manager exchange window is `post_prompt_leftover`; anything before the first
manager record is `login`.

`drop_ratio` is the headline number — the fraction of the MUD's output the agent
never had a chance to read.

```
GET /api/v1/diffs/reshaped?session=<agent session id>
```
**manager − agent: what the tool layer changed.** Joins each agent `tool_result`
to its manager record (§4.5) and compares payloads:

```jsonc
{ "reshaped": [
    { "session_seq": 42, "manager_seq": 812,
      "kind": "truncated",              // truncated | ansi_stripped | wrapped | identical
      "manager_bytes": 486, "agent_bytes": 400,
      "detail": "agent result is a 400-byte prefix of the manager payload" } ],
  "summary": { "compared": 41, "identical": 39, "truncated": 2 } }
```
Expected to be almost entirely `identical` today — which is worth confirming
rather than assuming, since it is the layer where a future summarizer or
token-budget trimmer would silently start changing what the LLM sees.

#### 3.7 World & health

```
GET /api/v1/world/index | rooms | rooms/:id | mobs | objects | zones | shops
                        | triggers | quests
GET /api/v1/health   → { ok, telnet_dir, manager_dir, sessions_dir,
                         telnet_logging_enabled, manager_logging_enabled,
                         world_ready, knowledge_attached, live_sessions }
```
See §7 for whether the world endpoints are implemented in phase 1.

---

### 4. Changes to existing code

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
log_viz keeps working). `mono_ms` is added because wall-clock deltas are
vulnerable to NTP steps and DST while the durations we care about are
sub-second; the parser prefers `mono_ms` and falls back to `at`.

The parser handles three vintages — `at` at 1s resolution, `at` at ms
resolution, and `at`+`mono_ms` — and reports which as
`timing_source: "monotonic" | "wallclock" | "wallclock_coarse"`. The UI greys out
sub-second durations when the source is coarse rather than rendering a fake
`0ms`.

**All three logs use this same stamping helper**, so cross-layer joins compare
like with like.

#### 4.2 Telnet log — `mud_manager/lib/mud_manager/telnet_log.rb` (new)

Written from `MudManager::Session`: the reader thread for inbound,
`send_command` for outbound. That is the one place every byte passes in both
directions, and it sits **below** the pool, so it also captures the login dance
the pool never sees.

```ruby
class TelnetLog
  def self.from_env
    dir = ENV["MUD_TELNET_LOG_DIR"] and new(dir: dir)   # nil => disabled
  end
  def chunk(session:, dir:, text:, redacted: false)
end
```

`.boukensha/telnet/<YYYYMMDD>.jsonl`, one line per `readpartial` chunk and per
send, interleaved in true chronological order:

```jsonc
{"seq":1839,"at":"2026-07-22T12:23:29.881-04:00","mono_ms":98122104,
 "session":"default","dir":"in","bytes":31,"text":"\r\nThe Mayor has arrived.\r\n"}
{"seq":1840,"at":"…","mono_ms":98122227,"session":"default","dir":"in",
 "bytes":28,"text":"20H 100M 84V (news) (motd) > "}
{"seq":1841,"at":"…","mono_ms":98124341,"session":"default","dir":"out",
 "text":"look"}
{"seq":1842,"at":"…","mono_ms":98124363,"session":"default","dir":"in",
 "bytes":486,"text":"[0;33mThe Common Square[0m\r\n   The common square…"}
```

- **One file, both directions.** "Did my command go out before or after that mob
  arrived?" is unanswerable across two files.
- **Chunk boundaries are arbitrary but the timing is true.** A chunk may split
  mid-line or mid-escape-sequence; the API reassembles for display. Preserving
  arrival timing is worth more than tidy line framing, and the §3.6 alignment
  works on concatenated text, so boundaries do not affect it.
- **Text is post-`strip_iac`** — IAC negotiation is protocol noise. Pre-strip
  bytes are recorded as `raw_hex` only when `MUD_TELNET_RAW=1`.
- **Passwords must never land here.** `Session#login` calls
  `send_command(password)` (`session.rb:180`), which *would* be logged. The
  password send is marked so the record is written as
  `{"dir":"out","text":"<redacted>","redacted":true,"bytes":9}`. This is a
  required part of the change, not a follow-up — a test asserts it against a
  full `FakeMud` login (§10).
- Writing happens inside the existing `@buffer_mu` critical section in the
  reader thread — no new lock, no new thread, ordering guaranteed by the mutex
  already held.
- **Off by default** via `from_env` returning nil; every call site is `@telnet&.`.

#### 4.3 Manager log — `mud_manager/lib/mud_manager/manager_log.rb` (new)

Written from `SessionPool` at the three methods that drive the socket —
`run_command`, `run_raw`, `poll`. This is the narrowest cut that sees every
executed command with its semantic identity and its returned payload.

```ruby
class ManagerLog
  def self.from_env
    dir = ENV["MUD_MANAGER_LOG_DIR"] and new(dir: dir)  # nil => disabled
  end
  def exchange(session:, mode:, sent:, received:, elapsed_ms:, tool: nil,
               args: nil, correlation_id: nil, error: nil)
end
```

`.boukensha/manager/<YYYYMMDD>.jsonl`:

```jsonc
{"seq":812,"at":"2026-07-22T12:23:32.118-04:00","mono_ms":98124341,
 "session":"default","mode":"command",
 "tool":"tbamud__look","args":{},
 "correlation_id":"a6188b70-41",
 "sent":"look",
 "received":"[0;33mThe Common Square[0m\r\n   The common square…",
 "bytes_in":486,"elapsed_ms":1611,"error":null}
```

- Carries its **own full copy** of `received` — this log stands alone and is
  readable without the telnet log present.
- `elapsed_ms` is monotonic, measured around the send→read pair.
- `mode: "login"` records only `sent: "<username>"` and the outcome; no password
  field exists on that path.
- Daily files, not per-session: the daemon outlives any one agent run.
- `puts` + `flush` under the pool's existing mutex, so a tailer never sees
  interleaved lines.
- **Off by default**, independently of the telnet log — telnet is the expensive
  one, and being able to run manager-only is the common case.

Config: the `mud:` MCP server block in `.boukensha/settings.yaml` gains both
vars to its `env:` so the daemon inherits them:

```yaml
  mud:
    command: mud-manager
    args:    [--mcp]
    prefix:  tbamud
    env:
      MUD_HOST:              localhost
      MUD_PORT:              4000
      MUD_NAME:              dummy
      MUD_PASSWORD:          helloworld
      MUD_MANAGER_LOG_DIR:   .boukensha/manager
      MUD_TELNET_LOG_DIR:    .boukensha/telnet
```

#### 4.4 What `duration_ms` means per entry type

| type | duration | derived from |
|---|---|---|
| `tool` | `tool_call` → its `tool_result` | the paired events (the parser already pairs via `pending_calls`) |
| `assistant` | model latency: previous `iteration`/`tool_result` → this `response` | timestamps |
| `turn_end` | wall time of the whole turn | `turn` → `turn_end` |
| `user`, `plan`, `reasoning`, `compaction` | `null` | instantaneous marks |

Plus `dt_ms` on every entry — the gap since the previous one. That is the
"duration between each command" the plan asks for, and read alongside the tool
durations it separates *think time* from *MUD time*.

`SessionLog::Timing` also computes for the summary: `p50/p95 tool_ms`,
`p50/p95 model_ms`, `total_idle_ms` (sum of gaps > 5s), and `wall_ms` vs
`busy_ms`. Where a manager record is joined, the tool duration can be split
further into agent-side overhead vs the manager's `elapsed_ms` — MCP round-trip
cost becomes visible as the difference.

#### 4.5 Correlating agent tool calls to manager records

Timestamp-nearest matching is wrong under concurrency, and this system is
already concurrent: `player` and `room_inspector` drive the **same** MUD session
per `.boukensha/settings.yaml`.

- **Ship this:** the boukensha MCP client sends
  `_meta: { correlation_id: "<session_id>-<event_seq>" }` on `tools/call`;
  `mud_manager`'s MCP server reads `params._meta.correlation_id` and threads it
  into `ManagerLog#exchange`. `_meta` is MCP's sanctioned passthrough slot, so
  no protocol extension is needed and non-boukensha clients simply omit it.
- **Fallback:** nearest preceding manager record within 2s, tagged
  `"correlation": "inferred"` so the UI can render it dashed and never present a
  guess as a fact.

The telnet log needs no correlation id — §3.6 aligns it to the manager log by
byte content, which is exact by construction.

---

### 5. Frontend

Stack copied from `week0_explore/preview/web` so the port is mechanical: Vite 6,
React 18, `react-router` 7, TS 5.7, `@xyflow/react` + `dagre` (for the future
map, §8). No component library — `index.css` plus preview's styles, extended
with log_viz's `public/style.css` rules for ANSI spans and chips.

| route | content |
|---|---|
| `/` | Dashboard: live sessions, recent sessions, drop ratio, world counts, health |
| `/sessions` | the log_viz index table |
| `/sessions/:id` | the transcript (§5.1) |
| `/telnet` | raw byte stream, filter by session/direction, live-tailing |
| `/manager` | executed commands, filter by session/mode, live-tailing |
| `/world/*` | preview's routes, unchanged paths where possible |

#### 5.1 Transcript page

Port of `views/session.erb`, plus:

- **Timing gutter.** Absolute time (hover → full ISO), `+dt` since previous, and
  a duration pill colour-ramped by magnitude. When
  `timing_source == "wallclock_coarse"`, pills render as `~1s` in muted text —
  never a precise-looking `0ms`.
- **Dropped strip.** Between entries, where §3.6 reports a gap: a muted
  `▾ 2 events dropped · 59 bytes` bar. Expanded, it shows the ANSI-rendered text
  the agent never received. This is the headline feature — perception loss
  becomes something you can point at.
- **Live mode.** If `session.live`, open the SSE stream from the last-loaded
  `seq`. New entries append with a brief highlight; `LiveBadge` shows
  connected/reconnecting/ended. **Autoscroll sticks only when already at the
  bottom** — scrolling up to read must not be yanked back, which is the single
  most common way a live log UI becomes unusable.
- **Manager pane.** Toggleable right rail, or inline under each tool entry,
  showing the joined manager record (`sent`, `received`, `elapsed_ms`,
  `correlation`). This is where "we have no logging in mud manager" is answered
  visually: `tbamud__move{direction:"north"}` sits directly above the literal
  `north` that went out and the bytes that came back.
- **Sparkline + cost table.** Ported from the ERB helpers; the SVG sparkline
  becomes `Sparkline.tsx` (same math, points from `usage_series`).

`useEventStream.ts` owns `EventSource` lifecycle, exponential backoff reconnect
(250ms → 5s), cursor tracking via `Last-Event-ID`, dedupe by `seq` on replay,
and teardown on unmount. It is generic over the three log types.

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
    replica: true          # ActiveRecord refuses writes on this connection
    migrations_paths: []   # owned by the agent, not by Rails
```

`replica: true` is the important line: mud_monitor must never write or migrate
the agent's knowledge file. In phase 1 that file does not exist — the connection
is declared but established lazily, and `/api/v1/health` reports
`knowledge_attached: false` rather than failing to boot.

| var | default | purpose |
|---|---|---|
| `MUD_MONITOR_SESSIONS_DIR` | `<repo>/.boukensha/sessions` | agent logs |
| `MUD_MONITOR_TELNET_DIR` | `<repo>/.boukensha/telnet` | telnet logs (read) |
| `MUD_MONITOR_MANAGER_DIR` | `<repo>/.boukensha/manager` | manager logs (read) |
| `MUD_MONITOR_WORLD_DIR` | `<repo>/week0_explore/preview/data/world` | parsed world JSON |
| `MUD_KNOWLEDGE_DB` | `<repo>/.boukensha/knowledge.sqlite3` | future agent memory |
| `MUD_MONITOR_MAX_STREAMS` | `8` | concurrent SSE cap |
| `MUD_MONITOR_LIVE_WINDOW` | `10` | mtime freshness (s) → `live: true` |
| `PORT` | `3000` | Rails |

Writer-side, in `mud_manager` (§4.2, §4.3): `MUD_TELNET_LOG_DIR`,
`MUD_MANAGER_LOG_DIR`, `MUD_TELNET_RAW`.

CORS: `rack-cors` allowing `localhost:5173` in development only; in production
the Vite build is served as static files from the same origin and CORS is off.

---

### 7. World data — deliberately *not* a Rails concern in phase 1

`preview/web/scripts/build-data.mjs` already aggregates
`data/world/{wld,mob,obj,zon,shp,trg,qst}/*.json` into six id-keyed bundles in
`public/data/` (~4 MB), and `src/data/load.ts` fetches and memoizes them. That
pipeline works, is build-time, and costs the server nothing.

**Phase 1: copy the script and the bundles wholesale.** `mud_monitor/web` runs
the same `npm run build:data` against `MUD_MONITOR_WORLD_DIR`, and the world
pages keep fetching `/data/*.json` as static assets. `/api/v1/world/*` is
specified in §3.7 but **not implemented** until something needs server-side
world access — which is §8's map, where world rooms must be joined against agent
knowledge rows and the join genuinely belongs on the server.

This ordering makes the world port a file-move plus a path constant, keeping
phase 1's risk concentrated in what is actually new: the two loggers, the diffs,
SSE, and timing.

---

### 8. Future hooks (designed for, not built)

- **Map from agent knowledge.** `Knowledge::Room`, `Knowledge::Exit` on the
  `knowledge` connection; `GET /api/v1/map` joins them against the world bundles
  server-side and returns nodes/edges; the client renders with `@xyflow/react` +
  `dagre` — already dependencies, already used by `preview/src/pages/WorldMap.tsx`,
  so the renderer is a port too. The interesting half is the diff: rooms the
  agent *knows* vs rooms that *exist* — the real measure of exploration, and the
  third member of the same family as §3.6.
- **Player stats/inventory.** Already flowing past as
  `tbamud__check(kind: score|inventory|equipment|gold)` results. A
  `StatsExtractor` over the transcript gives a last-known-value panel with an
  `as_of` timestamp — no new logging needed, and it degrades honestly (stale
  values labelled stale rather than silently wrong).
- **Goals and tasks.** They will arrive as new `phase:` values in the same
  jsonl; §3.2's `unknown` passthrough means they are visible in the monitor
  before the monitor is taught about them.

---

### 9. Phasing

| # | Deliverable | Done when |
|---|---|---|
| 0 | Scaffold: `rails new --api -d sqlite3`, Vite app, `bin/setup`, `bin/dev`, `/api/v1/health` green | `bin/dev` serves both; health returns `ok: true` |
| 1 | Session API + React transcript (port of log_viz) | every log_viz page has an equivalent; side-by-side output matches on a real session |
| 2 | ms timestamps (§4.1) + `Timing` + gutter UI | new sessions show sub-second durations; old ones render coarse without lying |
| 3 | SSE tail + live transcript | a running agent's tool calls appear within ~500ms; restart the API and the client resumes with no gaps or dupes |
| 4 | `ManagerLog` (§4.3) + `/api/v1/manager` + manager pane | every agent tool call shows the command mud_manager actually executed |
| 5 | `TelnetLog` (§4.2) + `/api/v1/telnet` + telnet page | raw byte stream visible and tailing; password redaction test green |
| 6 | `/api/v1/diffs/dropped` + dropped-strip UI | `drop_ratio` reported on the dashboard; dropped events expandable in the transcript |
| 7 | Correlation ids via MCP `_meta` (§4.5) + `/api/v1/diffs/reshaped` | correlations are `exact` when boukensha is the client |
| 8 | World pages ported (§7) | `/world/*` matches preview's output |
| 9 | Retire `log_viz` and `preview/web` as *running* apps | each README points at mud_monitor; code stays in the tree as the week's artifact |

Phases 4 and 5 are ordered manager-then-telnet deliberately: the manager log is
cheap, always-on-able, and answers the plan's literal ask. The telnet log is the
expensive one and only pays off once phase 6 can diff against it.

---

### 10. Testing

**Rails (minitest):**
- `SessionLog::Parser` against fixtures covering all three timestamp vintages,
  unknown phases, a truncated final line (live file mid-write), and an empty file.
- `SessionLog::Timing` — deltas, tool pairing when calls interleave, monotonic vs
  wallclock fallback.
- `Pricing` — known model; unknown model → `nil`, **not `0.0`** (a fake zero cost
  is worse than an absent one).
- `Ansi` — HTML escaping before SGR wrapping; unterminated escape sequences.
- `Diff::TelnetManager` — the alignment: a synthetic telnet stream with known
  drained runs must produce exactly those runs, including a drop at the very
  start (login) and one at the very end (trailing chatter, no following command).
- `Diff::ManagerAgent` — identical, truncated, and ANSI-stripped cases.
- Request tests: index, show, 404, **path traversal** (`../../etc/passwd` as
  `:id`), `?after=` paging, `limit` clamping, stream cap → 503.
- SSE: append to a temp file, assert frames arrive in order with correct `id:`
  cursors, and that `after=` replays exactly the missing range.

**mud_manager:**
- `TelnetLog` and `ManagerLog` each off by default; each enabled independently.
- One telnet record per inbound chunk and per send, both directions, ordered.
- One manager record per `run_command`/`run_raw`/`poll`, with `elapsed_ms > 0`
  and errors captured.
- **No credential ever appears in either log** — assert against a full
  login+command cycle driven by `MudManager::FakeMud`, grepping both files for
  the password string.
- With both logs on, a `FakeMud` scenario that emits async chatter between
  commands produces a non-empty `dropped` diff — the end-to-end proof that §0.2
  is real and measured.

**boukensha:**
- Logger emits `at` with ms and `mono_ms`; log_viz still parses the new format
  (do not break the app we are replacing before it is replaced).

**web:** `tsc -b --noEmit` in CI (same as preview's `lint` script). Component
tests out of scope; the transcript is verified against real session files by eye
during phase 1.

---

### 11. Risks

- **Telnet log volume.** ~490 bytes per room look; roughly 1.5–3 MB/hour under
  active play, and the manager log duplicates most of it — call it ~5 MB/hour
  with both on. Daily rotation only, and `MUD_TELNET_LOG_DIR` unset by default.
  If it bites, add retention pruning to `bin/setup` — but not before it bites.
  - [Note] we aren't under that kind of heavy active play, if we have a way to turn logs on and off we should be fine.
- **Password leakage into the telnet log.** The one genuinely dangerous part of
  this spec: `Session#login` sends the password through the same
  `send_command` path being instrumented. Redaction is specified in §4.2 and
  tested in §10, and must land in the same commit as the logger, never after.
  - [Note] its for development and not real players so doesn't matter
- **SSE thread exhaustion.** Mitigated by the stream cap and puma thread config,
  but three tailing pages × several tabs will reach 8. The 503 must surface in
  the UI as a clear error.
- **Old sessions look broken.** 1-second timestamps mean most durations render as
  `~1s`. Handled by `timing_source`, but worth saying plainly: **the first
  genuinely useful timing data starts at phase 2**, and nothing recovers it for
  the nine sessions already on disk.
  - [Note] don't care about old sesssion
- **Diff alignment is heuristic at the edges.** The greedy run-alignment in §3.6
  is exact when the manager's payloads are verbatim substrings of the telnet
  stream. If a future change reshapes output before returning it, alignment
  degrades — `Diff::ManagerAgent` reporting anything other than `identical` is
  the signal that §3.6's assumption is weakening, so the two diffs check each
  other.
  - [Note] no idea what you're saying, I Dont think it matters
- **Correlation before phase 7 is a guess.** With `player` and `room_inspector`
  sharing one MUD session, nearest-timestamp matching will mis-attribute during
  concurrent activity. The `inferred` flag exists so the UI never presents a
  guess as a fact.
  - [Note] they dont run at the same time, so who cares.
- **Three apps become four.** Until phase 9, log_viz and preview still exist and
  still work. That is intentional — they are the week 0/1 artifacts — but each
  README must say which one is current, or the next person runs the wrong app.
  - [Note] I want the use to only default with single app, so this is not a real concern you are raising.

---

## Amendment A — one session file per run, with the task made visible

Observed: a single REPL turn ("can you find the fountain") produced **two**
session files —

```
.boukensha/sessions/20260722T195550Z-c9893a1f.jsonl   player
.boukensha/sessions/20260722T195616Z-2ee6aae7.jsonl   room_inspector
```

They are 26 seconds apart, and the second one's first `prompt` event is
`"Inspect the current room and return the structured room JSON."` — the
`InspectRoom::INSTRUCTION` constant. That is not a second run; it is the player
delegating, mid-turn, inside one conversation.

### A.1 Root cause

`Boukensha.run_task` unconditionally builds its own logger
(`boukensha/lib/boukensha.rb:214`):

```ruby
logger = Logger.new(log: log, snapshot: { ... })
```

`log:` is nil on the delegation path (`boukensha_loader.rb:128` passes no
`log:`), and `Logger#initialize` (`logger.rb:12-19`) treats a nil `session_id`
as "mint a new one":

```ruby
@session_id = session_id || generate_session_id
@path       = log || File.join(dir || default_dir, "#{@session_id}.jsonl")
```

So every `inspect_room` call opens a new file. The player's own file records the
`tool_call`/`tool_result` pair for `inspect_room` and nothing about what
happened inside it; the sub-run's file records the work with no indication of
who asked for it or which turn it belongs to. **Neither file is a complete
account of the turn, and nothing on disk links them** — not even the
`session_id`, which is regenerated rather than inherited.

This scales badly in exactly the way the user flagged: one delegating tool call
per room visited means one file per room visited.

### A.2 What the original spec got wrong

§3.1 and §3.2 assume **one physical `.jsonl` file == one logical run**, and
build the whole read model on it: `GET /api/v1/sessions/:id` maps `:id` straight
to a filename, and `entries` is a flat ordered array with no notion of nesting.
§4.5 designs correlation *downward* (agent tool call → manager record via MCP
`_meta`) but never considers correlation *sideways*, between two agent-layer
logs produced by the same turn. The spec inherited boukensha's bug as an
assumption.

There is also a latent symptom already visible in the spec: §3.1's
`cost_breakdown[]` is keyed by `task` (`"task": "room_inspector"`), but that key
can never be populated today. `task` reaches the log only through
`Logger#response`'s `execution_metadata` (`logger.rb:60-69`, `119-134`), and
every caller in `Agent` passes `task: nil` (`agent.rb:61`, `agent.rb:114`) or
omits it entirely (`agent.rb:157`) — after `metadata.compact` the key is dropped
from every record written. **The field is dead.** Amendment A is what makes
§3.1's own cost-by-task table possible.

### A.3 The fix — share the logger, label the task

One session file per run. The delegated sub-run appends to the parent's file,
bracketed by explicit markers, and **every** event carries the task that
produced it.

**A.3.1 `Logger` owns a task stack.**

```ruby
def initialize(session_id: nil, dir: nil, log: nil, snapshot: {}, task: "player")
  ...
  @task_stack = [task]
end

# Bracket a delegated sub-run. Reentrant; the stack keeps nesting honest if a
# subagent ever delegates further.
def task(name, snapshot: {})
  @task_stack.push(name.to_s)
  write_log({ phase: "task_start", task_name: name.to_s }.merge(snapshot))
  yield
ensure
  write_log(phase: "task_end", task_name: name.to_s)
  @task_stack.pop
end

def write_log(event)
  now = Time.now
  @log_io.puts JSON.generate(event.merge(
    session_id: @session_id,
    task:       @task_stack.last,
    depth:      @task_stack.size - 1,
    at:         now.iso8601(3),
    mono_ms:    (Process.clock_gettime(Process::CLOCK_MONOTONIC) * 1000).round
  ))
  ...
end
```

`task` and `depth` are stamped in `write_log`, so no call site can forget them —
the same argument §0.1 makes for not letting components self-report.

The sub-run's configuration (its own `model`, `max_iterations: 12`) is not lost:
it becomes the `task_start` payload, which is exactly what the old duplicate
`session_start` line was carrying. There is only ever one `session_start` per
file again.

**Remove the now-redundant `task:` parameter** from `Logger#response` and
`execution_metadata` in the same change. Two sources of truth for one field is
how it went dead in the first place; `write_log` is the survivor.

**A.3.2 `run_task` accepts a logger instead of always minting one.**

```ruby
def self.run_task(task_class, input, log: nil, logger: nil, max_output_tokens: nil, ...)
  ...
  own_logger = logger.nil?
  logger   ||= Logger.new(log: log, snapshot: { ... })
  ...
  logger.task(task_class.task_name, snapshot: {
    max_iterations: max_iters, max_output_tokens: max_out,
    context_window: context_window, model: model, provider: backend
  }) do
    ctx.add_message(:user, input)
    agent.run
  end
ensure
  logger&.close if own_logger
end
```

`own_logger` matters: a borrowed logger belongs to the parent and must not be
closed when the sub-run returns — otherwise the delegation silently truncates
the rest of the turn. Standalone `run_task` callers (tests, scripts) keep
today's behaviour and still get their own file.

**A.3.3 The ordering constraint — why the closure can't just capture it.**

In `Boukensha.repl` the native-tool block is evaluated *before* the logger
exists:

```
boukensha.rb:130   registry = Registry.new(...)
boukensha.rb:134   RunDSL.new(registry).instance_eval(&block)   # inspect_room defined here
boukensha.rb:142   logger = Logger.new(...)                     # ...but only born here
```

So `boukensha_loader.rb:127-129`'s lambda has nothing to close over. Fix by
**moving `Logger.new` above the `RunDSL` eval** (it depends only on `cfg`,
`model`, `backend`, `context_window` — all resolved by line 126, so the move is
safe) and exposing it on the DSL:

```ruby
class RunDSL
  def initialize(registry, logger: nil)
    @registry = registry
    @logger   = logger
  end
  attr_reader :logger
end
```

The entrypoint then threads it explicitly:

```ruby
Boukensha.repl(tui: !no_tui) do
  parent = logger
  tool "inspect_room", description: "..." do |**_|
    Boukensha::Tools::InspectRoom.call(
      run: ->(instruction) {
        Boukensha.run_task(Boukensha::Tasks::RoomInspector, instruction, logger: parent)
      }
    )
  end
end
```

Explicit passing, not an ambient `Boukensha.current_logger` thread-local. The
delegation graph stays readable, and a test can hand in a fake logger without
touching global state.

`Boukensha.run` gets the same treatment as `.repl`, so both entrypoints behave
identically.

**A.3.4 Interleaving is a non-issue.** `inspect_room` blocks on `run.call`
(`tools/inspect_room.rb:20`) — the player's agent loop is parked inside
`Registry#dispatch` for the whole sub-run. Same thread, sequential writes, no
lock needed. This is the same fact the §11 risk note relies on ("they dont run
at the same time"), now load-bearing in a second place.

**A.3.5 TUI subscribers.** `Logger#subscribe` (`logger.rb:85-88`) feeds the TUI,
which will now receive `task_start`/`task_end` and sub-run events it has never
seen. Verify it ignores unknown phases rather than raising — same
unknown-passthrough discipline §3.2 requires of the monitor.

### A.4 API changes

**§3.1 session summary** gains a task roster, so the index can show delegation
without opening the session:

```jsonc
{
  "id": "20260722T195550Z-c9893a1f",
  "task": "player",                              // the root task
  "tasks": ["player", "room_inspector"],         // every task that ran
  "sub_runs": 7,                                 // count of task_start events
  ...
}
```

`cost_breakdown[].task` (already specified in §3.1) now populates for real —
"what did room_inspector cost me this session" becomes answerable, which is the
number that decides whether it moves to a local Ollama model (`settings.yaml:54`).

**§3.2 entry shape** gains two fields on *every* entry and two new types:

```jsonc
{
  "seq": 42,
  "type": "tool",
  "task": "room_inspector",     // NEW — always present
  "depth": 1,                   // NEW — 0 = root task, 1 = delegated, …
  ...
}
```

```
type: "task_start"   task_name, model, provider, max_iterations, context_window
type: "task_end"     task_name, duration_ms
```

`entries` stays a flat ordered array — the parser does not build a tree. `depth`
is enough for the client to render nesting, and flat keeps `?after=<seq>`
cursors, SSE replay (§3.3), and the `dropped`-strip interleaving (§3.6) working
exactly as specified. **Nesting is a rendering concern, not a transport one.**

**§4.4 durations.** `task_end` gets `duration_ms` = its `task_start` → `task_end`
span. The parent's `inspect_room` `tool` entry already measures the same
interval from outside; the difference between the two is subagent startup
overhead (settings resolution, tool registration, backend construction), which
is worth seeing.

### A.5 UI — the task must be obvious

The user's requirement: *the session UI needs to make clear what task is
running.*

- **Task chip on every entry row.** Colour-coded per task, in the timing gutter
  next to `+dt` (§5.1). `player` and `room_inspector` must be distinguishable at
  a glance while scrolling, not on hover.
- **Delegated runs render as a nested, collapsible block.** `task_start` opens an
  indented group headed `▾ room_inspector · haiku-4-5 · 12 iterations max`,
  closed by `task_end` showing duration, iteration count, and cost. Collapsed by
  default once a session has more than a few — the player's narrative is the
  spine, and sub-runs are detail you open when a room looks wrong.
- **Indent by `depth`,** with a left rule down the group so a long sub-run's
  membership stays visible when its header has scrolled off.
- **Live mode (§5.1) follows into sub-runs.** SSE entries carry `task`/`depth`
  like any other, so an open group streams in place. The autoscroll rule is
  unchanged.
- **Session list** shows the task roster as chips, plus a `⑂ 7` delegation count.
- **Header strip** on the transcript names the currently-running task when the
  session is live — answering "what is it doing right now" without reading.

### A.6 Testing

Added to §10's **boukensha** block:

- One `inspect_room` call produces **exactly one** session file, containing
  both the player's and the sub-run's events.
- Events between `task_start` and `task_end` carry `task: "room_inspector"`,
  `depth: 1`; events outside carry `task: "player"`, `depth: 0`.
- The parent logger is **still open and writing** after the sub-run returns —
  the `own_logger` regression test, and the one that actually bites.
- `run_task` called without `logger:` still mints its own file (standalone path
  unbroken).
- A raised exception inside the sub-run still emits `task_end` and pops the
  stack — subsequent player events must not be mislabelled `room_inspector`.
- Nested delegation (`depth: 2`) via a fake task, so the stack is exercised
  rather than assumed.

Added to the **Rails** block:

- Parser: `task`/`depth` on every entry; `task_start`/`task_end` typed
  correctly; a file whose `task_end` is missing (session killed mid-sub-run)
  parses without hanging the group open incorrectly — the group closes at EOF
  and is marked incomplete.
- Summary: `tasks[]` and `cost_breakdown[].task` populated from a real
  two-task fixture.

### A.7 Phasing

Amendment A lands as **phase 1.5** — after the session API and transcript exist
(phase 1), before ms timestamps (phase 2).

| # | Deliverable | Done when |
|---|---|---|
| 1.5 | Shared logger + task labelling + nested transcript UI | one `inspect_room` call yields one file; the transcript shows a collapsible `room_inspector` group; cost-by-task is non-empty |

It cannot go earlier: there is no UI to render nesting into. It should not go
later: every session recorded before it ships is split across files that nothing
will ever join, and phases 4–7 all join *against* the session log — building
correlation on a broken session model means doing it twice.

Old split sessions on disk are **not** migrated (consistent with §11's "don't
care about old sessions"), but the parser must not choke on them: a file whose
only content is a `room_inspector` run is a valid session with
`task: "room_inspector"` as its root and `depth: 0` throughout.
