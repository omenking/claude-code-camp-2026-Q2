# Tier Bake-off — Measured Results

All tiers run against the same corpus (12,668 rooms), the same frozen splits, the
same candidate pool (`LC.candidates`), and the same scoring code (`LC.score_ranked`).
Reproduce: `ruby run_t0.rb`, `ruby run_t1.rb`, `ruby run_t1_ablation.rb`,
`ruby run_t2.rb`, `python run_t3.py --split zone && ruby run_t3.rb`.

**Zone split is the headline.** 151 train zones / 38 held-out zones — unseen
authors, unseen vocabulary. That is the deployment condition as the bot explores.

---

## 1. Headline table — zone split

| Tier | | P@3 | R@3 | **F1@3** | **PR-AUC** | best-threshold F1 |
|---|---|---:|---:|---:|---:|---:|
| T0a | predict nothing | 0.0% | 0.0% | 0.0% | 0.0% | 0.0% |
| T0b | all content words | 1.1% | 13.3% | 2.0% | 2.1% | 1.4% |
| T0c | learned dictionary | 3.1% | 37.1% | 5.7% | 3.6% | 11.8% |
| T0d | dictionary × purity | 3.9% | 45.6% | **7.2%** | 5.2% | 12.6% |
| T1 | logistic regression | 3.6% | 45.6% | 6.7% | 6.1% | 12.6% |
| T1b | logreg, lex+context (no suffix) | 3.6% | 44.8% | 6.6% | 7.8% | — |
| T2 | fastText | 3.1% | 39.5% | 5.8% | 7.1% | 12.1% |
| **T3** | **BERT-mini token classification** | **4.2%** | **53.1%** | **7.8%** | **14.2%** | **18.9%** |

Candidate recall ceiling on this split: **69.8%** (§3.1 of DATASET.md — a large
share of gold aliases never appear in the description at all).

**T3 wins, and not narrowly.** PR-AUC 14.2% is ~1.8× the best non-transformer
(7.8%), and best-threshold F1 18.9% is +50% over the 12.6% that T0d/T1 plateau at.
Every non-contextual tier — lexicon, hand-built features, subword n-grams —
clusters in a band between 5.7% and 7.2% F1@3 and 3.6–7.8% PR-AUC. They are, for
practical purposes, the same model wearing different hats.

That is exactly what DATASET.md §3.1 predicted: median word purity is 8.6%, so
`wall` is examinable 3.7% of the time. Whether a noun is examinable is a property
of the room, not the word, and only the contextual encoder can represent it.

---

## 2. Why T1 failed — ablation

Zone split, 3 epochs, feature families isolated:

| Feature set | P@3 | R@3 | F1@3 | PR-AUC |
|---|---:|---:|---:|---:|
| lexical only | 3.3% | 41.9% | 6.2% | 6.4% |
| context only | 2.0% | 25.3% | 3.7% | 2.6% |
| context + structural | 2.2% | 27.5% | 4.0% | 4.0% |
| **lexical + context** | 3.6% | 44.8% | 6.6% | **7.8%** |
| everything (incl. suffix n-grams) | 3.6% | 45.4% | 6.7% | 6.1% |

Three readings:

1. **There is real context signal.** Context-only (F1 3.7%) nearly doubles the
   all-words floor (2.0%) without using word identity at all.
2. **But hand-built context is weak.** Adding it to lexical moves PR-AUC 6.4% →
   7.8%. Real, ~22% relative, and nowhere near T3's 14.2%. The signal exists; my
   nine hand-designed proxies capture a fraction of it.
3. **Suffix n-grams actively hurt** (PR-AUC 7.8% → 6.1%). The learned weights make
   the failure obvious — top features were `suf4=dule`, `suf4=yphs`, `suf4=hbox`:
   memorized rare strings, not morphology. **Drop them.**

The top-weighted feature overall was `purity` (+8.3), i.e. T1 largely re-derived
the T0d lexicon and added a little context on top. That is a faithful description
of what a bag-of-features model can do here.

---

## 3. The zone/room split gap is real and large

Same models, same code, only the split differs:

| Tier | PR-AUC (zone) | PR-AUC (room) | inflation |
|---|---:|---:|---:|
| T0d dictionary × purity | 5.2% | 13.9% | 2.7× |
| T1 logistic regression | 6.1% | 13.4% | 2.2× |
| T2 fastText | 7.1% | **22.2%** | **3.1×** |
| T3 BERT-mini | **14.2%** | **31.4%** | 2.2× |

fastText is the most flattered, which makes sense — subword n-grams memorize
zone-specific vocabulary very efficiently. Had we evaluated on the room split at
the time T3 had not yet run, T2 would have looked like the winner
(best-threshold F1 25.3% vs T1's 17.1%) and we would have shipped a model that
mostly recognizes zones it has already read.

Two further readings now that T3's room number is in:

- **T3 wins on both splits** (room: PR-AUC 31.4%, best-threshold F1 26.6%), so the
  conclusion is not an artifact of the split choice — it is robust to it.
- **T3 is the *least* inflated of the strong tiers** (2.2× vs fastText's 3.1×).
  It is not just scoring higher, it is leaning less on memorized vocabulary to do
  it — which is the property we actually want as the bot walks into new zones.

**This is the single most consequential decision in the whole plan**, and it was
nearly wrong: the first version of `README.md` §12.2 specified a room-level split.

---

## 4. Product policy — "always emit top-3" is the wrong default

87.6% of rooms have no examinable scenery, so emitting three guesses everywhere
manufactures false positives. Gating on score fixes most of it (T3, zone split):

| policy | P | R | F1 | rooms with output |
|---|---:|---:|---:|---:|
| top-3, no threshold | 4.2% | 53.1% | 7.8% | 100.0% |
| top-3, score ≥ 0.3 | 9.3% | 36.2% | 14.8% | 45.6% |
| top-3, score ≥ 0.5 | 10.1% | 29.0% | 15.0% | 36.2% |
| top-3, score ≥ 0.7 | 14.0% | 23.5% | 17.6% | 20.3% |
| **top-1, score ≥ 0.7** | **19.4%** | 16.7% | **18.0%** | 20.3% |
| top-3, score ≥ 0.9 | 25.0% | 13.3% | 17.3% | 8.8% |

*Reference: 14.7% of test rooms actually have gold.*

Thresholding more than doubles F1 (7.8% → 18.0%) purely by choosing when to stay
silent — and the model is reasonably calibrated: at ≥0.7 it speaks in 20.3% of
rooms against a true base rate of 14.7%.

The operating point is a product call, not a model property:

- **≥0.9** — speaks in 9% of rooms, right 1 time in 4. Highest confidence.
- **≥0.7, top-1** — speaks in 20% of rooms, right 1 in 5, best F1.

At ~1.2s per `look` probe, ≥0.9 costs the player ~3.6s per room it speaks in to
find real hidden scenery a quarter of the time.

---

## 4b. Capacity ladder — is this capacity-limited or noise-limited?

The Python dependency constraint was lifted, so the question became *what actually
solves this*. Two changes from the §1 run: the encoder now also sees **room name,
sector, and exit destination names** as unlabelled context (T1 had these as
`in_name`/`in_exit` features; T3 originally did not), and model size sweeps
11M → 110M. All zone split, 4 epochs, identical data and scorer.
Run: `bash /tmp/ladder.sh`, then `ruby compare_t3.rb`.

| Model | params | ctx | P@3 | R@3 | F1@3 | **PR-AUC** | **best F1** |
|---|---:|:--:|---:|---:|---:|---:|---:|
| BERT-mini `L-4_H-256` | 11.2M | — | 4.2% | 53.1% | 7.8% | 14.2% | 18.9% |
| BERT-mini | 11.2M | ✓ | 4.2% | 53.1% | 7.8% | 15.8% | 21.8% |
| BERT-small `L-4_H-512` | 29M | ✓ | 4.4% | 54.9% | 8.1% | 18.0% | 22.6% |
| BERT-medium `L-8_H-512` | 41M | ✓ | 4.3% | 54.4% | 8.0% | 19.2% | 23.1% |
| BERT-base | 110M | ✓ | 4.0% | 50.2% | 7.4% | **21.9%** | **23.5%** |

**Adding room/exit context is free and worth it**: PR-AUC 14.2% → 15.8%, best F1
18.9% → 21.8% at identical model size.

**Capacity helps, then flattens.** Best-F1 gains per step: +0.8, +0.5, +0.4 —
clearly asymptotic. PR-AUC is still climbing at 110M, so ranking keeps improving
even as the thresholded decision does not. BERT-base also **overfit hard** (train
loss 0.010 vs mini's 0.084) with no regularisation or early stopping, so its
110M-parameter advantage is partly wasted — a tuned base model would likely do
better than 23.5%, but not dramatically.

**Practical pick: BERT-medium (41M).** It matches base on F1 (23.1% vs 23.5%),
trains in ~2 min on the 4060, and has better recall at usable thresholds:

| policy | medium (41M) | base (110M) |
|---|---|---|
| top-3, ≥0.3 | P 19.4% / R 30.9% / **F1 23.9%** | P 27.8% / R 18.1% / F1 21.9% |
| top-3, ≥0.9 | P 31.8% / R 16.7% | P **40.3%** / R 10.7% |

Base is sharper (higher precision, speaks in only 4.6–10% of rooms); medium is
better balanced. Which you want is the product call from §4 — base if a wrong
suggestion is costly, medium if a missed one is.

**Engineering note:** BERT-base at bs32/fp32 exhausted the 4060's 8 GB and ran at
~0.2 steps/s. With `--amp` (mixed precision) and bs16 it runs at ~8 steps/s — a
~40× wall-clock difference. Any future scaling work should use `--amp` by default.

---

## 4c. TL — the LLM reference (and it loses)

README §8 item 10 called for an LLM reference point. Run locally against ollama
(`qwen3.5`, 6.6 GB, zero-shot) so it costs nothing: `ruby run_tl_local.rb 400 qwen3.5:latest`.
400 rooms sampled from the zone test split at the natural base rate.

| | P | R | F1 | speaks in |
|---|---:|---:|---:|---:|
| **TL — qwen3.5 7B zero-shot** | 9.2% | 25.9% | **13.5%** | 45% of rooms |
| **T3 — BERT-medium 41M, ≥0.3** | 19.4% | 30.9% | **23.9%** | 21% of rooms |
| T3 — BERT-base 110M, ≥0.3 | 27.8% | 18.1% | 21.9% | 10% of rooms |

**A 41M-parameter model trained on the world files beats a 7B zero-shot LLM by
10 F1 points — on both precision and recall simultaneously.** The LLM also
over-fires badly, emitting suggestions in 45% of rooms against a 18.8% base rate;
it has no calibration for "most rooms have nothing."

Two consequences:

1. **The distillation plan in `../scripted_room_survey.md` §10.5 is dead as
   written.** "Use Haiku as a teacher, then train a local model" only works if the
   teacher is better than the student. Here the student wins by a wide margin,
   because it has something the LLM does not: 9,860 rooms of ground truth from the
   world files. Supervision beats priors on this task.
2. **Option B (per-room Haiku call) is very hard to justify.** It would need to
   beat 23.9% F1 to be worth $0.0007/room and ~1.4s, when the local model is free
   and ~10 ms.

**Caveats, stated plainly.** This is one 7B open model, zero-shot, with a
prompt I wrote in one pass — no few-shot examples, no prompt iteration, no
calibration instruction. Haiku 4.5 would likely do better and has **not** been
run. I would not claim "LLMs can't do this"; I would claim the burden of proof
has moved, and the free trained model is now the thing to beat rather than the
fallback.

Also worth recording as a debugging trap: qwen3.5 is a reasoning model, and
without `think: false` the whole token budget goes to a hidden reasoning block,
returning an empty string with `done_reason: "length"`. The first two TL runs
scored a clean 0.0% F1 for exactly this reason and looked like a real result.
`run_tl_local.rb` now raises on an empty response rather than scoring it as zero.

---

## 5. Honest assessment

**T3 is the winner and the recommendation**, with caveats worth stating plainly:

**Absolute numbers are low.** Best precision at a useful operating point is 25%.
This is a hard task with three stacked ceilings: 69.8% of gold is even reachable
from description text on this split, ~90% of positive word types are contested,
and authorial noise (README §7.4) is still unmeasured and caps everything above.
Do not expect this field to be reliable — it is advisory, which is what
`look_candidates` was always specified to be.

**A Python dependency is accepted**, so the ONNX export is no longer required.
Training and inference both run on `torch` + `transformers`. Inference for a
41M model is ~10 ms/room on GPU and still well under the ~1.2 s MUD round trip
on CPU, so this stays far cheaper than the API call it replaces.

**We are near, but not at, the plateau.** Capacity gains are asymptotic
(+0.8/+0.5/+0.4 best-F1 across 11M→29M→41M→110M) and BERT-base overfit without
regularisation. Remaining headroom is more likely in **data and framing** than in
parameters: early stopping and weight decay on base, a room-level "does this room
have anything?" gate (87.6% of rooms are empty and that is a much easier
classification), and the §4.2 head-noun scoring question.

**The authorial-noise ceiling is still unmeasured** (README §7.4). We now know
the task is not *purely* noise-limited — scaling still moves the metric — but we
do not know how much of the remaining ~76% error is a builder's coin-flip. That
study remains the highest-value cheap experiment, and it should be run before
anyone invests in a larger model.

**Haiku has not been run.** §4c used a local 7B zero-shot as the LLM reference.
Haiku 4.5 could plausibly beat it, though it would have to clear 23.9% F1 to
change the recommendation.

---

## 6. What changed vs. the plan's assumptions

| Prior claim | Result |
|---|---|
| "T3 is almost certainly overkill; the task is ~90% lexical" | **Wrong.** T3 is the only tier that breaks the plateau. |
| "Dictionary is free, instant, and the sensible default" | **Wrong at the honest split.** F1@3 7.2% but PR-AUC 5.2%, and it cannot rank. |
| "T1 pure-Ruby logreg is where I'd start and probably end" | **Half wrong.** Good starting point, but it plateaus at the lexicon and the context features underperform. |
| "Subtract exit-destination names" (README §10.6) | **Already disproved**; kept as a feature (`in_exit`), which the ablation shows contributes via the structural set. |
| Zone-level split matters | **Confirmed, 2.2–3.1× inflation.** |
