require_relative "extractors/word_piece"
require_relative "extractors/structural"
require_relative "extractors/model"

module Boukensha
  # Enrichers for the room survey. Today there is exactly one — `look_candidates`
  # (docs/plans/week_2/look_candidates_runtime.md) — assembled here so the survey
  # gets a plain lambda and never learns what an ONNX session is.
  module Extractors
    DEFAULT_DIR = "models/look_candidates".freeze

    # The seam the scripted survey injects into `RoomParser`:
    #
    #   ->(name:, description:, exit_targets:, exclude:) { [String] }
    #
    # `exclude` is the caller's own additions; the structural exclusions (exit
    # destination names, mob/object keywords) are folded in here so no caller has
    # to remember them. Returns [] when disabled or when no model is installed,
    # because `look_candidates` is advisory and must never break a survey.
    # `model_dir:` is honoured but undocumented — the tests point it at a temp
    # directory. There is no threshold/top_k setting on purpose: those are swept
    # at build time and written into the artifact's manifest, so they travel with
    # the weights they were measured against. A settings override would let a
    # rebuild silently decouple the number from its evidence.
    def self.look_candidates(config: Boukensha.config)
      settings = config.dig(:tools, :inspect_room, :look_candidates) || {}
      return ->(**) { [] } if settings["extractor"].to_s == "none"

      dir   = expand(settings["model_dir"]) || File.join(config.dir, DEFAULT_DIR)
      model = Model.load(dir)

      lambda do |name:, description:, exit_targets: {}, mobs: [], objects: [], exclude: Set.new|
        model.call(name: name, description: description, exit_targets: exit_targets,
                   exclude: exclude | Structural.exclusions(exit_targets: exit_targets,
                                                            mobs: mobs, objects: objects))
      end
    end

    # settings.yaml paths may use ${VAR}, matching the mcp_servers `env:` block.
    def self.expand(path)
      path&.gsub(/\$\{(\w+)\}/) { ENV.fetch(::Regexp.last_match(1), "") }
    end
    private_class_method :expand
  end
end
