# What is goal for Week1?

We want to build a baseline agent that has all the common components for building any kind of agent. Things it should include:
- a simple agentic loop
- a tool registry along with tools
- it should be able to handle multiple bankends
- it should be able to produce logs
- it should have an DSL so we can use the agent like an SDK
- it should have global binary execution so we can interact via the CLI
- We should have an option CLI model
- it should manage context and compact messages when reaching out set limit
- it should have its own configuration directory

Some other things we should have:
- log visualizer so we can better view the logs in our browser.

## What should the baseline be able to do?
It should be able to play the MUD though we will have to give it specific commands

## What will not be able to do?
It will have poor peception since it doesn't have a way of managing memory, or decision making, or be token effective.

## Technical Design Considerations
- We will use REST APIs directly, this design choice is so we are understanding how simple it is to interact with Managed APIs and how much they vary.
- Some SDKS even offical ones do not expose all features and so REST API will give full access to feature sets
- We are using Ruby but the end user can port it over to another langauge
- We must used the ruby MudManager to interact with the MUD.
- We should attempt to use the Standard Library (STDs) as much as possible and avoiding introducing third party libraries.

### What should we not use?
- we should avoid using Agent SDKs since they already implement features we are implement by scratch they also might limit our ability to implement exactly what we need.
  - eg. Don't use OpenRouter, Don'ts use Amazon Strands or CoreAgent or LangChain
- We shouldn't be using the Coding harness to drive the agent, since thats is not purposed for our agent task.

## Explain Structure Approach

The `ruby/` folder contains each step-by-step iteration for agent.

### Considerations
-We will need to make some manual adjustments since the original code did not exist in a ruby sub-folder
- AI affected the handwritten code and so we will indentify parts that should be rewritten but we may leave entact not to distrub future layers
- We can and will port the code over to Python, we will have to ensure the MudManager ruby version works with both Ruby and Python.

## Student Completion Approaches
As a student you have some flexbility in how you can get through this week:.
- You can exactly follow along and make the ruby changes.
  - You can treat the ruby implementation as your main implementation
- If you have no interest in the Python porting you can completing ignore those videos.
- You can watch all the videos and then do a single port of the last ruby interation to your langauge of choice.
- You don't have to port the ruby but you will have to use it in your Week 2 when we implement extra capabilities.

## Baseline Mud Agent

The baseline mud agent is a fully working MUD agent that can connect to a tbaMUD server, log in as a character, and control it through natural language.

**What the baseline gives you:**
- A persistent TCP session to the MUD server that stays connected across the agent's tool calls
  - technically the MudManager is persisting the connection
- Five interchangeable LLM backends (Anthropic, OpenAI, Gemini, Ollama, Ollama Cloud) behind one normalized request/response shape, configured per-task in `settings.yaml`
  - Andrew imeplements 5 backends, the student can use a single backend or multiple backends, its up to them.
- MUD tools covering every core action: movement, combat, perception, inventory, magic, and communication
  - MudManager imeplements specific actions, but there are actions missing, eg. Thief commands, rest commands, The student needs to consider solving these at some point, In end of Week 1 or in Week 2.
- A standard tool library for file I/O and shell commands so the agent can also read/write local state
  - These tools are simply mirror the MudManager tools and likely need reworking which does occur in Week 1.
- A multi-turn REPL so you can have a back-and-forth conversation with the agent while it plays
- Full conversation history carried across turns so the agent remembers what it has seen and done
  - This is the sessions log files, but consider we can load previous conversations since we don't implement those features in the Agent.
- Coloured structured logging of every API call, tool dispatch, and response
  - Technically there is a bit of colouring, but the Web-browser logger provides more information.

**What it does not yet have** (to be added in later iterations):
- Long-term memory beyond the current conversation window
- A world model or map built from exploration
- Goal planning, tactical reasoning, or autonomous behaviour
- Character progression tracking or strategy


-  For each of our steps often we will have a class for each eg. Configuration will config, REPL will have repl.rb

### 0 Configuration

`Boukensha::Config` and ~/.boukensha directory stores all our configuration data including secrets, prompts, loggging (aka sessions) and settings file.

We have a env var called BOUKENSHA_DIR that lets override its default location which is in the user's home directory.

We do use .dotenv standard for storing our secrets and we do need to include the dotenv library.

> If we are building an agent that can be deploy on multiple servers a configuration directory seem appropriate. 

### 1 The Struct Skeleton

Define `Boukensha::Tool`, `Boukensha::Message`, and `Boukensha::Context` as plain data containers. No logic yet, just the shapes.

We are defining the main datastructure to pass around data.

### 2 The Tool Registry

The Tool Registory is responsible for managing a data table of possible tools, and also dispatch tools when called. In other words it matches a prompt call to an approaite tool.

> We did discover that the at somepoint the AI regressed the implementation and Context is still responsible for mangaing tools which is not correct and the tools[] need to be moved to the Tool Registry

### 3 The Prompt Builder

Since we are calling multiple backends via direct REST API requests, we need to know exactly their schema structure. So we need to build thoes expected structures.

We also need the prompt builder to normalize the responses into a single standard.

> We have to consider the thinking option models, some models have thinking turn on default where others do not, some cannot turn off thinking. There are other parmeters we can fine tune, but we didn't much time exploring them in the video.

### 4 The API Client

The API Client is simply a low-level http-server making a direct API call to the REST API.

> We end up harcoding the exact OpenSSL path, and this changes based on Windows, Mac or Linux, a third party http-server like HTTPParty or Faraday would solve this but it will abstract more and make it harder to see the moving parts and we would have to take a library so we just fix the code for where we run it.

### 5 The Agent Loop

`Boukensha::Agent` — the core agentic loop. Calls the API, checks `stop_reason`, dispatches tool calls back into the registry, appends results to the context, and repeats until `end_turn` or `MAX_ITERATIONS` is hit. Adds `Boukensha::Errors` (`LoopError`, `ApiError`) and wires everything together in `Boukensha.run`. 

Also brings the OpenAI, Gemini, and Ollama Cloud backends online alongside Anthropic and Ollama — each implements `parse_response` to convert its raw reply into one normalized `{stop_reason:, content:}` shape so `Agent` never has to know which provider it's talking to.

> So we mentioned earleier we need to normalize the repsonses in the prompt backend and so it occurs here I believe we implement that nomralization within the prompt builder and their backends.

### 6 The Logger

We create a logger which will record the logs of a session in ~/.boukensha/sessions/<date>-<session_id>.jsonl

> We have a log_viz app which is a simple sintra app to visualize the sessions, We should really in the future port it to typescript and have it realtime.

We make sure we store exactly which model, which provider and cost, trying up uplift as much information on each call for details reporting and also allowing us to mid conversation switch agents (despite lacking commands to due so in the CLI)

### 7 The Run DSL

Up to the point we have multiple classes we need to create instances of and it becomes a mess of code so we implement a single .run command to abstract away the complexity and give us a SDK like interface to our agent.

`Boukensha::RunDSL` — the object `self` becomes inside a `Boukensha.run { }` block. Exposes a single `tool` method so callers can register ad-hoc tools inline alongside the task, keeping the DSL surface small and the main `Boukensha.run` signature clean.

### 8 The REPL Loop

It lets us have interactive loop for the terminal.

`Boukensha::Repl` — an interactive session that stays alive across turns. Reads user input, runs the agent, prints the reply, and loops back to the prompt. A single `Context` is shared across all turns so the agent sees full conversation history. Built-in commands: `/quiet`, `/loud`, `/clear` (wipe history, keep tools), `/exit` / `/quit`, `/help`. Adds `Boukensha::VERSION`.

### 9 Global Executable

lets us called `boukensha` anywhere in terminal to start using our agent.

> Here we a .boukensharc get introduce which allows use to set the configuration path and the current gem path for boukensha binary to load and we end up having to carry that code in future steps

Packages everything as an installable gem so the `boukensha` command is available anywhere on the machine. Adds `boukensha.gemspec`, `bin/boukensha`, and `lib/boukensha_loader.rb`. The loader resolves which step folder to use in priority order: `BOUKENSHA_PATH` env var → `~/.boukensharc` file → bundled default. `BOUKENSHA_DEBUG=1` prints the resolved path on startup.

```sh
cd 09_global_executable
gem build boukensha.gemspec
gem install boukensha-0.9.0.gem

BOUKENSHA_PATH=~/Sites/boukensha/09_global_executable boukensha
```

Each step from here on ships its own gem the same way (`gem build boukensha.gemspec && gem install boukensha-<version>.gem`) — point `BOUKENSHA_PATH` at whichever step folder you want to run.

> We skip this step for Python port, Not sure if that was a bad idea but we do that.

### 10 Standard Tool Library — MCP Host

We are implementing a mapping of tools for the agent from the Mud Manager.
However when we went to port the code to Python the python app had no way of accessing the MudManager ruby version so we end up implementing MCP

> The MCP implemenating is a 2 hour video and its worth watching but not doing, so I would recommend copying over the MudManager and the 10_standard_tool_library from omenking repo.

>We end up adding the MCP server within Mud Manager so its a single gem.

> Also due the major code changes we end up having to carry forward code which makes the ruby step more involved.


This step originally shipped three built-in tool modules (`Tools::FileSystem`, `Tools::Shell`, `Tools::Mud`). That code has since been **deleted and replaced** by an MCP-host rewrite that also applies to every step after this one — the directory keeps its `10_standard_tool_library` name only so step ordering and existing paths still resolve.

Boukensha now ships **no tools of its own**. It is an MCP *host*: every tool the agent can call comes from an MCP server declared in `settings.yaml`. An agent with an empty `mcp_servers:` block can only talk.

- **`Boukensha::Mcp::Client`** — a minimal MCP-over-stdio client: spawn a server, handshake, `tools/list`, `tools/call`. Server-agnostic; `command` / `args` / `env` is the standard stdio transport config.
- **`Boukensha::Tools::Mcp`** — the only file left under `tools/`. Registers a server's discovered tools into the registry, optionally scoping their names with a `prefix:` (client-side only — a collision between two servers' tool names raises rather than silently clobbering).
- **`mcp_servers:` in `settings.yaml`** — adding a capability is a config edit, not a code change. Each entry takes `command`, `args`, `env`, `prefix`, and `required: false` (downgrade a failed start to a warning instead of an error).
- File access and shell commands now come from whichever filesystem/shell MCP server you plug in. MUD gameplay comes from the `mud-manager --mcp` daemon (the same `mud_manager` gem the old `Tools::Mud` wrapped, now run as a separate process).
- `working_dir:` survives on `Boukensha.run` / `.repl` but is now Context metadata only — it registers nothing.

### 11 Terminal UI

TUI is just a nicer REPL, so it has advanced display features within terminal

> We use Charm's BubbleTea for the TUI in Ruby, AI thnks bubble Tea is not avaliable for python and so ends up using Texual. In honestly sinc we have the log_viz we don't really need a TUI but in my original implementation I implemented log_viz later.


Adds a full terminal UI (TUI) on top of the MCP-host tool model, built on the [`charm`](https://github.com/charm-ruby/charm) gem (bubbletea + lipgloss + bubbles). The plain REPL is still there via `tui: false`.

- **`Boukensha::Tui`** — wraps a `Repl` and replaces raw `puts`/`gets` with a four-zone display: scrollable conversation viewport, a live progress line (spinner, iteration counter, elapsed time, token counts, tool call count), an input box, and an always-on status line (version, model, context tokens used/max, tool count, wall-clock time). The agent runs on a background thread so the UI stays responsive during a turn.
- Keyboard shortcuts: `Enter` submit, `Esc` interrupt the running turn, `Ctrl+L` clear history, `PgUp`/`PgDn` scroll, `Ctrl+C`/`Ctrl+D` quit.
- **`Boukensha.repl(tui:)`** — `true` (default) launches the charm TUI, `false` falls back to the plain REPL. `--no-tui` sets this from the command line.
- **`Repl` refactored for composability** — no longer hard-codes I/O. `on_output(&block)`, `handle_command(input)`, and `run_turn(input)` are public so any front-end can drive it.
- **`Logger#subscribe`** — every structured log event is now broadcast to subscribers in addition to being written to the JSONL file, which is how `Tui` updates its progress line in real time without polling.

### 12 Context Management

There is no auto-compacting when you call an LLM directly — you're responsible for the context window. This step adds proper token tracking, visual warnings, and automatic compaction on top of the MCP-host tool model and TUI carried forward from steps 10–11.

> There should be settings exposed to increase the 600 eg. 60,000 max token limit, as that is a very low amount but we never tested in Week1 but it probably can be adjusted.

- **Accurate token tracking** — `Context` now tracks `context_window` (the model's max input capacity, from `Boukensha::Models.context_window(model)`) separately from `current_tokens` (actual usage from the most recent API response), fixing an earlier display that conflated the output-token budget with the context window and let a cumulative session sum grow unbounded past `/clear`.
- **`Boukensha::Models`** — a static model → capability table built from every backend's own model list, so `Context` can be sized correctly before a backend is constructed. Unknown models fall back to a conservative default rather than assuming a huge window.
- **Colour-coded context indicator** — grey under 70% used, yellow 70–84%, red (with a `⚠`) at 85%+, shown in both the progress and status lines.
- **Auto-compaction** — at the start of each turn, if usage crosses `agent.compaction_threshold` (default 0.85), `Context#compact_messages!` drops the oldest ~40% of messages (keeping at least 2) before the next API call. `/compact` triggers it manually from the REPL or TUI. Emits a `Logger#compaction` event that the TUI renders as a notice in the conversation view.
- **A second circuit breaker** — `Agent` now stops a turn on whichever trips first: `max_iterations` (tool-call count) or the new `max_turn_tokens` (cumulative input+output tokens spent this turn). Both read from `settings.yaml`'s `agent:` block.
- **Normalized reasoning blocks** — every backend now surfaces provider-specific "thinking" output (Anthropic `thinking`/`redacted_thinking`, Gemini `thought`/`thoughtSignature`, Ollama `message["thinking"]`) as a common `{"type" => "reasoning", ...}` content block, logged via `Logger#reasoning`.
- **OpenAI backend moved to `/v1/responses`** — gpt-5.x rejects `reasoning_effort` + tools on `/v1/chat/completions`. Messages become `input` items, the system prompt becomes a top-level `instructions` string, and tool results round-trip via `function_call_output` items matched by `call_id`.
- **`Boukensha.run` / `.repl` — `context_window:` keyword** replaces `token_budget:`, defaulting to `Models.context_window(model)`.
- **`Logger#response` cost metadata** — every response event now carries provider, model, token counts, and an estimated USD cost via `Backends::Base#estimate_cost`.

## Not Yet Built

The following were sketched as a roadmap in an earlier version of this document but have not been started — no orchestrator, turn-counter wrapper, or memory-store code exists anywhere in `ruby/` yet:

- An orchestrator layer around the existing agent loop (turn counting, an `orchestrator.run_turn()` wrapping the loop as an "Executor" stage)
- Persistent memory stores — World, Character, Episodic, Semantic — beyond the current conversation window

## Architecture — Final Baseline (Step 12)

```
                         ┌───────────────────────┐
                         │    Boukensha::Tui      │  viewport / progress
                         │    (or plain Repl)     │  / input / status line
                         └───────────┬────────────┘
                                     │ run_turn(input)
                                     ▼
                         ┌───────────────────────┐
                         │   Boukensha::Agent     │  max_iterations
                         │    the agent loop      │  max_turn_tokens
                         └───────────┬────────────┘  compaction_threshold
                    ┌────────────────┼────────────────┐
                    ▼                ▼                ▼
          ┌────────────────┐┌────────────────┐┌────────────────┐
          │    Context      ││    Client      ││   Registry     │
          │  messages       ││ → Backends::   ││  dispatch()    │
          │  tools          ││   Anthropic    │└───────┬────────┘
          │  current_tokens ││   OpenAI       │        │
          │  context_window ││   Gemini       │        ▼
          │  compact_msgs!  ││   Ollama       │┌────────────────┐
          └────────────────┘│   OllamaCloud  ││  Tools::Mcp    │
                             └────────────────┘│  (prefix: ns)  │
                                                └───────┬────────┘
                                                        │ stdio
                                                        ▼
                                            ┌───────────────────────┐
                                            │      Mcp::Client       │
                                            │ spawn / handshake /    │
                                            │ tools_list / tools_call│
                                            └─────┬─────────────┬────┘
                                                  ▼             ▼
                                        ┌───────────────┐┌───────────────┐
                                        │ mud-manager    ││ filesystem /  │
                                        │ --mcp          ││ shell / other │
                                        │ (CircleMUD)    ││ MCP servers   │
                                        └───────────────┘└───────────────┘

   Logger#subscribe fans every event (iteration, tool_call, tool_result,
   response, compaction, reasoning) out to two places at once: the TUI's
   live progress line, and a JSONL file on disk.
```
