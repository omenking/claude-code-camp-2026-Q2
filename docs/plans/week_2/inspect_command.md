## Inspect Command

The agent is wasting turns and tokens excuting the following commands in new rooms:
- look
- exits
They need this information to reason where to go next when they don't have traversal information.

A tool call called `inspect` that will use the Mud Manager MCP to call look and exits and return that information to the agent in a single call.

We dont want a slash command.