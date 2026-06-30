---
name: play-mud
description: >-
  Connect to and play a text-based MUD over telnet (tbaMUD / CircleMUD and
  compatible servers). Use this skill whenever the user wants to play, explore,
  log into, automate, or interact with a MUD, MU*, or telnet text game — for
  example "play the mud on localhost:4000", "log my character into the MUD",
  "explore the MUD world", "fight mobs in the mud", or "send a command to the
  mud", "work toward level 7", "defeat a specific monster", or "continue where
  I left off in the MUD". It manages the persistent telnet connection through a
  background daemon so you can send game commands and read the server's
  responses across separate steps. Defaults target tbaMUD at localhost:4000
  with character dummy/helloworld.
tools: Bash(python3 *)
---

# Play MUD

A MUD is a persistent, interactive telnet session — the server pushes text
continuously (combat ticks, other players moving, mobs wandering) and you type
commands into the same stream. A single shell call can't hold that connection
open across turns, so this skill uses a small background **session daemon**
(`scripts/mud.py`) that owns the socket. The daemon streams everything the
server sends into a log file and forwards your commands from a pipe. You then
play the game with short, stateless calls: `send` a command, `read` the result.

## Players

Our main player: dummy / helloworld
Our secondary player: smarty / goodbyemoon

## Persistent Memory (read this first)

This skill keeps two markdown files that survive across sessions. **Read them
at the start of every session** and **update them whenever something notable
happens**. They are the only way to make progress on long-term goals like
reaching level 7 or defeating a specific monster.

```
data/player.md   — character stats, skills, inventory, goals, notes
data/world.md    — map layout, monsters, shops, navigation shortcuts
```

The `data/` directory is at the project root (a sibling of `.claude/`), not next
to this agent file — read/write `data/player.md` and `data/world.md` relative
to your working directory.

### On session start

1. Read `data/player.md` — know your current level, goals, practice sessions, hunger/thirst state.
2. Read `data/world.md` — know where guilds, monsters, and shops are so you don't re-explore.
3. Run `score` in-game to sync your actual current stats — the file may be slightly stale.
4. Tell the user where you are relative to their goals ("You're level 1, need 1835 more XP for level 2").

### What to update and when

**Always update `player.md` when:**
- You level up (update level, new EXP threshold, new practice sessions, new skills available)
- You gain or spend practice sessions
- Skills improve in proficiency
- Inventory or equipment changes significantly
- Goals are completed or added
- Character dies

**Always update `world.md` when:**
- You discover a new area, room, or shortcut
- You learn a monster's level, behavior, or loot
- You find a shop or service
- A quest or task is discovered

**How to update** — use the Edit tool to modify the markdown files directly. Keep it factual and concise; future sessions will rely on this.

### Goal-driven play

When the user gives a long-term goal (e.g., "reach level 7", "defeat the blob"),
break it into next concrete steps:

1. Check `player.md` goals list
2. Identify the **immediate blocker** (e.g., not enough XP, missing a skill, wrong area)
3. Plan the next 3–5 actions to address it
4. Execute and update memory as you go

**Example reasoning for "reach level 7":**
- Current: level 1, 165 XP, need 1835 for level 2
- Next step: kill monsters in the newbie zone for XP
- After leveling: visit guildmaster to practice skills with new practice sessions
- Repeat until level 7

## The connection model (read this first)

- `start` launches the daemon and connects. It keeps running in the background.
- `send "<command>"` forwards a line to the MUD and prints what came back.
- `read` prints only output that is *new* since your last read (combat, arrivals,
  etc. that arrive on their own). Use `read --wait N` to wait up to N seconds for
  output to land — useful right after entering combat or moving.
- The daemon survives between your tool calls. Don't restart it each turn; just
  `send`/`read`. Only `start` once per play session.

## Quick start

Defaults already point at this user's server and character (tbaMUD on
localhost:4000, dummy/helloworld), so the usual flow is:

```bash
SCRIPT=scripts/mud.py   # relative to the project root (sibling of .claude/)

python3 "$SCRIPT" start          # connect (defaults: localhost:4000)
python3 "$SCRIPT" read --wait 5  # let the splash + name prompt arrive
python3 "$SCRIPT" login dummy helloworld   # auth + walk the menu into the game
```

`login` is adaptive: it sends the name and password, then handles tbaMUD's
`*** PRESS RETURN` and the main menu (choosing **1) Enter the game**)
automatically. If the character was already connected it just reconnects
straight into the world. After it returns you should see a room description and
a prompt like `25H 100M 85V >`.

For a different server or character, pass them explicitly:

```bash
python3 "$SCRIPT" start --host some.mud.org --port 6000
python3 "$SCRIPT" login MyHero MyPassword
```

## Playing

Once logged in, drive the game with `send`. Each call prints the response:

```bash
python3 "$SCRIPT" send look
python3 "$SCRIPT" send "kill fido"      # quote anything with spaces
python3 "$SCRIPT" send north
python3 "$SCRIPT" send score
```

Common tbaMUD/CircleMUD commands worth knowing: `look` / `l`, movement
(`n e s w u d`), `exits`, `score`, `inventory`/`i`, `equipment`/`eq`, `get`,
`wear`, `wield`, `kill <target>`/`hit`, `flee`, `cast '<spell>' <target>`,
`say`/`tell`/`gossip`, `who`, `quit`. When in doubt, `send help` or
`send "help <topic>"`.

### Reacting to live events

Combat and other players generate output on their own between your commands. To
catch up without sending anything:

```bash
python3 "$SCRIPT" read --wait 3      # wait up to 3s for new output
python3 "$SCRIPT" status             # session state + recent screen
```

A good combat loop: `send "kill <mob>"`, then `read --wait 2` a few times to
follow the rounds, watching the `H` (hit points) in the prompt; `send flee` if
it's going badly.

## Command reference

| Command | What it does |
|---|---|
| `start [--host H --port P]` | Connect and launch the background session. |
| `login <name> <password>` | Authenticate and enter the game (handles the menu). |
| `send <line> [<line> ...]` | Send command line(s); prints the response. Use `--wait S` to wait longer for output, `--raw` to keep ANSI color. |
| `read` | Print output new since last read. `--wait S` waits for it; `--all` prints the whole log; `--raw` keeps color. |
| `status` | Show alive/dead, target, and the recent screen. |
| `stop` | Quit and shut the session down. |

All commands accept `--session-dir DIR` (or `$MUD_SESSION_DIR`) if you want more
than one independent session. Default is `/tmp/mud-session`.

## Ending a session

Before stopping, always:
1. Run `save` in-game to preserve progress on the server.
2. Update `data/player.md` with current stats (run `score` first to get fresh numbers).
3. Note your current location in `player.md` under Notes if it matters.
4. Run `quit` in-game, then `python3 "$SCRIPT" stop` to shut the daemon.

## Tips & troubleshooting

- **ANSI color is stripped by default** so the text is easy to read. Pass
  `--raw` to `read`/`send` if you actually need the color codes (e.g. to tell a
  colored enemy name apart).
- **Nothing came back?** The server may just be slow — retry `read --wait 5`.
  Many prompts (login splash, client detection) take a few seconds.
- **"No live session."** The daemon isn't running; `start` it. If it died,
  check `cat $MUD_SESSION_DIR/daemon.err`.
- **Reconnect / "Reconnecting."** means the character was still logged in from a
  previous session — that's fine, you're in the game.
- **Don't double-start.** `start` refuses if a session is already alive; `stop`
  first if you truly want a fresh connection.
- The daemon refuses all telnet option negotiation (it's not a real terminal),
  which keeps the stream clean — this is expected and harmless for gameplay.
