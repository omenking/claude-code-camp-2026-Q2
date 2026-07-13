import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from boukensha import Config, Context, Player, Registry, UnknownToolError

os.environ.setdefault(
    "BOUKENSHA_DIR", str(Path(__file__).resolve().parent.parent.parent.parent.parent / ".boukensha")
)

config = Config()
player_settings = config.tasks("player")
system_prompt = Player.system_prompt(
    player_settings,
    user_prompts_dir=config.user_prompts_dir,
    default_prompts_dir=Config.PROMPTS_DIR,
)

ctx = Context(task=Player, system=system_prompt)
registry = Registry(ctx)


@registry.tool(
    "move",
    description="Move the player in a direction (north, south, east, west, up, down)",
    parameters={"direction": {"type": "string"}},
)
def move(direction):
    return f"You move {direction} into a torch-lit corridor."


@registry.tool(
    "shout",
    description="Shout a message so everyone in the zone can hear it",
    parameters={"message": {"type": "string"}},
)
def shout(message):
    return message.upper()


print("=== BOUKENSHA Step 2: Tool Registry ===")
print()
print(f"Config:  {config}")
print(f"Context: {ctx}")
print("Tools:")
for t in ctx.tools.values():
    print(f"  {t}")
print()

print("Dispatching 'shout' with message='dragon spotted'...")
result = registry.dispatch("shout", {"message": "dragon spotted"})
print(f"Result: {result}")
print()

print("Dispatching 'move' with direction='north'...")
result = registry.dispatch("move", {"direction": "north"})
print(f"Result: {result}")
print()

try:
    registry.dispatch("flee")
except UnknownToolError as e:
    print(f"UnknownToolError caught: {e}")
