import os
from pathlib import Path

import yaml
from dotenv import load_dotenv


class Config:
    """The .boukensha config directory is resolved in this order:
    1. BOUKENSHA_DIR environment variable (set before loading .env)
    2. ~/.boukensha (default)
    """

    DEFAULT_DIR = Path.home() / ".boukensha"

    # Default prompts shipped alongside this step.
    PROMPTS_DIR = Path(__file__).resolve().parent.parent / "prompts"

    def __init__(self):
        self.dir = self._resolve_dir()
        self._load_env()
        self.settings = self._load_settings()

    # ---------- tasks -----------------------------------------------------

    def tasks(self, name=None):
        """With no argument: returns the full tasks dict from settings.yaml.
        With a name: returns that task's settings dict, e.g. tasks("player").
        """
        all_tasks = self.dig("tasks") or {}
        return all_tasks.get(name) if name else all_tasks

    @property
    def user_prompts_dir(self):
        """The user's prompts directory for task prompt overrides."""
        return os.path.join(self.dir, "prompts")

    # ---------- provider ----------------------------------------------------

    @property
    def provider_type(self):
        return self.dig("tasks", "player", "provider") or "anthropic"

    @property
    def model(self):
        return self.dig("tasks", "player", "model") or "claude-haiku-4-5"

    # ---------- MCP servers -------------------------------------------------

    @property
    def mcp_servers(self):
        """MCP servers to plug into the agent, keyed by name. This is where ALL
        of the agent's tools come from — boukensha ships none of its own:

            mcp_servers:
              mud:
                command: mud-manager
                args:    [--mcp]
                prefix:  tbamud
                env:
                  MUD_HOST: your.mud.host      # a stdio server's credentials
                  MUD_NAME: Gandalf            # travel by environment

        Returns {"mud": {"command":, "args":, "env":, "prefix":, "required":}}
        with defaults applied. `required: False` lets a server fail to spawn
        without taking the agent down with it.
        """
        raw_servers = self.dig("mcp_servers") or {}
        out = {}
        for name, raw in raw_servers.items():
            entry = raw if isinstance(raw, dict) else {}
            required = entry.get("required")
            out[str(name)] = {
                "command": str(entry.get("command") or ""),
                "args": [str(a) for a in (entry.get("args") or [])],
                "env": {str(k): str(v) for k, v in (entry.get("env") or {}).items()},
                "prefix": str(entry["prefix"]) if entry.get("prefix") is not None else None,
                "required": True if required is None else bool(required),
            }
        return out

    # ---------- agent limits ------------------------------------------------
    # Static per-turn circuit breakers, read where the agent is constructed.
    # A value of 0 or nil means "disabled" (no ceiling) — useful for debugging.

    @property
    def agent_max_iterations(self):
        value = self.dig("agent", "max_iterations")
        return 25 if value is None else int(value)

    @property
    def agent_max_output_tokens(self):
        value = self.dig("agent", "max_output_tokens")
        return 1024 if value is None else int(value)

    @property
    def agent_max_turn_tokens(self):
        value = self.dig("agent", "max_turn_tokens")
        return 60_000 if value is None else int(value)

    @property
    def agent_compaction_threshold(self):
        value = self.dig("agent", "compaction_threshold")
        return 0.85 if value is None else float(value)

    # ---------- low-level helpers -----------------------------------------

    def dig(self, *keys):
        """Fetch a nested key path from settings, e.g. dig("mud", "host")"""
        node = self.settings
        for key in keys:
            if isinstance(node, dict):
                node = node.get(key)
            else:
                return None
        return node

    def __str__(self):
        return f"#<Boukensha::Config dir={self.dir} provider={self.provider_type} model={self.model}>"

    def __repr__(self):
        return str(self)

    def _resolve_dir(self):
        explicit = os.environ.get("BOUKENSHA_DIR")
        if explicit:
            return str(Path(explicit).expanduser().resolve())
        return str(self.DEFAULT_DIR.expanduser().resolve())

    def _load_env(self):
        env_file = os.path.join(self.dir, ".env")
        if os.path.exists(env_file):
            load_dotenv(env_file)

    def _load_settings(self):
        settings_file = os.path.join(self.dir, "settings.yaml")
        if os.path.exists(settings_file):
            return yaml.safe_load(Path(settings_file).read_text()) or {}
        return {}
