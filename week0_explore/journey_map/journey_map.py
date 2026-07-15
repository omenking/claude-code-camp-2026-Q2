#!/usr/bin/env python3
"""
journey_map.py - standalone live fog-of-war journey map for the tbaMUD server.

Architecture (README.md in this folder covers the design and how the
localization works):

    telnet client / agent --> :4001 proxy --> :4000 tbaMUD
                                   | (byte-exact tap, both directions)
                                   v
                          ANSI-aware room-block parser
                                   v
                          localizer (candidate-set tracking)
                                   v
                       journey_state.json (persisted)
                                   ^
             browser <-- :4002 HTTP (viewer.html, /world.json, /journey.json)

Python 3.11+ stdlib only. No pip/npm deps, no build step.

Run: python3 journey_map.py
Then either point a telnet client at localhost:4001 (instead of :4000) and
play normally, or open http://localhost:4002/ in a browser to watch the map.
"""

import glob
import json
import os
import re
import socket
import threading
import time
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

BASE_DIR = Path(__file__).resolve().parent
PREVIEW_WORLD_DIR = BASE_DIR.parent / "preview" / "data" / "world"
STATE_PATH = BASE_DIR / "journey_state.json"
VIEWER_PATH = BASE_DIR / "viewer.html"

MUD_HOST = "localhost"
MUD_PORT = 4000
PROXY_PORT = 4001
HTTP_PORT = 4002

# tbaMUD exit direction encoding: 0=n 1=e 2=s 3=w 4=u 5=d
DIR_LETTERS = {0: "n", 1: "e", 2: "s", 3: "w", 4: "u", 5: "d"}
DIR_VECTORS = {"n": (0, -1), "s": (0, 1), "e": (1, 0), "w": (-1, 0)}
MOVE_ALIASES = {
    "n": "n", "north": "n",
    "e": "e", "east": "e",
    "s": "s", "south": "s",
    "w": "w", "west": "w",
    "u": "u", "up": "u",
    "d": "d", "down": "d",
}

ANSI_RE = re.compile(r"\x1b\[[0-9;]*m")
EXITS_RE = re.compile(r"^\[\s*Exits:\s*(.*?)\s*\]$")
# Observed live prompt: "20H 100M 80V (news) (motd) > " (no trailing newline).
PROMPT_RE = re.compile(r"\d+H\s+\d+M\s+\d+V\b.*>\s*$")

YELLOW = "\x1b[0;33m"
CYAN = "\x1b[0;36m"
GREEN = "\x1b[0;32m"

WORLD_JSON_BYTES = b"{}"
JOURNEY = None


def normalize_text(s):
    """Strip ANSI codes and collapse whitespace, for line comparisons."""
    s = ANSI_RE.sub("", s or "")
    return " ".join(s.split()).strip()


# ---------------------------------------------------------------------------
# World graph loader (startup, read-only against ../preview/data/world)
# ---------------------------------------------------------------------------

def load_world():
    rooms = {}
    for path in sorted(glob.glob(str(PREVIEW_WORLD_DIR / "wld" / "*.json"))):
        with open(path) as fh:
            for r in json.load(fh):
                rid = r["id"]
                exits = {}
                for ex in r.get("exits", []):
                    letter = DIR_LETTERS.get(ex.get("dir"))
                    if letter:
                        exits[letter] = ex.get("room_linked")
                flags = [f.get("note") for f in r.get("flags", []) if f.get("note")]
                extra_descs = [
                    {"keywords": ed.get("keywords", []), "desc": ed.get("desc") or ""}
                    for ed in r.get("extra_descs", [])
                ]
                rooms[rid] = {
                    "id": rid,
                    "name": r.get("name") or "",
                    "zone_number": r.get("zone_number"),
                    "sector": (r.get("sector_type") or {}).get("note", "CITY"),
                    "exits": exits,
                    "desc": r.get("desc") or "",
                    "flags": flags,
                    "extra_descs": extra_descs,
                    "triggers": r.get("triggers", []) or [],
                }

    mobs = {}
    for path in sorted(glob.glob(str(PREVIEW_WORLD_DIR / "mob" / "*.json"))):
        with open(path) as fh:
            for m in json.load(fh):
                mid = m["id"]
                mobs[mid] = {
                    "id": mid,
                    "short_desc": m.get("short_desc") or "",
                    "long_desc": m.get("long_desc") or "",
                }

    objs = {}
    for path in sorted(glob.glob(str(PREVIEW_WORLD_DIR / "obj" / "*.json"))):
        with open(path) as fh:
            for o in json.load(fh):
                oid = o["id"]
                objs[oid] = {
                    "id": oid,
                    "short_desc": o.get("short_desc") or "",
                }

    # Zone spawn/placement data: "expected here" for both mobs and objects.
    # Note the mob spawn entries key the mob type as "mob", but object spawn
    # entries key the object type as "id" - different field names for the
    # same shape, confirmed against the live parsed data.
    expected_mobs = {}
    expected_objects = {}
    for path in sorted(glob.glob(str(PREVIEW_WORLD_DIR / "zon" / "*.json"))):
        with open(path) as fh:
            for z in json.load(fh):
                for spawn in z.get("mobs", []):
                    rid = spawn.get("room")
                    mid = spawn.get("mob")
                    if rid is None or mid is None:
                        continue
                    bucket = expected_mobs.setdefault(rid, [])
                    if mid not in bucket:
                        bucket.append(mid)
                for spawn in z.get("objects", []):
                    rid = spawn.get("room")
                    oid = spawn.get("id")
                    if rid is None or oid is None:
                        continue
                    bucket = expected_objects.setdefault(rid, [])
                    if oid not in bucket:
                        bucket.append(oid)

    # Localizer indices.
    title_index = {}
    exit_sig_index = {}
    exit_only_index = {}
    for rid, r in rooms.items():
        letters = tuple(sorted(r["exits"].keys()))
        title_index.setdefault(r["name"], []).append(rid)
        exit_sig_index.setdefault((r["name"], letters), []).append(rid)
        exit_only_index.setdefault(letters, []).append(rid)

    long_desc_index = {}
    for mid, m in mobs.items():
        key = normalize_text(m["long_desc"])
        if key:
            long_desc_index.setdefault(key, []).append(mid)

    layout = compute_layout(rooms)
    for rid, (x, y, z) in layout.items():
        rooms[rid]["x"] = x
        rooms[rid]["y"] = y
        rooms[rid]["z"] = z

    return {
        "rooms": rooms,
        "mobs": mobs,
        "objs": objs,
        "expected_mobs": expected_mobs,
        "expected_objects": expected_objects,
        "title_index": title_index,
        "exit_sig_index": exit_sig_index,
        "exit_only_index": exit_only_index,
        "long_desc_index": long_desc_index,
    }


def compute_layout(rooms):
    """Classic MUD-mapper grid layout, per zone: BFS from the zone's lowest
    room id, n/e/s/w move the grid position, u/d only change the z-level
    (rendered as badges, not edges - see viewer.html). Any room a zone's
    primary BFS does not reach (disconnected sub-graph) gets its own local
    BFS root, nudged to a free slot so it never overlaps the primary layout.
    """
    by_zone = {}
    for rid, r in rooms.items():
        by_zone.setdefault(r["zone_number"], []).append(rid)

    coords = {}
    for zone, rids in by_zone.items():
        occupied = {}
        visited = set()
        for root in sorted(rids):
            if root in visited:
                continue
            pos = find_free_slot(occupied, (0, 0, 0))
            occupied[pos] = root
            coords[root] = pos
            visited.add(root)
            queue = [root]
            qi = 0
            while qi < len(queue):
                cur = queue[qi]
                qi += 1
                cx, cy, cz = coords[cur]
                for letter, target in rooms[cur]["exits"].items():
                    if target not in rooms or target in visited:
                        continue
                    if rooms[target]["zone_number"] != zone:
                        continue
                    if letter in DIR_VECTORS:
                        dx, dy = DIR_VECTORS[letter]
                        cand = (cx + dx, cy + dy, cz)
                    elif letter == "u":
                        cand = (cx, cy, cz + 1)
                    elif letter == "d":
                        cand = (cx, cy, cz - 1)
                    else:
                        continue
                    cand = find_free_slot(occupied, cand)
                    occupied[cand] = target
                    coords[target] = cand
                    visited.add(target)
                    queue.append(target)
    return coords


def find_free_slot(occupied, cand):
    if cand not in occupied:
        return cand
    x, y, z = cand
    nudges = [(0.5, 0), (0, 0.5), (-0.5, 0), (0, -0.5),
              (0.5, 0.5), (-0.5, 0.5), (0.5, -0.5), (-0.5, -0.5)]
    step = 1
    for attempt in range(1, 200):
        for nx, ny in nudges:
            c2 = (x + nx * step, y + ny * step, z)
            if c2 not in occupied:
                return c2
        step += 1
    # Should not happen at this scale; deterministic last-resort fallback.
    return (x + 1000, y + 1000, z)


# ---------------------------------------------------------------------------
# Telnet IAC stripper (text extraction only - never touches forwarded bytes)
# ---------------------------------------------------------------------------

IAC, DONT, DO, WONT, WILL, SB, SE = 255, 254, 253, 252, 251, 250, 240


class TelnetStripper:
    """Stateful (across chunks) telnet IAC negotiation stripper, used only to
    get clean text for parsing. The proxy forwards the original raw bytes
    untouched regardless of what this produces."""

    def __init__(self):
        self.state = "DATA"

    def feed(self, data: bytes) -> str:
        out = bytearray()
        for b in data:
            if self.state == "DATA":
                if b == IAC:
                    self.state = "IAC"
                else:
                    out.append(b)
            elif self.state == "IAC":
                if b == IAC:
                    out.append(IAC)
                    self.state = "DATA"
                elif b in (DO, DONT, WILL, WONT):
                    self.state = "NEG"
                elif b == SB:
                    self.state = "SB"
                else:
                    self.state = "DATA"
            elif self.state == "NEG":
                self.state = "DATA"
            elif self.state == "SB":
                if b == IAC:
                    self.state = "SB_IAC"
            elif self.state == "SB_IAC":
                if b == SE:
                    self.state = "DATA"
                else:
                    self.state = "SB"
        return bytes(out).decode("latin-1")


# ---------------------------------------------------------------------------
# Stream parser: turns server->client text into resolved room blocks
# ---------------------------------------------------------------------------

class SessionParser:
    """Per-session (one telnet connection through the proxy). Buffers server
    text into lines, recognizes a full room block (title?...exits...entity
    lines...prompt), and hands it to Journey.observe(). Non-room output
    (failed moves, combat spam, async chatter, the login sequence) has no
    exits line and is silently ignored."""

    def __init__(self, journey):
        self.journey = journey
        self.stripper = TelnetStripper()
        self.buf = ""
        self.pending_lines = []
        self.command_queue = []

    def note_command(self, cmd):
        cmd = cmd.strip().lower()
        if cmd:
            self.command_queue.append(cmd)

    def feed_server_bytes(self, data: bytes):
        text = self.stripper.feed(data)
        if not text:
            return
        self.buf += text
        while True:
            idx = self.buf.find("\n")
            if idx == -1:
                break
            raw_line = self.buf[:idx]
            self.buf = self.buf[idx + 1:]
            if raw_line.endswith("\r"):
                raw_line = raw_line[:-1]
            stripped = normalize_text(raw_line)
            if stripped:
                self.pending_lines.append((raw_line, stripped))

        # The prompt has no trailing newline - it is whatever is left in buf.
        remainder_stripped = normalize_text(self.buf)
        if remainder_stripped and PROMPT_RE.search(remainder_stripped):
            self.buf = ""
            self._resolve_block()

    def _resolve_block(self):
        lines = self.pending_lines
        self.pending_lines = []
        cmd = self.command_queue.pop(0) if self.command_queue else None

        exits_idx = None
        exit_letters = []
        for i, (raw, stripped) in enumerate(lines):
            if raw.startswith(CYAN):
                m = EXITS_RE.match(stripped)
                if m:
                    exits_idx = i
                    exit_letters = m.group(1).split()
                    break

        if exits_idx is None:
            # Not a room block: failed move, combat spam, tells/channels,
            # login/menu text, etc. State is untouched.
            return

        title = None
        for raw, stripped in lines[:exits_idx]:
            if raw.startswith(YELLOW):
                title = stripped
                break

        mob_lines = [stripped for raw, stripped in lines[exits_idx + 1:]
                     if raw.startswith(YELLOW)]

        move_dir = MOVE_ALIASES.get(cmd) if cmd else None
        self.journey.observe(title, exit_letters, move_dir, mob_lines)


# ---------------------------------------------------------------------------
# Localizer + persisted journey state
# ---------------------------------------------------------------------------

class Journey:
    def __init__(self, world):
        self.world = world
        self.lock = threading.Lock()
        self.current = None
        self.candidates = set()
        self.visited = set()
        self.sightings = {}
        self.pending_trail = []
        self.updated_iso = None
        self._load()

    def _load(self):
        if not STATE_PATH.exists():
            return
        try:
            with open(STATE_PATH) as fh:
                data = json.load(fh)
            self.current = data.get("current")
            self.candidates = set(data.get("candidates") or [])
            self.visited = set(data.get("visited") or [])
            self.sightings = data.get("sightings") or {}
            self.updated_iso = data.get("updated_iso")
            print(f"[state] restored: current={self.current} "
                  f"visited={len(self.visited)} rooms")
        except (OSError, json.JSONDecodeError) as e:
            print(f"[state] failed to load {STATE_PATH}: {e}")

    def _rooms_matching(self, title, exit_letters):
        key = tuple(sorted(exit_letters))
        if title:
            ids = self.world["exit_sig_index"].get((title, key))
            return set(ids) if ids else set()
        # Pitch-black / titleless room: fall back to exit-signature-only
        # matching (deviation from the doc's title+exit index, needed
        # because a global match on title="" would never hit; flagged in
        # the implementer report).
        return set(self.world["exit_only_index"].get(key, []))

    def observe(self, title, exit_letters, move_dir, mob_lines):
        with self.lock:
            matches = self._rooms_matching(title, exit_letters)

            if move_dir and self.candidates:
                transitioned = set()
                for c in self.candidates:
                    target = self.world["rooms"].get(c, {}).get("exits", {}).get(move_dir)
                    if target is not None:
                        transitioned.add(target)
                narrowed = (transitioned & matches) if matches else transitioned
                new_candidates = narrowed if narrowed else matches
            elif self.candidates:
                narrowed = (self.candidates & matches) if matches else set()
                new_candidates = narrowed if narrowed else matches
            else:
                new_candidates = matches

            self.candidates = new_candidates

            if len(self.candidates) == 1:
                room_id = next(iter(self.candidates))
                self._resolve_trail(room_id, move_dir)
                self.current = room_id
                self.visited.add(room_id)
                self._record_sightings(room_id, mob_lines)
                self.pending_trail = []
            elif len(self.candidates) > 1:
                self.current = None
                self.pending_trail.append({
                    "move_dir": move_dir,
                    "matches": set(self.candidates),
                })
                self.pending_trail = self.pending_trail[-8:]
            else:
                # Total localization loss (e.g. an unmapped room). Keep the
                # last known current/visited; drop the ambiguous trail since
                # it no longer leads anywhere.
                self.pending_trail = []

            self._persist()

    def _resolve_trail(self, final_room, last_move_dir):
        """Walk the buffered ambiguous steps backwards now that we've
        resolved to a single room, retroactively marking the unambiguous
        part of the path visited. Stops the moment a step no longer
        collapses to exactly one predecessor."""
        known = final_room
        next_dir = last_move_dir
        for step in reversed(self.pending_trail):
            if not next_dir:
                break
            preds = [r for r in step["matches"]
                     if self.world["rooms"].get(r, {}).get("exits", {}).get(next_dir) == known]
            if len(preds) != 1:
                break
            known = preds[0]
            self.visited.add(known)
            next_dir = step["move_dir"]

    def _record_sightings(self, room_id, mob_lines):
        if not mob_lines:
            return
        entries = self.sightings.setdefault(str(room_id), [])
        now = datetime.now(timezone.utc).isoformat()
        for line in mob_lines:
            key = normalize_text(line)
            for mid in self.world["long_desc_index"].get(key, []):
                mob = self.world["mobs"].get(mid, {})
                for e in entries:
                    if e["mob_id"] == mid:
                        e["last_seen_iso"] = now
                        break
                else:
                    entries.append({
                        "mob_id": mid,
                        "name": mob.get("short_desc", ""),
                        "last_seen_iso": now,
                    })

    def _persist(self):
        self.updated_iso = datetime.now(timezone.utc).isoformat()
        data = {
            "current": self.current,
            "candidates": sorted(self.candidates),
            "visited": sorted(self.visited),
            "sightings": self.sightings,
            "updated_iso": self.updated_iso,
        }
        tmp_path = str(STATE_PATH) + ".tmp"
        with open(tmp_path, "w") as fh:
            json.dump(data, fh)
        os.replace(tmp_path, STATE_PATH)

    def snapshot(self):
        with self.lock:
            return {
                "current": self.current,
                "candidates": sorted(self.candidates),
                "visited": sorted(self.visited),
                "sightings": self.sightings,
                "updated_iso": self.updated_iso,
            }


# ---------------------------------------------------------------------------
# Telnet tap proxy: :4001 -> :4000, byte-exact both directions
# ---------------------------------------------------------------------------

def pump_client_to_server(client_sock, mud_sock, parser, stop):
    stripper = TelnetStripper()
    line_buf = ""
    try:
        while not stop.is_set():
            data = client_sock.recv(4096)
            if not data:
                break
            mud_sock.sendall(data)  # byte-exact passthrough, untouched
            text = stripper.feed(data)
            if not text:
                continue
            line_buf += text
            while True:
                idx = -1
                for i, ch in enumerate(line_buf):
                    if ch in "\r\n":
                        idx = i
                        break
                if idx == -1:
                    break
                cmd = line_buf[:idx]
                line_buf = line_buf[idx + 1:]
                if cmd:
                    parser.note_command(cmd)
    except OSError:
        pass
    finally:
        stop.set()
        try:
            mud_sock.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass


def pump_server_to_client(mud_sock, client_sock, parser, stop):
    try:
        while not stop.is_set():
            data = mud_sock.recv(4096)
            if not data:
                break
            client_sock.sendall(data)  # byte-exact passthrough, untouched
            parser.feed_server_bytes(data)
    except OSError:
        pass
    finally:
        stop.set()
        try:
            client_sock.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass


def run_session(client_sock, journey):
    mud_sock = socket.create_connection((MUD_HOST, MUD_PORT))
    parser = SessionParser(journey)
    stop = threading.Event()
    t_c2s = threading.Thread(target=pump_client_to_server,
                              args=(client_sock, mud_sock, parser, stop), daemon=True)
    t_s2c = threading.Thread(target=pump_server_to_client,
                              args=(mud_sock, client_sock, parser, stop), daemon=True)
    t_c2s.start()
    t_s2c.start()
    t_c2s.join()
    t_s2c.join()
    try:
        mud_sock.close()
    except OSError:
        pass


def run_proxy(journey):
    listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind(("0.0.0.0", PROXY_PORT))
    listener.listen(5)
    print(f"[proxy] listening on :{PROXY_PORT} -> {MUD_HOST}:{MUD_PORT}")
    while True:
        client_sock, addr = listener.accept()
        print(f"[proxy] client connected: {addr}")
        try:
            run_session(client_sock, journey)
        except OSError as e:
            print(f"[proxy] session error: {e}")
        finally:
            try:
                client_sock.close()
            except OSError:
                pass
            print("[proxy] session closed")


# ---------------------------------------------------------------------------
# HTTP server: :4002 -> viewer.html, /world.json, /journey.json
# ---------------------------------------------------------------------------

class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass  # keep stdout limited to proxy/journey events

    def do_GET(self):
        if self.path in ("/", "/viewer.html"):
            self._serve_file(VIEWER_PATH, "text/html; charset=utf-8")
        elif self.path == "/world.json":
            self._serve_bytes(WORLD_JSON_BYTES, "application/json")
        elif self.path == "/journey.json":
            data = json.dumps(JOURNEY.snapshot()).encode("utf-8")
            self._serve_bytes(data, "application/json")
        else:
            self.send_response(404)
            self.end_headers()

    def _serve_file(self, path, content_type):
        try:
            data = path.read_bytes()
        except OSError:
            self.send_response(404)
            self.end_headers()
            return
        self._serve_bytes(data, content_type)

    def _serve_bytes(self, data, content_type):
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


def build_world_json(world):
    rooms_out = {}
    for rid, r in world["rooms"].items():
        rooms_out[str(rid)] = {
            "id": rid,
            "name": r["name"],
            "zone_number": r["zone_number"],
            "sector": r["sector"],
            "exits": r["exits"],
            "x": r["x"], "y": r["y"], "z": r["z"],
            "desc": r["desc"],
            "flags": r["flags"],
            "extra_descs": r["extra_descs"],
            "triggers": r["triggers"],
            "expected_mobs": world["expected_mobs"].get(rid, []),
            "expected_objects": world["expected_objects"].get(rid, []),
        }
    mobs_out = {str(mid): {"id": mid, "short_desc": m["short_desc"]}
                for mid, m in world["mobs"].items()}
    objs_out = {str(oid): {"id": oid, "short_desc": o["short_desc"]}
                for oid, o in world["objs"].items()}
    payload = {
        "rooms": rooms_out,
        "mobs": mobs_out,
        "objs": objs_out,
        "meta": {
            "room_count": len(rooms_out),
            "generated_iso": datetime.now(timezone.utc).isoformat(),
        },
    }
    return json.dumps(payload).encode("utf-8")


def run_http_server():
    server = ThreadingHTTPServer(("0.0.0.0", HTTP_PORT), Handler)
    server.serve_forever()


def main():
    global WORLD_JSON_BYTES, JOURNEY

    print("[journey_map] loading world data from preview/data/world ...")
    t0 = time.time()
    world = load_world()
    print(f"[journey_map] loaded {len(world['rooms'])} rooms, "
          f"{len(world['mobs'])} mobs in {time.time() - t0:.1f}s")

    JOURNEY = Journey(world)
    WORLD_JSON_BYTES = build_world_json(world)

    threading.Thread(target=run_http_server, daemon=True).start()
    print(f"[journey_map] viewer at http://localhost:{HTTP_PORT}/")
    print(f"[journey_map] point your telnet client at localhost:{PROXY_PORT} "
          f"instead of :{MUD_PORT}")

    run_proxy(JOURNEY)


if __name__ == "__main__":
    main()
