import json
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from boukensha import Client, Config, Context, Player, PromptBuilder, Registry, backends

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
    "read_file",
    description="Read the contents of a file from disk",
    parameters={"path": {"type": "string", "description": "The file path to read"}},
)
def read_file(path):
    return Path(path).read_text()


@registry.tool(
    "list_directory",
    description="List files in a directory",
    parameters={"path": {"type": "string", "description": "The directory path to list"}},
)
def list_directory(path):
    return "\n".join(sorted(f.name for f in Path(path).iterdir() if not f.name.startswith(".")))


ctx.add_message("user", "What files are in the current directory?")

provider = Player.provider(player_settings)
model = Player.model(player_settings)

if provider == "anthropic":
    backend = backends.Anthropic(api_key=os.environ["ANTHROPIC_API_KEY"], model=model)
elif provider == "openai":
    backend = backends.OpenAI(api_key=os.environ["OPENAI_API_KEY"], model=model)
elif provider == "gemini":
    backend = backends.Gemini(api_key=os.environ["GEMINI_API_KEY"], model=model)
elif provider == "ollama":
    backend = backends.Ollama(model=model)
elif provider == "ollama_cloud":
    backend = backends.OllamaCloud(api_key=os.environ["OLLAMA_API_KEY"], model=model)
else:
    raise ValueError(f"Unsupported provider for player task: {provider}")

builder = PromptBuilder(ctx, backend)
client = Client(builder)

print("=== BOUKENSHA Step 4: API Client ===")
print()
print(f"Config: {config}")
print(f"Provider: {provider}")
print(f"Model: {model}")
print(f"Sending request to {builder.url()}...")
print()

response = client.call()
print("Raw response:")
print(json.dumps(response, indent=2))
