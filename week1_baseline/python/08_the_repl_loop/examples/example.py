import os
import sys
from pathlib import Path

STEP_DIR = Path(__file__).resolve().parent.parent
os.environ.setdefault(
    "BOUKENSHA_DIR", str(STEP_DIR.parent.parent.parent / ".boukensha")
)
sys.path.insert(0, str(STEP_DIR))

from boukensha import config, repl


def register_tools(dsl):
    @dsl.tool(
        "read_file",
        description="Read the contents of a file from disk",
        parameters={"path": {"type": "string", "description": "The file path to read"}},
    )
    def read_file(path):
        return (STEP_DIR / path).resolve().read_text()

    @dsl.tool(
        "list_directory",
        description="List the files in a directory",
        parameters={"path": {"type": "string", "description": "The directory path to list"}},
    )
    def list_directory(path):
        return ", ".join(
            sorted(
                entry.name
                for entry in (STEP_DIR / path).resolve().iterdir()
                if not entry.name.startswith(".")
            )
        )


print("=== BOUKENSHA Step 8: The REPL loop ===")
print()
print(f"Config: {config()}")
print()

# Tools are registered once; task defaults and credentials come from config.
repl(configure=register_tools)
