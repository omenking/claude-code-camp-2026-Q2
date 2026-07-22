## Technical Goal
In Week 2 we want the to create an outer agnetic loop to make the agent capable.
Its important we improve its token efficeny, and have very good observability.

## Technical Uncertainty
I am uncertain through prompting alone that we can engineer such a complex outer loop.
I am uncertain if we can make it token efficent, since itelligence may just require a specific amount of cost.
I am uncertain if we will just end up having to rely mostly on "scripts" due to model latency.
Will we simply just end up have an Agent that is simply wearing a trenchcoat of many tranditional scripting and routing logic.

## Technical Hypotheses 
Purely using AI along will fail to achieve build a capable loop.
We will need as humans build the problem infront of us, solving key issues first, and the iterate back again to build a real loop.
AI will fail to handle the level of complexity for development and if we do not keep full ownership of code we will end in a technical dead end.

## Technical Observerations

Since I attempted twice and failed to build a complete outerloop using AI with the most intelligent avaliable models,
Instead of working of closing the outer loop I am going to tackle the each problem in front of me.

### Step 1: Determine a benchmark of token usage from moving from Point A to Point B

I will ask the agent from the starting position move to the bakery and list the menu.
65K tokens and not reaching the bakery often happens.

- We need to "cache" knowledge about each room to reduce traversal.
- The agent isn't checking "exits" to get full exit names making its reasoning navigating an unknown world often random movements
- manually loging in and moving the player back to the starting position is annoying.

### Step 2: Reset Player Script

We will create a reset player script to move the player back to starting position.
./bin/move_player_to_start_room
- we added to the mud_manager admin specific tools
- this script will login as the player and admin
- the admin commands will move the player back to the starting position.

### Step 3: Always Collect Exits Data 

Since we always need to see full exits information create a composite tool call "inspect"
which will show ==look and ==exits

This works, but the are other things we could be learning about new visited rooms, like objects, mobs, npcs and interactions.

- We will need to parse the data and keep a subagent that extract out entities
- We can iterate over entities and use "examine, consider" and other non-dangerous commmands
- We can return structured JSON and the upset this into an SQLITE table.
- We could consider using a local models that is even more cost effective than Haiku but we will stick with Haiku for now.

### Step 4: Subtask Delegation

We need to define a new "task" in our settings.yml called room_inspector.
We will have our player agent call a tool "inspect_room" which in turns will
will call MCP calls to MudManager and have our RoomInspector agent parse the contents.

- Claude suggested that it make MCP calls and just pass the raw data to RoomInspector and no tool use, I disagreed that it RoomInspector should have ownership of calling the MudManager, it should share the Telnet session since only one "task" should run at a time, and I want my player to be the orchestrator and want it to avoid making multiple tool calls when it can delegate out.
- Before even testing now I had a concern of allowing the player having access to "look" command to force it to select inspect_room tool

### Step 5 Allow List (Tool Permissions)

I asked Claude Opus to write me tool permissions. It took multiple iterations since it kept making poor assumptions:
- it only allowed MCP tools to have permissions, I had to tell it all tools define needs permission
- It create allow, deny, and permit, where the last was for graunlar permissions, this was really confusing, so I said only have allow, and by default a task has no tools.
- It updated the settings.yml with a large list of tool commands, I noticed there are many "item" commands "get_item", "drop_item" where other tools are rolled up into single tool calls with parameters, Claude thinks this is fine and 26 tools is not a lot, but I am tempting to roll all items tool into an "item" tool call.
- I decided to not let the playe have access to send_raw so it reasons based on the tools it has.
- We don't have like Claude's API to tell our agent it has to use a tool, or use at least one tool, which is a common tool permission.
- Claude was really confused about what snytax format to use for the permissions, and I did tell it determine the shape of permissions since we want to full granular control and dont want permissions to be brittle.
- I did test asking Claude to move without having the ability to move and it determined it couldn't moved and didn't waste calls.
- for some reason Cluade decided to remove the prefix for tools from MCP and I told it needs to have explict naming to avoid conflicts.
  - I discovered that prefixes are aded in our settings.yml when adding mcp so we have control avoid scoping issue in the future.

## Step 6: Fast Rebuild

I keep forgetting to rebuild my gems, so I created a ascript called .week2_capable/bin/rebuild
to rebuild the mud_manager and boukensha.

## Step 7: Test inspect_room

⠦ Calling tool: inspect_room  (iter 1/25 · 37s · ↑ 3.1k · ↓ 65 · 1 calls)
Calling "inspect_room" is really slow.

- When we move to a new area with move it always "look" information if we want it or not.
  - I dont know if this gets ingested by the LLM on that turn or next so it might not matter.

- [inspect_room_1](./artifacts/inspect_room_1.json)
- [inspect_room_1](./artifacts/inspect_room_2.json)

- Does the agent actually see the response from the subtask?
- In our log_viz we have no sense of time since its not visualized, not even timestamps or duration
- it seems parsing to json is the most expensive task
- the subtask has its own token usage, does it include that in our overall limits?
- it moved several times without calling inspect_room for new rooms navigating blind again
- it never found the bakery this time.
- We can't tell whats going on in a tool call since there is no logging setup
- We could probably use a seperate log of just calls to mud manager so we can see the real underlying calls.

Its concerning that the json part is so painful to debug.

## Step 8: Improved Observability Tool
We obviously need better obserability, the sintra app is fine, but we also have another one to visualize the mud data.
We should just have a single mud monitor:
- see mud manager logs
- see world data visualization
- see agent sessions
I'll create a new plan [mud_monitor](../plans/week2/mud_monitor.md)
Considerable amount of arugments planning with Claude Opus but I told it I want logs at:
  - telnet session raw output
  - mud manager api calls
  - agent sessions
It didn't like security for passwords, or size of logs, but they are okay for our development usecase.
It broke it plan to mud_monitor into 10 phases, Im not sure how much confidence I have in to do that much work.
I only had to run to phase 6, after implementation we discovered that each subtask will spawn a new log/session and thats a problems so I asked Claude to fix it.


## Technical Conclusions
Reflecting back your education guesses from the technical uncertainty section what was the technical outcomes. Is there any new technical uncertainty that has been put aside for future exploration. Are there any next steps or technical considerations worth noting?


## Key Takeaway
In one sentence. State the most important lesson from the week.