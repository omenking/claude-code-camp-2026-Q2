# NLP for `look_candidates` — Dataset, Validation, and Tier Bake-off

`look_candidates` is the one field in the room-survey schema that needs
judgement (see `../scripted_room_survey.md` §7.1). Every proposal so far — mine
included — argued about which extractor to build from intuition. We have the
CircleMUD world files, which contain the ground truth. So we stop arguing and
measure.

This plan builds the dataset, the split, and the harness **first**, then runs
the T-tiers against it progressively.

---

## 0. TL;DR — what the ground truth already told us

I ran the extraction and four baselines while writing this plan. Three of my
earlier recommendations did not survive contact with the data:

| Claim (prior plan) | Verdict |
|---|---|
| "Subtract exit-destination names — biggest precision win, do it first" (§10.6) | **Wrong.** F1 15.4 → 13.9. 29% of true positives *are* exit-destination words. |
| "The task is ~90% lexical; T3 is overkill" (§10.5) | **Wrong.** 77% of positive word types also appear as negatives. `wall` is 17+/155−, `path` 60+/157−. Context is the whole game. |
| "Dictionary is free, instant, and the sensible default" (§10.2) | **Overturned at the honest split.** Zone-level F1 **2.1%** — worse than predicting every content word (3.3%). |

The last one is the important one, and it is a *methodology* finding: switching
from a room-level split to a zone-level split moves F1 by **8×**. Any bake-off
run on a room-level split will produce confident, wrong conclusions.

**Baseline table** (measured, see §6 for protocol):

| Extractor | Room split F1 | Zone split F1 |
|---|---:|---:|
| predict nothing | 0.0% | 0.0% |
| all content words (regex floor) | 3.3% | 3.3% |
| learned dictionary | 16.5% | **2.1%** |
| dictionary − exit-dest words | 13.9% | — |

That is the real starting line. Everything in this plan exists to beat 3.3%
honestly.

---

## 1. The data source (verified)

**Location:** `~/Sites/ExamProCo/claude-code-camp-2026-Q2/week0_explore/circlemud-world-parser/assets/wld/`
— 29 `.wld` files, a sibling checkout to this repo.

**Live server:** docker container `circlemud` (image `infrastructure-circlemud`),
`0.0.0.0:4000->4000`. This is the MUD `mud_manager` talks to.

**Format — confirmed by inspection**, not from memory. Room `#3014`:

```
#3014
Market Square~
   You are standing on the market square, the famous Square of Midgaard.
A large, peculiar looking statue is standing in the middle of the square.
Roads lead in every direction, north to the temple square, south to the
common square, east and westbound is the main street.
~
30 0 1
D0
You see the temple square.
~
~
0 -1 3005
...
E
statue~
What you see is the Midgaard Worm, stretching around the Palace of Midgaard.
~
S
```

Structure per room: `#vnum` → `name~` → description → `~` → flags →
`D<dir>` exit blocks (last field of the third line is the **target vnum**) →
`E` extra-description blocks (`keywords~` then text then `~`) → `S`.

`E` blocks are the labels. Market Square's ground truth is exactly
`["statue"]` — which matches what Haiku produced in the session log, so the
LLM's behaviour on this room was correct and we now have a way to check that
claim at scale instead of eyeballing three rooms.

**Corpus size:** 1878 rooms parsed, 686 `E` blocks, 404 rooms (21.5%) with at
least one.

### 1.1 Parity check — required before trusting any number

The world assets live in a *different checkout* from the container's runtime
data. Spot-checks match (Market Square and Temple Square are byte-identical to
what came back over telnet), but that is two rooms.

**Work item:** walk N≈50 rooms over the live MUD, capture `look` output, and
diff room name + description against the parsed assets. If they diverge, every
label in this plan is describing a different game than the one we play. Do this
before building anything on top.

---

## 2. What a label actually is

`E` keyword strings are **space-separated alias lists**, CircleMUD-style — one
examinable *thing*, several ways to name it:

```
["scorecards", "pencils pencil"]              # room 12001, two things
["swords weapons armor halberds whips"]       # room 12006, ONE thing, five aliases
["seats benches"]                             # room 12003
```

398 of 686 blocks (58%) carry multiple aliases.

**Matching rule — this is load-bearing.** A prediction hits a gold block if it
contains **any** alias in that block. Scoring is set-of-sets, not set-of-words.
Getting this wrong (treating each alias as a separate gold item) silently
deflates recall by ~40% and makes every tier look worse than it is.

```ruby
gold = room.kws.map { |k| k.downcase.split.to_set }   # [Set[swords, weapons, ...], ...]
tp   = gold.count { |aliases| aliases.any? { |a| predicted.include?(a) } }
fn   = gold.size - tp
fp   = predicted.count { |w| !gold.flat_map(&:to_a).include?(w) }
```

---

## 3. Measured properties — why this is hard

Every number below is from the corpus, not an estimate.

| Property | Value | Consequence |
|---|---:|---|
| Rooms with ≥1 `E` block | 21.5% | "predict `[]`" is right 78.5% of the time at room level |
| Token-level positive rate | **1.66%** | ~1:60 imbalance. **Accuracy is meaningless** — a null model scores 98.3% |
| Unique words per description | 25.5 avg | ~25 decisions per room, ~0.37 of them positive |
| `E` blocks per room (when present) | 1.7 avg | short gold lists; precision errors dominate F1 |

### 3.1 Three ceilings

**Reachability — 89.5%.** An alias appears verbatim in the description for
86.3% of blocks; +3.5% reachable by stemming. **10.2% of gold blocks contain no
word from the description at all** and are unreachable by *any* text-based
extractor. Measured: the "all content words" baseline hits R=89.5%, matching
this prediction almost exactly — a good sanity check that the harness is
correct.

**Dictionary — 85.3% recall.** On a room-level split, 14.7% of test positive
tokens never appear as a positive in training. A lookup scores 0 on those by
construction. This is the only column where a *model* can earn anything over a
dictionary.

**Authorial noise — unknown, and the most important open question.** Whether
room 3014's author wrote an `E` block for `statue` is partly a coin-flip of
effort. `path` appears as a positive 60 times and a negative 157 times. Some of
that is resolvable context (a path you walk *on* vs. scenery); some is
irreducible. **We do not know the split, and it caps every tier.** §7.4 proposes
how to estimate it.

### 3.2 The ambiguity problem

77% of positive word types also appear as negatives somewhere:

| word | positive | negative |
|---|---:|---:|
| `trees` | 76 | 64 |
| `path` | 60 | 157 |
| `wall` | 17 | 155 |
| `water` | 15 | 69 |
| `sign` | 25 | 9 |

This is the finding that reorders the tier ladder. "Is `wall` examinable?" has
no answer — only "is `wall` examinable *in this room*." A bag-of-words model
cannot represent that. `sign` (25+/9−) shows some words really are near-decidable
lexically, but they are the minority.

---

## 4. Dataset construction

Three artifacts, built in order. All live in this directory.

### 4.1 `extract.rb` → `rooms.jsonl` (the corpus)

Parse all 29 `.wld` files. One line per room:

```json
{"vnum":3014,"zone":30,"name":"Market Square",
 "desc":"You are standing on the market square...",
 "gold":[["statue"]],
 "exits":{"0":3005,"1":3015,"2":3025,"3":3013}}
```

Notes from writing the prototype parser:
- Files are **ISO-8859-1**, not UTF-8. `File.read(f, encoding: "ISO-8859-1")`
  or you get invalid-byte errors on a handful of zones.
- Descriptions are hard-wrapped; join and collapse whitespace.
- `zone` = `vnum / 100`. 35 zones across 1878 rooms.
- Resolve `exits` vnums → names in a second pass so exit-destination features
  are available (still worth *having* as a feature even though subtracting them
  outright loses — see §0).

### 4.2 `splits.json` (frozen, committed)

**Two splits, both committed, both always reported.**

- **`room` split** — 80/20 over shuffled rooms, seed 42. Optimistic. Measures
  "can we do this in a zone we've partly seen."
- **`zone` split** — 80/20 over the 35 *zones*, seed 42 (28 train / 7 test).
  Honest. Measures "can we do this in a zone we've never seen," which is the
  actual deployment condition as the bot explores.

Freeze both to a committed JSON of vnum lists. Do not re-shuffle per run —
two prototype runs with slightly different iteration order already produced
F1 16.5 vs 15.4 on nominally the same config, which is enough drift to mislead.

**Report both numbers in every result. The zone split is the headline.**

### 4.3 `observed.jsonl` (the "known data" set)

§4.1 is what the *world files* say. This is what the *running game* says — the
bot's own experience, and the thing that would exist in production where world
files aren't assumed.

Two writers:
- **Probe labels.** For each visited room, `look <noun>` every candidate noun.
  Extra-description returned → positive; "You do not see that here." → negative.
  ~1.2s per probe, zero tokens.
- **Survey byproducts.** Mob/object keywords from each survey — free negatives.

This set exists for three reasons: it validates that world-file labels match
live behaviour (§1.1 at label granularity), it's the training source if we ever
run against a world we don't have files for, and it's the only way to catch
extra-descriptions added by builders after our asset snapshot.

**Keep it separate from §4.1. Never merge.** World-file labels are complete per
room; probe labels are sparse and biased toward what the bot bothered to try.
Mixing them silently corrupts the negative class.

---

## 5. Tier ladder

`T0` is the floor; each tier must beat the previous **on the zone split** to
justify its dependency.

| | What | Deps | Inference | Expected to buy |
|---|---|---|---|---|
| **T0a** | predict nothing | — | 0 | Floor. F1 0. |
| **T0b** | all content words | — | ~1µs | Recall ceiling probe. F1 3.3%. |
| **T0c** | learned dictionary | — | ~1µs | Measured: 16.5% room / **2.1% zone**. |
| **T1** | logistic regression | none (pure Ruby) | ~10µs | Context features → resolve some of §3.2 |
| **T2** | fastText supervised | `fasttext` 0.5.0 | ~0.1–1ms | Char n-grams → unseen-word generalization |
| **T3** | distilled transformer | `onnxruntime` 0.11.4 (prebuilt x86_64-linux, no compile) | ~1–5ms | True contextual disambiguation of §3.2 |
| **TL** | Haiku 4.5 (option B) | network | ~1.4s | Zero-shot reference point |

`ollama` is already running as a container — worth adding a local-model row
between T3 and TL once the harness exists.

### 5.1 T1 feature set

Per candidate noun. Deliberately includes the features §3.2 says we need:

- word identity (hashed) — the dictionary, as weights
- character 3–4-gram suffixes — morphological backoff
- adjective count modifying the noun
- indefinite article vs. directional framing ("*a* large statue *is standing*"
  vs. "to the west *is* the alley")
- inside a "leads to/into" clause
- appears in this room's **own name** (positive signal — measured: subtracting
  room-name words cut recall 79%→24.5%, so this feature has the *opposite* sign
  from what §10.6 assumed)
- appears in an **exit destination** name (keep as a feature, do **not** hard-subtract)
- is a mob/object keyword in the live survey (hard negative — the one
  subtraction that is safe)
- position in description; sentence index

### 5.2 What would make T3 worth it

T3 earns its dependency only if it beats T2 on the **zone split**, on the
**ambiguous-word subset** specifically (the 77% from §3.2). Evaluate that slice
separately — aggregate F1 will be dominated by easy unambiguous words and will
hide the difference either way.

---

## 6. Evaluation protocol

1. **Split by zone (headline) and by room (reported alongside).** Never a
   noun-level split — word identity is the dominant feature and it leaks.
2. **Alias-set matching** per §2.
3. **Precision / Recall / F1, never accuracy.** At 1.66% positives a null model
   scores 98.3% accuracy. Also report PR-AUC for the tiers that emit scores
   (T1–T3), since threshold choice is a product decision, not a model property.
4. **Report these slices separately** — aggregate numbers hide every effect
   that matters:
   - seen vs. unseen words (§3.1 dictionary ceiling)
   - ambiguous vs. unambiguous words (§3.2, decides T3)
   - rooms with gold vs. rooms without (the 78.5% empty-list majority)
5. **Cap predictions at top-k (k=3).** `look_candidates` is advisory and the
   player probes them serially at ~1.2s each; an unbounded list is worse than a
   short wrong one. Precision@3 is closer to the real objective than raw F1, so
   report it as the product metric.
6. **Fix seeds; commit splits.** See §4.2.

---

## 7. Open questions

**7.1 Live-world parity (§1.1).** Blocking. Do first.

**7.2 Does the world-file corpus transfer to what the bot sees?** The corpus is
static prose. Live `look` output also carries mobs, objects, and events. The
harness trains on clean description text; the runtime extractor sees the parsed
`description` field from `Tools::RoomParser`. These should be the same string —
verify that assumption explicitly, it is exactly the kind of train/serve skew
that silently costs 10 points.

**7.3 Is the zone split too harsh?** 7 test zones is a small sample and zone
authorship varies wildly. Consider k-fold over zones (5 folds) rather than a
single 80/20 — with 35 zones that is cheap and much more stable.

**7.4 Estimating the authorial-noise ceiling (§3.1).** Proposal: take 50 rooms
that have no `E` block but whose descriptions mention a noun that is a positive
elsewhere (`statue`, `fountain`, `altar`). Have a human — or a strong model as
a proxy — judge "should this have been examinable?" If judges say yes for most,
the ceiling is low and no tier will do well; if they agree with the absent
label, the signal is real and there is headroom. **Run this before investing in
T3.** It is the difference between "our model is bad" and "the task is noisy."

**7.5 Should the label set be the union across zones?** If `fountain` is
examinable in 8 zones and absent in 1, treating the 9th as a hard negative may
be teaching the model an author's oversight rather than a fact about the world.
An alternative target is "probably examinable" rather than "has an `E` block."
This changes the labels, so decide before training.

---

## 8. Work items

1. **Live-world parity check** (§1.1). 50 rooms, diff name + description
   against assets. **Blocking — nothing downstream is trustworthy without it.**
2. `extract.rb` → `rooms.jsonl` (§4.1). ISO-8859-1; two-pass for exit names.
   A working prototype parser exists in this session's scratchpad — port it,
   don't rewrite it.
3. `splits.json` (§4.2) — frozen room split and zone split, committed.
4. `evaluate.rb` — the harness. Takes an extractor lambda, emits the §6 metric
   table with both splits and all slices. **Build this before any tier.**
5. Port T0a/T0b/T0c into the harness and reproduce §0's table. If the numbers
   don't match, the harness is wrong — fix before proceeding.
6. **T1** (§5.1) — `train.rb` writes `weights.json`; scorer reads it. Gate:
   must beat 3.3% zone-split F1.
7. **§7.4 noise-ceiling study.** Cheap, and it determines whether T2/T3 are
   worth starting.
8. **T2** — only if T1 clears the gate and unseen-word recall is the binding
   constraint.
9. **T3** — only if T2 plateaus *and* §5.2's ambiguous-word slice shows headroom.
10. **TL reference run** — Haiku option B over the test split, for a zero-shot
    comparison point. ~$0.30 at the §9.1 rates in `../scripted_room_survey.md`.
    This also directly tests that plan's "use the LLM as a teacher" claim: if
    Haiku's zone-split F1 is below T1's, the distillation story dies.
11. `observed.jsonl` writer (§4.3) — probe loop + survey byproducts.
12. Wire the winning tier into `Extractors::Model` per
    `../scripted_room_survey.md` item 17.

---

## 9. Relationship to `../scripted_room_survey.md`

That plan stands as written for everything *except* `look_candidates`: the
script-driven survey, the dispatcher seam, `RoomParser`, and option B's costing
are unaffected.

Superseded by this plan:
- §10.6 (structural subtraction of exit names) — **disproved**, see §0. Keep
  exit-name membership as a *feature*, not a subtraction. Mob/object keyword
  subtraction survives.
- §10.7's build order — items 1–2 (dictionary as default) are demoted to
  baselines. Build the harness first.
- §10.5's "T3 is overkill" — withdrawn. §3.2 says contextual modelling is
  exactly where the remaining headroom is.

Unchanged: `look_candidates` stays a swappable enricher behind one config key,
so whichever tier wins is a config line.
