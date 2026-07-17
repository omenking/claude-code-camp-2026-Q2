Our MudManager is written in Ruby.
In our Bootcamp, Bootcampers want to ouse their own langauge eg. Java, Python, Rust, Go.

What is the solution?
- We have to create wrapper per lang
- We make MudManager a command line tool, and other langs execute shell commands in their langs
- We implement a communication protcol
- We implement MCP as a layer.

Consider taht the MudManager is managing the sessions for the Mud.

## Technical Exploration

### 1. The problem is narrower than "port MudManager"

MudManager is two things wearing one coat, and they have opposite portability profiles:

| Component | Nature | What it does | Cost to reimplement per language |
| --- | --- | --- | --- |
| `MudManager::Session` | **Stateful, long-lived** | Holds a TCP socket, runs a background reader thread, strips telnet IAC bytes, buffers async chatter, implements `read_until` / `read_until_quiet` / `read_until_prompt` and the multi-step login dance. | **High.** Subtle, concurrency-heavy, bug-prone. The value of the gem lives here. |
| `MudManager::Primitives` | **Stateless, pure** | Validates enum args and returns a command *string* (`"kill goblin"`, `"cast 'fireball' orc"`). No I/O, no state. | **Low.** It is string templating + a few frozen enum lists. |

This split is the whole ballgame. Nobody should reimplement `Session` four times — that is where the concurrency bugs, the IAC edge cases, and the login state machine live. `Primitives`, by contrast, is essentially a **data table** (verb + arg-shape + allowed enums) that any language can render, and it can even be generated from a single spec file.

So the real question is not "how do we port MudManager to Java/Python/Rust/Go" but:

> **Where does the one stateful `Session` live, and how do foreign-language agents drive it?**

### 2. Why the naive CLI option collapses

Option "make MudManager a command-line tool and shell out" fails on the statefulness above. A MUD session is a **persistent socket** with a background thread draining async output. If each `mud_manager send "look"` were its own process:

- the socket would open and die within that one invocation — the login dance and world state would be gone by the next call;
- async output (combat ticks, other players) arriving *between* commands would be lost, because no process is listening;
- you'd re-run the ~1–2s login dance on every single command.

The only way a "CLI" works is if it is a **long-running daemon** that one command *starts* and subsequent commands *talk to*. But "a long-running process you send messages to" **is** the communication-protocol option. So options 2 and 3 are the same option; the naive per-command CLI is off the table.

This leaves three genuinely distinct architectures.

### 3. The three real candidates

#### Option A — Port the library to each language
Each track (Ruby/Python/Rust/Go/Java) ships its own `Session` + `Primitives`.

- ➕ No inter-process moving parts; native, debuggable in the bootcamper's own stack.
- ➖ The hard part (`Session`) is reimplemented N times → N sets of telnet/threading/login bugs, N things to keep in sync when CircleMUD behavior changes. Primitives drifting between languages is guaranteed.
- ➖ Highest total maintenance; worst reproducibility across the cohort.
- **Verdict:** Acceptable only if `Session` is genuinely trivial in a target language (it isn't — background reader + quiet/prompt detection is the tricky bit). Reject as the default.

#### Option B — One session daemon + a thin JSON line protocol
Keep the single Ruby `Session`. Wrap it in a long-lived process that speaks a tiny **newline-delimited JSON** protocol over **stdio** (spawned as a child of the agent) or a local socket.

Request/response sketch (one JSON object per line):

```jsonc
// framework → daemon
{"id":1,"op":"connect","host":"localhost","port":4000}
{"id":2,"op":"login","name":"Gandalf","password":"secret"}
{"id":3,"op":"send","raw":"kill goblin"}        // or {"op":"primitive","name":"attack","args":{"style":"kill","target":"goblin"}}
{"id":4,"op":"read_prompt","timeout":10}
{"id":5,"op":"close"}

// daemon → framework
{"id":4,"ok":true,"text":"You hit the goblin. It shrieks...\n<100hp 50m 30v>"}
{"id":2,"ok":false,"error":"LoginError: wrong password"}
```

- ➕ The stateful session exists **once**, in Ruby. Every language writes a ~30–50 line client (open a pipe, write JSON, read a line). No MUD/telnet knowledge needed in any other language.
- ➕ Great pedagogy: bootcampers implement a real protocol client — a transferable skill.
- ➕ Primitives can stay server-side (validated once) **or** ship as a spec (below) and be validated client-side.
- ➖ We invent and document a bespoke protocol; every track writes (a little) plumbing.
- **Verdict:** Strong, minimal-dependency baseline. This is the substrate everything else builds on.

#### Option C — Expose the daemon as an MCP server
Same daemon as B, but the protocol is **MCP** (JSON-RPC 2.0 with tool discovery) instead of a bespoke line format. MCP is *exactly* "a standard way to expose a set of tools to an agent," which is precisely what the boukensha frameworks already do internally — they register MUD tools and let the LLM call them.

- ➕ **Zero protocol code per language.** Every agent SDK the bootcampers build against can already speak to an MCP server; they point their MCP client at `mud-manager` and instantly get typed MUD tools with schemas + descriptions.
- ➕ Tool schemas (names, enums, descriptions) are served *by the daemon*, so there is **one source of truth** — no per-language tool drift.
- ➕ Natural transport is **stdio**: the agent spawns the MCP server as a subprocess, so session lifecycle == subprocess lifecycle (auto-cleanup, no port management — matters on WSL2/Windows).
- ➖ Requires each track's framework to have an MCP client. Heavier than a 30-line JSON reader.
- ➖ MCP tools are *LLM-facing*; session lifecycle (connect/login) is *framework-facing* and deterministic. Exposing `login` as an LLM tool is wasteful and error-prone (see §5 for the fix).
- **Verdict:** Best fit for *this* bootcamp because the deliverable is tool-calling agents and MCP is the lingua franca of tools.

### 4. Recommendation

**Build the single Ruby session daemon (Option B substrate) and put an MCP facade on it (Option C) as the primary, blessed interface. Ship `Primitives` as a language-neutral spec, not as ported code.** Concretely:

1. **`mud-manager` daemon** — one process, owns exactly one `MudManager::Session`. This is the only place telnet/threading/login lives, forever.
2. **MCP facade over stdio** — the agent framework spawns `mud-manager --mcp` as a subprocess. This is the interface 90% of bootcampers use; they write no protocol code.
3. **Raw JSON-line mode** (`mud-manager --stdio-json`) — the same daemon, bespoke protocol, as the lower-level escape hatch and teaching artifact for tracks that want to implement a client by hand. (MCP is itself just JSON-RPC over this same pipe, so this is nearly free.)
4. **`primitives.json` spec** — a single machine-readable table describing every primitive (verb, arg names, arg types, allowed enums, help text). The daemon generates its MCP tool schemas from it; any track that wants *local* typed builders generates them from the same file. One source of truth, no drift.

```jsonc
// primitives.json (excerpt) — the language-neutral source of truth
{
  "attack": {
    "verb_template": "{style} {target}",
    "args": {
      "style":  {"type":"enum","values":["hit","murder","kill"]},
      "target": {"type":"string","required":true}
    },
    "description": "Attack a target with the given style."
  },
  "move": {
    "verb_template": "{direction}",
    "args": {"direction": {"type":"enum","values":["north","east","south","west","up","down"]}},
    "description": "Move one step in a compass direction (or up/down)."
  }
}
```

Rationale: this pays the hard cost (stateful session) **once**, gives every language a first-class path with **no protocol code** (MCP), keeps a **teaching-friendly** low-level path (JSON lines), and makes primitive definitions **un-driftable** across the cohort (shared spec).

### 5. Design detail: hide the session lifecycle behind the tools

The one real friction with MCP is that connect/login are deterministic framework concerns, not decisions we want an LLM making. Resolve it by having the **daemon own the session lifecycle internally**:

- Credentials + host/port come from **env/config** (`MUD_NAME`, `MUD_PASSWORD`, `MUD_HOST`, `MUD_PORT`), exactly as `live_session_test.rb` already does — never from LLM tool args.
- On the **first gameplay tool call**, the daemon lazily `connect`s and runs the `login` dance. On a dropped socket it transparently reconnects and re-logs-in (the gem already models `Reconnecting` vs fresh login).
- The LLM therefore only ever sees **gameplay** tools (`look`, `move`, `attack`, `cast`, `shop`…) plus a `send_raw` escape hatch — the exact surface the boukensha `Mud` tool module already exposes. The stateful complexity is completely invisible above the daemon boundary.

This turns a stateful session into a **stateless-looking** set of tool calls — which is what makes the MCP mapping clean.

### 6. Tool/response surface (maps 1:1 to existing boukensha tools)

The daemon exposes essentially what `week1_baseline/ruby/10_standard_tool_library/lib/boukensha/tools/mud.rb` already registers, so this is a repackaging, not a redesign:

- Perception: `look`, `examine`, `check`
- Movement: `move`, `flee`, `set_position`, `track`
- Combat: `attack`, `skill_strike`, `consider`
- Comms: `say`, `tell`, `channel_say`
- Inventory/equip: `get_item`, `drop_item`, `put_item`, `equip_item`, `consume_item`
- Magic: `cast_spell`, `use_magic_item`
- Utility: `shop`, `practice`, `save_character`, `send_raw`

Every tool internally does the same thing the boukensha `send_cmd` lambda does today: `drain` stale bytes → `send_command(primitive)` → `read_until_prompt` → return text. That logic moves *into the daemon* so all four languages inherit it for free.

### 7. What each track actually writes

- **Ruby:** nothing new — use the gem directly, or the daemon for parity with the others.
- **Python / Go / Rust / Java (MCP path):** point the framework's MCP client at `mud-manager --mcp`. Register the discovered tools into their own registry. Zero MUD/telnet code.
- **Any track (raw path, optional):** ~40-line client that spawns the daemon and exchanges JSON lines — a good exercise, not a requirement.

### 8. Trade-offs summary

| Criterion | A: Port per lang | B: Daemon + JSON | C: Daemon + MCP (recommended) |
| --- | --- | --- | --- |
| `Session` implemented once | ❌ N times | ✅ once | ✅ once |
| Protocol code per language | n/a | ~small | ✅ none |
| Tool-schema drift | ❌ high | ⚠️ if client-side | ✅ served centrally |
| Fits "build tool-calling agents" goal | ⚠️ | ⚠️ | ✅ native |
| Extra runtime dependency | none | none | MCP client |
| Lifecycle/cleanup | native | manage process | ✅ subprocess = session |
| Pedagogical value | high (but duplicated) | high (protocol design) | high (industry-standard integration) |

### 9. Open questions / risks

1. **One session vs many:** stdio-per-agent gives one session per subprocess (clean). If we ever want *many* agents on *one* character or a shared world-observer, we need a socket daemon with client multiplexing — defer until needed.
- We should be able to handle multiple sessions
2. **Async chatter delivery:** today `read_until_prompt` folds async lines into the next command's response. If agents need *unprompted* pushes (combat while "idle"), MCP needs server-initiated notifications or a `poll` tool. Start with poll; it's simpler.
- sure
3. **Timeouts/backpressure:** the daemon must surface `Timeout`/`ConnectionError` as structured errors (see the `ok:false` shape) so foreign clients can branch, rather than parsing prose.
- sure
4. **Spec ownership:** `primitives.json` must be generated from (or the generator of) the Ruby `Primitives` enums so the two never diverge — pick one as canonical. Recommendation: make `primitives.json` canonical and have Ruby load/validate against it too.
- ruby would be canonical
5. **Packaging/distribution:** how bootcampers *get* `mud-manager` (gem + shim binary? container? prebuilt executable?) so a Rust/Go student isn't forced to set up a Ruby toolchain. A small container or a `mud-manager` launcher script is the likely answer.
- mud manager is already a ruby gem taht you install, so why can't we just make it a binary that we start up an mcp server?
- Answered: [`single_gem.md`](single_gem.md) folds the daemon into the `mud_manager` gem itself, shipping `mud-manager` as that gem's own binary — one `gem install`, no second gem to version-lock.