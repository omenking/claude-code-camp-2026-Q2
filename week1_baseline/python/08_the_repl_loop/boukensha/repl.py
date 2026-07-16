import os
import sys

from .agent import Agent
from .errors import ApiError, LoopError


class Repl:
    """Interactive, multi-turn agent session over a shared context."""

    PROMPT = "boukensha> "
    HELP = """Commands:
  /quiet   suppress logging output
  /loud    re-enable logging output
  /clear   wipe conversation history (tools stay)
  /exit    leave the REPL
  /quit    leave the REPL
  /help    show this message"""

    def __init__(
        self, *, context, registry, builder, client, logger,
        task_settings=None, max_iterations=None, max_output_tokens=None,
        config_dir=None, provider=None, model=None, version=None, api_key=None,
    ):
        self.context = context
        self.registry = registry
        self.builder = builder
        self.client = client
        self.logger = logger
        self.task_settings = task_settings
        self.max_iterations = max_iterations
        self.max_output_tokens = max_output_tokens
        self.config_dir = config_dir
        self.provider = provider
        self.model = model
        self.version = version
        self.api_key = api_key
        self.turn = 0

    def start(self):
        print(self._banner())
        while True:
            sys.stdout.write(self.PROMPT)
            sys.stdout.flush()
            line = sys.stdin.readline()
            if line == "":
                break
            task = line.strip()
            if not task:
                continue
            if task in ("/exit", "/quit"):
                print("Goodbye.")
                break
            if task == "/help":
                print(self.HELP)
                continue
            if task == "/quiet":
                from . import quiet
                quiet()
                print("(logging suppressed — type /loud to re-enable)")
                continue
            if task == "/loud":
                from . import loud
                loud()
                print("(logging enabled)")
                continue
            if task == "/clear":
                self.context.clear_messages()
                self.turn = 0
                print("(conversation history cleared)")
                continue
            self._run_turn(task)

    def _run_turn(self, task):
        self.turn += 1
        self.logger.turn(self.turn)
        self.context.add_message("user", task)
        agent = Agent(
            context=self.context, registry=self.registry, builder=self.builder,
            client=self.client, logger=self.logger,
            task_settings=self.task_settings, max_iterations=self.max_iterations,
            max_output_tokens=self.max_output_tokens,
        )
        try:
            result = agent.run()
            print()
            print(result)
        except LoopError as error:
            print(f"\n[error] {error}")
        except ApiError as error:
            print(f"\n[error] API call failed: {error}")

    def _banner(self):
        key_status = "✓ API key set" if self.api_key and self.api_key.strip() else "✗ API key not set"
        provider = self.provider or "default"
        model = self.model or "default"
        config_dir = self.config_dir or "(default)"
        if not self.config_dir or not os.path.isdir(self.config_dir):
            config_dir = f"{config_dir}  ✗ directory not found"
        version = self.version or "?.?.?"
        return (
            f"\n╭── BOUKENSHA MUD Assistant (v{version}) ──╮\n"
            f"  config:    {config_dir}\n"
            f"  provider:  {provider} ({model})  {key_status}\n\n"
            "  /quiet or /loud   toggle logging\n"
            "  /clear            reset conversation history\n"
            "  /exit or /quit    leave the REPL\n"
        )


PROMPT = Repl.PROMPT
HELP = Repl.HELP
