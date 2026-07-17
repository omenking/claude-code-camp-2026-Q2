from .errors import ApiError, TurnCancelled
from .logger import Logger


class Agent:
    MAX_ITERATIONS = 25
    WRAP_UP_OUTPUT_TOKENS = 400
    WRAP_UP_DIRECTIVE = (
        "You have reached your action limit for this turn. Do not call any more tools.\n"
        "Briefly summarize what you accomplished, what is still unfinished, and the\n"
        "single next action you would take."
    )

    def __init__(
        self, context, registry, builder, client,
        max_iterations=None, max_turn_tokens=None, max_output_tokens=None,
        logger=None, cancel_event=None,
    ):
        self.context = context
        self.registry = registry
        self.builder = builder
        self.client = client
        self.logger = logger if logger is not None else Logger()
        self.max_iterations = int(max_iterations) if max_iterations else self.MAX_ITERATIONS
        self.max_turn_tokens = int(max_turn_tokens) if max_turn_tokens else 0
        self.max_output_tokens = max_output_tokens
        self.cancel_event = cancel_event
        self.iteration = 0

    def run(self):
        self.context.reset_turn_tokens()
        self._compact_if_needed()

        while True:
            if self.cancel_event is not None and self.cancel_event.is_set():
                raise TurnCancelled()

            if self._iteration_limit_reached():
                self.logger.limit_reached(
                    kind="max_iterations", n=self.iteration, max=self.max_iterations
                )
                return self._wrap_up("max_iterations")
            if self._token_limit_reached():
                self.logger.limit_reached(
                    kind="max_tokens", n=self.context.turn_tokens, max=self.max_turn_tokens
                )
                return self._wrap_up("max_tokens")

            self.iteration += 1
            self.logger.iteration(n=self.iteration, max=self.max_iterations)
            self.logger.prompt(
                messages=self.context.messages, tools=self.context.tools,
                context_window=self.context.context_window,
            )
            options = {}
            if self.max_output_tokens is not None:
                options["max_output_tokens"] = self.max_output_tokens
            response = self.client.call(**options)
            self.logger.raw(data=response)
            parsed = self.builder.parse_response(response)
            self._record_usage(response)
            self._log_reasoning(parsed["content"])

            if parsed["stop_reason"] == "tool_use":
                self._handle_tool_calls(parsed["content"], response)
            else:
                text = self._extract_text(parsed["content"])
                self.logger.response(
                    text=text, usage=response.get("usage"),
                    stop_reason=parsed["stop_reason"], task=None, backend=self.builder.backend,
                )
                self.logger.turn_end(
                    reason="completed", iterations=self.iteration, tokens=self.context.turn_tokens
                )
                self.context.add_message("assistant", text)
                return text

    def _iteration_limit_reached(self):
        return self.max_iterations > 0 and self.iteration >= self.max_iterations

    def _token_limit_reached(self):
        return self.max_turn_tokens > 0 and self.context.turn_tokens >= self.max_turn_tokens

    def _record_usage(self, response):
        usage = response.get("usage") or {}
        self.context.add_turn_tokens(usage.get("input_tokens"), usage.get("output_tokens"))
        self.context.update_tokens(usage.get("input_tokens"))

    def _compact_if_needed(self):
        if not self.context.needs_compaction():
            return
        before = self.context.current_tokens
        dropped = self.context.compact_messages()
        self.logger.compaction(
            before=before, dropped=dropped, context_window=self.context.context_window
        )

    def _wrap_up(self, reason):
        self.context.add_message("user", self.WRAP_UP_DIRECTIVE)
        try:
            response = self.client.call(tools=[], max_output_tokens=self.WRAP_UP_OUTPUT_TOKENS)
            parsed = self.builder.parse_response(response)
            text = self._extract_text(parsed["content"])
            text = text if text.strip() else self._fallback_message(reason)
            self._record_usage(response)
            self.logger.response(
                text=text, usage=response.get("usage"),
                stop_reason=parsed["stop_reason"], task=None, backend=self.builder.backend,
            )
            self.logger.turn_end(reason=reason, iterations=self.iteration, tokens=self.context.turn_tokens)
            self.context.add_message("assistant", text)
            return text
        except ApiError:
            message = self._fallback_message(reason)
            self.logger.turn_end(reason=reason, iterations=self.iteration, tokens=self.context.turn_tokens)
            self.context.add_message("assistant", message)
            return message

    def _fallback_message(self, reason):
        return (
            f"I reached my {self.max_iterations}-action limit for this turn before finishing "
            f"({reason}). Ask me to continue and I'll pick up from here."
        )

    @staticmethod
    def _extract_text(content):
        return "\n".join(
            block.get("text", "") for block in content if block.get("type") == "text"
        )

    def _log_reasoning(self, content):
        for block in content:
            if block.get("type") != "reasoning":
                continue
            redacted = block.get("redacted") is True
            text = str(block.get("text") or "")
            if not text.strip() and not redacted:
                continue
            self.logger.reasoning(text=text, redacted=redacted)

    def _handle_tool_calls(self, content, response):
        tool_calls = [block for block in content if block.get("type") == "tool_use"]
        preamble = self._extract_text(content)
        if preamble.strip():
            self.logger.plan(text=preamble)
        suffix = "" if len(tool_calls) == 1 else "s"
        self.logger.response(
            text=f"(tool use — {len(tool_calls)} call{suffix})",
            usage=response.get("usage"), stop_reason="tool_use",
        )
        self.context.add_message("assistant", content)
        for block in tool_calls:
            name = block["name"]
            args = block["input"]
            self.logger.tool_call(name=name, args=args)
            try:
                result = self.registry.dispatch(name, args)
                self.logger.tool_result(name=name, result=result, ok=True)
            except Exception as error:
                result = f"ERROR: {error.__class__.__name__}: {error}"
                self.logger.tool_result(
                    name=name, result=result, ok=False, error=str(error)
                )
            result_text = str(result)
            self.context.add_message(
                "tool_result", result_text, tool_use_id=block["id"]
            )
