We have an inspect command for our Mud Manager to bring in the look and exit command.

This does provide better information for the agent to reason its next move but there can be such more going on in a room.

- determining objects that can be examined
- indentifying mobs or npcs that may appear the room.

We want to try and capture as best we can.

I would think that when we call a command its printing to STDOUT
And when an npc or mob moves in or out of a room it may just print a single line when we are sitting in the room.

Is there a way for us to call multiple commands, and then just read the back into the stdout, can we capture our first move into the room so we are reading up until that standpoint.

Investigate Mud Manager and how the telnet sessions would gather data.

Also do we need an LLM to parse this information and is there a model cheaper than haiku that is more suited to parse this information quickly into a json format.

# Technical Exploration

## TL;DR

- **Extending `inspect` is the right move, and the mechanism it needs already exists.** `inspect` runs `look` + `exits` and returns both in one tool call (`mcp/dispatcher.rb:61`). The telnet layer's `read_until_prompt` already lets us chain N commands into one buffer read, so expanding `inspect` (per this doc's name) means adding *more* commands/parsing to that composite, not building new plumbing.
- **Keep `exits` — it is the most valuable call, not a redundant one.** The autoexit line inside `look` only gives directions (`[ Exits: n e s w d ]`). The full `exits` command names the **destination room per direction** (`north - By The Temple Altar`, `east - The Midgaard Donation Room`, …). That adjacency fingerprint is exactly what we need to build a **unique room id** and upsert into the rooms DB, because room *names* repeat all over Midgaard.
- **Mobs and ground objects are already in the `look` output** — coloured lines *after* the exits line. We just aren't parsing them yet.
- **Interactable targets also hide inside the description prose** — "statue", "altar", "wall paintings", "fountain" are `look <keyword>` extra-descriptions the server never lists. Pulling candidate targets out of free text is a genuine extraction task, and a good fit for a model.
- **Async mob movement** (a mob wandering in/out while we sit still) is capturable via `poll`, but `run_command` drains-and-discards the buffer before every command, so idle chatter is silently lost unless we poll first. Main thing to fix.
- **A model does the parse. We use Haiku 4.5 now.** Room text → structured JSON (mobs, objects, interactable candidates, plus the exact identity fields) is a good fit for structured output. Ollama/local small models are a **later cost optimization**, not the first build — get it working on Haiku 4.5, keep the interface swappable.
- **Execution shape: a `room_inspector` subagent.** boukensha's architecture defines "tasks" (subagents) in `settings.yaml`. We add a new `room_inspector` task (Haiku 4.5) whose only job is to turn raw room text into our structured JSON. The player agent calls an `inspect_room` function → which fires the `inspect` MCP call (poll → look → exits) → then hands the raw output to `room_inspector` for extraction. The player never parses room text itself.
- **Parsing the room is only half of perception — the mobs then need appraising.** `look` names entities but never states their **command keyword**, never their **level**, and never their **health/equipment**. So after `room_inspector` produces candidate `mobs[]`, we run a second **appraisal loop**: for each candidate, `consider <keyword>` (→ a relative-difficulty read) and `examine <keyword>` (→ description + health diagnosis + visible equipment). This loop does triple duty — it **validates the guessed keyword** (a keyword that resolves is real; one that returns "They aren't here." was a hallucination to drop), it **attaches threat/health/equipment** to the record, and its resolve/fail outcome is what **decides each entity's inclusion**. See §4.5 — it is grounded in the tbaMUD source, not CircleMUD memory.
- **You cannot read a mob's absolute level as a mortal.** `consider` returns a *qualitative difficulty string* keyed off `GET_LEVEL(victim) - GET_LEVEL(ch)` (a level **delta** bucket), and `examine`/`look_at_char` shows health-diagnosis and equipment but **no level**. So "level information relative to us" is exactly what the game exposes — a relative bucket — and absolute mob level is not observable. Plan the record around the delta, not an absolute.

---

## 1. How the telnet session actually gathers data

The whole stateful surface lives in one class: `MudManager::Session` (`mud_manager/lib/mud_manager/session.rb`).

- On `open`, a **background reader thread** (`start_reader`) loops on `@socket.readpartial(4096)`, strips telnet IAC negotiation bytes (`strip_iac`), and appends the decoded text into a shared `@buffer` under a mutex, signalling a condition variable each time (`session.rb:200-227`).
- The agent side never reads the socket directly. It calls one of three drain strategies:
  - `read_until_prompt` — blocks until the CircleMUD prompt sentinel `"> "` appears, then returns everything up to it (`session.rb:161`). This is the workhorse: "send a command, get its full response."
  - `read_until_quiet(n)` — blocks until `n` seconds pass with no new bytes (`session.rb:102`). Used for commands that don't emit a prompt promptly.
  - `drain` — non-blocking, returns whatever is buffered right now (`session.rb:92`).

`SessionPool` wraps this per named session and adds lazy connect + login + self-healing reconnect (`mcp/session_pool.rb`). The three verbs the agent uses:

| Pool method | Strategy | Used by |
|---|---|---|
| `run_command` | `drain` → `send` → `read_until_prompt` | structured tools (`look`, `move`, …) |
| `run_raw` | `send` → `read_until_quiet` | `send_raw` escape hatch |
| `poll` | `drain` only, non-blocking | `poll` tool (async chatter) |

So the answer to *"is there a way to call multiple commands and read back into stdout?"* is **yes, and it's already the pattern.** `read_until_prompt` returns a full command's output up to the sentinel; calling it in sequence gives you each command's block cleanly separated. The `inspect` composite already does this for two commands:

```ruby
def inspect_room(id)
  look  = @pool.run_command(id, MudManager::Primitives.look)
  exits = @pool.run_command(id, MudManager::Primitives.info_self("exits"))
  "== look ==\n#{look}\n\n== exits ==\n#{exits}"
end
```
(`mcp/dispatcher.rb:61`)

Expanding `inspect` = adding to this chain (e.g. a leading `poll` for async events) and parsing the combined result — no new telnet mechanism required.

---

## 2. What a room actually looks like on the wire

Captured from real sessions (`.boukensha/sessions/…`), ANSI stripped.

### `look` — Market Square, two visits

```
Market Square
   You are standing on the market square, the famous Square of Midgaard.
A large, peculiar looking statue is standing in the middle of the square.
Roads lead in every direction, north to the temple square, south to the
common square, east and westbound is the main street.
[ Exits: n e s w ]
A Peacekeeper is standing here, ready to jump in at the first sign of trouble.

20H 100M 42V (news) (motd) >
```
…and the same room moments later (Peacekeeper has wandered off):
```
Market Square
   ...
[ Exits: n e s w ]

20H 100M 58V (news) (motd) >
```

The mob is present in one visit and gone the next — the exact "mobs move around" problem, confirmed in real data. Note also the prose names a **statue** you could `look statue` at; that keyword appears nowhere structured.

### `exits` — why it is NOT redundant

The full `exits` command returns destination room names per direction (captured, `20260716T151021Z`):

```
Obvious exits:
north - By The Temple Altar
east  - The Midgaard Donation Room
south - The Temple Square
west  - The Reading Room
down  - The Temple Square
```

The autoexit line in `look` is only `[ Exits: n e s w d ]`. This block is the difference between "there is a north exit" and "north leads to *By The Temple Altar*." That mapping is what lets us:

- build a **stable room identity** (name + sorted `{direction → destination}` pairs, optionally + description hash), since bare room names repeat across the world (many "Main Street", "The Temple Square"),
- **upsert adjacency** into the rooms DB and pathfind over it,
- detect when the same name is actually two different rooms.

So `exits` is the single highest-value call for map-building. Keep it.

### Room anatomy (raw ANSI the server sends)

| Part | Marker | Example |
|---|---|---|
| Room name | `\e[0;33m` (yellow), first line | `The Temple Of Midgaard` |
| Description | plain prose, first line of each paragraph indented 3 spaces | `   You are in the southern end…` |
| Autoexit line | `\e[0;36m` (cyan) | `[ Exits: n e s w d ]` |
| Entities (mobs + ground objects) | `\e[0;32m` (green) lines *after* exits | `A Peacekeeper is standing here…` / `An automatic teller machine has been installed in the wall here.` |
| Prompt | ends in `> ` | `20H 100M 45V (news) (motd) >` |

The prompt carries HP/Mana/Move for free — `20H 100M 45V` parses with `(\d+)H (\d+)M (\d+)V`, no separate `score`/`report` needed.

**Entity lines are not one fixed shape.** Verified against tbaMUD `src/act.informative.c` (`list_one_char`): a mob prints its authored `long_descr` **only** when it is an NPC, has a long_descr, *and* is in its default position (`GET_POS(i) == GET_DEFAULT_POS(i)`). Otherwise the server emits a generated position line from the `positions[]` table — ` is standing here.`, ` is sitting here.`, ` is sleeping here.`, ` is lying here, dead.`, etc. — and a fighting mob prints `...is here, fighting <target>.`. So the same mob reads as `A Peacekeeper is standing here, ready to jump in...` (idle, default pos) one moment and `The Peacekeeper is here, fighting a thief.` the next. The parser must treat the trailing lines as **variable-phrasing entity lines**, not a single template.

---

## 3. The async-capture gap (the real bug to fix)

When we sit in a room and a mob leaves/arrives, the server pushes a single unsolicited line (e.g. `The cityguard leaves north.`) with **no prompt**. The reader thread captures it into `@buffer` correctly. The `poll` tool (`drain`) retrieves it.

**But `run_command` calls `s.drain` *before* sending its command** (`session_pool.rb:66`) to clear stale output. Any async line that arrived while we were idle is **thrown away** the moment we issue the next structured command — unless we `poll` first. So today the agent only reliably sees async events if it explicitly polls between actions.

Options, in order of preference:

1. **Have `run_command` return the pre-send drained text alongside the response** instead of discarding it — the dispatcher prepends it as an `== events ==` section. Cheapest, no protocol change.
2. **Fold a `poll` into `inspect`** so a room survey always reports "what changed while you were away" plus the current room. Fits the inspect-as-composite model.
3. Leave `run_command` as-is and make the agent loop poll on a cadence — pushes the burden onto the prompt, least reliable.

Recommendation: **(1) + (2)** — never silently discard buffered async text, and make `inspect` = `poll` → `look` → `exits`.

---

## 4. Parsing a room into JSON — deterministic core + model for the fuzzy layer

Two failure modes to avoid:

- If a **DB-identity field** (room name, an exit destination) is ever hallucinated, it corrupts the room graph — bad key, wrong adjacency, duplicate/merged rooms. These must be **exact**.
- The **fuzzy layer** (which trailing lines are mobs vs objects, what keywords in the prose are interactable) is inherently ambiguous and is where a model earns its keep.

So: **regex for the exact fields, model for the fuzzy fields**, and let the model emit the combined structured JSON.

### 4a. Deterministic core (regex, in the Mud Manager — never a model)

```
name          = first non-blank line after stripping ANSI
autoexits     = /\[ Exits: ([^\]]*) \]/            → split on whitespace
exit_targets  = "Obvious exits:" block             → { "north" => "By The Temple Altar", ... }
vitals        = /(\d+)H (\d+)M (\d+)V/  (prompt)    → { hp, mana, move }
description   = lines between name and the autoexit line
```

`name` + `exit_targets` (+ optional description hash) form the room identity key for upsert. These are cheap, instant, and must stay deterministic.

### 4b. Fuzzy layer (a model)

Two things the model does that regex can't do robustly:

1. **Entity lines → structured records.** Classify each trailing green line as `mob` / `object` / `feature`, and extract a **targetable keyword** ("A Peacekeeper is standing here…" → `peacekeeper`). The long description never states the keyword directly.
2. **Candidate interactables from prose.** Read the description and surface nouns worth probing with `look <keyword>` — `statue`, `altar`, `paintings`, `fountain`. These are tbaMUD extra-descriptions the server never enumerates; the agent then confirms them by trying `look fountain`.

Both are naturally expressed as **structured JSON output** against a fixed schema, e.g.:

```json
{
  "mobs":    [{ "keyword": "peacekeeper", "desc": "A Peacekeeper is standing here..." }],
  "objects": [{ "keyword": "teller",      "desc": "An automatic teller machine..." }],
  "look_candidates": ["statue"]
}
```

### 4c. Do we need a model, and which one?

- **A pure-regex path exists** (grab capitalised/salient nouns, classify by phrase patterns) and is fine for common newbie-zone mobs, but it's brittle on the prose-noun extraction and on unusual phrasings.
- **A model is the better tool for 4b specifically** — classification + noun extraction + schema-constrained JSON is squarely what a small instruct model is good at.

**Decision: Haiku 4.5 now.** Do the parse with a managed model first — it's the fastest path to a working `room_inspector`, and quality is high enough that we're not fighting the extractor while building everything downstream (identity keys, DB upsert, the player loop). There's no cheaper *Claude* model (Haiku 4.5 is the floor, $1/$5 per 1M, 200K ctx), but the cost per room is small and bounded by caching.

**Ollama is a later optimization, not the first build.** Once the schema and prompt are stable, a local small instruct model (Qwen2.5-3B / Llama-3.2-3B) with Ollama's `format`=JSON-schema (grammar-constrained decoding → always-valid JSON) can replace Haiku for ~zero marginal cost. Because the `room_inspector` task's provider/model live in `settings.yaml` (see §5), this is a config swap, not a rewrite — build the interface so it stays swappable.

| Option | Cost | When |
|---|---|---|
| **Haiku 4.5** (managed) — structured outputs / strict tool use | $1/$5 per 1M | **now** |
| Ollama local, 3B (Qwen2.5-3B, Llama-3.2-3B) — `format`=schema | ~free marginal | later, once schema stabilises |
| Regex/heuristic pre-pass | free, instant | optional guard on identity fields (see below) |

**Cache aggressively.** A room's fixed entities and `look_candidates` don't change between visits — key the model result on the room identity and only re-run when the *entity set* changes (mobs come and go, but their keyword/classification is stable once learned). Vitals and async events are cheap/volatile — don't cache them.

### 4d. Guarding the identity fields

`room_inspector` produces the whole JSON, but `name` and `exit_targets` become DB keys, so a hallucination there corrupts the room graph. Cheap insurance: run the deterministic regexes from §4a as a **validation pass** and reconcile — if the model's `name`/`exit_targets` disagree with what regex pulled straight from the raw text, trust the regex (or flag the mismatch). This keeps the model's flexibility for the fuzzy fields while making the identity fields effectively deterministic. Optional for v1; cheap enough to add early.

---

## 4.5 Appraising entities — the `examine` + `consider` loop

Parsing the room text (§4) gets us *candidate* mobs with a *guessed* keyword and no idea how dangerous they are. `look` structurally cannot tell us more: it prints the long description but never the mob's command keyword, level, health, or gear. To turn a candidate into an actionable record we have to *interrogate* each one. This is a second pass, run after `room_inspector` returns, iterating over `mobs[]`.

### What the two commands actually give us (tbaMUD source, verified)

From `src/act.informative.c`:

- **`consider <keyword>` → `do_consider`.** Computes `diff = GET_LEVEL(victim) - GET_LEVEL(ch)` and prints one qualitative line from a cascading table. It is our **only** window on relative level:

  | `diff` (victim − you) | message |
  |---|---|
  | ≤ −10 | `Now where did that chicken go?` |
  | ≤ −5  | `You could do it with a needle!` |
  | ≤ −2  | `Easy.` |
  | ≤ −1  | `Fairly easy.` |
  | 0     | `The perfect match!` |
  | ≤ 1   | `You would need some luck!` |
  | ≤ 2   | `You would need a lot of luck!` |
  | ≤ 3   | `You would need a lot of luck and great equipment!` |
  | ≤ 5   | `Do you feel lucky, punk?` |
  | ≤ 10  | `Are you mad!?` |
  | ≤ 100 | `You ARE mad!` |

  Note this is a **delta bucket**, not an absolute level, and it is relative to *our current level* — so a stored `threat` reading is only valid at the level it was taken (record the level alongside it, per the player-strategy note in `prompts/player/system.md`).

- **`examine <keyword>` → `do_examine` → `look_at_target` → `look_at_char`.** For a character this shows its description, a **health diagnosis** (the `diagnose`-style condition line), and **visible equipment**; for an object it shows extra-descriptions and, for containers/fountains/drinkcons, the contents. No level. This is where per-mob health and gear come from.

- **Keyword resolution is free validation.** Both commands answer `They aren't here.` when the target doesn't resolve. Because `room_inspector`'s keyword is a *guess* pulled from prose (§4b), that failure is the signal to **drop the candidate or re-guess** — which is exactly "determine their inclusion."

### The loop

```
room_inspector.mobs[]  →  for each mob m:
      consider(m.keyword)                     # relative-difficulty line
        ├─ "They aren't here."  → keyword wrong → re-guess once, else DROP m
        └─ difficulty line      → m.threat = { message, level_taken_at }
      examine(m.keyword)                       # description + health + equipment
        └─ m.health, m.equipment, m.desc_full
   →  keep m
```

Design constraints this introduces:

- **Cost.** Each kept mob adds **two** MUD round-trips. A 3-mob room is 6 extra calls on top of `inspect` — this erodes the "one call" win, so appraise **only `mobs[]`** (objects and `look_candidates` have no level and are appraised lazily via `look <keyword>` only if the goal needs them), and make the loop **skippable** when the player's goal isn't combat-adjacent.
- **Where it runs.** It belongs in the **`inspect_room` player-side pipeline (Step 4)**, *after* `room_inspector` yields keywords — the MCP daemon can't run it blind because it doesn't know the keywords until the parse happens. Options: (a) the pipeline loops `tbamud__consider`/`tbamud__examine` per mob and merges results deterministically into the record, or (b) a second daemon composite `appraise(keywords[])` that batches the round-trips and returns labelled blocks for `room_inspector` (or a deterministic merge) to fold in. Prefer (a) first; promote to (b) if per-call latency hurts.
- **Caching.** A mob's keyword, base description, and equipment are stable across visits; its **health and `threat`-vs-our-level are volatile**. Cache the former on the room-identity key (§4d), re-take the latter each encounter.

### Schema additions

`room_inspector`'s `mobs[]` records gain appraisal fields, populated by the loop (not by the parser):

```json
{
  "keyword": "peacekeeper",
  "desc": "A Peacekeeper is standing here...",
  "resolved": true,
  "threat": { "message": "Are you mad!?", "level_taken_at": 3 },
  "health": "in excellent condition",
  "equipment": ["a long sword", "a suit of chain mail"]
}
```

`resolved: false` records are dropped (or flagged) before the room is returned to the player.

---

## 5. Execution architecture — `inspect_room` + the `room_inspector` subagent

boukensha defines **tasks** (subagents) as `Boukensha::Tasks::*` classes plus a matching block under `tasks:` in `settings.yaml`. Today there is one task, `player` (`boukensha/lib/boukensha/tasks/player.rb`, model `claude-haiku-4-5`). We add a second.

**New task: `room_inspector`.**

- `boukensha/lib/boukensha/tasks/room_inspector.rb` — a `Boukensha::Tasks::Base` subclass with `task_name = "room_inspector"`.
- `settings.yaml` gains a sibling of `player`:
  ```yaml
  tasks:
    player:
      provider: anthropic
      model: claude-haiku-4-5
      prompt_override:
        system: true
    room_inspector:
      provider: anthropic
      model: claude-haiku-4-5      # swap to ollama later, config-only
      prompt_override:
        system: true
  ```
- Its system prompt (`prompts/room_inspector/system.md`) instructs it to emit **only** the structured JSON for our schema: `{ name, description, exit_targets, hp, mana, move, mobs[], objects[], look_candidates[], events[] }`. No prose, no chatter — this subagent's entire job is text → JSON. The `mobs[]` records it emits carry only what the room text supports (`keyword` guess + `desc`); the appraisal loop (§4.5) fills in `resolved`, `threat`, `health`, and `equipment` afterward.

**Flow (as built).** The player's `inspect_room` tool does **not** gather or pass any data. It simply triggers the `room_inspector` subagent, which drives the shared MUD session itself:

```
player calls  inspect_room                 (native tool; no arguments, no data)
      │
      └─ Boukensha.run_task(RoomInspector, "Inspect the current room…")
             │
             │  room_inspector — an AGENTIC subagent on the SHARED session,
             │  scoped to tools { poll, look, check, consider, examine } (§5.5):
             │
             ├─ 1. poll  → look  → check(kind:"exits")   (assembles the survey)
             ├─ 2. per mob: consider → threat (relative difficulty)
             │              examine  → health + equipment            [§4.5]
             └─ 3. emit structured JSON (our schema)
      │
      └─ tidy (strip stray ``` fence) → return JSON to the player
```

The split is: **the subagent owns all MUD I/O, composition, and parsing; the player owns nothing but the trigger.** The player never sees or parses raw MUD text, which keeps its context small (the token-cost win from `perception/technical_challenges.md`) and isolates every fragile step — surveying, keyword-guessing, appraisal, JSON shaping — inside one cheap, swappable subagent.

This replaces two earlier drafts: one where the player-side tool fetched the survey and handed raw text in, and one where the *daemon* pre-assembled a `poll→look→exits` composite (`tbamud__inspect_room`). Both are gone. **The composite now lives in the agent, not the daemon** — room_inspector calls the primitives itself. The daemon exposes only flat primitives, so "what a survey is" is a boukensha policy, not baked into the MUD manager (see §1).

---

## 5.5 Shared MCP sessions + per-task tool visibility

The first cut of `run_task` (§5) gave the `room_inspector` subagent **no** MCP servers, reasoning that a second server spawn = a second `mud-manager` daemon = a second telnet login as the same character (which the MUD rejects). That reasoning is right about the *symptom* but wrong about the *fix*: the answer is not "no MCP for subagents," it is **share the one session**. This section supersedes that decision.

### Why a subagent doesn't need its own session — share the client

An MCP "session" here is a spawned `mud-manager` subprocess wrapped by a `Boukensha::Mcp::Client`, and that client already holds the one live telnet login. The seam to reuse it exists today: `Tools::Mcp.register` *spawns* a client, but `Tools::Mcp.register_client(registry, client, prefix:)` registers an **already-spawned** client's tools into *any* registry. So:

- **Spawn each server once** at process start (as `register_mcp_servers` does now), and **keep the client handles**.
- When building **any** task's registry — the player's *or* a subagent's via `run_task` — call `register_client` with those same handles instead of spawning again.
- Same client → same subprocess → same daemon → **same session**. No second login.

**Concurrency is a non-issue here because access is serial.** `run_task` is called *synchronously from inside the player's tool dispatch* — the player is blocked while the subagent runs, so parent and child never drive the shared client at the same time. (If we ever run subagents truly concurrently, the daemon's single `"default"` session would need per-task session ids — out of scope now, worth a note.)

### Per-task permissions in `settings.yaml` — a pure allowlist

Sharing the clients means every task *could* see every tool — which we don't want. Each task declares an `allow:` block: a **pure allowlist, default-deny**. A task may call a tool only if a rule names it, and may pass an argument value only if the rule permits it. No `deny`, no wildcard, no implicit "everything else."

```yaml
tasks:
  room_inspector:
    allow:
      - poll
      - look
      - check(kind: exits)     # check pinned to one kind
      - consider               # free-string target left open
      - examine
  player:
    allow:
      - move
      - attack
      - consider
      - check(kind: score|inventory|equipment|gold|time|weather|levels|wimpy|toggle|where)
      # …every tool the player may use (no `look`; check pinned to non-exits kinds)…
```

**Rule grammar** (one string per rule):

```ebnf
Rule    ::= Tool [ "(" Arg { "," Arg } ")" ]
Arg     ::= Param ":" Pattern
Pattern ::= "*" | Value { "|" Value }        ; "*" = any value; "|" = alternation
```

Tool names are bare (`check`) or prefixed (`tbamud__check`); a bare name matches regardless of the MCP prefix. A parameter you don't name is unconstrained.

**The grammar per tool is the tool's own schema.** Each tool already publishes its parameter schema (the `enum` written next to it in `tool_spec.rb`, delivered over MCP as `inputSchema`). A rule is validated against *that*, at startup:

- unknown tool → `references unknown tool 'flyaway'`
- unknown parameter → `'check' has no parameter 'knd'`
- non-constrainable parameter (no enum) → `parameter 'target' of 'consider' is not constrainable`
- value outside the enum → `teleport is not a valid kind (one of: score, inventory, …, exits)`

So a typo or an illegal value fails loudly at boot, not silently at runtime — the thing a stringly-typed matcher couldn't give us. Only enum params are constrainable by default (the case we can validate); a free-string/numeric param would have to opt in explicitly, which nothing needs yet.

**Enforcement is two-point** (`Tools::Mcp.register_client`), which is what makes it real rather than advisory:

1. **Name level** — a tool no rule names is never registered, so it is neither advertised to the model nor dispatchable by that task.
2. **Value level** — a registered tool's enum params are narrowed in the *advertised* schema to the permitted values (`to_boukensha_params(..., permissions:, tool_name:)`), so the model isn't offered a blocked value; and a **dispatch guard** rejects any call the rules don't permit (`call_permitted?`) *before* it reaches the server — necessary because boukensha carries the enum only in the param description, not as an API-enforced constraint.

Validated against the real daemon: room_inspector's `check` advertises only `exits`, refuses `kind:score`, passes `kind:exits` to the MUD; the player has no `look` and its `check` advertises only the non-`exits` kinds. A `check(kind: teleport)` rule and a `flyaway` rule each abort boot with the messages above.

The parsed shape lives in `Boukensha::Permissions` (`allow_tool?`, `allowed_values`, `call_permitted?`, `validate_tool!`, `validate_referenced!`), built from the `allow:` block by `task_permissions`.

> Note: the **native `inspect_room`** tool is registered by the entrypoint block, not by `register_client` — but it **is** gated by `allow:`, through the same `Registry#tool`/`#dispatch` enforcement every MCP tool goes through (see `docs/plans/week_2/native_tool_permissions.md`). It's just written as a bare rule (`inspect_room`), since native tools have no server `prefix:` to disambiguate.

### The appraisal loop (§4.5) lives inside room_inspector

Because the shared session lets `room_inspector` hold `include: [tbamud__inspect_room, tbamud__consider, tbamud__examine]` and drive them itself, the per-mob appraisal loop lives **inside the subagent** (its system prompt walks survey → per-mob consider/examine → JSON), not in a player-side orchestration. Extraction and appraisal are fused in the one agent that already has the room in hand.

---

## 6. Recommended next steps

1. ~~**Expand the `inspect` MCP composite** to `poll` → `look` → `exits`.~~ **Reversed.** The daemon composite was built, then removed: the survey is now composed *agent-side* by room_inspector (poll → look → check(exits)), and the MUD manager exposes only flat primitives. The reasoning in §1 that favoured a daemon composite no longer holds — composition is a boukensha policy. (`exits` is still load-bearing; the agent gets it via `check(kind:"exits")`.)
2. **Stop discarding pre-send buffered text** in `run_command` (`session_pool.rb:66`) — surface it as an events section so async mob movement isn't lost.
3. **Add the `room_inspector` task**: `Tasks::RoomInspector` class, `settings.yaml` block (Haiku 4.5), and `prompts/room_inspector/system.md` with the schema and "JSON only" instruction.
4. **Add the player `inspect_room` function** that calls `tbamud__inspect`, forwards the raw text to `room_inspector`, and returns the structured JSON.
5. **Add the appraisal loop (§4.5)** — implemented *inside the agentic `room_inspector`* (not a player-side orchestration): its prompt has it `consider` + `examine` each mob, drop keywords that don't resolve, and attach `threat`/`health`/`equipment`. Future tuning: gate the per-mob cost behind a "combat-adjacent" hint so a fly-through room doesn't pay 2 round-trips per mob.
6. **Share MCP clients across tasks + per-task permissions (§5.5).** Spawn each server once and keep the handles; register them into each task's registry via `Tools::Mcp.register_client` (no re-spawn, one session). Give each task an `allow:` block — a **pure allowlist, default-deny**, matcher grammar `tool(param: a|b)` — parsed into `Boukensha::Permissions`, validated at boot against each tool's own enum schema, enforced by advertised-enum narrowing + a dispatch guard.
7. **Add the §4a regex validation pass** for `name`/`exit_targets` and reconcile against the model output (optional for v1).
8. **Build the room-identity key** (`name` + sorted `exit_targets`) and upsert adjacency into the rooms DB; cache stable mob fields (keyword, desc, equipment) on that key, re-take volatile ones (`threat`, `health`) per visit.
9. **Later:** swap `room_inspector`'s model to a local Ollama 3B once the schema/prompt are stable — config-only change in `settings.yaml`.

---

## Implementation status (as of this pass)

- **Done & tested:**
  - §6.1 (`inspect` = poll → look → exits, labelled sections) and §3 async-event capture via the leading `poll`.
  - §6.3 (`room_inspector` task class + `settings.yaml` block + `prompts/room_inspector/system.md`).
  - **§6.4 the player `inspect_room` tool + task→task invocation.** `Boukensha.run_task(task_class, input)` runs a subagent from the task's own settings (provider/model/prompt/`max_iterations`). The native `inspect_room` tool is registered at the entrypoint (`boukensha_loader.rb`); its thin orchestration is `Boukensha::Tools::InspectRoom` (injected `run:`, unit-tested with a fake). The player passes **no data** — it only triggers the subagent.
  - **§6.6 shared MCP sessions + per-task permissions.** MCP clients are spawned **once** and memoized (`mcp_clients`); every task registers *those same clients* into its registry via `register_client(..., permissions:)`, scoped by a `Boukensha::Permissions` built from the task's `allow:` block (`task_permissions`). It is a **pure allowlist, default-deny**, with a matcher grammar `tool(param: a|b)` (pipe alternation, `*` = any). Each rule is **validated at boot against the tool's own enum schema** (`validate_tool!` / `validate_referenced!`): unknown tool/param, non-constrainable param, or illegal enum value aborts startup. Enforcement is two-point — advertised enum narrowed (`to_boukensha_params`) + dispatch guard (`call_permitted?`). Replaced the earlier `ToolFilter` (include/exclude/restrict), now deleted. Validated against the real daemon: room_inspector's `check` narrowed to `exits` (refuses `score`, passes `exits`); player has no `look`, `check` narrowed to non-`exits`; bad rules (`check(kind: teleport)`, `flyaway`) fail loudly at boot.
  - **room_inspector is now agentic and composes the survey from primitives** — it calls `poll` → `look` → `check(kind:"exits")`, then `consider`/`examine` per mob, then emits JSON (system prompt rewritten). This folds the **§4.5 appraisal loop** into the subagent.
  - **The daemon `inspect_room` composite was removed** (`dispatcher.rb` `:inspect` mode + `tool_spec.rb` entry, and its test). The MUD manager now exposes only flat primitives (`poll`, `look`, `check`, …); the survey composite lives agent-side. This reverses plan step §6.1 — expanding a daemon composite — in favour of composing in boukensha. Daemon tool count 27 → 26; validated with FakeMud that `tbamud__inspect_room` is no longer advertised and calling it errors.
  - boukensha suite green (incl. new filter tests). Two pre-existing config tests that would exercise the real spawn stay *skipped* here due to an off-by-one in the test helper's `MUD_MANAGER_ROOT` path (unrelated to this work); the refactored path was validated by a direct FakeMud integration check instead. The one path needing a live API key is the actual room_inspector agent run.
- **Not yet built:** §6.7 regex validation of `name`/`exit_targets` (bolt onto room_inspector's output or `InspectRoom`), §6.8 rooms DB, §6.9 Ollama swap (now genuinely config-only).