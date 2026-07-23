## Scripted Room Survey

`inspect_room` takes ~34 seconds and ~10 LLM calls per room. It should take
~7 seconds and zero. This plan replaces the `room_inspector` ReAct loop with a
deterministic Ruby survey script, restoring the design the code's own comments
already describe.

---

## TL;DR

- **The subagent drives its own tool loop today, and every turn of that loop is
  a full LLM round trip.** `room_inspector` decides *which* MUD tool to call
  next by asking Haiku — three inferences to issue five trivially-ordered
  commands.
- **Measured: 18.6s of a 33.8s `inspect_room` call is LLM latency** (55%),
  against 6.4s of actual MUD I/O (19%). The rest is subagent spin-up and
  per-log-event overhead.
- **Cost: 3 rooms consumed 10 LLM calls and $0.0363 — 47% of that session's
  total spend.** The player's own 9 turns of actual gameplay cost $0.0417.
- **Fix: the script picks the commands, not the model.** poll → look →
  check(exits) → consider/examine per *distinct* mob is a fixed sequence with
  one data-dependent step (which mobs). Ruby can do all of it.
- **The parse is deterministic too.** tbaMUD colors ground objects green
  (`CCGRN`) and mobs yellow (`CCYEL`) — verified in `act.informative.c`, and
  present in our telnet logs. Everything else in the schema is a regex.
- **This restores intent, it doesn't invent it.**
  `tasks/room_inspector.rb:5-11` already says its job is "turn the raw text of
  an `inspect` survey (events + look + exits) into the structured room JSON."
  The implementation drifted; the comment didn't.
- **Projected: 33.8s → ~10.6s, and → ~6.5s if the logging overhead below is
  also fixed.** Zero LLM calls in the warm path.
- **One decision for you** (§7): keep a single parse-only LLM call as you
  originally envisioned, or go fully deterministic. I recommend fully
  deterministic — see §7 for why the parse-only call earns less than it costs.

---

## 1. The problem, measured

From `.boukensha/sessions/20260722T231230Z-e16fba10.jsonl`, the third
`inspect_room` call (The Common Square, 3 fidos) — log lines 89 → 114:

| # | Δ | Event |
|---|---|---|
| 89 | — | `tool_call inspect_room` (player, depth 0) |
| 90 | **+2.08s** | `task_start room_inspector` — subagent spin-up |
| 93 | **+5.76s** | `plan` ← **LLM call 1**: decide to poll/look/check |
| 96 | +1.32s | `tool_result poll` ← MUD |
| 98 | +1.28s | `tool_result look` ← MUD |
| 100 | +1.23s | `tool_result check(exits)` ← MUD |
| 103 | **+5.64s** | `plan` ← **LLM call 2**: decide to consider/examine |
| 106 | +1.22s | `tool_result consider` ← MUD |
| 108 | +1.31s | `tool_result examine` ← MUD |
| 111 | **+7.22s** | `response` ← **LLM call 3**: compose the JSON |
| 114 | +0.42s | `tool_result inspect_room` returns to player |

**Total 33.83s**, accounted for as:

| Bucket | Time | Share |
|---|---|---|
| LLM inference (3 calls) | 18.62s | 55% |
| MUD round trips (5 calls) | 6.36s | 19% |
| Per-log-event gaps (16 × ~0.42s) | ~6.72s | 20% |
| Subagent spin-up (`task_start`) | 2.08s | 6% |

Two observations that matter more than the totals:

**The LLM is not doing anything hard.** Call 1 decides to run the exact three
commands its system prompt names in order (`prompts/room_inspector/system.md:22`
— "Call `tbamud__poll`, then `tbamud__look`, then `tbamud__check`"). Call 2
decides to consider/examine, also verbatim from the prompt. Only call 3 does
work a computer couldn't trivially do — and §3 argues a computer can.

**It is not "one consider per mob."** The room had three identical fidos; the
log shows exactly **one** `consider` and **one** `examine`, whose result the
model copied into all three mob entries. So the cost is not N-per-mob — it's
the fixed 3-inference loop overhead, paid on *every* room regardless of
contents. A deduplicating script gets the same coverage for the same 5 MUD
calls.

### 1.1 Cost

Same session, by task:

| Task | LLM calls | Cost |
|---|---|---|
| `player` (9 gameplay turns) | 9 | $0.0417 |
| `room_inspector` (**3 rooms**) | **10** | **$0.0363** |

Looking at three rooms cost nearly as much as playing the game.

---

## 2. Where the composition belongs

`mud_manager`'s dispatcher makes an explicit, correct decision we are not
touching (`mcp/dispatcher.rb:53-58`):

> The room survey composite (poll → look → exits) is deliberately NOT a daemon
> tool. The daemon exposes only primitives; the composite is assembled
> agent-side […] Keeping composition out of the daemon means every consumer
> sees the same flat primitive surface and no policy about "what a survey is"
> lives here.

This plan keeps that true. The composite stays agent-side — it just stops being
*LLM-driven* agent-side and becomes *script-driven* agent-side. The daemon
surface does not change; no new `mud-manager` tool is added.

`Tools::InspectRoom` is already the right home. Its own header
(`tools/inspect_room.rb:3-9`) describes itself as "the player-facing
`inspect_room` tool's orchestration, kept separate from the run/repl wiring so
it can be unit-tested with a fake runner." It just needs a different injected
dependency: a way to call MUD tools, instead of a way to run a subagent.

### 2.1 The seam

Today the entrypoint injects a subagent runner (`boukensha_loader.rb:132-136`):

```ruby
Boukensha::Tools::InspectRoom.call(
  run: ->(instruction) {
    Boukensha.run_task(Boukensha::Tasks::RoomInspector, instruction, logger: parent)
  }
)
```

It will instead inject a permission-scoped tool dispatcher:

```ruby
Boukensha::Tools::InspectRoom.call(
  call_tool: Boukensha.task_dispatcher(Boukensha::Tasks::RoomInspector, logger: parent)
)
```

`Boukensha.task_dispatcher(task_class, logger:)` is a new public class method,
returning a `->(name, args) { text }` lambda. It reuses the machinery
`run_task` already assembles (`boukensha.rb:219-223`) — the same shared MCP
clients (`mcp_clients`), the same `task_permissions(cfg, task_name)` scoping,
the same `Registry`. **The survey therefore still runs under
`room_inspector`'s `allow:` block** (`settings.yaml:63-67`): poll, look,
check(kind: exits), consider, examine, and nothing else. Removing the LLM does
not widen the tool surface, and the allowlist keeps enforcing rather than
becoming decoration.

This matters because `look` is deliberately absent from the *player's*
allowlist (`settings.yaml:16-18`), so the survey cannot simply borrow the
player's registry.

### 2.2 Logging is a requirement, not a nicety

`mud_monitor` reads the session log, and its session view expects the survey's
MUD calls to appear as `tool_call`/`tool_result` events at depth 1 under task
`room_inspector`. A script calling the MCP client directly would make them
vanish from that view (they'd survive only in the manager and telnet logs).

So `task_dispatcher` wraps each call in `logger.tool_call` / `logger.tool_result`
and the whole survey in `logger.task("room_inspector")`, exactly as `run_task`
does today (`boukensha.rb:251`). The observable shape of a survey in
`mud_monitor` stays recognizable — same task label, same depth, same tool
names — it just loses the `prompt`/`plan`/`response` events in between. That is
the visible diff, and it's the point.

---

## 3. The survey script

### 3.1 Sequence

```
1. poll                      → events
2. look                      → name, description, entity lines, prompt stats
3. check(kind: "exits")      → exit_targets
4. classify + dedupe entity lines
5. for each DISTINCT mob:  consider <kw>  → threat
                           examine  <kw>  → health, equipment
```

Steps 1-3 are unconditional and fixed. Step 5 is the only data-dependent part,
and dedupe means three fidos cost one pair of calls, not three.

### 3.2 Parsing rules

Every field in the existing schema (`prompts/room_inspector/system.md:42-88`)
is mechanically derivable. Nothing about the schema changes — the player's
contract is untouched.

| Field | Rule |
|---|---|
| `name` | First non-blank line of `look`. |
| `description` | Prose between the name and the `[ Exits: ` line, whitespace-collapsed. |
| `hp`/`mana`/`move` | `/(\d+)H (\d+)M (\d+)V/` on the prompt line; `null` if absent. |
| `exit_targets` | The "Obvious exits:" block of `check(exits)`, `direction - Destination`. |
| `mobs` / `objects` | Entity lines after `[ Exits: ]` — split by color, see §3.3. |
| `events` | Non-blank lines from `poll`, verbatim. |
| `look_candidates` | The one genuinely fuzzy field — see §7.1. |

### 3.3 Mob vs. object: verified, not assumed

tbaMUD colors the two lists differently. From `src/act.informative.c`:

- `list_obj_to_char()` wraps ground objects in `CCGRN(ch, C_NRM)` → `\e[0;32m`
- `list_char_to_char()` wraps mobs in `CCYEL(ch, C_NRM)` → `\e[0;33m`
- `look_at_room()` also wraps the **room name** in `CCYEL` — same code as mobs,
  but it is the first line, so position disambiguates it.

Confirmed against our own capture (`.boukensha/telnet/20260722.jsonl`):

```
32 | A large fountain carved from blue-streaked marble is here…
32 | An automatic teller machine has been installed in the wall here.
33 | A Peacekeeper is standing here, ready to jump in…
33 | A beastly fido is mucking through the garbage…
33 | A cityguard stands here.
33 | The Common Square              ← room name, first line
```

**Caveat with a required mitigation:** color emission is gated by
`COLOR_LEV(ch)` / `PRF_COLOR_1|2` — i.e. the character's own `color` toggle. It
is on for our bot today, which is why the codes are in the log. The script must
not silently depend on that:

- At session start, assert color is enabled (via `check(kind: "toggle")`, which
  is in the player's allowlist) and set it if not.
- If a `look` comes back with no color codes at all, fall back to a positional
  heuristic and log a warning — never guess silently.

### 3.4 Picking the target keyword

`consider`/`examine` need the keyword the mob answers to, which comes from the
mob's namelist, not its long description — so this is a heuristic with a
verification step, not a pure parse.

1. **Cache first.** Keep a session-lifetime `desc line → keyword` map. Fidos,
   cityguards and Peacekeepers recur constantly; after the first room, most
   lookups are free.
2. **Guess:** take the words before the line's first verb, drop articles and
   adjectival stopwords, try the last one. ("A beastly fido is mucking…" →
   `fido`; "A cityguard stands here." → `cityguard`.)
3. **Verify:** `consider` answering `"They aren't here."` means the guess was
   wrong. Retry with the next candidate right-to-left. Each miss costs one MUD
   round trip (~1.2s), once per distinct description for the whole session.
4. **Give up after 2 misses** and emit the mob with `threat: null` rather than
   burning turns — same failure posture the current prompt specifies
   (`system.md:30-33`).

---

## 4. Projected result

Warm cache, a room like The Common Square:

| Bucket | Now | After |
|---|---|---|
| LLM inference | 18.62s | **0** |
| MUD round trips | 6.36s | 6.36s |
| Log-event gaps | ~6.72s | ~4.2s (10 events, not 16) |
| Subagent spin-up | 2.08s | ~0 |
| **Total** | **33.8s** | **~10.6s** |

And ~$0.0121/room → **$0**.

With §6's logging overhead also fixed: **~6.5s**, i.e. the MUD's own latency
and essentially nothing else. That is the floor, and it's the right floor —
five telnet round trips is what surveying a room actually costs.

---

## 5. What happens to the `room_inspector` task

Depends on §7's decision.

- **Fully deterministic:** the `room_inspector` *task* (provider, model,
  `max_iterations: 12`, system prompt) is deleted from `settings.yaml`, along
  with `tasks/room_inspector.rb` and `prompts/room_inspector/system.md`. The
  `allow:` block moves into the new dispatcher's scoping (§2.1) so permissions
  survive. This loses the "swap to a local Ollama 3B, config-only" story that
  `tasks/room_inspector.rb:8-11` advertises — but that story existed to make a
  cheap model do a job that turns out to need no model.
- **Parse-only LLM retained:** everything stays, but `allow:` becomes empty
  (it calls no tools), `max_iterations` drops to 1, and the system prompt is
  rewritten from "here is a procedure, go drive it" to "here is raw text,
  return JSON" — which is what its own class comment already claims it does.

---

## 6. Adjacent finding: ~0.42s per logged event

> **CORRECTION (see `look_candidates_runtime.md` §12.6).** This section blames
> the logger. Measured since: `Logger#write_log` costs **0.003 ms/event**, the
> MCP round trip **0.2 ms**, the MUD **62 ms**. The ~0.42 s floor is real and
> appears between *every* pair of events — including ones that do no work — but
> it is not the log write. Current suspect is GVL contention with the TUI's
> 60 ms render tick. Verify with a `--no-tui` run before changing anything.


Sixteen of the 33.8s are inter-phase gaps averaging **420ms**, appearing
between events with no work between them at all — e.g. `turn_end` → `task_end`
→ `tool_result` (log lines 112→113→114) is 900ms of pure bookkeeping.

`Logger#write_log` (`logger.rb:129-140`) does a `puts` + `flush` + fan-out to
`@subscribers`, none of which should cost 420ms. The TUI subscribes at
`tui.rb:82` and ticks at 60ms (`TICK_MS = 60`), so the frame rate doesn't
explain it either. **I could not identify the cause from reading; this needs
instrumentation, not a guess.**

Worth doing as a separate task, because it is not an `inspect_room` problem —
it is a tax on *every* logged event in every agent turn. At ~20% of wall-clock
it is larger than all MUD I/O combined.

---

## 7. Decision for review

**Recommendation: go fully deterministic (zero LLM calls).**

Your original framing was "the subagent only does the parsing, and commands like
consider/examine get done by a script." The wrinkle is that the script cannot
call `consider` without first knowing *which mobs are in the room and what to
call them* — so by the time the script can issue those commands at all, it has
already done the classification and keyword extraction that constitute the
parse. The remaining LLM call would spend ~6.5s and ~$0.004/room reformatting
text the script already understands into JSON the script could emit directly.

The honest counterargument is §7.1.

### 7.1 The one field that wants a model

`look_candidates` — "lowercase nouns from the description prose worth probing
with `look`" (`system.md:84-86`), i.e. tbaMUD extra-descriptions like statues
and fountains that the server never lists. That is genuine judgement, and a
noun-extraction heuristic will be visibly worse at it.

Three ways out, in my order of preference:

1. **Heuristic and accept the quality drop.** Extract capitalized/concrete
   nouns from the description minus known mobs/objects. Cheap, and the field is
   advisory — a missed statue costs the player one unexplored `look`.
2. **Make the LLM enrichment opt-in per settings.** Script does everything;
   if `room_inspector` is configured, one extra call fills `look_candidates`
   only. Costs the 6.5s only when you want it.
3. **Drop the field.** It is not currently load-bearing for navigation, which
   is what the player actually uses `inspect_room` for.

If you'd rather keep a parse-only LLM call for the whole schema anyway — your
original design — the projected total is **~17s** instead of ~10.6s, still a 2×
win, and §5's "retain" branch applies.

---

## 8. Work items

1. `Boukensha.task_dispatcher(task_class, logger:)` — permission-scoped,
   logging, shares `mcp_clients`. Extract the common setup it shares with
   `run_task` (`boukensha.rb:208-254`) rather than duplicating it.
2. `Tools::InspectRoom` — replace `run:` with `call_tool:`; implement the §3.1
   sequence. Keep it injectable so the existing fake-runner test style still
   works.
3. `Tools::RoomParser` (new) — pure text → Hash, no I/O. This is where the
   §3.2/§3.3 rules live and where the test weight should sit: feed it captured
   `look`/`exits`/`consider` text, assert the schema.
4. Color assertion at session start (§3.3) + no-color fallback path.
5. Keyword cache + verify/retry (§3.4).
6. `boukensha_loader.rb:119-137` — rewire the entrypoint block; update the
   comment, which currently documents the LLM-driven design.
7. `settings.yaml` — per §5.
8. Regression check: confirm a survey still renders correctly on `mud_monitor`'s
   session page (§2.2).
9. **Separate task:** instrument the 420ms logging gap (§6).

### 8.1 Test corpus

`.boukensha/telnet/20260722.jsonl` and the session logs already contain real
captured `look`, `exits`, `consider`, and `examine` output for the Temple of
Midgaard, Temple Square, Market Square, The Common Square and Poor Alley —
including the multi-identical-mob case and an object-plus-mob room. Build the
parser tests from these rather than from hand-written fixtures.

## Developer Notes
You didn't follow my intention implementation which was to use the llm to do two things:
- extract candidates out of the description text for examine
- and parse the json

We need to know what the cost of that is to run in haiku 4.5

> Extract capitalized/concrete nouns from the description minus known mobs/objects.
If its a regex that would be terrible, what are our options from regex, inbetween an LLM.
It seems like there would be an NLP solution.

We might be able to produce json by just parsing structure within using an LLM.

## New Proposal

Your design — script drives the tools, LLM does (a) candidate extraction and
(b) the JSON — is the right shape. §7's "go fully deterministic" was the wrong
call, and the reason it was wrong is §7.1: `look_candidates` is a judgement
field and a noun regex will be visibly bad at it.

But (a) and (b) have very different price tags, and the measurements below say
so clearly. **Keep (a). Drop (b).** The LLM should emit the one field it is
actually good at and nothing else.

---

## 9. What Haiku 4.5 actually costs here

Haiku 4.5 is **$1.00 / 1M input, $5.00 / 1M output**. Output is 5× input, which
is the whole story — this decision is about output tokens, not prompt size.

Measured from `.boukensha/sessions/20260722T231230Z-e16fba10.jsonl`, all ten
`room_inspector` calls across the three rooms:

| Room | Call | in | out |
|---|---|---:|---:|
| Temple | plan (poll/look/exits) | 2360 | 142 |
| | plan (consider) | 2687 | 51 |
| | plan (examine) | 2946 | 73 |
| | **compose JSON** | 3099 | **310** |
| Market | plan | 2360 | 145 |
| | plan | 2796 | 120 |
| | **compose JSON** | 3041 | **256** |
| Common | plan | 2360 | 141 |
| | plan | 2841 | 121 |
| | **compose JSON** | 3105 | **386** |
| | **total** | **27,595** | **1,745** |

$0.0276 input + $0.0087 output = **$0.0363 for 3 rooms = $0.0121/room**.

Note the shape: the three compose calls are **55% of all output tokens** (952 of
1745) in **30% of the calls**. That is where the money and the seconds are.

### 9.1 The three candidate designs, priced

Two things shrink when the script drives: the **prompt** loses the tool schemas
(~950 tok — the gap between `system.md` at ~1310 tok and the observed 2360-token
first call) and the ReAct scratchpad, and the **call count** drops from 3 to 1.
What does *not* shrink in your design is the output — the model still types the
whole JSON.

| | LLM calls | in/room | out/room | $/room | LLM latency |
|---|---:|---:|---:|---:|---:|
| **Today** (ReAct) | 3 | 9,198 | 582 | $0.0121 | 18.6s |
| **A** — parse whole schema (your (b)) | 1 | ~1,550 | ~317 | **$0.0031** | **~7.2s** |
| **B** — candidates only (your (a)) | 1 | ~550 | ~20 | **$0.0007** | **~1.4s** |
| **C** — fully deterministic (§7) | 0 | 0 | 0 | $0 | 0s |

Latency uses the measured Haiku throughput from this session — the 310-token
compose call took 7.22s, i.e. ~1.0s TTFT + ~51 tok/s. Input size barely moves
it; **output length is latency**.

### 9.2 Why A is the trap

A is a 74% cost cut and a 3→1 call cut, and it still lands at **~17s/room**
end-to-end. Because the one call it keeps is *the slowest one* — the compose
call was always the expensive third of the loop, and A changes only its prompt.

And look at what those ~317 output tokens are. From the Temple room, the model's
JSON is ~310 tokens, of which the `description` field alone is ~180 — prose the
script already holds as a string, retyped through a model at $5/1M so it can
come back byte-identical. `name`, `exit_targets`, `hp/mana/move`, and `events`
are another ~90 tokens of pure transcription. `look_candidates` — the only field
that needed a model — is about **8 tokens**.

So A pays for ~309 tokens of copying to get 8 tokens of judgement.

There's a correctness argument too, not just a cost one. `name` and
`exit_targets` are map keys; the plan's own §3.2 flags that a hallucination
there corrupts the room graph. Routing them through a model is a hallucination
surface the script doesn't have. A model that retypes 300 tokens of text gets it
right ~always — but "~always" is a different guarantee than `String#dup`.

**Prompt caching can't rescue A.** Haiku 4.5's minimum cacheable prefix is 4096
tokens; A's whole prompt is ~1550. It would silently never cache — no error,
just `cache_creation_input_tokens: 0`.

### 9.3 The proposal: B

The script emits the schema. The LLM is handed the description prose and the
known mob/object list, and returns one array:

```
input:  "You are standing on the market square, the famous Square of
         Midgaard. A large, peculiar looking statue is standing in the
         middle of the square. Roads lead in every direction..."
        already-listed: []
output: ["statue", "square", "roads"]
```

~550 in, ~20 out, **$0.0007/room**, ~1.4s. That is **17× cheaper than today**,
**4.4× cheaper than A**, and it keeps exactly the capability §7.1 says we'd lose.

This is also, I think, what your third note is pointing at — "produce json by
just parsing structure within using an LLM." The structure is the part the
script can do; the model should touch only the unstructured field.

Everything in §§1–6 and §8 still stands: the script is the same script, the
dispatcher seam is the same seam, `Tools::RoomParser` is the same pure function.
The only change from §7 is that `RoomParser` takes an injected
`candidate_extractor` instead of hardcoding a noun regex.

---

## 10. The NLP question — options between regex and LLM

You're right that a capitalized-noun regex would be terrible. Concretely, on the
Temple description it would return `["walls", "appearance", "blocks",
"paintings", "end", "hall"]` — mostly abstract nouns and prose scaffolding, and
it would miss `altar` if the sentence structure didn't cooperate.

Here is the actual ladder, worst to best.

### 10.1 POS tagging — `engtagger` (a better regex, not a solution)

`engtagger` (0.4.3, on rubygems, pure Ruby, no native extensions, no model
download) is the Ruby port of Perl's `Lingua::EN::Tagger`. It gives you
`get_nouns` and `get_noun_phrases` in about a millisecond.

It is a genuine upgrade over a regex — it finds `altar` regardless of position
and won't mistake a verb for a noun. But it does not solve the problem, because
the problem isn't *"which words are nouns"* — MUD prose is wall-to-wall
concrete nouns — it's *"which nouns did the area author bother to write an
extra-description for."* `engtagger` has no opinion on that. You'd get high
recall and poor precision, which for an advisory field means the player burns
`look` calls on `walls` and `appearance`.

Worth adding **as the tokenizer** in front of the filter below. Not worth
shipping alone.

### 10.2 A learned dictionary — the one I'd actually build

The missing piece is a filter, and the game hands us one for free: **every
`look <noun>` we've ever issued told us whether that noun is examinable.** A
real extra-description comes back; a miss comes back as the server's
"You do not see that here."

So: keep a persistent `Set` of nouns that have ever resolved. `look_candidates`
= `engtagger` nouns from the description ∩ that set, minus known mobs/objects.

- **Cost: $0. Latency: ~1ms.**
- Unlike the LLM it **cannot invent a noun that isn't in the text**.
- It gets monotonically better with play, and it generalizes — `fountain`
  learned in Market Square is still a candidate in every future fountain room.
- Cold start is the weakness: an empty dictionary returns `[]`. Seed it with
  30–40 obvious MUD nouns (statue, altar, fountain, sign, board, painting,
  door, tree, well, corpse…) and it's useful on turn one.

This is a strictly better shape than a heuristic *and* better than the LLM on
the axis that matters — it never hallucinates, and it's free. Its ceiling is
lower than a model's on a genuinely novel noun, which is what §10.4 is for.

### 10.3 World-file harvest — potentially exact, needs a decision from you

**Unverified — do not build on this until checked.** tbaMUD area files declare
extra-descriptions explicitly rather than inferring them from prose, so the
keyword lists may be readable directly from the server's world data. I could not
confirm the file format: there is no tbaMUD source or `.wld` file anywhere on
this machine (the MUD answers on `localhost:4000` but its install isn't local to
this repo), and I'm not going to assert CircleMUD file-format details from
memory.

**To check:** find the server install, look for `lib/world/wld/*.wld`, and
confirm whether room entries carry keyword-tagged extra-description blocks.

If they do, there are two very different ways to use it, and the choice is
yours, not mine:

- **Per-room lookup** — read this room's extra-descs directly. Exact, zero cost.
  But it makes the bot omniscient about things it has never examined, which may
  be the kind of cheating you don't want in a MUD-playing agent.
- **Global dictionary harvest** — collect every extra-desc keyword across the
  whole world into one flat set, and use it as §10.2's filter. This is *not*
  per-room omniscience; it's "the bot knows which nouns MUDs tend to make
  examinable," which is exactly what a human player learns after a week. This
  one I'd consider fair game, and it solves §10.2's cold start completely.

### 10.4 Local model — where option B should end up

`settings.yaml:57-60` already advertises that `room_inspector` can swap to a
local Ollama 3B config-only. That claim was made for the *whole* task, where it
was a stretch. For a single sentence-level noun-extraction call it is very
comfortable — a 3B does this well.

That makes B's marginal cost **$0** and its latency local (~1–2s, no network).
So the honest end state is: B is the design, and the model behind B is a config
choice — Haiku 4.5 today at $0.0007/room, local 3B later at $0.

### 10.5 Training our own — the option I skipped, and shouldn't have

§§10.1–10.4 asked "what can I install." That was the wrong question. This task
is narrow, the labels are free, and the inference budget is microseconds — it is
almost the ideal shape for a purpose-trained model. Worth noting the dictionary
in §10.2 *is* already a model: word-identity features with binary weights and no
backoff. Everything below is that same model, better.

**The labels cost nothing, and that's the real finding.** Three sources, none
of which need an external dataset:

1. **The MUD is the labelling oracle.** `look <noun>` returns either an
   extra-description or "You do not see that here." That is a ground-truth
   binary label, on demand, for free. The bot can probe every noun in every
   description it visits during idle time — ~1.2s per probe, no tokens. A few
   hundred rooms of exploration yields thousands of labelled examples, and it's
   genuinely self-supervised: no human ever annotates anything.
2. **Structural negatives, free with every survey.** See §10.7 — a large share
   of nouns in these descriptions are references to *adjacent rooms*, and we
   already hold the adjacent room names. Plus every mob/object keyword. These
   are hard negatives requiring zero probes.
3. **World files** (§10.3, still unverified) — if readable, thousands of gold
   positives instantly, no probing at all.

**Model tiers.** All three are real options; the gems all exist and are
installed-checkable today.

| | Deps | Model size | Inference | Trains in |
|---|---|---:|---:|---:|
| **T1** Logistic regression, pure Ruby | none | ~50KB JSON | ~10µs | <1s |
| **T2** fastText supervised (`fasttext` 0.5.0) | C++ ext | ~0.1–1MB quantized | ~0.1–1ms | seconds |
| **T3** Distilled transformer via `onnxruntime` 0.11.4 | prebuilt binary | 4–22M params | ~1–5ms | minutes (GPU) |

For scale, option B's Haiku call is **~1,400,000µs**. Every local tier is
between 1,000× and 100,000× faster, and all of them are free per call.

**T1 is where I'd start, and I suspect it's where this ends.** Features, all
cheap, over each `engtagger`-tagged noun:

- word identity (hashed) — the dominant feature; this is the dictionary,
  learned with weights instead of a binary set
- character 3–4-gram suffixes — the morphological backoff the dictionary
  lacks, so `fountain` transfers to `mountain`, `altar` to `pillar`
- count of adjectives modifying the noun
- preceded by an indefinite article vs. a direction word (§10.7)
- appears in `exit_targets` / mob keywords / object keywords → hard negative
- appears in the room name
- inside a "leads to/into" clause → navigational, negative

That's ~15 features and a dot product. Weights ship as JSON, training is an
offline Ruby script, and there is nothing to install.

**T2 buys one specific thing: better generalization to nouns never seen.**
fastText's built-in character n-grams are exactly the right inductive bias for
"words that look like concrete physical objects," and you get them without
hand-designing suffix features. If T1's cold-start recall disappoints, this is
the next move, not T3.

**T3 is almost certainly overkill, and I'd rather say so than hedge.** The task
is ~90% lexical plus a handful of syntactic cues that T1 captures explicitly.
Real contextual understanding buys little here. Reach for it only if T1 and T2
both plateau below what the LLM does — and measure that before believing it.

**This also reframes what the LLM is for.** Option B's right role isn't the
runtime path — it's the **teacher**. Have Haiku label the first few hundred
descriptions, train T1 on its output plus the probe labels, then run free
forever. At $0.0007/room, bootstrapping 500 rooms costs **$0.35, one time**.
That is distillation, and it's a far better use of the expensive thing than
paying it on every room forever.

### 10.6 The free precision win nobody's model needs to learn

Reading the actual captured descriptions changed my estimate of this problem.
Look at what the nouns really are:

> "To the **west** is the **poor alley** and to the **east** is the **dark
> alley**. To the **north**, this **square** is connected to the **market
> square**."

Nearly every noun in The Common Square's description is a **reference to an
adjacent room**. And we already know every adjacent room's name — that is
exactly what `exit_targets` holds, from the `check kind:"exits"` call the
script already makes.

So: subtract `exit_targets` values (tokenized) from the candidate set. No model
required, no training, no probing. On this corpus that removes `poor alley`,
`dark alley`, `market square`, `temple square` — the bulk of the false
positives a regex or a naive POS tagger would produce.

The inverse holds for positives. Compare:

> "A large, peculiar looking **statue** is standing in the middle of the square."

versus a bare directional mention. Authors write extra-descriptions for things
they bothered to describe, and "bothered to describe" shows up syntactically as
adjective stacking plus existential framing ("*a* large, peculiar looking X *is
standing*") rather than directional framing ("to the west *is* X"). That is a
learnable feature and it is in T1's list above.

Both of these are worth building **before** any model, because they raise the
floor for every tier — including the LLM, which should be handed the exit names
as exclusions too.

### 10.7 Recommendation

Build in this order. Each step is useful shipped alone, and each one raises the
floor for everything after it.

1. **§10.6 structural subtraction** — exit names, mob keywords, object
   keywords out of the candidate set. No model, no training, no probes. Biggest
   precision win per line of code in this entire plan; do it first regardless of
   what follows.
2. **§10.1 + §10.2 — `engtagger` nouns ∩ learned set.** Free, instant, cannot
   hallucinate. Ships as the default.
3. **Probe loop** — every `look <noun>` outcome writes a label. This is
   step 2's data source *and* step 4's training set; it starts paying the moment
   step 2 exists.
4. **§10.5 T1 — pure-Ruby logistic regression** over the §10.5 feature list,
   trained on the accumulated labels. Replaces the binary dictionary with
   weights and morphological backoff. No new dependencies. Escalate to T2
   (fastText) only if cold-start recall on unseen nouns is measurably weak, and
   to T3 only if T2 plateaus.
5. **§9.3 option B (Haiku)** — kept, but as the **teacher**, not the runtime
   path: label the bootstrap corpus once (~$0.35 for 500 rooms), then let T1
   run free.

Expose it as a configured enricher rather than a fork, so all of the above is a
config line instead of a rewrite:

```yaml
look_candidates: model   # none | dictionary | model | llm | model+llm
```

- `none` — §7's fully deterministic path, still available.
- `dictionary` — steps 1–2. Free, instant.
- `model` — step 4. Free, ~10µs, generalizes to unseen nouns. The target
  default.
- `llm` — option B. Zero-shot; the only tier that works with no accumulated
  data at all.
- `model+llm` — model result, LLM consulted only when it returns empty.
  $0.0007 on the rooms that need it, $0 on the rest.

The through-line: **the LLM's only real advantage here is cold start.** Once
labels exist, every local tier beats it on cost (free), latency (1,000×+), and
hallucination (structurally impossible). So use the LLM to manufacture the
labels, then stop paying it.

---

## 11. Revised projection

Warm cache, The Common Square, `dictionary+llm` with the dictionary cold (worst
case — the LLM call fires):

| Bucket | Today | §7 (fully det.) | A (parse JSON) | **B (recommended)** |
|---|---:|---:|---:|---:|
| LLM inference | 18.62s | 0 | ~7.2s | ~1.4s |
| MUD round trips | 6.36s | 6.36s | 6.36s | 6.36s |
| Log-event gaps | ~6.72s | ~4.2s | ~5.0s | ~4.6s |
| Subagent spin-up | 2.08s | 0 | 0 | 0 |
| **Total** | **33.8s** | **~10.6s** | **~17.2s** | **~12.4s** |
| **$/room** | **$0.0121** | **$0** | **$0.0031** | **$0.0007** |

With §6's logging overhead also fixed, B lands at **~8s** — and at **~6.5s** on
any room where the dictionary answers and the LLM never fires.

Compared against the same session's actual gameplay: 3 rooms would cost
**$0.002** instead of $0.0363, against the player's $0.0417 for 9 turns. Room
inspection stops being half the bill and becomes a rounding error.

## 12. Revised work items

Replaces §8. Items 1, 2, 4, 6, 8, 9 are unchanged from §8 — the dispatcher seam,
the survey script, the color assertion, the entrypoint rewiring, the
`mud_monitor` regression check, and the logging investigation all stand as
written.

3. `Tools::RoomParser` (new) — pure text → Hash, no I/O, **emits the full schema
   including `look_candidates`**. Takes an injected `candidate_extractor`
   (`->(description, exclude) { [String] }`) so the extractor is swappable and
   the parser stays testable without a model.
5. Keyword cache + verify/retry (§3.4) — unchanged, but note it is a *different*
   cache from §10.2's: this one maps desc-line → target keyword for
   `consider`/`examine`; §10.2's maps noun → is-examinable for `look`. Both are
   session/persistent `Set`s; don't merge them.
10. `Extractors::Dictionary` — `engtagger` nouns ∩ learned set, minus
    mobs/objects. Add `engtagger` to the gemspec (pure Ruby, no native deps).
11. Dictionary persistence + learning hook — record every `look <noun>` outcome.
    Needs a `look`-result observation point; the player's allowlist has no
    `look` (`settings.yaml:16-18`), so the hook belongs wherever the survey's
    own `look` probes land. Seed file of ~40 nouns checked into the repo.
12. `Extractors::Llm` — option B. One call, description + exclusions in, array
    out. New minimal prompt (`prompts/room_candidates/system.md`, ~250 tok);
    the existing `room_inspector` system prompt is **deleted**, not rewritten —
    B's prompt shares nothing with it.
13. `settings.yaml` — replace the `room_inspector` task block with a
    `look_candidates` enricher setting (§10.7). The `allow:` block moves into
    the dispatcher's scoping per §2.1; when the enricher is `llm` it needs an
    empty allowlist and `max_iterations: 1`, since it calls no tools.
14. **Decision required:** verify the tbaMUD world-file format (§10.3), then
    choose per-room lookup vs. global harvest vs. neither.
15. **`Extractors::Structural`** (§10.6) — subtract tokenized `exit_targets`
    values, mob keywords, and object keywords from the candidate set. Runs in
    front of *every* other extractor, including `Extractors::Llm` (the exit
    names go into option B's exclusion list too). **Build this first** — it is
    the cheapest precision win in the plan and it makes every later tier better.
16. **Label store + probe loop** (§10.5) — one append-only JSONL of
    `{noun, context_features, label, room}`. Written by item 11's `look`
    observation hook, plus item 15's structural negatives (free, no probe), plus
    optionally a background probe pass over unlabelled nouns during idle time.
    This is the training set; nothing downstream exists without it.
17. **`Extractors::Model` — T1 logistic regression** (§10.5). Two pieces: an
    offline `train_candidates.rb` script (reads the label store, writes
    `weights.json`) and a runtime scorer (~15 features, dot product, ~10µs). No
    new gem dependencies. Ships `weights.json` in the repo so a fresh clone
    isn't cold.
18. **Escalation gate, not a commitment:** only if T1's recall on *unseen*
    nouns is measurably weak, evaluate T2 (`fasttext` 0.5.0, quantized). Only if
    T2 plateaus, evaluate T3 (`onnxruntime` 0.11.4 — prebuilt x86_64-linux
    binaries, no compile). Both are dependency additions and neither is assumed.
19. **Bootstrap run** — point `Extractors::Llm` at ~500 rooms once to seed the
    label store (~$0.35), then train T1 and flip the default to `model`.

### 12.1 Test corpus

Unchanged from §8.1, plus: the captured descriptions double as the
`Extractors::Dictionary` fixture. Market Square's "peculiar looking statue" and
the Temple's "ancient wall paintings" are the two cases worth asserting on —
the first is a true positive the regex would also catch, the second is one it
would catch *wrongly* (`paintings` is scenery prose, and whether it's actually
examinable is precisely what the learned dictionary knows and a regex can't).

### 12.2 How we'll know which tier is enough

Items 18–19 are gated on measurement, so the measurement has to exist. Hold out
~20% of the label store (item 16) by *room*, never by noun — splitting by noun
leaks, because the same word recurs across rooms and word identity is the
dominant feature.

Report precision/recall separately for **seen** and **unseen** nouns. That split
is the whole decision:

- On **seen** nouns, the dictionary is already at ceiling and every model tier
  ties it. No tier can beat a lookup on a word it has a label for.
- On **unseen** nouns, the dictionary scores 0 by construction. This is the only
  column where T1/T2/T3 — or the LLM — can earn anything.

So don't compare aggregate F1 across tiers; it will be dominated by the seen
bucket and will make every tier look identical. Escalate T1 → T2 → T3 only on
the unseen column, and stop as soon as the curve flattens.

Cheap sanity check before any of this: run all tiers over the five captured
descriptions and eyeball the output. `statue` should survive in Market Square;
`poor alley`, `dark alley`, and `market square` should be gone from The Common
Square (item 15 alone should achieve that); and the Temple's `paintings` is the
genuinely ambiguous case worth arguing about.
