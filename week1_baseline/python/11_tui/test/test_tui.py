import asyncio
import threading
import unittest

from boukensha.context import Context
from boukensha.repl import Repl
from boukensha.tasks.player import Player
from boukensha.tui import Tui

from .helper import FakeLogger


class FakeRepl:
    """Stands in for Repl so Tui tests exercise only the Tui/Textual side —
    no Agent, no Client, no network. Mirrors the subset of Repl's public
    surface Tui actually drives.
    """

    PROMPT = Repl.PROMPT
    version = "0.11.1-test"
    model = "fake-model"
    banner = "BANNER-TEXT"

    def __init__(self):
        self.context = Context(task=Player, system="test")
        self.logger = FakeLogger()
        self._cancel_event = None
        self.commands = []
        self.run_turn_calls = []

    def on_output(self, callback):
        self._output_cb = callback

    def handle_command(self, command):
        self.commands.append(command)
        return "quit" if command in ("/exit", "/quit") else "command"

    def run_turn(self, task):
        self.run_turn_calls.append(task)


class BlockingFakeRepl(FakeRepl):
    """A FakeRepl whose run_turn blocks until its cancel_event is set —
    long enough for a test to press Esc mid-turn, matching what a real
    in-flight Agent.run() call looks like from Tui's perspective.
    """

    def __init__(self):
        super().__init__()
        self.started = threading.Event()

    def run_turn(self, task):
        self.run_turn_calls.append(task)
        self._cancel_event = threading.Event()
        self.started.set()
        self._cancel_event.wait(timeout=2)


async def _type(pilot, text):
    for ch in text:
        await pilot.press(ch)


class TestTuiPilot(unittest.IsolatedAsyncioTestCase):
    async def test_submitting_text_launches_a_turn_and_grows_the_log(self):
        repl = FakeRepl()
        app = Tui(repl)
        async with app.run_test() as pilot:
            await pilot.click("#input")
            await _type(pilot, "look around")
            await pilot.press("enter")
            await pilot.pause()
            await asyncio.sleep(0.2)
            await pilot.pause()

            self.assertEqual(["look around"], repl.run_turn_calls)

    async def test_slash_command_is_not_sent_to_run_turn(self):
        repl = FakeRepl()
        app = Tui(repl)
        async with app.run_test() as pilot:
            await pilot.click("#input")
            await _type(pilot, "/help")
            await pilot.press("enter")
            await pilot.pause()

            self.assertEqual(["/help"], repl.commands)
            self.assertEqual([], repl.run_turn_calls)

    async def test_slash_quit_exits_the_app(self):
        repl = FakeRepl()
        app = Tui(repl)
        async with app.run_test() as pilot:
            await pilot.click("#input")
            await _type(pilot, "/quit")
            await pilot.press("enter")
            await pilot.pause()

            self.assertFalse(app.is_running)

    async def test_ctrl_l_clears_history_and_resets_turn_count(self):
        repl = FakeRepl()
        app = Tui(repl)
        async with app.run_test() as pilot:
            app._turn_count = 3
            await pilot.press("ctrl+l")
            await pilot.pause()

            self.assertIn("/clear", repl.commands)
            self.assertEqual(0, app._turn_count)

    async def test_ctrl_c_exits_the_app(self):
        repl = FakeRepl()
        app = Tui(repl)
        async with app.run_test() as pilot:
            await pilot.press("ctrl+c")
            await pilot.pause()

        self.assertFalse(app.is_running)

    async def test_ctrl_d_exits_the_app(self):
        repl = FakeRepl()
        app = Tui(repl)
        async with app.run_test() as pilot:
            await pilot.press("ctrl+d")
            await pilot.pause()

        self.assertFalse(app.is_running)

    async def test_escape_sets_the_cancel_event_mid_turn(self):
        repl = BlockingFakeRepl()
        app = Tui(repl)
        async with app.run_test() as pilot:
            await pilot.click("#input")
            await _type(pilot, "go north")
            await pilot.press("enter")

            await asyncio.get_event_loop().run_in_executor(None, repl.started.wait, 2)
            await pilot.press("escape")
            await pilot.pause()
            await asyncio.sleep(0.1)

            self.assertIsNotNone(repl._cancel_event)
            self.assertTrue(repl._cancel_event.is_set())

    async def test_escape_is_a_no_op_when_no_turn_is_running(self):
        repl = FakeRepl()
        app = Tui(repl)
        async with app.run_test() as pilot:
            await pilot.press("escape")
            await pilot.pause()

        self.assertIsNone(repl._cancel_event)


if __name__ == "__main__":
    unittest.main()
