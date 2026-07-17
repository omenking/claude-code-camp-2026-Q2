from . import backends

DEFAULT_CONTEXT_WINDOW = 32_000

_BACKEND_CLASSES = (
    backends.Anthropic, backends.OpenAI, backends.Gemini,
    backends.Ollama, backends.OllamaCloud,
)

_table = None


def table():
    global _table
    if _table is None:
        _table = {}
        for backend_class in _BACKEND_CLASSES:
            _table.update(backend_class.MODELS)
    return _table


def context_window(model):
    info = table().get(str(model))
    return info["context_window"] if info else DEFAULT_CONTEXT_WINDOW
