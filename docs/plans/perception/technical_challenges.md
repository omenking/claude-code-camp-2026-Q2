## Baseline Usage

Lets give our agent a simple task we know that can be completed and determine how many tokens it uses.
> Find the bakery and tell me what is on the menu

- 65.0k and it did not find the bakery.
- I notice the agent isn't using "exits" command to help its navigation, I will attempt to update the system prompt.

Exits and Look commands we basically want to constantly do.
It may be better if we have an inspect_room function that will use the mud manager
directly to 



## Perception Layers

We need to reduce the cost of perception.
Its currently costly since our baseline agent consumes the text of every room.








## Reducing Token Count
The biggest issue with our baseline agent is that its ingesting on every single the look command information. Once a room is visted we generally know about the room.

We could be interested in things that change in the room.
Mobs and NPCs can move around which can look like can change.

## Data Store

### Graph
Because rooms are connected to each other, you would think that a graph
database would be the ideal choice sinc we have tranverse a graph.

We have hundreds of rooms which is not a lot and graph databases can handle alot of nodes.
If we express what kind of information we can back in a query that might help us determine if a graph database is a fit.

Claude is not convinced we need a graph database an a relational database can handle it.

? Your agent's real workload is: many-hop pathfinding done in-memory (not queried), plus lots of simple attribute lookups and single-hop exit checks. Multi-hop relationship queries that would actually justify Cypher's expressiveness (recursive CTE territory) are rare and better handled by loading the graph once and traversing it in code anyway — because you want that traversal fused with agent-specific logic (risk scoring, loot priority, "avoid rooms I died in"), which lives awkwardly in a query language regardless of which one you pick.

> SQLite + an in-memory adjacency structure for pathfinding is the sweeter spot. Want me to sketch the schema plus a small pathfinder module together, so you can see the whole pattern end to end?

Probably SQLITE is the best choice since our dataset is very small.

Pathfinding: in-memory BFS/Dijkstra over the adjacency list.
## Vector

Anything structural — exits, room IDs, "where am I," pathfinding — a vector DB is the wrong tool. Embeddings measure semantic similarity, not exact relationships. Don't use it as a substitute for the rooms/exits schema.

1. Fuzzy matching room/object descriptions across resets or variants. MUDs often regenerate or slightly reword room text ("A dusty crypt lies before you" vs "You stand in a dust-covered crypt"). If your agent is trying to recognize "have I been here before" purely from text (no stable room ID feed, e.g. scraping raw game output), embedding the description and doing a similarity search against previously-seen rooms is a legitimate use case that plain SQL text-matching won't handle well.

query: embed("A dusty crypt lies before you, cobwebs cover the walls")
search against: room_description_embeddings
→ returns closest match with similarity score

That's a real graph-DB-can't-do-this, SQL-can't-do-this-well problem.

2. Semantic recall over freeform agent memory/notes. If your agent logs things like "this NPC seemed hostile," "found a hidden lever behind the painting," "this shop had good prices," and later needs to answer something like "have I encountered anything like a hidden mechanism before?" — that's a semantic query, not an exact-match one. Vector search over a notes table is a good fit.

3. Matching player/user free-text commands to known actions, if your agent is interpreting loosely-phrased instructions ("go bug the shopkeeper about prices" → map to a known "haggle" action). This is classic embedding-similarity territory.

4. Retrieval-augmented behavior against game lore/help files. If the MUD has help text, quest lore, or wiki-style docs and you want the agent to reason using that context, chunk-and-embed-and-retrieve is the standard RAG pattern and works well here.

> I think Claude is wrong here because we are exploring room per room, we know what each room is once we visit due to exits, location. A vector database doesn't really fit our need.

## SQL Schema

it seems like SQL will be our winning data store but we need to determine the data structure:

# rooms
- name: 
  - we will need a unique name for the room
  - consider names in the real game can be repeated 
  - some locations dont have names.
- description: we should probably provide a descripton that AI decides to summarize
- seen_entities[] - a list of entities in the room that you have seen in this room
  - We will need to use look and other commands to identify the entities
  - some entities are fixed and others are not.
- exits[]
 - exits to other specific rooms





- Name: the name of the location
- Description


## Creative Reasoning
My goal to defat the minotaur in the newbie zone.
I have explored everywhere I have found a locked door and a locked grate.
I see no path forward so I need to figure out how to unlock the door.

What would be the reasonable boundaries of solving the problem:
problem: I dont have key
- the key is likely in the newbie zone
- the key is held by someone one
- the key is hidden within interactive entity eg. under rock

I see a gaurd, I looked at them and they never mentioned having a key, and they room description doesn't a key.

They are a guard, and gaurds do have key,
The guard is outside of town, and therefor I will not negative alignment for killing them.
If I kill them they will respawn



How does the agent know that their obstacle is a door?
How will they know to reason to try to find one?>