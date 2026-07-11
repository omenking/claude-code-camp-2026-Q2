# Preweek Technical Documentation

## Technical Goal
The technical goal of Preweek (Explore) is to determine how well do Agent Architectures fit our business use-case.

[Ref 1] Examples of Agent Architectures That Scale With Effort:
- An agent file with referenced files eg. AGENT.md,  @~/docs/*.MD
- Agent Skills driven by main agent eg. ~/.skills
- Filesystem Subagent driven by a coding harness or Coding Agent SDK eg. ~/subagents
- AI workflow automation platform eg. n8n
- Use a generic AI Agent SDK that leverages plug and plays generic AI packages.
- Use low level first-party LLM SDKs and write our own agentic loop
- Use REST APIs directly, write our own agentic loop
  - The agentic loop is model-driven orchestration  with middleware programmatic guidance
  - The agentic loop is code-driven orchestration

## Technical Uncertainty
- I'm uncertain if an coding harnesses agentic loop is effective/productive enough to drive a non-coding workload.
- I'm uncertain if LLMs model's thinking mode and other intelligent parameters is sufficent enough to hold memory and drive decisions for work specific use-case.
- I'm uncertain that a coding harnesses can interact with a MUD without an interface or SDK or manage the telnet session.

## ## Technical Hypotheses
- Based on our [Ref 1] I think that we will have issues with the coding harness driving the MUD without an interface because we don't a defined API, we are driving commands over a protocol that we need to live-monitor. Telnet communication seems like it would be a sticking point.

- I think we will need an interface because mangaging a long-lived telnet session may prove difficult. In the past I've always found managing live-sessions challenging.

- I think that only agent architecture that will be able to drive our use-case will be where we implement a specialized agentic loop, as I think generic models memory will not be capable enough to remember and navigate the MUD world.

- I think that we need to roll-our-own agent without an SDK because generic primitives for observability, for memory, and our use-case will required  specialzed implementation. And that we want to connect broadly will all frontier models and many SDKS will lack one of them.

## Technical Observerations
- An Agent.md could not connect to the MUD, it could produces scripts but it was unreliable in creating a connection to the MUD and needed knowledge of the deterministic TUI of the MUD.
- Skills and Subagents preformed accompanied with a script to manage the telnet session. They were able to play the MUD, but maybe not efficiently
- Using Markdown files where the coding harness updates simple memory files produced brittle navigation instructions. eg:

```sh
To reach the **Newbie Zone** from Market Square:
1. `north` → Temple Square
2. `north` → Temple
3. `north` → Altar
4. `north` → Behind Altar
5. `north` → Great Field
6. `north` → Great Field (with newbie zone sign)
7. `east` → Newbie Zone entrance
8. `north` → Enter corridor
```

## Technical Conclusions
- Skills and Subagents are capable of driving the MUD.
- We do need specialized memory for map navigation and world data
- We opened a new technical use-case of if we should have our agent handle multiple sessions of multiple player, playing at the same time since co-op is a common factor in MUDs which we forget to consider in our design.
- We could not explore n8n completely due to technical restraints executing external scripts.
- Implementing our own specialized loops remain technical uncertain and will need to be explored in depth in Week 2.
- Without a customized agentic loop the agents could not preform goals efficently. And did not have any key meta strategies or journey player strategies.

## Key Takeaway
When we have a specialized use-case like a playing MUD, we likely cannot leverage generic SDKs for Agents because we need specialized tooling and agentic loops.