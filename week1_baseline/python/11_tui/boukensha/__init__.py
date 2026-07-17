from .config import Config

_config = None
_quiet = False
_debug = False


def config():
    """Return the process-wide, lazily constructed configuration."""
    global _config
    if _config is None:
        _config = Config()
    return _config


def quiet():
    global _quiet
    _quiet = True


def loud():
    global _quiet
    _quiet = False


def is_quiet():
    return _quiet


def debug():
    global _debug
    _debug = True


def is_debug():
    return _debug


from . import backends
from .agent import Agent
from .client import Client
from .context import Context
from .errors import (
    ApiError, LoopError, TurnCancelled, UnknownToolError, UnsupportedModelError,
)
from .logger import Logger
from .message import Message
from .prompt_builder import PromptBuilder
from .registry import Registry
from .repl import Repl
from .run_dsl import RunDSL
from .tasks.player import Player
from .tool import Tool
from .tools import mcp as tools_mcp

try:
    from .tui import Tui
except ImportError:
    Tui = None

__version__ = "0.11.1"


def _register_mcp_servers(registry, cfg):
    """Register every server in settings.yaml's `mcp_servers:` block. This is
    the agent's ONLY source of tools — boukensha ships none of its own.
    Nothing here knows what any particular server does; a MUD daemon and a
    filesystem server are registered by the identical code path.

    A server marked `required: False` that fails to spawn is a warning, not a
    fatal error — the agent runs without its tools. A name collision is never
    excused that way: it means the config asks for two tools with one name,
    and answering by dropping one of them silently is the worst option
    available.

    Returns {server_name: tool_count} for the servers that came up.
    """
    import sys

    summary = {}
    for name, entry in cfg.mcp_servers.items():
        try:
            client = tools_mcp.register(
                registry, entry["command"], args=entry["args"],
                env=entry["env"], prefix=entry["prefix"],
            )
            summary[name] = len(client.tools)
        except tools_mcp.CollisionError:
            raise
        except Exception as error:
            if entry["required"]:
                raise RuntimeError(
                    f"boukensha: MCP server '{name}' failed to start: {error}"
                )
            print(
                f"[boukensha] optional MCP server '{name}' failed to start: "
                f"{error} — continuing without its tools",
                file=sys.stderr,
            )
    return summary


def run(
    *, task, configure=None, system=None, model=None, backend=None, api_key=None,
    ollama_host="http://localhost:11434", log=None, max_output_tokens=None,
    working_dir=None,
):
    """Construct and run the configured player agent."""
    import os

    if working_dir is None:
        working_dir = os.getcwd()

    cfg = config()
    task_settings = cfg.tasks(Player.task_name())

    if system is None:
        system = Player.system_prompt(
            task_settings,
            user_prompts_dir=cfg.user_prompts_dir,
            default_prompts_dir=Config.PROMPTS_DIR,
        )
    if model is None:
        model = Player.model(task_settings)
    if backend is None:
        backend = Player.provider(task_settings)

    if api_key is None:
        environment_variable = {
            "anthropic": "ANTHROPIC_API_KEY",
            "openai": "OPENAI_API_KEY",
            "gemini": "GEMINI_API_KEY",
            "ollama_cloud": "OLLAMA_API_KEY",
        }.get(backend)
        if environment_variable is not None:
            api_key = os.environ.get(environment_variable)

    context = Context(task=Player, system=system, working_dir=working_dir)
    registry = Registry(context)
    _register_mcp_servers(registry, cfg)
    if configure is not None:
        configure(RunDSL(registry))

    backend_classes = {
        "anthropic": backends.Anthropic,
        "openai": backends.OpenAI,
        "gemini": backends.Gemini,
        "ollama": backends.Ollama,
        "ollama_cloud": backends.OllamaCloud,
    }
    backend_class = backend_classes.get(backend)
    if backend_class is None:
        supported = "anthropic, openai, gemini, ollama, and ollama_cloud"
        raise ValueError(f"Unknown backend {backend!r}. Use {supported}.")

    if backend == "ollama":
        selected_backend = backend_class(model=model, host=ollama_host)
    else:
        selected_backend = backend_class(api_key=api_key, model=model)

    builder = PromptBuilder(context, selected_backend)
    client = Client(builder)
    effective_max_iterations = Player.max_iterations(task_settings)
    effective_max_output_tokens = (
        Player.max_output_tokens(task_settings)
        if max_output_tokens is None else max_output_tokens
    )
    logger = Logger(log=log, snapshot={
        "task": Player.task_name(),
        "max_iterations": effective_max_iterations,
        "max_output_tokens": effective_max_output_tokens,
        "model": model,
        "provider": backend,
    })
    try:
        agent = Agent(
            context=context,
            registry=registry,
            builder=builder,
            client=client,
            logger=logger,
            task_settings=task_settings,
            max_iterations=effective_max_iterations,
            max_output_tokens=effective_max_output_tokens,
        )
        context.add_message("user", task)
        return agent.run()
    finally:
        logger.close()


def repl(
    *, configure=None, system=None, model=None, backend=None, api_key=None,
    ollama_host="http://localhost:11434", log=None, max_output_tokens=None,
    working_dir=None, tui=True,
):
    """Start an interactive player session with persistent conversation history.

    tui=True (default) wraps the session in a Textual TUI; tui=False falls
    back to the plain terminal REPL.
    """
    import os

    if working_dir is None:
        working_dir = os.getcwd()

    cfg = config()
    task_settings = cfg.tasks(Player.task_name())

    if system is None:
        system = Player.system_prompt(
            task_settings,
            user_prompts_dir=cfg.user_prompts_dir,
            default_prompts_dir=Config.PROMPTS_DIR,
        )
    if model is None:
        model = Player.model(task_settings)
    if backend is None:
        backend = Player.provider(task_settings)

    if api_key is None:
        environment_variable = {
            "anthropic": "ANTHROPIC_API_KEY",
            "openai": "OPENAI_API_KEY",
            "gemini": "GEMINI_API_KEY",
            "ollama_cloud": "OLLAMA_API_KEY",
        }.get(backend)
        if environment_variable is not None:
            api_key = os.environ.get(environment_variable)

    context = Context(task=Player, system=system, working_dir=working_dir)
    registry = Registry(context)
    servers = _register_mcp_servers(registry, cfg)
    if configure is not None:
        configure(RunDSL(registry))

    backend_classes = {
        "anthropic": backends.Anthropic,
        "openai": backends.OpenAI,
        "gemini": backends.Gemini,
        "ollama": backends.Ollama,
        "ollama_cloud": backends.OllamaCloud,
    }
    backend_class = backend_classes.get(backend)
    if backend_class is None:
        supported = "anthropic, openai, gemini, ollama, and ollama_cloud"
        raise ValueError(f"Unknown backend {backend!r}. Use {supported}.")

    if backend == "ollama":
        selected_backend = backend_class(model=model, host=ollama_host)
    else:
        selected_backend = backend_class(api_key=api_key, model=model)

    builder = PromptBuilder(context, selected_backend)
    client = Client(builder)
    effective_max_iterations = Player.max_iterations(task_settings)
    effective_max_output_tokens = (
        Player.max_output_tokens(task_settings)
        if max_output_tokens is None else max_output_tokens
    )
    logger = None
    try:
        logger = Logger(log=log, snapshot={
            "task": Player.task_name(),
            "max_iterations": effective_max_iterations,
            "max_output_tokens": effective_max_output_tokens,
            "model": model,
            "provider": backend,
        })
        repl_instance = Repl(
            context=context, registry=registry, builder=builder, client=client,
            logger=logger, task_settings=task_settings,
            max_iterations=effective_max_iterations,
            max_output_tokens=effective_max_output_tokens,
            config_dir=cfg.dir, provider=backend, model=model,
            version=__version__, api_key=api_key, servers=servers,
        )
        if tui and Tui is not None:
            Tui(repl_instance).run()
        else:
            repl_instance.start()
    except KeyboardInterrupt:
        print("\nInterrupted.")
    finally:
        if logger is not None:
            logger.close()

__all__ = [
    "ApiError",
    "Agent",
    "Client",
    "Config",
    "Context",
    "Logger",
    "LoopError",
    "Message",
    "Player",
    "PromptBuilder",
    "Registry",
    "Repl",
    "RunDSL",
    "Tool",
    "Tui",
    "TurnCancelled",
    "UnknownToolError",
    "UnsupportedModelError",
    "backends",
    "tools_mcp",
    "config",
    "debug",
    "is_debug",
    "is_quiet",
    "loud",
    "quiet",
    "repl",
    "run",
    "__version__",
]
