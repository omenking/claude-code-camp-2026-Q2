import os
import sys
import threading

from .agent import Agent
from .errors import ApiError, LoopError, TurnCancelled


class Repl:
    """Interactive, multi-turn agent session over a shared context."""

    PROMPT = "boukensha> "
    HELP = """Commands:
  /quiet    suppress logging output
  /loud     re-enable logging output
  /clear    wipe conversation history (tools stay)
  /compact  drop oldest 40% of messages to free context
  /exit     leave the REPL
  /quit     leave the REPL
  /help     show this message"""

    def __init__(
        self, *, context, registry, builder, client, logger,
        max_iterations=None, max_turn_tokens=None, max_output_tokens=None,
        config_dir=None, provider=None, model=None, version=None, api_key=None,
        servers=None,
    ):
        self.context = context
        self.registry = registry
        self.builder = builder
        self.client = client
        self.logger = logger
        self.max_iterations = max_iterations
        self.max_turn_tokens = max_turn_tokens
        self.max_output_tokens = max_output_tokens
        self.config_dir = config_dir
        self.provider = provider
        self.model = model
        self.version = version
        self.api_key = api_key
        self.servers = servers
        self.turn = 0
        self._output_cb = None
        self._cancel_event = None

    def on_output(self, callback):
        """Route every string the REPL would otherwise print to stdout
        through `callback` instead. Used by Tui."""
        self._output_cb = callback

    @property
    def banner(self):
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
            f"  provider:  {provider} ({model})  {key_status}\n"
            f"  servers:   {self._servers_status_string()}\n\n"
            "  /quiet or /loud   toggle logging\n"
            "  /clear            reset conversation history\n"
            "  /compact          free context (drop oldest messages)\n"
            "  /exit or /quit    leave the REPL\n"
        )

    def handle_command(self, task):
        """Handle a slash command. Returns "quit", "command", or None (not a command)."""
        if task in ("/exit", "/quit"):
            self._output("Goodbye.")
            return "quit"
        if task == "/help":
            self._output(self.HELP)
            return "command"
        if task == "/quiet":
            from . import quiet
            quiet()
            self._output("(logging suppressed — type /loud to re-enable)")
            return "command"
        if task == "/loud":
            from . import loud
            loud()
            self._output("(logging enabled)")
            return "command"
        if task == "/clear":
            self.context.clear_messages()
            self.turn = 0
            self._output("(conversation history cleared)")
            return "command"
        if task == "/compact":
            dropped = self.context.compact_messages()
            self._output(f"(compacted context — {dropped} messages dropped)")
            return "command"
        return None

    def run_turn(self, task):
        self.turn += 1
        self.logger.turn(self.turn)
        self.context.add_message("user", task)
        self._cancel_event = threading.Event()
        agent = Agent(
            context=self.context, registry=self.registry, builder=self.builder,
            client=self.client, logger=self.logger,
            max_iterations=self.max_iterations, max_turn_tokens=self.max_turn_tokens,
            max_output_tokens=self.max_output_tokens,
            cancel_event=self._cancel_event,
        )
        try:
            result = agent.run()
            self._output("")
            self._output(result)
        except LoopError as error:
            self._output(f"\n[error] {error}")
        except ApiError as error:
            self._output(f"\n[error] API call failed: {error}")
        except TurnCancelled:
            self._output("\n(interrupted)")

    def start(self):
        self._output(self.banner)
        while True:
            if self._output_cb is None:
                sys.stdout.write(self.PROMPT)
                sys.stdout.flush()
            line = sys.stdin.readline()
            if line == "":
                break
            task = line.strip()
            if not task:
                continue
            result = self.handle_command(task)
            if result == "quit":
                break
            if result == "command":
                continue
            self.run_turn(task)

    def _output(self, s):
        if self._output_cb is not None:
            self._output_cb(str(s))
        else:
            print(s)

    def _servers_status_string(self):
        if not self.servers:
            return "(none configured — the agent has no tools)"
        return "  ".join(f"{name} ({count})" for name, count in self.servers.items())


PROMPT = Repl.PROMPT
HELP = Repl.HELP
