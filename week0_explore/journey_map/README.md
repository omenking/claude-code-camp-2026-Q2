# Journey Map

A standalone, live fog-of-war world map for the tbaMUD server running in this
repo's Docker environment. It is an *observer* that sits beside `preview/`
(the parsed-world browser) - it reads `preview`'s parsed JSON world data
read-only and never modifies anything under `preview/`.

Unlike an immortal roomflag map, this tool localizes the player the way a
real player would have to: by watching the room title, the exit list, and
movement history, and narrowing down which room that must be. No vnums, no
"goto" tricks.

## What it is

One Python process (`journey_map.py`, stdlib only, no pip/npm deps) that:

1. Loads the parsed world graph from `../preview/data/world/{wld,mob,zon}/*.json`
   (12,679 rooms) and precomputes a per-zone grid layout for the viewer.
2. Runs a **telnet tap proxy** on `:4001` that forwards to the real MUD on
   `:4000`, byte-exact in both directions (telnet IAC negotiation passes
   through untouched - the proxy never injects or strips protocol bytes).
   It taps the stream in both directions to see what the player typed and
   what the server sent back.
3. Parses the server's ANSI-colored output into room blocks (title, exits,
   objects, mob sightings) and feeds them to a **localizer** that tracks a
   candidate set of rooms consistent with everything observed so far.
4. Persists progress to `journey_state.json` (gitignored - it's per-player
   state, not project source) and serves it over `:4002` alongside the
   world graph, for a browser-based viewer.

And one self-contained `viewer.html` (vanilla JS + SVG, no CDN, no build
step) that polls the state once a second and renders:
- visited rooms, sector-colored (same palette as `preview`'s map view), each
  labeled with its **full room name** - shown as one line where it fits,
  wrapped to two where it doesn't, and only shrunk or (last resort, for the
  rare 50+ character title) ellipsis-truncated if it still doesn't fit. Each
  label is placed via greedy collision avoidance (tries below/above/right/
  left of its room) against every other label and room square already
  placed, so labels never overlap even in dense clusters (Midgaard's Main
  Street area); a label that truly can't fit anywhere is dropped rather than
  drawn on top of something else. The current/selected room is exempt from
  being dropped - it always gets a label. Below a small zoom threshold only
  the current/selected room is labeled at all, since anything else would
  render too small to read regardless of placement.
- **frontier** rooms - unvisited but adjacent to a visited room via a known
  exit - as grey ghosts
- the current room as a pulsing ring
- ambiguous localization (candidate set > 1) as dashed "?" rooms
- mob sightings (dot badge) plus "expected here" mobs and objects from zone
  spawn data
- a legend in the sidebar explaining every marker (ring/dot/^/v/?/colors) -
  no need to guess what a symbol means
- a search box that type-aheads over discovered rooms (visited + frontier)
  by name or id, jumping to and centering on the pick
- a detail panel for the selected room with everything the parsed world
  data has for it: full description, flags, extra descriptions (keyword +
  text), triggers, exits (each a clickable link to the neighboring room -
  but only if that neighbor is itself already discovered, so clicking
  through a frontier room's own exits can't reveal undiscovered territory),
  sighted mobs, and expected mobs/objects from zone data

## How to run

Prerequisite: the MUD server must already be running on `localhost:4000`
(see `week0_explore/infrastructure/`, `docker compose up --build`).

```bash
cd week0_explore/journey_map
python3 journey_map.py
```

This starts the proxy on `:4001` and the viewer/API on `:4002`. Then either:

- Open `http://localhost:4002/` in a browser to watch the map, and/or
- Point any telnet client at `localhost:4001` instead of `:4000` and play
  normally (`telnet localhost 4001`, or a raw socket script). The proxy is
  transparent - login, movement, everything works exactly as if you had
  connected straight to `:4000`.

State persists in `journey_state.json` next to this README; stop and
restart `journey_map.py` at any time and the visited set/current room are
restored on startup.

## Stopping / restarting / resetting

- **Stop**: `Ctrl+C` in the terminal it's running in, or (if you backgrounded
  it) `pkill -f journey_map.py`. This only stops the proxy/viewer - it does
  not touch the MUD server itself.
- **Restart**: `python3 -u journey_map.py` (the `-u` flag disables Python's
  stdout buffering, so the startup/proxy/state log lines show up immediately
  instead of only after the process exits - handy when running in the
  background with output redirected to a file). Visited rooms and the
  current position are restored from `journey_state.json` automatically.
- **Reset the map** (start fully fresh, forget everything visited so far):
  stop the tool, delete `journey_state.json`, restart. World data reloads
  from `preview/` either way - only the per-player progress is reset.
- **The MUD server** (`localhost:4000`) is a separate process from this tool
  - it's started/stopped independently via `docker compose` in
    `week0_explore/infrastructure/`. Stopping `journey_map.py` never stops
    the MUD, and stopping the MUD doesn't affect `journey_state.json`.

## How localization works

A "room block" is title (if any) + description + an exits line + any
object/mob lines, terminated by the game prompt. tbaMUD's live output
(verified against the running server) wraps the title in
`\x1b[0;33m...\x1b[0m` (yellow) and the exits line in `\x1b[0;36m...\x1b[0m`
(cyan); mob long-descriptions are also yellow but appear *after* the exits
line, so the parser uses line order, not color alone, to tell a room title
from a mob sighting. Blocks with no exits line (a failed move like "Alas,
you cannot go that way...", combat spam, tells, async chatter, the
login/menu sequence) are not room blocks and never touch the map state.

Title alone is ambiguous for about 8,100 of the 12,679 rooms; title + exit
signature is still ambiguous for about 5,100. So the localizer keeps a
**candidate set** - every room consistent with everything seen so far:

- If the last command was a movement direction, candidates narrow to rooms
  reachable from the previous candidate set via that direction *and*
  matching the newly observed title/exits. If that intersection is empty
  (teleport, death, recall), it falls back to a fresh global match on the
  new observation.
- Otherwise (a `look`, or an async room redisplay), candidates narrow to
  the previous set intersected with a fresh global match.
- One candidate left -> localized: mark the room visited, record it as
  current, and (if any mob long-desc lines matched a mob's `long_desc`
  exactly after whitespace/ANSI normalization) record the sighting.
- More than one candidate -> tentative: nothing is marked visited yet, and
  the viewer shows every candidate with a "?" badge.
- When an ambiguous run collapses back down to one candidate, the tool
  walks the buffered trail of ambiguous steps *backwards* through the world
  graph (each step's recorded candidate set intersected with "has an exit
  in the direction that was actually taken, leading to the next known
  room") to retroactively mark the now-unambiguous path visited, without
  ever guessing a wrong room.

One deviation from the original design: pitch-black rooms have no title
line at all. Matching a room by `title=""` against the global title index
would never hit (no real room is named ""), so when no title line is
found the localizer falls back to matching on the exit signature alone
(see `Journey._rooms_matching` in `journey_map.py`).

## Files

- `journey_map.py` - the whole backend (proxy, parser, localizer, HTTP
  server). Ports and paths are fixed per the architecture doc (`:4001`
  proxy, `:4002` HTTP, world data at `../preview/data/world/`).
- `viewer.html` - the browser viewer. Single file, no dependencies.
- `journey_state.json` - generated at runtime, gitignored. Delete it to
  start the map over from scratch.
- `.gitignore` - ignores the generated state file.
