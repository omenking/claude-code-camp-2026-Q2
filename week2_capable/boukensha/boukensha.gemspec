require_relative "lib/boukensha/version"

Gem::Specification.new do |spec|
  spec.name        = "boukensha"
  spec.version     = Boukensha::VERSION
  spec.summary     = "BOUKENSHA — a tiny teaching framework for coding harnesses"
  spec.description = "Step-by-step coding harness framework. " \
                     "Set BOUKENSHA_PATH to load a specific lesson step, " \
                     "or run with defaults to use the bundled release."
  spec.authors     = ["Andrew Brown"]
  spec.email       = ["andrew@exampro.co"]
  spec.license     = "MIT"

  spec.required_ruby_version = ">= 3.0"

  # All files tracked in git, plus the bin/ executable.
  spec.files = Dir["lib/**/*.rb"] + ["bin/boukensha"]

  spec.bindir      = "bin"
  spec.executables = ["boukensha"]

  # MCP servers bring their own dependencies; boukensha itself needs only
  # `charm`, for the TUI (bubbletea + lipgloss + bubbles bindings).
  spec.add_dependency "charm"

  # Scores `look_candidates` locally (Extractors::Model). Resolves to a prebuilt
  # platform gem — no compiler, no libonnxruntime install, no Python at runtime.
  # Optional in practice: without the model artifact the extractor returns [].
  spec.add_dependency "onnxruntime", "~> 0.11"

  # open3, net/http, and json are stdlib. Users supply their own ANTHROPIC_API_KEY.
end
