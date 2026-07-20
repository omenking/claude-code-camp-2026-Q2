module Boukensha
  # Static model → capability table.
  #
  # `context_window` is a known *model* fact — the physical input ceiling — not a
  # value the user sets. The agent looks it up from its configured model id; the
  # user never configures it in settings.yaml. Unknown models fall back to a
  # conservative default so an unrecognised id can't silently assume a huge window.
  #
  # Built from every backend's own MODELS constant rather than hand-maintained
  # separately, so a model added to a backend is automatically sized correctly
  # here too. Table is built lazily on first use, by which point all backends
  # are loaded regardless of require order.
  module Models
    DEFAULT_CONTEXT_WINDOW = 32_000

    BACKEND_CLASSES = -> {
      [
        Backends::Anthropic,
        Backends::OpenAI,
        Backends::Gemini,
        Backends::Ollama,
        Backends::OllamaCloud
      ]
    }

    def self.table
      @table ||= BACKEND_CLASSES.call.each_with_object({}) { |backend, out| out.merge!(backend::MODELS) }
    end

    def self.context_window(model)
      table.dig(model.to_s, :context_window) || DEFAULT_CONTEXT_WINDOW
    end
  end
end
