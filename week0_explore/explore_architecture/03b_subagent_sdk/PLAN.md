# Plan: replace filesystem-loaded subagent with inline `AgentDefinition`

## Current state

- `.claude/agents/play-mud.md` defines the `play-mud` subagent purely via Claude
  Code's filesystem discovery convention (YAML frontmatter: `name`,
  `description`, `tools`; body = system prompt).
- There is **no driver script in this directory that uses the Claude Agent SDK
  at all**. `scripts/mud.py` is just the telnet-daemon CLI that the agent
  invokes through its `Bash` tool — it has nothing to do with how the subagent
  itself is defined/loaded.
- Nothing in the repo currently imports `claude_agent_sdk`
  (`pip show claude-agent-sdk` / grep across the repo both came back empty), so
  this isn't an edit to existing SDK code — it's new code.

## Goal

Add a Python driver script that uses the Claude Agent SDK directly and
registers the `play-mud` subagent **in code** via `AgentDefinition`, instead of
relying on Claude Code's filesystem discovery of `.claude/agents/*.md`.

## Proposed changes

1. **Add SDK dependency**
   - `03b_subagent_sdk/requirements.txt` pinning `claude-agent-sdk`.

2. **New driver script**: `03b_subagent_sdk/scripts/run_agent.py`
   - Imports `ClaudeSDKClient` (or `query`), `ClaudeAgentOptions`,
     `AgentDefinition` from `claude_agent_sdk`.
   - Builds the subagent in code:
     ```python
     play_mud_agent = AgentDefinition(
         description="...",   # copied from play-mud.md frontmatter
         prompt="...",         # copied from play-mud.md body
         tools=["Bash"],
     )
     options = ClaudeAgentOptions(
         agents={"play-mud": play_mud_agent},
         cwd=PROJECT_ROOT,
     )
     ```
   - Opens a `ClaudeSDKClient(options)` session, sends the user's request
     (e.g. "play the MUD and work toward level 7"), and streams the response
     to stdout.

3. **Source of truth for the prompt text** — the long instructional body
   currently in `play-mud.md` needs a new home. Two options (pick one, see
   question below):
   - **3a. Inline**: paste it as a Python string constant in `run_agent.py`.
   - **3b. Plain file, explicitly loaded**: move it to a markdown file that is
     *not* under `.claude/agents/` (e.g. `agents/play-mud.md`), and have
     `run_agent.py` `open()` it and pass the contents as `AgentDefinition.prompt`.
     Keeps the prose out of Python source, but loading is explicit/code-driven
     rather than Claude Code's implicit discovery.

4. **Retire (or keep) the filesystem-discovered version**
   - Option A: delete `.claude/agents/play-mud.md` and
     `.claude/settings.local.json` — full replacement, only the SDK path
     remains.
   - Option B: leave `.claude/agents/` untouched and add the SDK script
     alongside it, so both the Claude Code CLI route and the SDK route work
     independently.

5. **Unchanged**
   - `scripts/mud.py` (telnet daemon) — still invoked via `Bash` by whichever
     agent runs.
   - `data/player.md`, `data/world.md` — still the persistent memory files the
     agent reads/writes.

## Open questions for you

1. Delete `.claude/agents/play-mud.md` (full replacement) or keep it side by
   side with the new SDK script (Option A vs B in step 4)?
A:  We want to implement a full replacement.
2. Prompt text: inline string vs. loaded from a plain `.md` file at runtime
   (3a vs 3b)?
A: We want to load a markdown file
3. How should `run_agent.py` receive the user's request — hardcoded prompt,
   CLI argument, or an interactive stdin loop?
A: interactive loop

