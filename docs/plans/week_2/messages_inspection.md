## Mud Monitor - Messages Inspection

As the agent is running its messages that it feeds into the model is not visible to me.
It makes it hard for me to understand what its actually consuming.
What I would like is to be able to click on a tiny link that opens a sidebar for a session
and I can see exactly in mesages history.

We wouldn't want to store the message history every single change, but just whats been added.
I would imagine we could add checkpoints to the message history so we know whats been addded.

Compaction can change it so it has to handle that, same if the clear command is run.

Does clear commands get captured in our session history?

http://localhost:5173/sessions/20260723T164944Z-52fbb929

## Technical Exploration

### What already exists (the good news)

The exact message array fed to the model **is already captured on disk**, in full,
on every model call. In `boukensha/lib/boukensha/logger.rb:62`:

```ruby
def prompt(messages:, tools:, context_window:)
  write_log(
    phase:         "prompt",
    message_count: messages.size,
    messages:      messages.map { |m| serialize_message(m) },  # role + content, the WHOLE array
    ...
  )
end
```

So every `prompt` event in a session `.jsonl` is a **complete snapshot** of the
message history at that moment — role + content (content being a string, or an
array of `text` / `tool_use` / `tool_result` blocks). The linked session
`20260723T164944Z-52fbb929` has 13 `prompt` events = 13 snapshots.

The reason you can't see it today is purely a **read-side** limitation: the
monitor's parser throws almost all of it away. In
`mud_monitor/api/lib/session_log/parser.rb:78`:

```ruby
when "prompt"
  next unless pending_user
  message = event["messages"]&.last     # only the LAST message, and only if it's a new user turn
  ...
```

Everything except the newest user message is discarded. The transcript you see
is a *curated reconstruction* (user / assistant / plan / tool / reasoning), not
the raw array the model consumes. That's the gap this feature closes.

### Answering the direct questions in the brief

- **"Does `/clear` get captured in our session history?"** — **No.**
  `Repl#handle_command("/clear")` (`repl.rb:103`) calls
  `Context#clear_messages!` (`context.rb:73`), which just does `@messages = []`
  with **no log event**. `/compact` in the REPL (`repl.rb:108`) is the same — no
  event. Note both are **REPL/TUI-only** commands; the MUD agent sessions
  (`task: "player"`, driven by `boukensha.rb`'s agent loop) never invoke them, so
  the linked session contains no clear/compact. If we want clear/compact to be
  *visible* in the sidebar, we must emit an event for them (small change, below).
- **Compaction** during an agent run *is* captured: `Agent#compact_if_needed`
  (`agent.rb:94`) calls `logger.compaction(before:, dropped:, ...)` →
  `phase: "compaction"`. The parser already turns this into a `:compaction`
  entry, and the very next `prompt` snapshot reflects the trimmed array. So
  compaction is handled "for free" by snapshot diffing.

### "We wouldn't want to store every change, just what's been added" — reframed

The brief assumes we'd need to *add* storage. We don't — the logger already
stores the full array every prompt (arguably too much). Two ways to give you the
checkpoints-and-deltas view:

1. **Derive deltas at read time from existing snapshots (recommended).**
   No log-format change, works on every existing session immediately. Each
   `prompt` = a checkpoint; the delta is `newMessages − previousSnapshot`.
2. **Change the logger to store deltas + periodic checkpoints.** More faithful
   to the brief's wording, but changes the on-disk format, needs reconstruction
   logic, and buys nothing the read-side approach doesn't already give us. Defer
   as an optional storage optimization, not part of this feature.

Recommendation: **(1)**. Treat this as a presentation feature over data we
already have. Optionally trim logger redundancy later as a separate task.

### Delta algorithm (parser side)

Message arrays are **append-only except for front-trimming** (compaction/clear
drop from the head; the agent loop appends assistant + tool_result to the tail).
So a snapshot `N` relative to snapshot `N-1` is fully described by:

- `dropped_prefix`: messages at the front of `N-1` no longer present in `N`
- `appended_suffix`: messages at the tail of `N` not in `N-1`
- everything in between is unchanged (the "carried" window)

Compute by finding the longest run of `N-1` that appears as a contiguous block
at the head of `N` (compare on `{role, content}` equality). Robust enough given
the append/front-trim invariant; if alignment ever fails (e.g. a hard clear to
empty), fall back to "everything dropped, everything in N is new," which reads
correctly as a reset.

### Proposed implementation

**A. Boukensha (make clear/compact visible) — small, optional-but-recommended**
- Add `Logger#clear(before:)` → `phase: "clear"`, and have
  `Repl#handle_command`'s `/clear` and `/compact` branches log via the logger
  (compact can reuse the existing `compaction` event). Pass the logger into the
  Repl/Context where `clear_messages!` is invoked.
- Add a test in `boukensha/test/test_logger.rb` asserting the `clear` event is
  written. (Purely additive; existing sessions simply never contain the event.)

**B. API (surface the snapshots + deltas)**
- New parser method `SessionLog::Parser#message_checkpoints` (or a small
  dedicated `SessionLog::MessageTimeline` class fed the same `.jsonl`) that walks
  `prompt` (and `compaction`/`clear`) events and yields ordered checkpoints:
  `{ seq, turn, iteration, at, message_count, dropped_prefix, appended, full }`.
  Anchor each checkpoint to the seq of the transcript entry at that iteration so
  the sidebar can cross-link to the main transcript.
- New endpoint `GET /api/v1/sessions/:id/messages` returning the checkpoint list.
  Add a `MessageCheckpointSerializer`. Register the route as another `member` on
  `resources :sessions` (`routes.rb:11`). Reuse `SessionLog::Store#path_for`
  (safe path resolution already handled there).
- Keep it out of the SSE stream for v1 (poll/refetch on demand); live streaming
  of message deltas can be a follow-up once the static view is proven.
- Tests: `api/test/lib/session_log/parser_test.rb` (or new
  `message_timeline_test.rb`) covering append-only growth, a compaction that
  drops a prefix, and a clear-to-empty reset; a controller test for the endpoint.

**C. Web (the sidebar)**
- Add a "tiny link" in `SessionDetail.tsx` — e.g. next to the session title or in
  the `.meta` line — labelled something like `🧠 context` / `messages`, that
  toggles a right-hand **drawer** (new `MessagesSidebar.tsx` component +
  `.messages-drawer` styles in `index.css`).
- Drawer content: a vertical list of checkpoints (one per model call). Each
  checkpoint header shows turn/iteration/time and message count; the body shows
  **what changed** — appended messages highlighted, a `↻ dropped N (compaction)`
  or `⌫ cleared` marker where the front was trimmed. A per-checkpoint toggle
  switches between **delta** (default) and **full snapshot** (the entire array
  the model saw at that call — the "exactly what it's consuming" view).
- Render message content faithfully with a small block renderer (text /
  `tool_use` name+args / `tool_result`), reusing `Ansi`/`formatArgs` from the
  existing transcript.
- Add `MessageCheckpoint` + block types to `api/types.ts` and a
  `fetchSessionMessages(id)` call in `api/client.ts`.

### Suggested phasing

1. **API-only, read-side** (B): endpoint + parser deltas + tests. Verifiable via
   curl against the linked session — proves the data is all there.
2. **Web sidebar** (C): link → drawer → delta/full toggle.
3. **Clear/compact visibility** (A): only needed once someone runs the REPL; can
   ship after 1–2 without blocking them.

### Open decisions for you

- **Delta vs. full as the sidebar default** — I'd default to delta ("what was
  added") since that's the stated need, with a per-checkpoint "show full" toggle.
- What I need to see in the sidebar is the entire message history as the agent sees it that was ingested on that call.
- **Live updates** — v1 is on-demand refetch; do you want the drawer to follow a
  live session over SSE, or is a manual refresh fine to start?
- manual refresh is fine.
- **Clear/compact logging (part A)** — worth doing now for completeness, or defer
  until the REPL is actually used against monitored sessions?
  - it should log these in the session