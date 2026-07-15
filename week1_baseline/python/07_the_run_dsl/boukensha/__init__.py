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
from .errors import ApiError, LoopError, UnknownToolError, UnsupportedModelError
from .logger import Logger
from .message import Message
from .prompt_builder import PromptBuilder
from .registry import Registry
from .run_dsl import RunDSL
from .tasks.player import Player
from .tool import Tool


def run(
    *, task, configure=None, system=None, model=None, backend=None, api_key=None,
    ollama_host="http://localhost:11434", log=None, max_output_tokens=None,
):
    """Construct and run the configured player agent."""
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
        import os

        environment_variable = {
            "anthropic": "ANTHROPIC_API_KEY",
            "openai": "OPENAI_API_KEY",
            "gemini": "GEMINI_API_KEY",
            "ollama_cloud": "OLLAMA_API_KEY",
        }.get(backend)
        if environment_variable is not None:
            api_key = os.environ.get(environment_variable)

    context = Context(task=Player, system=system)
    registry = Registry(context)
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
    "RunDSL",
    "Tool",
    "UnknownToolError",
    "UnsupportedModelError",
    "backends",
    "config",
    "debug",
    "is_debug",
    "is_quiet",
    "loud",
    "quiet",
    "run",
]
