# Explore Agent Architectures

The largest confusion tech professionals have is applying the correct agent solution
because many solutions appears to overlap responsibilies. 

We will explore multiple agent architecture to determine fit for our agent workload.

## 1. An agent file with referenced files eg. AGENT.md,  @~/docs/*.MD

The simplest agent is creating an "agent file" and possibly importing other files that are read conditionally when needed.

We should attempt to create an agent file and see if it can connect to the MUD and complete a simple goal:
eg. "Find the bakery and list the menu."

We want to use the the smallest and least intelligent model and scale up.

### Technical Observations

Using Haiku 4.5 we created a CLAUDE.md with a simple prompt, and told it will need to manage its own local memory via simple markdown files. We provided it with the location of the MUD and the players credentials.

The agent struggled to connect to the MUD.
The agent would attempt to create temporary code files to manage a telnet connection and execute commands.
The agent did not have enough information about Text User Interface of the MUD to login and see its mistakes.
The agent would try and read files not relating to the task.
Increasing the model intelligence to Sonnet 4.6 did not help.

### Technical Conclusions

We could probably write a better prompt or create an artifact that would give the agent full knowledge of the MUD's Text User Interface to succesfully login, but since this experience is so fixed, it would be better to have a script that exactly knows how to login so we are not wasting token/usage on determinstic user flows.

Coding harnesses tend to go off task and try to write code which we do not need our agent to do.
Coding harnesses at least at this specific architecture stage does not appear to be a good fit.

We are justified to build our own Mud SDK to connect to the MUD since clearly the agent wants to manage the connection via script and execute common commands over the port.

If we had an MCP server to our MUD SDK than maybe we could drive the agent better at this architectual level.

I think due to the complexity of the world and player state data I simply do not think updating markdown files will be sufficent but we never concluded whether the current agentic loop of the coding harness could handle said task.

> Use coding harnesses for coding, and for specialized agents make your own loop.

## 2. Agent Skills driven by main agent eg. ~/.skills

A very common way to drive specific functionality is via Agent Skills which is an open format for agents adopted by many coding harnesses and agent SDKs.

We should create a skill that has its own script to help it connect to a MUD, we should attempt to have it manage its own data.

### Technical Observations

Using the offical claude creator skill to create our skill it was succesful in creating a skill that could reliably connect and play the MUD using Haiku 4.5

It was able to complete simple goals the [despite many calls], and it did stop when given a task that was not possible. So for example when we asked it to practice kick at the guild, it found the correct guild and could tell it had no more kicks it could perform and reported back. But it never considered if it should attempt to level up, how hard it would be to level kick up one more level.

When giving it the broader task to defeat the massive minotaur in the newbie zone it found the newbie zone but did considerable amount of backtracking first trying to find the massaive minotaur and when it couldn't find it, it gave up, it wasn't ever able to open any locked doors.

Even telling the agent it was in the "Red Room" is was single focused on finding that room, and doing nothing else.

A real player would have held the goal, and been more productive expecting it to br the boss of the level, and progressively leveling up and exploring not simply trying to find the end boss.

It did appear to update the world and player state but not in real time which makes it hard to observe what it knows has changed. It should have been collecting observations to explore later, but instead would go back and just brute force not appearing to reason its journey pathing.

Claude Code's agentic loop is a good driver but if Claude Code was to update, we would have no idea how the agentic loop would be affected.

I could see it having a hard time managing the state of just markdown files for memory if they grew too large.
I think we need dyanmic adaptive task management:

eg. Goal: Defeat the Massive Minitaur in the Newbie Zone north of town

Before I find the Newbie Zone and leave the town, do I need to prepare?
- collect information from NPCs for my goal?
- can I obtain any resources?
- any training I need to do?

I should find the Newbie Zone.
- while on path was there anything of interest that should warrant a detour? Would this spawn a sidequest?
- Explorer Mode:
  - Focused: Stay on main quest
  - Curious: Consider sidquests while on main quest, especially if could save backtracking or provide an advantage or resources
  - Aloof: Do all sidequests, and not worry too quickly about mainquest progression

I have found the Newbie Zone.
- Risk Mode:
  - Bold: Try and push exploration to find your end goal, and try to run pass high level mobs, or run away, try and push fighting stronger mobs to level up faster, and take more risks
  - Balanced:  <something inbetwwen>
  - Scared: Don't progress exploration where mobs are higher level or I am at risk of dieing. Take the time to be in a safe area and heal. If hungry and thirsty or risk of losing money backtrack to town always, have plently of resources
    - There can be high level mobs that are not a risk like Town gaurds, context is key, if we are in a forrest of monsters then mobs are higher risk. 

## Technical Conclusions

Agent Skills does work, and quite well, but we will need much more complex state, world and player management.
We really need to have auditable visibility of the agent for reporting token/usage and to review the player journey. We need a custom agentic loop. We want an agent that acts, and spends less time asking "What should it do".

We should probably be defining a Player Persona, which describes how the player like to play, based on a mixed of modes eg: Risk Mode, Exploration Mode etc....

When we enter goal we should see a goal decomposition/planning so we can see how it will reason the goal.

