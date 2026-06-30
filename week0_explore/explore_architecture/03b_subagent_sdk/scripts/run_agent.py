#!/usr/bin/env python3
"""run_agent.py - drive the play-mud subagent via the Claude Agent SDK.

Registers the play-mud subagent in code via `AgentDefinition` instead of
relying on Claude Code's filesystem discovery of `.claude/agents/*.md`. The
subagent's system prompt is still loaded from a plain markdown file
(agents/play-mud.md) so the prose stays out of this script.

Run it and type requests at the prompt (e.g. "work toward level 7").
"""
import asyncio
import os

from claude_agent_sdk import (
    AgentDefinition,
    AssistantMessage,
    ClaudeAgentOptions,
    ClaudeSDKClient,
    TextBlock,
)

PROJECT_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PROMPT_PATH = os.path.join(PROJECT_ROOT, "agents", "play-mud.md")

PLAY_MUD_DESCRIPTION = (
    "Connect to and play a text-based MUD over telnet (tbaMUD / CircleMUD and "
    "compatible servers). Use this skill whenever the user wants to play, "
    "explore, log into, automate, or interact with a MUD, MU*, or telnet text "
    "game — for example \"play the mud on localhost:4000\", \"log my character "
    "into the MUD\", \"explore the MUD world\", \"fight mobs in the mud\", or "
    "\"send a command to the mud\", \"work toward level 7\", \"defeat a "
    "specific monster\", or \"continue where I left off in the MUD\". It "
    "manages the persistent telnet connection through a background daemon so "
    "you can send game commands and read the server's responses across "
    "separate steps. Defaults target tbaMUD at localhost:4000 with character "
    "dummy/helloworld."
)


def build_options() -> ClaudeAgentOptions:
    with open(PROMPT_PATH) as f:
        prompt = f.read()

    play_mud_agent = AgentDefinition(
        description=PLAY_MUD_DESCRIPTION,
        prompt=prompt,
        tools=["Bash"],
    )
    return ClaudeAgentOptions(
        agents={"play-mud": play_mud_agent},
        cwd=PROJECT_ROOT,
        permission_mode="bypassPermissions",
    )


async def main() -> None:
    options = build_options()
    loop = asyncio.get_event_loop()

    async with ClaudeSDKClient(options) as client:
        print("play-mud SDK driver. Type a request, or 'exit' to quit.")
        while True:
            try:
                user_input = await loop.run_in_executor(None, input, "> ")
            except EOFError:
                break

            user_input = user_input.strip()
            if not user_input:
                continue
            if user_input.lower() in ("exit", "quit"):
                break

            await client.query(user_input)
            async for message in client.receive_response():
                if isinstance(message, AssistantMessage):
                    for block in message.content:
                        if isinstance(block, TextBlock):
                            print(block.text, end="", flush=True)
            print()


if __name__ == "__main__":
    asyncio.run(main())
