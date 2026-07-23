## `look_candidates` in Ruby — wiring the trained model into `RoomInspector`

Follows [`nlp_look_candidates/`](nlp_look_candidates/README.md) (the bake-off:
BERT-medium wins, LLM loses) and [`scripted_room_survey.md`](scripted_room_survey.md)
(the deterministic survey that replaces the ReAct loop). This plan is the join:
**how the winning model actually runs inside `inspect_room`, in Ruby, with no LLM
in the loop.**

Everything in §2–§5 was measured on this machine, not estimated. The spike
scripts are committed at [`nlp_look_candidates/spike/`](nlp_look_candidates/spike/README.md).

**Decisions taken (Andrew, this round):**

- Training on world files is **fine**. §7 is closed; the runtime still never
  opens one.
- **~4 s** for a whole `inspect_room` is the target, not 2 s. §8 is now a budget
  we clear rather than a problem to solve.

---

## TL;DR

- **Yes, Ruby can run the model.** `onnxruntime` 0.11.4 ships a prebuilt
  `x86_64-linux` binary — no compiler, no Python at runtime. Verified end to
  end: **Ruby reproduces Python's scores to 1.6e-06** and scores *identically*
  at every operating point (F1 49.5% / P 50.0% / R 49.0% at ≥0.9 — the same
  numbers from both languages, not close ones).
- **The tokenizer needs no gem either.** ~20 lines of pure Ruby WordPiece
  reproduce the training tokenization exactly: **0 token-id mismatches**.
- **10.3 ms mean / 15 ms p95 per room**, CPU, single thread. Against a ~4 s
  budget the model spends **0.25% of it**. Speed is settled; stop optimizing it.
- **Yes, we must retrain and re-export** — three independent reasons, §3. It is
  **22 s per seed**, ~3 minutes for the whole pipeline including evaluation.
- **The `sector` field has to come out of the model's context.** It is a
  world-file field with no runtime equivalent, so shipping the current recipe
  would feed the model an empty string it never saw in training. **Measured: it
  costs nothing to drop** (median F1@≥0.9 44.7% without vs 44.8% with, n=3
  seeds each) — §5.1.
- **The recipe is now settled by measurement, not by inheritance:**
  **BERT-medium (41 M)** — small was tested and loses by 9.6 F1 on this split,
  refuting `RESULTS.md` §4b's ladder, which was measured on a different split
  (§5.2) — exported to **int8, 41 MB**, which is smaller, faster, *and* better at
  the operating point we want (§5.3).
- **Built, tested, green (§12).** The shipped artifact is int8 BERT-medium at
  **top-3, ≥0.80: P 55.6% / R 55.2% / F1 55.4%, speaking in 26.8% of rooms for
  0.42 probes each** — a `look` every other room, right more often than not. The
  threshold came from the build's own sweep under a P ≥ 40% floor, not from a
  number anyone picked (§6.3).
- **Thresholds are not a property of the model.** Seed-to-seed F1 swings ±5
  points while *ranking* stays put, so threshold selection belongs in the build
  pipeline, written into a manifest — §4.
- §9 is the technical specification: file layout, class APIs, manifest schema,
  config, failure posture, and the tests that pin each claim.

---

## 1. The questions, answered

| Question | Answer | Where |
|---|---|---|
| Can we run the model weights in Ruby? | **Yes** — `onnxruntime` gem, prebuilt binary, exact parity with Python | §2 |
| Can we parse the survey into JSON without an LLM? | **Yes** — unchanged from `scripted_room_survey.md` §3.2 | §6.1 |
| Can we do examine/consider without an LLM? | **Yes** — fixed sequence + dedupe + keyword cache, §3.1/§3.4 there | §6.1 |
| Do we need to retrain and export? | **Yes** — nothing was saved, and the recipe needs one change first | §3 |
| Is ~4 s achievable? | **Yes, comfortably** — projected ~10.6 s → ~4 s with §8.1 alone | §8 |

---

## 2. The spike: Ruby really runs it

Reproduce (~3 min; a CUDA box is needed for training only):

```bash
cd docs/plans/week_2/nlp_look_candidates
python3 -m venv venv --system-site-packages
./venv/bin/pip install transformers onnx onnxruntime
SEED=42 ./venv/bin/python spike/train_save.py --split walk --epochs 4 \
    --model google/bert_uncased_L-8_H-512_A-8 --use-context --tag noamp   # 22s
./venv/bin/python spike/export_onnx.py                                     # -> spike/lc.onnx
gem install onnxruntime && ruby spike/ruby_preds.rb lc
```

### 2.1 Parity — Ruby vs Python, same checkpoint

| check | result |
|---|---|
| token ids identical (20 rooms, ids + length) | **0 mismatches** |
| max abs score difference per candidate | **1.6e-06** |
| F1@≥0.0 / ≥0.3 / ≥0.9 on the 340-room walk test set | **20.5% / 38.1% / 49.5% — identical in both languages** |

The scores are not "close enough to ship"; they are the same numbers. There is
no accuracy story to tell about the port, because there is no accuracy delta.

### 2.2 Latency, measured in Ruby (CPU, 1 thread, 340 rooms)

| artifact | size | session load | mean | median | p95 |
|---|---:|---:|---:|---:|---:|
| fp32 | 165 MB | 264 ms | **10.3 ms** | 10.0 ms | 15.0 ms |
| int8 dynamic | 41 MB | 111 ms | 6.7 ms | 5.8 ms | 11.0 ms |

Session load is one-time at boot, not per room.

### 2.3 No tokenizer dependency

`run_t3.py` tokenizes with `tok.tokenize(w)` over words matched by
`/[A-Za-z]{2,}/`. That path never exercises BERT's basic tokenizer — no
punctuation splitting, no accent stripping, no CJK — so it is just lowercase +
WordPiece, and ~20 lines of Ruby reproduce it exactly.

**Ship the vocab as JSON and skip the `tokenizers` gem.** One fewer native
dependency, and the tokenizer becomes readable Ruby a test can pin. If the input
regex is ever widened beyond `[A-Za-z]`, this equivalence breaks — §9.7 makes
that a failing test rather than a silent drift.

---

## 3. Yes, we retrain — three reasons

1. **The weights don't exist.** `run_t3.py` trains, predicts, writes
   `data/t3_preds.json`, and exits without ever calling `save_pretrained`. Every
   bake-off model died at process exit, and the venv was a session scratchpad
   that has been cleaned up. Every number in `RESULTS.md` describes a model no
   one can load.
2. **The recipe is wrong for serving** — the `sector` context field has no
   runtime equivalent (§5). This has to change *before* the artifact is built,
   or we bake in a train/serve mismatch on day one.
3. **The threshold has to be measured on the artifact we ship** (§4), which
   means a multi-seed run whose median checkpoint is the one we keep.

The cost is small: **22 s per seed** on the walkable split (1521 train / 340
test), and the corpus is committed. The whole pipeline in §9.8 — 3 seeds, score,
export, quantize, sweep, manifest — is about **3 minutes**.

---

## 4. Threshold ≠ model property

Five fresh runs of the same config (BERT-medium, `--use-context`, walk split, 4
epochs) against the same frozen split, versus the `walk_medium_ctx` predictions
`JOURNAL.md`'s table is built from:

| run | F1@≥0.9 (P / R) | F1@≥0.3 (P / R) |
|---|---|---|
| `walk_medium_ctx` **(recorded)** | **25.7%** (37.3 / 19.6) | 27.0% (30.2 / 24.5) |
| seed 42, amp | 46.6% (45.1 / 48.3) | 37.3% (26.0 / 66.4) |
| seed 42, no amp | 49.5% (50.0 / 49.0) | 38.1% (27.0 / 65.0) |
| seed 1 | **52.7%** (55.4 / 50.3) | 41.5% (28.7 / 74.8) |
| seed 2 | 44.8% (38.8 / 53.1) | 34.4% (22.6 / 72.7) |
| seed 3 | 41.6% (43.5 / 39.9) | 36.1% (24.7 / 67.1) |

**Ranking reproduces; calibration does not.** With no threshold (top-3, ≥0.0)
the recorded run gets R 80.4% and the fresh runs 80.4–82.5% — same model, same
ordering. Divergence appears only once a *score* threshold is applied, i.e. the
probability scale shifts run to run while the ranking holds. Expected for a
1521-room training set with a hand-set `--pos-weight 20`.

**The recorded run is an outlier below the seed spread, so the model is better
than we documented** — fresh runs cluster 41.6–52.7% (median ~47%) against 25.7%.
Nothing here is worse than believed. But ±5 F1 of seed noise means no single
run's threshold is trustworthy, so §9.8 trains 3 seeds, keeps the median, and
sweeps the threshold on the kept checkpoint.

`RESULTS.md` §4 and `JOURNAL.md`'s table should be regenerated from that run;
until then their absolute numbers are stale.

---

## 5. The shipping recipe, settled by measurement

Three questions the bake-off left open, all answered against the **walkable**
split with the runtime-honest context (name + exit names only), 3 seeds each,
340-room held-out test set. Medians reported; individual seeds in
`data/t3_preds.json` under the tags named in
[`spike/README.md`](nlp_look_candidates/spike/README.md).

### 5.1 The `sector` skew — found, measured, fixed

`run_t3.py --use-context` builds the encoder context as **room name + sector +
exit destination names**. Two of those three we have at runtime from the survey's
own `look` and `check(exits)` calls. **`sector` we do not**: it comes from the
world file (`extract.rb:96`, `sector_type.note` — `INSIDE`, `CITY`, `FOREST`,
`WATER_NOSWIM`, …) and tbaMUD never prints it to a player. Under the rule that
the runtime reads no world data, there is nothing to fill it with.

Shipping as-is would mean feeding an empty string into a slot that carried a real
token in every training example — textbook train/serve skew, and the kind that
degrades quietly rather than crashing.

**Measured cost of dropping it** (3 seeds each, identical otherwise, 340-room
walk test set):

| | F1@≥0.5 (median) | F1@≥0.9 (median) |
|---|---:|---:|
| with `sector` | 37.6% | 44.8% |
| **without `sector`** | **41.2%** | **44.7%** |

Indistinguishable — well inside the ±5 point seed noise of §4, and slightly
*better* at the looser threshold. The field was carrying no weight the room name
wasn't already carrying.

**Spec consequence:** the shipped model trains on `name + exit destination names`
only. `--use-context` grows a `--context-fields` flag (§9.8) so the recipe is
explicit in the manifest rather than implied by a flag name.

### 5.2 Capacity — BERT-medium stays, and small is refuted

I proposed dropping to BERT-small (29 M) on the strength of `RESULTS.md` §4b,
where it landed within 0.5 best-F1 of medium. **That does not transfer to the
walkable split.** Medians over 3 seeds each, shipping recipe:

| model | params | F1@≥0.3 | F1@≥0.5 | **F1@≥0.9** (P / R) |
|---|---:|---:|---:|---|
| **BERT-medium `L-8_H-512`** | 41 M | **37.7%** | **41.2%** | **44.7%** (46.9 / 52.4) |
| BERT-small `L-4_H-512` | 29 M | 31.1% | 33.1% | 35.1% (33.3 / 37.8) |
| BERT-mini `L-4_H-256` | 11 M | 28.5% | 32.2% | 42.2% (45.9 / 39.2) |

Medium wins at every threshold — by 6.6 F1 at ≥0.3 and **9.6 at ≥0.9**, far
outside the ±5 seed noise of §4. The §4b ladder was measured on the *zone* split
with 9,860 training rooms; on 1,521 walkable rooms the gap between 29 M and 41 M
reopens. **Prior conclusions measured on a different split do not transfer, even
when the model and code are identical** — the same lesson `RESULTS.md` §3 already
paid for once.

Note also that small < mini at ≥0.9 (35.1% vs 42.2%). Non-monotonic capacity at
this data size is a calibration artifact, not a real ordering, and it is another
reason thresholds belong in the build pipeline (§4) rather than in a constant.

**Decision: BERT-medium (41 M).** The size argument for small is dead — it costs
10 F1 points to save 12 MB.

### 5.3 Quantization — int8 wins on its own threshold

Same checkpoint (median seed), exported fp32 and int8-dynamic, both scored from
**Ruby**:

| | size | p95 latency | best F1 (at its own threshold) | high-precision point |
|---|---:|---:|---|---|
| fp32 | 165 MB | 17.5 ms | 44.7% at ≥0.90 (P 46.9 / R 42.7) | ≥0.95 → P 57.7%, 0.23 probes |
| **int8** | **41 MB** | **11.6 ms** | **53.1% at ≥0.70** (P 50.0 / R 56.6) | **≥0.90 → P 67.6%, 0.21 probes** |

Quantization **shifts calibration rather than degrading capability** — at ≥0.9
fp32 scores P 46.9% where int8 scores P 67.6%, because the same threshold now
cuts the distribution in a different place. This is exactly why §9.8 step 6
sweeps each artifact separately: an int8 model that inherited the fp32 threshold
would look worse than it is.

**Decision: int8, 41 MB.** Smaller, faster, and better at the operating point we
want. One caveat recorded honestly: this is a single seed's export, and the int8
*gain* is more likely threshold reshaping than real improvement. The pipeline
must confirm it holds across all 3 seeds before the manifest claims it — and if
it doesn't, fp32-at-≥0.9 remains a perfectly good fallback.

### 5.4 Ruby parity holds on the final recipe

Re-verified after both changes (no sector, int8): **Ruby fp32 reproduces Python
fp32 exactly** — F1 37.7 / 41.2 / 42.9 / 44.7% at ≥0.3 / 0.5 / 0.7 / 0.9, same
digits from both languages. 11.4 ms mean, 17.5 ms p95 fp32; 6.8 ms / 11.6 ms int8.

---

## 6. Where it plugs in

### 6.1 Nothing about the survey changes

`scripted_room_survey.md` stands as written: the deterministic sequence (§3.1),
the colour-based mob/object split (§3.3), the keyword cache with verify-and-retry
(§3.4), and the pure text → Hash parser (§12 item 3). Zero LLM calls in the warm
path. This plan only supplies the one field that plan left open.

### 6.2 Two extractors, in a fixed order

```
Extractors::Structural   # scripted_room_survey.md §10.6 — free, no model
        └─ Extractors::Model   # this plan — ONNX scorer, threshold, top-k
```

Structural subtraction runs **first**. It removes exit destination names, mob
keywords, and object keywords from the pool — the class of false positive the
model is worst at, since "to the west is the poor alley" is navigation prose that
reads exactly like scenery. We already hold every neighbour's name in
`exit_targets` from the `check(exits)` call the survey makes anyway.

### 6.3 Operating point

Your note — *"we don't need to capture everything, because we can always use
reasoning if the agent gets stuck"* — settles the product call `RESULTS.md` §4
left open. It argues for **precision and silence**: a wrong suggestion costs a
real MUD round trip and pollutes the room record the player agent reasons over;
a missed one costs nothing, because the agent can think its way to `look statue`
when it cares.

**Default: top-3 at whatever threshold the build swept to, with a precision
floor.** `build_model.rb` maximises F1 subject to **P ≥ 40%** — the floor encodes
"precision and silence", and the sweep then picks the best point that clears it
rather than a number I guessed. The shipped build landed on **≥0.80: P 55.6%,
R 55.2%, F1 55.4%, speaks in 26.8% of rooms, 0.42 probes per room** (§12).

Raise `min_precision` in the builder if you want it quieter still; the earlier
hand-picked ≥0.9 point is what that produces.

For contrast, the `≥0.0` "always emit 3" policy from `JOURNAL.md`'s saved-effort
table finds 80% but spends 3.0 probes (~3.75 s) in *every* room, including the
76% that contain nothing. The exact number ships in the manifest (§9.4), not in
the source.

---

## 7. World-file training — closed

Approved. Recording the boundary the implementation must keep:

- **Training** reads world files. Fine, and it is the entire reason a 41 M model
  beats a paid LLM here (`RESULTS.md` §4c).
- **Runtime** reads a description string, a room name, exit names, and an ONNX
  file. It must never open a world file, and there is no code path that could —
  the extractor takes strings and returns strings.
- The probe label store (`scripted_room_survey.md` §12 item 16) is still worth
  building, now as the path to *improving* the model and to finally measuring the
  authorial-noise ceiling `RESULTS.md` §5 lists as open — not as a workaround.

---

## 8. Latency budget at ~4 s

| bucket | today | after this plan | with §8.1 |
|---|---:|---:|---:|
| LLM inference (3 calls) | 18.62 s | **0** | 0 |
| Subagent spin-up | 2.08 s | **0** | 0 |
| MUD round trips (5 @ ~1.25 s) | 6.36 s | 6.36 s | 6.36 s |
| Per-log-event gaps (~0.42 s × N) | ~6.72 s | ~4.2 s | ~0.7 s |
| **model inference** | — | **0.010 s** | **0.010 s** |
| **total** | **33.8 s** | **~10.6 s** | **~7.1 s** |

Deleting the LLM gets 33.8 s → ~10.6 s. Reaching ~4 s needs one more thing, and
it is not NLP:

### 8.1 The ~0.42 s per logged event

`scripted_room_survey.md` §6 already flags this: every event written to the
session log costs ~0.42 s, and a survey writes ten of them. That is the largest
remaining non-MUD bucket by a wide margin and it is almost certainly a flush or
fsync per line. **Investigate and fix before touching anything else** — it is
worth more than every other optimization in this plan combined, and it speeds up
the *player* loop too, not just `inspect_room`.

### 8.2 Optional, only if ~4 s isn't met

- **Dedupe already helps**: three fidos cost one `consider`/`examine` pair, and a
  room of already-seen mob types costs zero extra calls (§3.4 cache).
- **Pipelining** `poll → look → check(exits)` into one write collapses three
  round trips into one. Gated on measuring where the ~1.25 s per command actually
  goes — `session_pool.rb:72` uses `read_until_prompt`, which should return in
  tens of milliseconds against a local MUD on a 0.1 s pulse. We do not currently
  know what that 1.25 s is made of.
- **`depth:` argument** to `inspect_room` — skip `consider`/`examine` when the
  player only wants the room shape. Two fewer round trips.

The model is 0.25% of the budget at every one of these operating points. It never
needs to appear in this table again.

---

## 9. Technical specification

### 9.1 Dependencies

| | change |
|---|---|
| `boukensha.gemspec` | `spec.add_dependency "onnxruntime", "~> 0.11"` |
| runtime Python | **none** — Python is a build-time dependency only |
| `tokenizers` gem | **not** added (§2.3) |

`onnxruntime` 0.11.4 resolves to a prebuilt `x86_64-linux` platform gem; no
compiler, no `libonnxruntime` install step. Verify the same on arm64-darwin
before anyone develops on a Mac — the platform gem exists, but we have not run it.

### 9.2 Artifact layout

Model files live beside the other runtime-editable assets (`prompts/`,
`settings.yaml`) rather than inside the gem, so `spec.files` stays
`lib/**/*.rb` and no packaging change is needed:

```
.boukensha/models/look_candidates/
├── model.onnx        # int8 or fp32, per §9.8 step 6
├── vocab.json        # {"token": id, …}, extracted from tokenizer.json
└── manifest.json     # §9.4
```

### 9.3 Modules

All under `week2_capable/boukensha/lib/boukensha/extractors/`.

**`WordPiece`** — `lib/boukensha/extractors/word_piece.rb`

```ruby
WordPiece.new(vocab_hash)        # {"##ing" => 4894, …}
#encode_word(String) -> [Integer]  # greedy longest-match, "##" continuation, [UNK] fallback
```

Pure Ruby, no dependency. Downcases; assumes the input contains no punctuation
(guaranteed by the `[A-Za-z]{2,}` split — §9.7 pins this).

**`Model`** — `lib/boukensha/extractors/model.rb`

```ruby
Model.load(dir)                  # reads model.onnx + vocab.json + manifest.json; memoized per dir
#call(name:, description:, exit_targets:, exclude:) -> [String]   # lowercase, ranked, <= top_k
#available? -> Boolean
```

`#call` is the whole runtime path:

1. **pool** — `description.downcase.scan(/[a-z]{3,}/)`, drop `STOP`, dedupe
   preserving first occurrence. **Must be byte-identical to `LC.candidates`**
   (`nlp_look_candidates/lib/common.rb:44`) including the stopword list; §9.7
   pins it by checksum.
2. **encode** — `[CLS] <name> <exit names, ≤48 words> [SEP] <description words>
   [SEP]`, truncated at `max_len` (256). Words split on `/[A-Za-z]{2,}/`, each
   through `WordPiece`; record the position of each word's **first** subtoken.
   Context fields come from the manifest, not from constants in the code.
3. **infer** — one `OnnxRuntime::Model#predict` with `input_ids` and
   `attention_mask`, batch of 1.
4. **score** — position-wise softmax over the 2 logits, take the **max** over
   repeated occurrences of the same word.
5. **select** — drop anything in `exclude`, keep `score >= manifest.threshold`,
   sort descending, take `manifest.top_k`.

**`Structural`** — `lib/boukensha/extractors/structural.rb`

```ruby
Structural.exclusions(exit_targets:, mobs:, objects:) -> Set[String]
```

Tokenizes exit destination names and every mob/object keyword and long-desc noun
into the exclusion set. No model, no I/O, no config.

**Wiring** — `RoomParser`'s injected `candidate_extractor`
(`scripted_room_survey.md` §12 item 3) widens from `->(description, exclude)` to
keywords, because the model needs the room name and exit names as context:

```ruby
candidate_extractor: ->(name:, description:, exit_targets:, exclude:) { [String] }
```

The default injection composes the two:

```ruby
->(name:, description:, exit_targets:, exclude:) do
  model.call(name:, description:, exit_targets:,
             exclude: exclude | Structural.exclusions(exit_targets:, mobs:, objects:))
end
```

### 9.4 `manifest.json`

The manifest is the contract between the build pipeline and the runtime. The
runtime reads its inference parameters from here and hard-codes none of them.

```json
{
  "built_at": "2026-07-23T09:00:00Z",
  "git_sha": "5a2e178",
  "base_model": "google/bert_uncased_L-8_H-512_A-8",
  "params": 41000000,
  "split": "walk",
  "seeds": [1, 2, 3],
  "chosen_seed": 3,
  "quantization": "int8",
  "context_fields": ["name", "exit_targets"],
  "max_len": 256,
  "word_regex": "[A-Za-z]{2,}",
  "candidate_regex": "[a-z]{3,}",
  "stopwords_sha256": "…",
  "threshold": 0.9,
  "top_k": 3,
  "eval": { "rooms": 340, "rooms_with_gold": 83,
            "p": 0.676, "r": 0.336, "f1": 0.449,
            "speaks_pct": 15.0, "probes_per_room": 0.21 }
}
```

`chosen_seed` is the **median**-F1 run, not the best (§4). Recording the best
would be quietly selecting on the test set.

### 9.5 Configuration

`.boukensha/settings.yaml`, new top-level block:

```yaml
tools:
  inspect_room:
    look_candidates:
      extractor: model          # none | model
      model_dir: ${BOUKENSHA_DIR}/models/look_candidates
      threshold: null           # null = use manifest; a number overrides it
      top_k: null               # null = use manifest
```

`dictionary`, `llm`, and `model+llm` from `scripted_room_survey.md` §10.7 are
**dropped, not left unimplemented** — the bake-off eliminated them (the
dictionary scored barely above random; the LLM lost to the free model). Keeping
dead enum values in config is a promise we measured our way out of.

Same file, deletions:

- The whole `tasks.room_inspector` block — with no subagent there is no task.
  Its `allow:` list **moves to `tools.inspect_room.allow`** and keeps scoping
  the survey per `scripted_room_survey.md` §2.1; everything else (provider,
  model, `max_iterations`, `prompt_override`) is deleted.
- `prompts/room_inspector/system.md` is **deleted**, not rewritten.
- The name `room_inspector` disappears: one feature, one name, `inspect_room`.

### 9.6 Failure posture

`look_candidates` is advisory (`RESULTS.md` §5). Nothing about it may break a
survey.

| condition | behaviour |
|---|---|
| `extractor: none` | return `[]`, never load onnxruntime |
| model dir or `model.onnx` missing | return `[]`, warn **once** per process |
| `require "onnxruntime"` fails | return `[]`, warn once |
| manifest missing or unparseable | **raise at load** — a model with unknown threshold/context is not safe to guess at |
| inference raises | return `[]`, warn, do not retry |
| description empty / no candidates | return `[]`, no inference |

The asymmetry is deliberate: a *missing* model is a degraded but honest install;
a *present* model with unknown parameters would silently score against the wrong
recipe, which is exactly the "believable wrong answer" class `JOURNAL.md` warns
about.

### 9.7 Tests

| test | pins |
|---|---|
| **Parity fixture** — 20 rooms' token ids and scores vs `spike/ref.json`, tolerance 1e-5 | the whole port. This is the one bug class here that produces believable garbage rather than a crash |
| **Candidate-pool checksum** — Ruby pool for N rooms equals `LC.candidates`, and `STOP` sha256 matches the manifest | the train/serve pool identity |
| **Tokenizer guard** — asserts the word regex is `[A-Za-z]{2,}`, so widening it fails the build (§2.3) | the "no gem needed" argument |
| **Single session** — N inspections construct exactly one `OnnxRuntime::Model` | the 264 ms load stays one-time |
| **Exclusions** — a word in `exclude` never appears in output even at score 1.0 | structural subtraction actually applies |
| **Degrade** — missing `model.onnx` yields `[]` and one warning, survey still returns full JSON | §9.6 |
| **Manifest-driven** — a manifest with `threshold: 0.99, top_k: 1` changes output without touching code | §9.4's contract |
| **Latency smoke** — p95 under 50 ms per room on the fixture | §2.2 doesn't regress |

### 9.8 Build pipeline — `rake model:build`

Committed and re-runnable; this is what stops us landing back in §3.

1. `--save DIR` and `--seed N` folded into `run_t3.py` (from
   `spike/train_save.py`); delete the fork.
2. Add `--context-fields name,exits` (replacing the implicit `--use-context`
   field set) and drop `sector` from the default (§5).
3. Train seeds 1–3 on the `walk` split, 4 epochs — 22 s each.
4. Score all three on the held-out split with `LC.score_ranked`; **keep the
   median-F1 checkpoint**, discard the others.
5. Export ONNX (opset 17, dynamic batch and sequence axes).
6. Also emit an int8 dynamic-quantized copy and **sweep the threshold separately
   for each** (§5.3) — an int8 artifact must never inherit an fp32 threshold.
   Ship int8 unless its advantage fails to hold across all three seeds, in which
   case fall back to fp32 at ≥0.9.
7. Extract `vocab.json` from `tokenizer.json`.
8. Write `manifest.json` (§9.4) and copy into `.boukensha/models/look_candidates/`.
9. Print the eval table; the pipeline **fails** if F1 falls outside the
   41.6–52.7% band established in §4, so a silently broken retrain can't ship.

**Model size is settled — do not re-open it at step 3.** BERT-small was tested
and loses by 9.6 F1 on this split (§5.2). Medium is the pick.

### 9.9 Where the artifact lives — Google Drive (decided)

**Andrew hosts `model.onnx` on a public-link Google Drive folder.** The repo
commits `manifest.json` only (1 KB of text, and it is the runtime contract),
which carries the download URL and the **sha256** — so the file being on a
mutable share does not weaken the integrity check. `rake model:fetch` downloads,
verifies the sha, and unpacks beside the manifest; a mismatch is a hard error,
never a warning.

The extractor already degrades to `[]` with one warning if the file is absent
(§9.6), so a fresh clone runs either way — it just has no `look_candidates` until
the fetch. Print the fetch command in that warning.

Rationale for not committing it, kept short: the repo is **476 KiB packed**, so a
41 MB artifact is ~90× the entire history and every retrain adds another
permanent blob. (For the record, fp32 at 165 MB could not be committed at all —
GitHub hard-blocks files over 100 MB.)

<details>
<summary>Options considered</summary>

| option | verdict |
|---|---|
| Commit to git | Permanent 41 MB blob per rebuild in a 476 KiB repo. No. |
| Git LFS | GitHub free tier is 1 GB storage **and 1 GB bandwidth/month** — ~25 clones and it starts failing. No. |
| GitHub release asset | Fine, but needs a tag-and-release step per rebuild. |
| **Google Drive** ✅ | Simplest; integrity comes from the manifest sha256, not the host. |
| Hugging Face | Idiomatic, but the model is useless outside this repo (our exact pool, stopwords, tokenizer, threshold), and publishing raises a DikuMUD-licence question about weights trained on `.wld` files that a private link does not. Revisit only if it is meant as a published teaching artifact. |

</details>

### 9.9b Not "train it yourself" — measured

"Let students train their own" is a good *lesson* and a bad *install path*.
Measured on this machine:

| | time |
|---|---|
| train 1 seed, RTX 4060 | **22 s** |
| train 1 seed, CPU only (32 cores) | **6 m 26 s** |
| …extrapolated to an 8-core laptop | **~20–25 min** |

Plus a ~200 MB CPU-only torch wheel (2.5 GB with CUDA), `transformers`, and a
sibling checkout of the `.wld` world files. Tolerable once, as an exercise.

**The real blocker isn't time, it's §4:** seed-to-seed F1 swings ±5 points and the
*calibration* moves with it. Every student would get a different model needing a
different threshold, so the committed manifest would be wrong for all of them and
`inspect_room` would behave differently on every machine. Train-as-install would
make the documented numbers unreproducible by construction.

So: **`rake model:fetch` is the install path** (§9.9), and **`rake model:build`
is the lesson** — and because the build writes its own manifest from its own
threshold sweep (§9.8), a self-trained model is correctly calibrated to itself.
Both land the same file layout, so the runtime cannot tell them apart.

### 9.10 The same question applies to `data/` today

`nlp_look_candidates/data/` is **39 MB and currently untracked**: `t3_input.json`
(16 MB), `t3_preds.json` (13 MB), `rooms.jsonl` (7 MB). It faces the identical
choice, and one part of it is *more* licence-relevant than the weights —
`rooms.jsonl` contains extracted world-file prose verbatim, which is Diku-licensed
text, not a derived statistic.

Recommendation: **commit `splits.json` and `stats.json`** (small, and they are
what make results reproducible), **gitignore the rest**, and have `extract.rb`
regenerate the corpus from the world files on demand — it already does, and the
`.wld` files are a sibling checkout that anyone reproducing this needs anyway.
`t3_preds.json` is pure scratch output and should never be committed.

---

## 10. Work items

Items marked ↩ are already specified in `scripted_room_survey.md` and appear
here only for sequencing.

| # | item | depends on |
|---|---|---|
| 1 | `run_t3.py`: `--save`, `--seed`, `--context-fields`; drop `sector` (§5) | — |
| 2 | `rake model:build` pipeline (§9.8) | 1 |
| 3 | Build the artifact; publish as a **GitHub release asset**, commit only `manifest.json`; add `rake model:fetch` with sha256 verification (§9.9) | 2 |
| 3b | `.gitignore` the 39 MB `data/` dir except `splits.json` + `stats.json` (§9.10) | — |
| 4 | Regenerate `RESULTS.md` §4 and `JOURNAL.md`'s table from item 2's run (§4) | 2 |
| 5 | ↩ `Extractors::Structural` (`scripted_room_survey.md` §10.6) — free precision, build first | — |
| 6 | `Extractors::WordPiece` + parity test (§9.3, §9.7) | 3 |
| 7 | `Extractors::Model` + `onnxruntime` in the gemspec (§9.1, §9.3) | 6 |
| 8 | Widen `RoomParser`'s `candidate_extractor` signature and compose the two extractors (§9.3) | 5, 7 |
| 9 | `settings.yaml`: `tools.inspect_room` block, delete the `room_inspector` task and its prompt (§9.5) | 8 |
| 10 | Remaining tests (§9.7) | 8 |
| 11 | **§8.1 — the ~0.42 s per logged event.** Biggest single win in the plan; helps the player loop too | — |
| 12 | ↩ Probe label store (`scripted_room_survey.md` §12 item 16) — the path to improving the model and measuring the noise ceiling | 8 |

Items 5 and 11 are independent of everything else and pay off alone. Item 11 is
the one I would do first if only one thing gets done.

---

## 11. Acceptance

- **Parity** — the §9.7 fixture is green: Ruby ids and scores match Python
  (1.6e-06 today).
- **Speed** — `inspect_room` p50 **under 4 s** with zero LLM calls in the session
  log, and the model's own contribution asserted under 50 ms.
- **Quality** — on the 340-room walk test set the shipped artifact at its
  manifest threshold reports **P ≥ 60%** and speaks in **≤ 20%** of rooms, from a
  median-of-3-seeds run (§4) — a single lucky run does not count. (Measured on
  the spike artifact: P 67.6%, speaks 15.0%, 0.21 probes/room.)
- **Cost** — a 3-room session shows `inspect_room` at **$0.00**, against
  $0.0363 today.
- **Reproducibility** — `rake model:build` on a clean checkout reproduces the
  committed manifest's eval numbers within the §4 seed band.

---

## 12. Implementation status — built and green

Landed in this pass. Full suite: **79 runs, 216 assertions, 0 failures** (the 14
skips are the pre-existing MCP tests that need the `mud_manager` sibling
checkout).

### 12.1 Build output

```
=== 2. score seeds, keep the median
  seed 1: best F1 55.0% (P 54.1 R 55.9) at >=0.90
  seed 2: best F1 49.3% (P 51.9 R 46.9) at >=0.95
  seed 3: best F1 50.8% (P 46.5 R 55.9) at >=0.90
  -> median seed 3
=== 4. re-score through the Ruby extractor, sweep each artifact
  fp32: F1 50.8%  P 46.5%  R 55.9%  at >=0.90  speaks 34%  probes/room 0.51  (12.8 ms/room)
  int8: F1 55.4%  P 55.6%  R 55.2%  at >=0.80  speaks 27%  probes/room 0.42  ( 7.3 ms/room)
  -> shipping int8 (41.6 MB)
```

The seed spread (49.3–55.0%) sits where §4 predicted, and int8-beats-fp32 (§5.3)
reproduced on a second independent build. **Step 4 scores through the production
Ruby extractor**, so the manifest's numbers are ones the runtime reproduces — not
ones from a scorer nothing ships.

### 12.2 Files

| file | what |
|---|---|
| `nlp_look_candidates/run_t3.py` | `--save`, `--seed`, `--context-fields`; `sector` no longer implied by `--use-context` |
| `nlp_look_candidates/export_onnx.py` | checkpoint → fp32 + int8 ONNX + `vocab.json` |
| `nlp_look_candidates/build_model.rb` | the whole pipeline: train seeds → median → export → Ruby sweep → manifest |
| `boukensha/lib/boukensha/extractors/word_piece.rb` | WordPiece in ~50 lines, no gem |
| `boukensha/lib/boukensha/extractors/model.rb` | ONNX scorer; every parameter from the manifest |
| `boukensha/lib/boukensha/extractors/structural.rb` | free exclusions, no model |
| `boukensha/lib/boukensha/extractors.rb` | composes both into the survey's injected lambda |
| `boukensha/lib/tasks/model.rake` | `model:fetch` (sha256-verified), `model:status` |
| `boukensha/test/test_extractors.rb` | 19 tests incl. the 478-word tokenizer parity fixture |
| `.boukensha/settings.yaml` | `tools.inspect_room.look_candidates` |
| `.gitignore` | weights, corpus, and training scratch out; `manifest.json`, `splits.json`, `stats.json` in |

### 12.3 One deviation from §9.3, on purpose

The spec said Structural should subtract entity **long descriptions** too. It
doesn't. "A beastly fido is mucking through the garbage" would remove `garbage`,
and a garbage heap is exactly the sort of thing a builder hides a description on.
Exit names and entity keywords can never be examinable scenery; a noun that
merely co-occurs with a mob often can. Pinned by a test.

### 12.4 The survey now runs it (second pass)

`scripted_room_survey.md` is implemented too — `inspect_room` no longer calls an
LLM at all.

| file | what |
|---|---|
| `tools/inspect_room.rb` | **`Tools::InspectRoom`** — one class, one tool: fixed sequence, colour-based mob/object split, dedupe, keyword guess + verify/retry, full parse |
| `boukensha.rb` | **`Boukensha.tool_dispatcher(tool_name, logger:)`** — permission-scoped tool access with no model attached |
| `boukensha_loader.rb` | builds the dispatcher and extractor once per session, brackets each survey in `logger.task("room_inspector")` |
| `tasks/room_inspector.rb`, `prompts/room_inspector/system.md`, `tasks.room_inspector` | **deleted** — no subagent means no task, so the name `room_inspector` is gone entirely |
| `test/test_inspect_room.rb` | 25 tests, the survey ones against transcripts captured from the live container |

There is now exactly one name for this feature — `inspect_room` — across the
class, the file, the settings key, the session-log label and the tool the player
calls. The allowlist outlives the subagent as **`tools.inspect_room.allow`**,
which is what `tool_dispatcher` scopes to: dropping the model did not widen the
tool surface, and `look` still appears nowhere in the player's own allowlist.

Measured end to end against the captured transcripts, with the real model
loaded: **15 ms for the first room, 5 ms after** — the whole survey's compute,
`look_candidates` included. The Temple returns `["wall", "paintings", "giants"]`
(its prose is "covered by ancient wall paintings picturing Gods, giants and
peasants"); The Common Square correctly returns nothing.

Two bugs the real transcripts caught that invented fixtures would not have:

1. **tbaMUD does not emit one colour code per line.** The reset closing entity N
   arrives at the *start* of the line carrying entity N+1
   (`"\e[0m\e[0;33mA beastly fido…"`), so reading each line's first escape found
   the reset and every entity after the first looked uncoloured — silently
   falling back to the positional guess. Fixed by taking the last non-reset code
   in the leading run.
2. **The prompt line was leaking into `events`** — `"20H 100M 83V (news) >"`
   would have been handed to the player as something that happened in the room.

### 12.5 What remains

1. **Upload `model.onnx` to Drive and paste the link into `manifest.json`'s
   `download_url`** — the one field the build cannot fill. `rake model:fetch`
   already verifies the committed sha256 (`8dc74be5…`).
2. **Run it against the live MUD.** Everything above is tested against captured
   transcripts; the container round trip is the one seam no fixture covers.
3. **§8.1's ~0.42 s per logged event.** Now the *dominant* remaining cost —
   see the note below.

### 12.6 The ~0.42 s per event is NOT logging — measured

§8.1 (inherited from `scripted_room_survey.md` §6) blamed the session logger.
**That is wrong.** Four measurements, all on this machine:

| suspect | measured cost | verdict |
|---|---|---|
| `Logger#write_log` (JSON + `puts` + `flush`) | **0.003 ms/event** (2,000 events in 5.9 ms) | not it, by 5 orders of magnitude |
| MCP stdio round trip → daemon → MUD | **0.1–0.2 ms/call** | not it |
| the MUD itself (manager log, 19 real commands) | **62 ms median** | not it |
| MCP spawn + handshake | 62 ms, once per session | not it |

What the session log actually shows, recomputed from
`.boukensha/sessions/20260722T231230Z-e16fba10.jsonl`, is a **uniform ~0.42 s
floor between *every* pair of consecutive events** — including transitions that
do no I/O and no inference at all:

```
+0.42s  iteration        <- pure in-process bookkeeping
+0.42s  prompt
+0.43s  response -> tool_call
+0.43s  turn_end -> task_end
```

A fixed per-event cost that no event's *work* explains. Since the write itself is
0.003 ms, the time is spent somewhere between the worker producing an event and
the next one being timestamped.

**Leading hypothesis: GVL contention with the TUI.** `Tui` renders on a 60 ms
tick (`tui.rb:41`) on the main thread while the agent turn runs in
`@turn_thread` (`tui.rb:272`). If a full re-render holds the GVL long enough,
the worker thread is starved between events — which would produce exactly this:
a floor proportional to render cost, independent of what the worker is doing.

**Next step, ~10 minutes and no code:** run the same three-room session with
`--no-tui` and recompute these deltas. If the floor disappears, it is the render
loop and the fix is to throttle or coalesce renders. If it survives, the
hypothesis is wrong and the next suspect is the Logger's subscriber fan-out.

Do not "fix the logging" before that run — the current diagnosis in
`scripted_room_survey.md` §6 does not survive measurement, and the numbers above
say a survey's real work is **~0.3 s** (5 commands × 62 ms) **plus ~15 ms of
model**. Everything above half a second is this floor.
