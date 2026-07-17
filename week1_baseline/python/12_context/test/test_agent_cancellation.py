import threading
import unittest

from boukensha.agent import Agent
from boukensha.context import Context
from boukensha.errors import TurnCancelled
from boukensha.registry import Registry

from .helper import FakeLogger


class FakeBuilder:
    backend = None

    def __init__(self, content_text="ok"):
        self._content_text = content_text

    def parse_response(self, response):
        return {
            "stop_reason": "end_turn",
            "content": [{"type": "text", "text": self._content_text}],
        }


class NeverCalledClient:
    def call(self, **options):
        raise AssertionError("client.call must not be reached once cancel_event is set")


class OkClient:
    def call(self, **options):
        return {}


# Agent's cancellation check runs at the top of every loop iteration, so a
# pre-set cancel_event must raise TurnCancelled without ever reaching the
# backend — this doesn't require a real (or fake-but-slow) API round trip to
# prove Esc-cancellation works, only that the check fires promptly.
class TestAgentCancellation(unittest.TestCase):
    def _agent(self, client, builder, cancel_event):
        context = Context(system="test")
        registry = Registry(context)
        return Agent(
            context=context, registry=registry, builder=builder, client=client,
            logger=FakeLogger(), cancel_event=cancel_event,
        )

    def test_run_raises_turn_cancelled_before_calling_client(self):
        cancel_event = threading.Event()
        cancel_event.set()
        agent = self._agent(NeverCalledClient(), FakeBuilder(), cancel_event)

        with self.assertRaises(TurnCancelled):
            agent.run()

    def test_run_completes_normally_when_event_not_set(self):
        agent = self._agent(OkClient(), FakeBuilder("done"), threading.Event())
        self.assertEqual("done", agent.run())

    def test_cancel_event_is_optional(self):
        agent = self._agent(OkClient(), FakeBuilder("done"), None)
        self.assertEqual("done", agent.run())
