# Journal — Teaching the Agent to Spot Hidden Scenery

Supporting detail: [README.md](README.md) (the plan), [DATASET.md](DATASET.md)
(corpus + label quality), [RESULTS.md](RESULTS.md) (every measurement).

## Technical Goal

Our `inspect_room` tool was slow and expensive — 34 seconds and 3 LLM calls per
room. Almost all of that work is mechanical and a Ruby script can do it: room
name, exits, mobs, objects, events are all parseable from what the MUD prints.

One field resisted. `look_candidates` asks: *which nouns in this room's
description are worth trying `look <noun>` on?* MUD builders hide extra detail
behind ordinary words — a statue you can examine, a drain you can reach into —
and the game never lists them. You have to guess from the prose.

The goal was to find out whether a machine can make that guess well enough to be
worth shipping, and if so, what kind of machine.

## Technical Uncertainty

Three things we couldn't answer by reasoning:

1. **Is this even learnable, or is it an author's whim?** Whether a builder
   bothered to write a description for the statue is partly a coin flip. If it's
   mostly coin flip, no amount of cleverness helps.
2. **How much machinery does it need?** A word list? A small classifier? A
   neural network? An LLM? Each step up costs more to build and run.
3. **Is paying an LLM per room worth it?** That was the original design, and it
   sets the bar everything else has to clear.

## Technical Hypotheses

I made four confident predictions. **Three were wrong**, which turned out to be
the most useful part of the exercise.

| Prediction | Outcome |
|---|---|
| Subtract the names of neighbouring rooms — they're navigation, not scenery | **Wrong.** Made it worse. Rooms are often named after the very thing you can examine next door. |
| The task is basically vocabulary, so a neural network is overkill | **Wrong.** Vocabulary is nearly useless here; only a context-aware model made real progress. |
| A learned word list is the sensible free default | **Wrong.** Scored barely above random once measured honestly. |
| Use an LLM as a "teacher" to train a cheap local model | **Wrong.** The student beat the teacher, because the game's own files are better supervision than an LLM's guesswork. |

## Technical Observations

### The game already knows the answers

CircleMUD/tbaMUD world files record every hidden description explicitly. That
turned a judgement problem into a supervised one: **12,668 rooms with ground
truth**, free. And because our Docker container mounts those very files, the
labels describe exactly the game we play — no assumptions needed.

This is the single most important move in the whole project. Everything after it
is ordinary engineering.

### How we measured mattered far more than what we built

Two evaluation decisions each moved the results more than any model change:

**Splitting by zone instead of by room.** Rooms in the same zone share an author
and a vocabulary. Testing on rooms from zones we'd trained on inflated scores by
2–3× and made the *worst* approach look like the best. Had we not caught it,
we'd have shipped a model that mostly recognises places it has already seen.

**Only training on rooms you can walk to.** Andrew spotted this: tbaMUD ships
~150 builder scratch zones with names like *"Ultima Description Room"* that no
player can reach. They were **85% of our data**. Walking the map from Midgaard's
temple found the 1,861 rooms that are actually reachable — and that turns out to
be essentially the stock CircleMUD world.

Training on a sixth of the data, but the *right* sixth, beat every larger model
trained on everything. Hidden scenery is nearly twice as common in the real world
(21.9% of rooms) as in the scratch zones, so the full corpus was teaching the
model the wrong base rate.

### The hard part is that words don't have fixed answers

Whether `wall` is examinable depends entirely on the room. Across the corpus,
seeing "wall" in a description means it's examinable **3.7% of the time**; "path"
6.7%; "trees" 12.8%. Nine out of ten words that are ever examinable are also
frequently *not*.

That single fact explains why word lists fail and why context-aware models were
the only ones that improved. It's also why I was wrong to call the neural network
overkill.

### What we ended up with

A small neural network (41M parameters — tiny by modern standards, trains in
about two minutes on a desktop GPU) that reads the description and scores each
word.

The useful way to think about its value isn't accuracy — it's **saved effort**:

| approach | words probed per room | time per room | hidden things found |
|---|---:|---:|---:|
| try every word | 20.4 | 24.5s | 89.5% (the ceiling) |
| **our model, top 3** | **3.0** | **3.6s** | **80.4%** |
| do nothing | 0 | 0s | 0% |

**Seven times less probing for ninety percent of what's findable.** The remaining
10% is unreachable by anything — scenery the room text never mentions at all.

### Paying for an LLM didn't buy anything

We tested Haiku properly, on the same rooms and the same scoring:

| | precision | recall | cost |
|---|---:|---:|---:|
| Our free model | **30%** | 25% | $0 |
| Haiku, best setup | 20% | **39%** | $0.037 per 340 rooms |
| Haiku with worked examples | 21% | 25% | $0.040 |
| Haiku, one room per call with memory | 11% | 42% | **$4.32** at full scale |
| A small local open model | — | — | roughly half as good |

Haiku and our model are **level overall** — they just fail differently. Haiku
guesses more and catches more; ours guesses less and is right more often. Nothing
here justifies paying per room for a model that a free one matches.

Two side findings worth keeping:

- **Adding worked examples made it worse.** My examples over-emphasised empty
  rooms, so the model went quiet and lost a third of its recall. That's a lesson
  about my prompt, not about few-shot prompting.
- **Giving it conversational memory made it much worse and cost 15× more.**
  Seeing its own previous answers pushed it toward always answering, which is
  exactly wrong when most rooms contain nothing.

### A related question with a completely different answer

*"If there's a locked door, can we work out what might contain the key?"*

This one needs no AI at all. Doors name their key, and the world files record
where every object spawns. Across all 947 locked doors:

- **61% of keys are carried by a monster** — you fight or steal, you don't search
- 21% lie loose in some room
- 16% are placed by quest scripts
- **2% are inside a container**

So "look inside something" is the *rarest* answer. The intuition that you search
furniture for keys is mostly wrong in this game — usually somebody is holding it.

### Two bugs that produced believable wrong answers

Both would have shipped a false conclusion if unexamined, and both looked like
legitimate results:

1. A local model returned empty answers because it spent its whole budget on
   hidden "thinking" — scoring a clean 0%, which read as "this model can't do the
   task."
2. A failed edit meant one experiment was scored against the wrong set of rooms,
   making Andrew's walkable-rooms idea look like a failure when it was the
   biggest win of the project.

Silent zeros and mismatched comparisons don't announce themselves. Both scripts
now refuse to score rather than quietly return nothing.

## Technical Conclusions

**It is learnable, but only just, and only with context.** The best setup finds
about 80% of hidden scenery for 3 probes per room. That's genuinely useful for a
bot that's exploring anyway, and not accurate enough to present to a human as
fact.

**A tiny trained model beats a paid LLM here**, because the game ships perfect
training data and the LLM only has priors. That flips the original design: we
planned to use the LLM as a teacher, and it turns out to be the weaker party.

**Careful evaluation was worth more than any modelling choice.** The two biggest
improvements came from deciding what to *measure* and what data to *exclude* —
not from bigger models. Model size gave diminishing returns after about 40M
parameters.

**Still open:**

- **How good could anything be?** We never measured how much is pure authorial
  whim. Until we do, we can't tell "our model is mediocre" from "the task is
  unpredictable." This is the cheapest remaining experiment and should come first.
- **Would a smarter LLM help?** We tested Haiku, the cheap tier. Sonnet or Opus
  is untested (~$0.11 for a full run).
- **Would combining approaches help?** Our model is precise, Haiku catches more.
  If they find *different* things, using both could beat either. One re-run
  (~$0.04) would settle it.
- **A design question, not a technical one:** should the bot be allowed to read
  world files directly? It would make hidden scenery and key locations exact —
  and remove the puzzle entirely.

**Total spent on API calls for all of this: $0.13.**

[Human Notes]
- the models should never read world data files because a real player would not have access to them.
- we don't need to capture everything, because we can always use reasoning if the agent gets stuck for deeper thinking.
- speed is what matters, this detect_candidates is a sub-feature of inspect_room which has to perform other calls, and overall we would want that upper action to take 2s or less if possible. 
- can we load our model into ruby? it would be nice if we could.

## Key Takeaway

The game's own world files were better teachers than a paid language model — and
deciding what to measure, and which data to throw away, mattered far more than
how big a model we trained.
