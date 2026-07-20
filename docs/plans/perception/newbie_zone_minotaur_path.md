# Newbie Zone — Path to the Great Minotaur

A walkthrough for finding and defeating the Minotaur in the newbie zone,
traced from the game data in `week0_explore/infrastructure/lib`.

## The setup

- **Newbie Zone** = zone 186 (rooms 18600–18699), builder "Maynard".
- **Entrance:** room `18600` — *The Entrance To The Newbie Zone*.
- **Target:** `the massive Minotaur` (mob `18609`), spawned in room `18629` — *The Red Room*.
- **Drops:** *the horns of the Minotaur* (obj `18610`) and *the smelly hide of the Minotaur* (obj `18611`) — he's wearing both, so they fall when he dies.

## Path backwards (how the route was traced)

Working back from the kill room via room exits:

```
18629 ← 18630 ← 18624 ← 18623 ← 18627 ← 18632 ← 18612 ← 18611 ← 18607 ← 18603 ← 18602 ← 18601 ← 18600
```

## Walkthrough forward (what the player types)

From the entrance (18600), the shortest route is **12 moves**:

| #  | Command                  | Arrive at                        |
|----|--------------------------|----------------------------------|
| 1  | `north`                  | 18601 Beginning Of The Passage   |
| 2  | `east`                   | 18602 The Dirty Hallway          |
| 3  | `east`                   | 18603 A Nexus                    |
| 4  | `south`                  | 18607 More Of The Hallway        |
| 5  | `south`                  | 18611 Another Corner             |
| 6  | `open door` then `east`  | 18612 The Alchemist's Room *(closed door)* |
| 7  | `down`                   | 18632 The Entrance               |
| 8  | `north`                  | 18627 A Crossing Of Corridors    |
| 9  | `north`                  | 18623 A Corner In The Hallway    |
| 10 | `east`                   | 18624 Another Turn               |
| 11 | `south`                  | 18630 A Branching Passage        |
| 12 | `west`                   | **18629 The Red Room — the Minotaur** |

**Speedwalk:** `n e e s s` → `open door; e` → `d n n e s w`

The only obstacle is the closed door between *Another Corner* (18611) and
*The Alchemist's Room* (18612) — it's a plain door, **no key needed**, just
`open door`. (The "wee little key" the Alchemist carries is for something
else, not this route.)

## Aggressive mobs (attack unprovoked)

Three mobs attack on sight, and **all three are on the route to the Minotaur**:

| Mob                        | Room                  | Behavior                                                                 |
|----------------------------|-----------------------|--------------------------------------------------------------------------|
| **the quasit** (18608)     | **18627** *(step 8)*  | `AGGRESSIVE` — attacks anyone. Also `WIMPY`, flees at low HP. Evil (−800).|
| **the zombiefied newbie** (18607) | **18624** *(step 10)* | `AGGRESSIVE` — attacks any alignment. Also spawns off-path in 18620/18633/18637. |
| **the massive Minotaur** (18609)  | 18629 *(target)*      | `AGGR_GOOD` + `AGGR_NEUTRAL` — auto-attacks good/neutral chars. **Not** aggressive to evil, so an evil char gets the first swing. |

Everything else in the zone is passive (newbie monsters, baby dragon, Guard,
Alchemist, pit beast, creepy crawlers) — they only fight if you hit them. The
off-path **dark spectre** (18639) is passive but has `MEMORY`, so it hunts you
if you flee after starting a fight.

**Expect two forced fights before the Minotaur:** the quasit (18627) and the
zombiefied newbie (18624).

## Gear to grab first

A full newbie starter kit is scattered across mobs (kill the mob, loot the
corpse). AC-apply values: **lower is better**.

**Weapons**

- **glowing newbie mace** (18614) — **2d6 (2–12 dmg)**, AC −2. On *the smart
  newbie* in **18645** (off-path detour, ~30% spawn). Best newbie weapon —
  worth the side-trip.
- **shiny newbie dagger** (18606) — 1d4, +1 mana. On the newbie monster in
  **18607**, **right on the path** (step 4). Grab-and-go backup.

**Armor**

| Item                        | Slot / bonus              | Where                          |
|-----------------------------|---------------------------|--------------------------------|
| bright green newbie vest (18602) | torso, AC 4          | newbie monster, **start room 18600** |
| pet dragon collar (18607)   | neck, +1 HP, AC −1        | baby dragon, **18602** (on path) |
| cool newbie sleeves (18613) | arms, AC 4, +1 INT        | smart newbie, **18645** (detour) |
| cool newbie leggings (18612)| legs, AC 4                | smart newbie, **18645** (detour) |
| bright newbie helm (18603)  | head, AC 3, +1 CON        | Newbie Guard, **18606** (key detour) |
| newbie signet ring (18605)  | finger, AC −2             | Newbie Guard, **18606** (key detour) |
| dark newbie cloak (18604)   | body, AC −3, +1 WIS       | pit beast, **18605** (behind locked grate) |

**The Minotaur's own drops** (reward, not prep): **horns** (18610, +1 STR) and
the **smelly hide** (18611) — the hide is the jackpot at **AC −6 and +15
damroll**.

### Suggested prep run

Kill the start-room monster (**vest**) → grab the **dagger** at 18607 on the
way → detour to **18645** for the **mace + sleeves + leggings** → optional
**18606** Guard for **helm + ring** → then push to 18629, clearing the quasit
(18627) and zombie (18624) en route.

## Defeating him

Despite the terrifying room text, he's a beatable newbie boss:

- **Level 7**, **~71 HP**, THAC0 18, AC 5, alignment −1000 (evil).
- **Damage:** `1d2+1` → only **2–3 per hit**. He hits soft.
- **Reward:** **4,900 XP** and **70 gold** — a huge XP bump for a newbie.

Tactics: he barely dents you, so a level ~5+ character with any starter
weapon can just `kill minotaur` and trade blows. Grab a *glowing newbie mace*
or *shiny newbie dagger* from the earlier newbie mobs on the way if you're
unarmed. After the kill: `get all corpse` to loot the horns and hide, then
`wear all`.

## Side quest — the wee little key & the Dark Pit

Not on the Minotaur route, but a small optional puzzle in the same zone.

- **The key:** *a wee little key* (obj `18608`) is carried by *the Newbie Guard*
  (mob `18604`), who stands in room `18606` — *A Small Room*.
- **What it unlocks:** the vertical door between `18606` *A Small Room* (top)
  and `18605` *The Dark Pit* (bottom). That is the only thing it opens.
- **What's behind it:** *The Dark Pit* (18605) holds *the pit beast* (mob `18601`).

### Getting the key

The Guard is a pushover — **Level 3, 30 HP, `1d2` damage** (2 per hit), 900 XP.

Path from the entrance (18600) — only **3 moves**:

| Command                   | Arrive at                        |
|---------------------------|----------------------------------|
| `north`                   | 18601 The Beginning Of The Passage |
| `east`                    | 18602 The Dirty Hallway          |
| `open door` then `south`  | 18606 A Small Room *(Guard + key)* |

**Speedwalk:** `n e` → `open door; s` → `kill guard` → `get all corpse`

The door into 18606 is a plain door (no key needed), just `open`. Once you
have the little key, stand in 18606 and `unlock down` → `open down` → `down`
to drop into *The Dark Pit* and fight the pit beast.

### Is the key discoverable in-game?

Mostly **no** — there is no textual breadcrumb linking the Guard to the key:

- Room 18606 *does* tell you a locked passage exists: *"there also appears
  to be some type of well down here also, but it has a rather secure grate
  covering it."* And the down exit is a locked `grate`.
- But `look guard` only shows flavor about a **missing pet dragon** — nothing
  about a key, grate, or pit. The Guard's `keeper` keyword (a faint "keeper of
  things" hint) is internal and not shown on look.

So for most players it is **kill-and-discover**: you see the locked grate, the
Guard is the only creature in the room, you kill him, and the key drops from
the corpse. The one exception is a thief (see below).

### Class options for the grate & key

> Engine note: **verified against the tbaMUD source** (`act.informative.c` for
> peek, `act.other.c` for steal, `act.movement.c` `ok_pick` for pick-lock,
> `class.c` for class skill assignment). Verified flags from the world data:
> the grate resets to state `2` (closed + locked) on both sides (zone 186
> `D 0 18606 5 2` / `D 0 18605 4 2`), but its room-file door flag is `1`
> (normal door), **not** `2` (pickproof).

**Thief — three ways, no kill required:**

- **`peek` — just `look guard`.** There is **no peek skill and no roll** in
  tbaMUD: `look_at_char` shows a target's carried inventory to any thief
  automatically (`IS_THIEF(ch) || GET_LEVEL(ch) >= LVL_IMMORT`). So a thief
  sees *"You attempt to peek at his inventory: a wee little key"* on sight —
  the one reliable way to *discover* the key before killing him. Works from
  level 1.
- **`steal key guard`** — the STEAL skill (thieves learn it at **level 4**).
  Works on NPCs; success is a dexterity/skill roll. On a **failed** attempt the
  Guard, being awake, attacks (`ohoh && IS_NPC && AWAKE → hit`) — but he's
  Level 3 / 30 HP, so a botched steal is harmless.
- **`pick down`** — the PICK LOCK skill (thieves learn it at **level 2**).
  `ok_pick` refuses a pickproof door, else rolls vs `SKILL_PICK_LOCK` + dex.
  The grate is **not** pickproof (flag 1), so a successful roll opens it
  **without the key at all**, skipping the Guard entirely.

**All other classes** (warrior, cleric, mage): in tbaMUD `class.c`,
`PICK_LOCK` and `STEAL` are assigned to **CLASS_THIEF only**, peek is gated on
`IS_THIEF`, and there is no `knock` spell or `force door` command. Warriors get
combat skills (kick/bash/rescue), clerics and mages get spells but **no**
lock/steal skills. So every non-thief must **kill the Guard and loot the key**
— it is the only way through the grate.

## Town & shopping (Midgaard)

The zone's exits (rooms 18600, 18608, and 18629-down) all lead to room `3061`
— *The Great Field Of Midgaard*. **Town = Midgaard** (zone 30); all shops below
are there.

### Budget

A full newbie-zone clear yields **~800 gold** from mob kills (see the gold
breakdown per mob in the zone data). Selling duplicate drops adds little —
shops pay only ~15% of an item's value — so treat **~800g per clear** as your
working budget. Enough for consumables, **not** for the good shop gear.

### Don't buy — the zone already gives it

- **Weapon:** the *glowing newbie mace* (**2d6**) beats every shop weapon you
  could afford. Shop long sword (1d8) and flail (2d4) cost **600–625g each**;
  the affordable dagger/short sword (1d4–1d6) are *worse* than the mace.
- **Armor:** the newbie set covers **head, torso, arms, legs, neck, finger,
  body** (helm, vest, sleeves, leggings, collar, ring, cloak). Shop bronze
  pieces are **AC 6 at 175–350g each** — comparable, not better, and would eat
  the whole budget.
- **Light:** the *brightly glowing jar* drops from the Alchemist (~50% of
  resets).

### Buy in town — the zone does NOT provide these

| Item | Shop | ~Price | Why |
|------|------|--------|-----|
| Bread / waybread | Baker | 5–50g | Food — you starve without it. Grab 3–4 loaves. |
| Canteen (water) | Grocer | ~80g | Refill **free** at Midgaard's fountain — one-time buy. |
| Bag | General store | ~20g | Carry loot / corpse items. |
| Brass lantern (96 hrs) or 2× torch | General store | ~50g / ~10g ea | Backup light — the jar only drops half the time. |
| Scroll of recall | Magic shop | ~200g | Panic-button teleport to town. Optional but a lifesaver. |

**Gap slots** the newbie set leaves open: **hands, feet, wrists, shield**.
Cheap fills if wanted: wooden shield ~100g (AC 2) or leather gloves. Not
essential at this level.

**Skip entirely:** *identify scroll* (5,000g — far out of budget) and any shop
weapon/armor upgrade; save gold for a real weapon later.

### Food values (which loaf to buy)

A FOOD item's `value[0]` is the **game-hours of fullness** it restores
(`gain_condition(ch, HUNGER, GET_OBJ_VAL(food,0))`, verified in tbaMUD
`act.item.c`). So different foods genuinely feed you more/longer — the value
*is* the duration; there's no separate stat.

| Food | Fills | Cost | Best for |
|------|-------|------|----------|
| waybread (3009) | **24** hrs | 50g | Topping up from near-empty (fills the whole bar) |
| bread loaf (3010) | **12** hrs | 10g | **Best value per coin** — everyday eating |
| danish pastry (3011) | **5** hrs | 5g | Cheap filler |

Two caveats from the code:

- Fullness **caps at 24** and you can't eat past ~20 (*"too full to eat
  more"*), so eating a 24-value waybread when you're already fairly full wastes
  most of it — bread is the efficient choice.
- These foods **do not spoil**. tbaMUD only decays `IS_CORPSE` objects on their
  timer (`point_update`); normal food has no timer and never rots. The only
  per-food hazard is the poison flag (`value[3]`), which is 0 on all Midgaard
  food.

### Suggested ~800g shopping list

```
Canteen ............ ~80g   (water, refill free)
4x bread ........... ~40g   (food)
Bag ................ ~20g   (storage)
Brass lantern ...... ~50g   (backup light)
Scroll of recall ... ~200g  (escape/safety)
-------------------------------
Total .............. ~390g   -> ~400g left for a wooden shield (100g)
                               or banked toward a weapon upgrade
```

Bottom line: **buy consumables (food, water, bag, backup light) and maybe a
recall scroll — that's it.** Weapons and armor are covered by newbie-zone
drops, so spending gold on shop gear at this stage is wasted. (Prices are base
value; shops charge roughly +15%.)

## Survival: tiredness, hunger, and death

> Engine note: the base game is **tbaMUD** (the Dockerfile builds from
> `github.com/tbamud/tbamud`; the docker *service* is just named `circlemud`).
> The mechanics below are **verified against the tbaMUD source** — `act.item.c`
> (eating), `limits.c` (`gain_condition`, `hit/mana/move_gain`, `point_update`),
> and `fight.c` (`die`, `update_pos`). Verified from the world data: there are
> **no death-trap rooms** in the newbie zone or in Midgaard, and the mortal
> start/respawn room is **The Temple Of Midgaard (room 3001)**.

### Tired (movement & positions)

- Walking spends **movement points**, scaled by the terrain you leave/enter.
  At 0 move points you get *"You are too exhausted"* and can't walk until you
  regenerate.
- You regenerate HP / mana / move faster the more relaxed your position:
  `sleep` (fastest, but helpless and blind) > `rest` > `sit` > `stand`.
  Use `wake` / `stand` to get back up.
- **Danger:** aggressive mobs will attack you while you `rest` or `sleep`. Only
  sleep in a safe, empty room (e.g., back in Midgaard), never mid-labyrinth
  next to the quasit or zombie.

### Hungry & thirsty

- Hunger and thirst tick down over time (conditions cap at 24; you're refused
  further food once fullness > 20 — *"You are too full to eat more!"*).
- When hunger **or** thirst hits 0, tbaMUD **quarters your regeneration** —
  `if (GET_COND(ch,HUNGER)==0 || GET_COND(ch,THIRST)==0) gain /= 4;` applies to
  **HP, mana, and move alike**. It won't kill you (there is no starvation
  death), but healing crawls, which stalls a newbie grinding the zone.
- Fixes: `eat bread` for food; `drink canteen` / `drink fountain` for water;
  refill a container at a fountain with `fill canteen fountain` (Midgaard's
  Temple Square has one). This is why the shopping list includes food and a
  canteen.
- Drinking alcohol (the pub bottles) raises your **drunk** condition — avoid
  before a fight.

### When you die

You die at **HP ≤ −11** (`update_pos`). Below 0 you pass through `stunned`
(−1 to −2) → `incapacitated` (−3 to −5) → `mortally wounded` (−6 to −10,
bleeding out and losing HP each tick) — a `heal` or a friend can still save you
in that window; at −11 you're dead.

On death (`die` → `raw_kill`):

- You **lose HALF your total experience** — `gain_exp(ch, -(GET_EXP(ch) / 2))`.
  This is a brutal penalty and can cost you a level (or more).
- All your **gear and gold go onto your corpse** where you fell —
  `make_corpse(ch)` builds a *"corpse of <name>"* holding everything you carried
  and wore.
- You **respawn at the mortal start room** — The Temple Of Midgaard (3001) in
  this world — at minimal HP.
- **Player corpses decay** after a while, so you must run back and
  `get all corpse` (and `get all.coin corpse`) to recover your equipment before
  it rots — then `wear all` / `wield` to re-equip.
- **Corpse-recovery risk:** the mob that killed you has likely respawned, so
  retrieving a corpse from the Minotaur's room (or next to the quasit/zombie)
  can get you killed again. Recover carefully, ideally healed up first.

Practical takeaway: keep a **recall scroll** for emergencies, `rest` to heal
between fights, keep **food/water** topped up so you regen, and don't sleep
anywhere a mob can reach you.
