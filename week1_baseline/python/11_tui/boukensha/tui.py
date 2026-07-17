import queue
import threading
import time
from datetime import datetime

from textual.app import App, ComposeResult
from textual.binding import Binding
from textual.containers import Horizontal
from textual.widgets import Input, RichLog, Static

from .agent import Agent


class Tui(App):
    """Wraps a Repl instance and replaces its raw print/input I/O with a
    structured four-zone display: a scrollable conversation viewport, a
    live progress line, a single-line input box, and an always-on status
    bar.

    Layout (top -> bottom):
      conversation viewport (scrollable)
      live progress line (hidden state shown when idle)
      boukensha> input box
      status line (always-on)

    The Repl continues to own session logic (turn counting, /commands,
    Agent dispatch). Tui registers output/event callbacks on the Repl and
    drives the Textual event loop.
    """

    SPINNER_FRAMES = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
    TICK_SECONDS = 0.06

    CSS = """
    #conversation {
        height: 1fr;
    }

    #progress {
        height: 1;
        color: $text-muted;
    }

    #progress.active {
        color: cyan;
    }

    #input-row {
        height: 3;
    }

    #prompt-label {
        width: auto;
        color: green;
        text-style: bold;
        content-align: left middle;
        padding: 0 0 0 1;
    }

    #input {
        width: 1fr;
    }

    #status {
        height: 1;
        background: $panel;
        color: white;
    }
    """

    BINDINGS = [
        Binding("ctrl+c", "quit", "Quit", show=False, priority=True),
        Binding("ctrl+d", "quit", "Quit", show=False, priority=True),
        Binding("escape", "cancel_turn", "Cancel", show=False),
        Binding("ctrl+l", "clear_history", "Clear", show=False),
        Binding("pageup", "scroll_log_up", "Scroll up", show=False),
        Binding("pagedown", "scroll_log_down", "Scroll down", show=False),
    ]

    def __init__(self, repl):
        super().__init__()
        self._repl = repl
        self._events = queue.Queue()
        self._turn_count = 0
        self._session_input_tokens = 0
        self._session_output_tokens = 0
        self._turn_thread = None
        self._live = self._idle_live()

    def compose(self) -> ComposeResult:
        yield RichLog(id="conversation", wrap=True, markup=True, auto_scroll=True)
        yield Static(id="progress")
        with Horizontal(id="input-row"):
            yield Static(self._repl.PROMPT, id="prompt-label")
            yield Input(placeholder="Type a message…", id="input")
        yield Static(id="status")

    def on_mount(self) -> None:
        self.query_one("#conversation", RichLog).write(self._repl.banner)
        self._repl.on_output(self._on_repl_output)
        self._repl.logger.subscribe(self._on_event)
        self.set_interval(self.TICK_SECONDS, self._tick)
        self._render_progress()
        self._render_status()
        self.query_one("#input", Input).focus()

    # -- Repl/Logger callbacks (invoked from the background turn thread) ----
    # Never touch widget state here directly — only enqueue. _tick, running
    # on the app's own event-loop thread, is the sole place that drains the
    # queue and mutates widgets.

    def _on_repl_output(self, text):
        self._events.put({"phase": "output", "text": str(text)})

    def _on_event(self, event):
        self._events.put(dict(event))

    # -- tick -----------------------------------------------------------------

    def _tick(self) -> None:
        self._drain_events()
        if self._live["active"] and self._live["start_time"] is not None:
            self._live["spinner_idx"] = (self._live["spinner_idx"] + 1) % len(self.SPINNER_FRAMES)
            self._live["elapsed"] = time.monotonic() - self._live["start_time"]
        self._render_progress()
        self._render_status()

    def _drain_events(self):
        while True:
            try:
                event = self._events.get_nowait()
            except queue.Empty:
                break
            self._handle_event(event)

    def _handle_event(self, event):
        phase = event.get("phase")
        if phase == "output":
            self.query_one("#conversation", RichLog).write(event.get("text", ""))
        elif phase == "iteration":
            self._live["iteration"] = int(event.get("n") or 0)
            self._live["current_action"] = "Thinking…"
        elif phase == "tool_call":
            self._live["current_action"] = f"Calling tool: {event.get('name')}"
            self._live["tool_call_count"] += 1
        elif phase == "tool_result":
            self._live["current_action"] = "Awaiting result…"
        elif phase == "response":
            usage = event.get("usage") or {}
            input_tokens = int(usage.get("input_tokens") or 0)
            output_tokens = int(usage.get("output_tokens") or 0)
            self._live["turn_input_tokens"] += input_tokens
            self._live["turn_output_tokens"] += output_tokens
            self._session_input_tokens += input_tokens
            self._session_output_tokens += output_tokens
        elif phase == "turn_complete":
            self._live["active"] = False
            self._turn_count += 1
        elif phase == "turn_error":
            self._live["active"] = False
            self.query_one("#conversation", RichLog).write(f"[error] {event.get('error')}")

    # -- rendering --------------------------------------------------------------

    def _render_progress(self):
        widget = self.query_one("#progress", Static)
        if self._live["active"]:
            frame = self.SPINNER_FRAMES[self._live["spinner_idx"]]
            action = self._live["current_action"]
            iteration = self._live["iteration"]
            max_iterations = Agent.MAX_ITERATIONS
            secs = int(self._live["elapsed"])
            itok = self._fmt_tokens(self._live["turn_input_tokens"])
            otok = self._fmt_tokens(self._live["turn_output_tokens"])
            calls = self._live["tool_call_count"]
            widget.set_class(True, "active")
            widget.update(
                f"{frame} {action}  (iter {iteration}/{max_iterations} · {secs}s · "
                f"↑ {itok} · ↓ {otok} · {calls} calls)"
            )
        else:
            widget.set_class(False, "active")
            used = self._fmt_tokens(self._session_input_tokens)
            widget.update(f"  [ready]   ctx {used}   {self._turn_count} turns")

    def _render_status(self):
        version = self._repl.version or "?.?.?"
        model = self._repl.model or "(model)"
        used = self._fmt_tokens(self._session_input_tokens)
        tools = self._repl.context.tool_count
        clock = datetime.now().strftime("%H:%M:%S")
        bar = f" boukensha v{version} · {model}  ·  ctx {used}  ·  {tools} tools  ·  {clock} "
        width = self.size.width or 80
        self.query_one("#status", Static).update(bar.ljust(width))

    # -- input / keyboard ---------------------------------------------------

    def on_input_submitted(self, event: Input.Submitted) -> None:
        if event.input.id != "input":
            return
        value = event.value.strip()
        event.input.value = ""
        if not value:
            return

        if value.startswith("/"):
            result = self._repl.handle_command(value)
            if result == "quit":
                self.exit()
            elif value == "/clear":
                self._turn_count = 0
        else:
            self.query_one("#conversation", RichLog).write(f"> {value}")
            self._launch_turn(value)

    def action_cancel_turn(self) -> None:
        if self._turn_thread is not None and self._turn_thread.is_alive():
            cancel_event = self._repl._cancel_event
            if cancel_event is not None:
                cancel_event.set()

    def action_clear_history(self) -> None:
        self._repl.handle_command("/clear")
        self._turn_count = 0

    def action_scroll_log_up(self) -> None:
        self.query_one("#conversation", RichLog).scroll_page_up()

    def action_scroll_log_down(self) -> None:
        self.query_one("#conversation", RichLog).scroll_page_down()

    # -- agent thread -----------------------------------------------------------

    def _launch_turn(self, task):
        self._live = {
            "active": True,
            "spinner_idx": 0,
            "start_time": time.monotonic(),
            "elapsed": 0,
            "current_action": "Thinking…",
            "iteration": 0,
            "tool_call_count": 0,
            "turn_input_tokens": 0,
            "turn_output_tokens": 0,
        }
        self._turn_thread = threading.Thread(
            target=self._run_turn_thread, args=(task,), daemon=True
        )
        self._turn_thread.start()

    def _run_turn_thread(self, task):
        # Repl.run_turn already handles TurnCancelled/LoopError/ApiError
        # internally and reports them through on_output; this guards only
        # against a genuinely unexpected exception escaping it.
        try:
            self._repl.run_turn(task)
        except Exception as error:
            self._events.put({"phase": "turn_error", "error": str(error)})
        finally:
            self._events.put({"phase": "turn_complete"})
            self._turn_thread = None

    # -- helpers ------------------------------------------------------------

    @staticmethod
    def _idle_live():
        return {
            "active": False,
            "spinner_idx": 0,
            "start_time": None,
            "elapsed": 0,
            "current_action": "idle",
            "iteration": 0,
            "tool_call_count": 0,
            "turn_input_tokens": 0,
            "turn_output_tokens": 0,
        }

    @staticmethod
    def _fmt_tokens(n):
        n = int(n or 0)
        return f"{n / 1000:.1f}k" if n >= 1000 else str(n)
