import json
import re
import secrets
from datetime import datetime, timezone
from pathlib import Path


class Logger:
    DEFAULT_SESSION_DIR = "sessions"

    def __init__(self, session_id=None, dir=None, log=None, snapshot=None):
        self.session_id = session_id or self._generate_session_id()
        if log is not None:
            self.path = Path(log)
        else:
            if dir is None:
                from . import config

                dir = Path(config().dir) / self.DEFAULT_SESSION_DIR
            self.path = Path(dir) / f"{self.session_id}.jsonl"

        self.path.parent.mkdir(parents=True, exist_ok=True)
        self._log = self.path.open("a", encoding="utf-8")
        self._subscribers = []
        event = {"phase": "session_start"}
        event.update(snapshot or {})
        self._write(event)

    def turn(self, n):
        self._write({"phase": "turn", "n": n})

    def iteration(self, n, max):
        self._write({"phase": "iteration", "n": n, "max": max})

    def limit_reached(self, kind, n, max):
        self._write({"phase": "limit_reached", "kind": kind, "n": n, "max": max})

    def turn_end(self, reason, iterations, tokens=None):
        self._write({
            "phase": "turn_end", "reason": reason,
            "iterations": iterations, "tokens": tokens,
        })

    def prompt(self, messages, tools):
        self._write({
            "phase": "prompt",
            "message_count": len(messages),
            "messages": [
                {"role": message.role, "content": message.content}
                for message in messages
            ],
            "tool_count": len(tools),
            "tools": list(tools.keys()),
        })

    def tool_call(self, name, args):
        self._write({"phase": "tool_call", "name": name, "args": args})

    def tool_result(self, name, result, ok=True, error=None):
        self._write({
            "phase": "tool_result", "name": name, "result": str(result),
            "ok": ok, "error": error,
        })

    def response(self, text, usage=None, stop_reason=None, task=None, backend=None):
        event = {
            "phase": "response", "text": str(text).strip(),
            "usage": usage, "stop_reason": stop_reason,
        }
        event.update(self._execution_metadata(task, backend, usage))
        self._write(event)

    def raw(self, data):
        from . import is_debug

        if is_debug():
            self._write({"phase": "raw", "data": data})

    def subscribe(self, callback):
        self._subscribers.append(callback)

    def close(self):
        if not self._log.closed:
            self._log.close()

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc_value, traceback):
        self.close()

    def _write(self, event):
        record = dict(event)
        record["session_id"] = self.session_id
        record["at"] = datetime.now().astimezone().isoformat()
        self._log.write(json.dumps(record, separators=(",", ":"), default=str) + "\n")
        self._log.flush()
        for callback in self._subscribers:
            callback(event)

    @staticmethod
    def _generate_session_id():
        stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        return f"{stamp}-{secrets.token_hex(4)}"

    def _execution_metadata(self, task, backend, usage):
        if task is None and backend is None and usage is None:
            return {}

        input_tokens, output_tokens = self._usage_tokens(usage)
        metadata = {
            "task": self._task_name(task),
            "provider": self._provider_name(backend),
            "model": getattr(backend, "model", None),
            "usage_unit": getattr(backend, "usage_unit", None),
            "usage_level": getattr(backend, "usage_level", None),
            "input_tokens": input_tokens,
            "output_tokens": output_tokens,
            "cost_usd": self._estimate_cost(backend, input_tokens, output_tokens),
        }
        return {key: value for key, value in metadata.items() if value is not None}

    @staticmethod
    def _task_name(task):
        if task is None:
            return None
        task_name = getattr(task, "task_name", None)
        return task_name() if callable(task_name) else str(task)

    @staticmethod
    def _provider_name(backend):
        if backend is None:
            return None
        name = backend.__class__.__name__
        return re.sub(r"([a-z\d])([A-Z])", r"\1_\2", name).lower()

    @classmethod
    def _usage_tokens(cls, usage):
        usage = usage if isinstance(usage, dict) else {}
        return (
            cls._first_integer(usage, "input_tokens", "prompt_tokens", "promptTokenCount", "prompt_eval_count"),
            cls._first_integer(usage, "output_tokens", "completion_tokens", "candidatesTokenCount", "eval_count"),
        )

    @staticmethod
    def _first_integer(values, *keys):
        for key in keys:
            if key not in values or values[key] is None:
                continue
            value = values[key]
            if isinstance(value, bool):
                return None
            try:
                return int(value)
            except (TypeError, ValueError, OverflowError):
                return None
        return None

    @staticmethod
    def _estimate_cost(backend, input_tokens, output_tokens):
        estimate = getattr(backend, "estimate_cost", None)
        if not callable(estimate) or input_tokens is None or output_tokens is None:
            return None
        return estimate(input_tokens, output_tokens)
