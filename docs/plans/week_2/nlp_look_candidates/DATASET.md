# `look_candidates` Dataset — Build Notes & Review

Prepared for review. Nothing here is trained or tuned yet — this is the corpus,
the splits, and the properties that determine what is worth building.

**Regenerate:** `ruby extract.rb` (deterministic; seed 42)
**Eyeball:** `ruby sample.rb 40 > data/sample.txt`

---

## 1. Provenance — why these labels describe the game we actually play

```
week0_explore/infrastructure/lib/world/wld/*.wld     189 files   <-- ground truth
        │
        ├─ bind-mounted by docker-compose.yml:  ./lib -> /opt/circlemud/lib
        │  into container `circlemud` (tbaMUD), serving localhost:4000
        │  = the MUD that mud_manager talks to
        │
        └─ exported to
week0_explore/preview/data/world/wld/*.json          189 files   <-- what we parse
```

This closes the parity question the plan flagged as blocking (§1.1). It isn't a
spot-check any more: the container mounts the very directory the labels come
from, so the world we score against *is* the world we play, by construction. The
only remaining risk is drift between the `.wld` source and its JSON export, which
§5 quantifies.

**We parse the JSON, not the `.wld`.** The export has already solved the two
traps that make hand-parsing world files unreliable: extra-description keywords
arrive pre-split into arrays, and `~`-terminated strings are resolved. Those
matter more than they sound — room `2815` is named `Welcors ~~~ ~~~ furnace~`
(embedded tildes), and every room in `654.wld` has a name beginning with `#`
(`#1 First Street~`), which any `^#\d+` room-delimiter scan misreads as a new
room. My own first pass over the `.wld` inflated the room count by ~30 for
exactly that reason.

> ⚠️ **The JSON export is gitignored** (`week0_explore/preview/data/.gitignore`
> excludes `world/`). So the dataset's input is not in version control. Either
> commit `data/rooms.jsonl` (6.7 MB) as the reproducible artifact, or commit the
> exporter and treat regeneration as a build step. **Your call — see §6.**

---

## 2. Files

| File | Size | What |
|---|---:|---|
| `data/rooms.jsonl` | 6.7 MB | 12,668 rooms, one JSON object per line |
| `data/splits.json` | 315 KB | Frozen zone-level and room-level train/test vnum lists |
| `data/stats.json` | 2 KB | Regenerated corpus statistics — never hand-edited |
| `data/sample.txt` | 549 lines | 40 random labelled rooms, human-readable |

### Schema (`rooms.jsonl`)

```json
{"vnum":3014,"zone":30,"zone_file":"30.json","name":"Market Square",
 "desc":"You are standing on the market square, the famous Square of Midgaard. ...",
 "sector":"CITY","flags":["NOMOB"],
 "gold":[{"aliases":["statue"],
          "desc":"What you see is the Midgaard Worm, stretching around the Palace...",
          "meta":false}],
 "exits":[{"dir":0,"to":3005,"to_name":"The Temple Square"}]}
```

`gold` is the label: one entry per extra-description. `aliases` is the full
keyword set — **a prediction counts as a hit if it matches *any* alias**, since
that is how the game's own keyword matching works. `exits[].to_name` is present
because exit destinations are a *feature*; the earlier plan's proposal to
subtract them was measured and lost (F1 15.4 → 13.9).

---

## 3. What the corpus looks like

| | |
|---|---:|
| Rooms | 12,668 |
| Zones | 189 |
| Rooms with ≥1 scoreable label | 1,568 (**12.4%**) |
| Gold blocks (total / scoreable / meta) | 2,380 / 2,175 / 205 |
| Multi-alias blocks | 1,433 (60%) |
| Distinct aliases | 1,373 |
| **Token-level positive rate** | **0.70%** (~1:143) |

Splits: zone 151/38 zones → 9,860/2,808 rooms. Room 10,134/2,534.

### 3.1 Three findings that should drive the build

**Recall ceiling is 79.8%.** For 439 of 2,175 scoreable blocks, *no alias
appears anywhere in the room description*. No text-based extractor — regex,
model, or LLM — can ever emit them. The sample makes clear this is legitimate
rather than a tokenisation artifact; builders hide things on purpose:

```
#3802  A Big Pipe
"You are in a big pipe where all the sewage from many parts of the sewers
 joins together... What seems like a tunnel is at the end of this pipe..."
  [MISS] red, grate  -> "It appears to be a red grate, but the color is very faded."
```

Nothing in that description mentions a grate. **Cap expectations at ~80% recall
and report against that ceiling, not against 100%.**

**Class imbalance is 1:143.** Accuracy is meaningless here — predicting nothing
scores 99.3%. Precision/recall/F1 and PR-AUC only.

**Word identity is nearly useless on its own — this is the big one.** Of the 114
words that are positive at least 5 times, the median *purity* (`pos/(pos+neg)`)
is **8.6%**:

| word | positive | negative | purity |
|---|---:|---:|---:|
| `trees` | 87 | 593 | 12.8% |
| `path` | 69 | 965 | 6.7% |
| `sign` | 63 | 191 | 24.8% |
| `wall` | 46 | 1,202 | 3.7% |
| `floor` | 40 | 1,067 | 3.6% |
| `door` | 33 | 679 | 4.6% |
| `desk` | 29 | 113 | 20.4% |

Read the `wall` row: seeing "wall" in a description means it is examinable
**3.7%** of the time. A lexicon that fires on `wall` is wrong 27 times out of 28.
89% of positive word types are contested this way (up from 77% on the smaller
corpus I was reasoning from earlier).

**Consequence:** a dictionary cannot work, and it is not a close call. Whether a
noun is examinable is a property of *this room*, not of the word. That is the
definition of a contextual task, and it moves T3 from "probably overkill" — my
earlier read — to the tier most likely to be necessary. The build order in
`README.md` §5 should be re-read with that in mind.

---

## 4. Label-quality issues for your review

**4.1 `meta` blocks (205, flagged not dropped).** Out-of-character furniture:
`credits`, `info`, `menu`, `motd`, and ASCII-art maps (detected via ≥3 colour
codes or heavy box-drawing characters). A player exploring a room does not want
`look credits`. Currently excluded from scoring but retained in the data.
**Decide:** drop entirely, or keep and let the model learn to suppress them?

**4.2 Alias lists include non-nouns.** Because game keyword matching is
per-word, a builder writing "thin rivulets" yields aliases `["thin","rivulets"]`
— and `look thin` genuinely works. But `thin` is a bad *suggestion*. Real
example from the sample:

```
#1907  Slippery Slope
  [ OK ] thin, rivulets, water, watery, pool, base
```

Six aliases for one thing; the player needs one, and three are poor candidates.
Since scoring is any-alias-matches, this **inflates measured recall** — an
extractor emitting `water` gets full credit without finding the interesting
noun. **Decide:** score against all aliases (current, generous), or against a
head-noun per block (harder, closer to the product goal)?

**4.3 Gold is "has an extra-description," not "is interesting."** A builder's
failure to write one is indistinguishable from a thing not being examinable.
This caps every tier and we cannot measure the cap from the data alone —
`README.md` §7.4 proposes a study. Worth doing before investing in T2/T3.

---

## 5. Known gaps

**21 rooms in the `.wld` source are absent from the JSON export** (0.17%),
carrying **14 extra-descriptions** (0.6% of labels). Two causes, both now
understood:

- `654.wld` — 20 rooms whose names begin with `#`. Its single lost label is an
  ASCII-art `map plan` block, which §4.1 would have flagged as meta anyway.
- `28.wld` room `2815` — embedded `~` in the room name. Loses a real label
  (`flame wall burning fire`).

Not worth recovering for a 0.6% label gain, but it should be recorded rather
than discovered later. If the exporter is ever rerun, these are the regression
cases.

**Verified clean:** no duplicate vnums after parsing, no empty names, no empty
descriptions, all 189 files parsed without error, zero rooms dropped for missing
description.

---

## 6. Decisions I need from you

1. **Commit `data/rooms.jsonl` (6.7 MB), or treat it as a build artifact?** The
   source JSON is gitignored, so if we don't commit the derived file the dataset
   is not reproducible from a fresh clone.
2. **§4.1** — drop `meta` blocks or model them?
3. **§4.2** — score any-alias (generous, current) or head-noun (honest, harder)?
4. **Zone split as headline** — confirm. 38 held-out zones, entirely unseen
   vocabulary and authors. It is the deployment condition as the bot explores,
   and it is much harsher than the room split.
5. **§4.3 noise-ceiling study** — worth running before T2/T3?

---

## 7. Not done yet

No extractor has been run against this corpus. The baselines quoted in
`README.md` §0 (dictionary F1 16.5% room / 2.1% zone) were measured on the
**smaller 1,878-room CircleMUD corpus** from the sibling checkout, not this one.
They are directionally useful but **stale** — this corpus is 6.7× larger, has
half the label density (12.4% vs 21.5% of rooms), a lower recall ceiling (79.8%
vs 89.5%), and worse ambiguity (89% vs 77%). Expect every number to get worse.

Next step is `evaluate.rb` (README §8 item 4) and re-running T0a/T0b/T0c here to
establish the real starting line.
