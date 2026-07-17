import contextlib
import importlib
import io
import unittest
from unittest.mock import patch

from boukensha.context import Context
from boukensha.errors import ApiError, LoopError, TurnCancelled
from boukensha.registry import Registry
from boukensha.repl import Repl

from .helper import FakeLogger


class FakeBuilder:
    backend = None

    def __init__(self, response=None):
        self._response = response or {"stop_reason": "end_turn", "content": []}

    def parse_response(self, response):
        return self._response


class FakeClient:
    def call(self, **options):
        return {}


class RaisingClient:
    def __init__(self, error):
        self._error = error

    def call(self, **options):
        raise self._error


def build_repl(client=None, builder=None):
    context = Context(system="test")
    registry = Registry(context)
    return Repl(
        context=context, registry=registry,
        builder=builder or FakeBuilder(), client=client or FakeClient(),
        logger=FakeLogger(),
    )


class TestReplHandleCommand(unittest.TestCase):
    def setUp(self):
        self.repl = build_repl()
        self.outputs = []
        self.repl.on_output(self.outputs.append)

    def test_exit_and_quit_return_quit(self):
        self.assertEqual("quit", self.repl.handle_command("/exit"))
        self.assertEqual("quit", self.repl.handle_command("/quit"))
        self.assertIn("Goodbye.", self.outputs)

    def test_help_returns_command(self):
        self.assertEqual("command", self.repl.handle_command("/help"))
        self.assertTrue(any("Commands:" in o for o in self.outputs))

    def test_quiet_and_loud_return_command(self):
        self.assertEqual("command", self.repl.handle_command("/quiet"))
        self.assertEqual("command", self.repl.handle_command("/loud"))

    def test_clear_resets_turn_and_wipes_messages_not_tools(self):
        self.repl.context.add_message("user", "hi")
        self.repl.turn = 5

        self.assertEqual("command", self.repl.handle_command("/clear"))

        self.assertEqual(0, self.repl.turn)
        self.assertEqual([], self.repl.context.messages)

    def test_non_command_returns_none(self):
        self.assertIsNone(self.repl.handle_command("look around"))

    def test_registered_on_output_suppresses_stdout(self):
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            self.repl.handle_command("/help")
        self.assertEqual("", buf.getvalue())
        self.assertTrue(len(self.outputs) > 0)


class TestReplWithoutOnOutput(unittest.TestCase):
    def test_falls_back_to_print(self):
        repl = build_repl()
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            repl.handle_command("/quiet")
        self.assertIn("logging suppressed", buf.getvalue())


class TestReplRunTurn(unittest.TestCase):
    def test_routes_result_through_on_output(self):
        response = {
            "stop_reason": "end_turn",
            "content": [{"type": "text", "text": "hello there"}],
        }
        repl = build_repl(builder=FakeBuilder(response))
        outputs = []
        repl.on_output(outputs.append)

        repl.run_turn("hi")

        self.assertTrue(any("hello there" in o for o in outputs))

    def test_reports_loop_error(self):
        repl = build_repl(client=RaisingClient(LoopError("boom")))
        outputs = []
        repl.on_output(outputs.append)

        repl.run_turn("hi")

        self.assertTrue(any("[error] boom" in o for o in outputs))

    def test_reports_api_error(self):
        repl = build_repl(client=RaisingClient(ApiError("down")))
        outputs = []
        repl.on_output(outputs.append)

        repl.run_turn("hi")

        self.assertTrue(any("API call failed" in o for o in outputs))

    def test_reports_turn_cancelled(self):
        class CancellingAgent:
            def __init__(self, **kwargs):
                pass

            def run(self):
                raise TurnCancelled()

        repl = build_repl()
        outputs = []
        repl.on_output(outputs.append)

        # "boukensha.repl" (the submodule) is shadowed in the package's own
        # namespace by boukensha's public repl() function of the same name,
        # so patch("boukensha.repl.Agent", ...) can't resolve it — go
        # through sys.modules via importlib instead.
        repl_module = importlib.import_module("boukensha.repl")
        with patch.object(repl_module, "Agent", CancellingAgent):
            repl.run_turn("hi")

        self.assertTrue(any("interrupted" in o for o in outputs))

    def test_builds_a_fresh_cancel_event_per_turn(self):
        import threading

        response = {"stop_reason": "end_turn", "content": []}
        repl = build_repl(builder=FakeBuilder(response))
        repl.on_output(lambda s: None)

        repl.run_turn("hi")
        first_event = repl._cancel_event
        self.assertIsInstance(first_event, threading.Event)

        repl.run_turn("hi again")
        self.assertIsNot(first_event, repl._cancel_event)


if __name__ == "__main__":
    unittest.main()
