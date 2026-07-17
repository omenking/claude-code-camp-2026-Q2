from ..errors import UnsupportedModelError


class Base:
    """Common base for all provider backends.

    Normalized response contract
    -----------------------------
    Every backend's parse_response returns:

        {"stop_reason": "tool_use" | "end_turn",
         "content": [<block>, <block>, ...]}

    where each block is one of:

        {"type": "reasoning",
         "text": "<human-readable reasoning, may be empty>",
         "signature": "<opaque provider token, optional>",  # round-trip only
         "redacted": True | False}                          # optional

        {"type": "text", "text": "..."}

        {"type": "tool_use", "id": ..., "name": ..., "input": {...}}

    Reasoning blocks come FIRST in content, before text and tool_use (matching
    Anthropic's native ordering). `text` is what the viewer renders and may be
    empty (redacted/omitted reasoning). `signature`/`redacted` are opaque
    carry-through for providers that require the block echoed back unchanged
    (Anthropic thinking signatures, Gemini thoughtSignature) — consumers never
    interpret them. Backends that don't accept reasoning back in a request drop
    these blocks when rebuilding assistant turns.
    """

    @classmethod
    def models(cls):
        try:
            return cls.MODELS
        except AttributeError:
            raise NotImplementedError(f"{cls.__name__} must define MODELS")

    @classmethod
    def model_info(cls, model):
        return cls.models().get(str(model))

    @classmethod
    def validate_model(cls, model):
        model = str(model)
        if cls.model_info(model):
            return model

        supported = ", ".join(sorted(cls.models().keys()))
        raise UnsupportedModelError(
            f"{cls.__name__} does not support model {model!r}. Supported models: {supported}"
        )

    @property
    def context_window(self):
        return self._model_info["context_window"]

    @property
    def input_token_cost_per_million(self):
        return self._model_info["cost_per_million"]["input"]

    @property
    def output_token_cost_per_million(self):
        return self._model_info["cost_per_million"]["output"]

    @property
    def usage_unit(self):
        return self._model_info["usage_unit"]

    @property
    def usage_level(self):
        return self._model_info.get("usage_level")

    def estimate_cost(self, input_tokens, output_tokens):
        if self.input_token_cost_per_million is None or self.output_token_cost_per_million is None:
            return None

        return (
            (input_tokens * self.input_token_cost_per_million)
            + (output_tokens * self.output_token_cost_per_million)
        ) / 1_000_000.0

    def _configure_model(self, model):
        self.model = self.__class__.validate_model(model)
        self._model_info = self.__class__.model_info(self.model)
