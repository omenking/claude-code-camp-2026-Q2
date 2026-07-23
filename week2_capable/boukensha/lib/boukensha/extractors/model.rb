require "json"
require "set"
require_relative "word_piece"

module Boukensha
  module Extractors
    # `look_candidates`: which nouns in a room's description are worth trying
    # `look <noun>` on. tbaMUD builders hide extra-descriptions behind ordinary
    # words and the game never lists them, so this is a guess — and the one
    # field of the room survey a script cannot derive (see
    # docs/plans/week_2/scripted_room_survey.md 3.2).
    #
    # It is answered by a 41M-parameter token classifier trained on the world
    # files' own `E` blocks, exported to ONNX, and run here in ~10ms. That is
    # ~1/120th of a single MUD round trip, and it replaced three LLM calls.
    #
    # Every inference parameter — threshold, top_k, max_len, which room fields
    # form the encoder context — comes from the artifact's manifest.json, never
    # from a constant here. Weights and thresholds are built together and drift
    # together (a retrain moves the calibration by ±5 F1 while the *ranking*
    # stays put), so a threshold is a property of one build, not of the design.
    class Model
      # Both regexes are part of the trained contract, not preferences:
      # WORD is how the trainer split text before tokenizing; CANDIDATE is how
      # it built the pool a room is scored against. Changing either silently
      # scores rooms against a model that saw something else.
      WORD      = /[A-Za-z]{2,}/.freeze
      CANDIDATE = /[a-z]{3,}/.freeze

      # Deliberately minimal — words that cannot plausibly be an extra-description
      # keyword. Aggressive stopwording would cut the recall ceiling instead of
      # the false positives. Must stay byte-identical to LC::STOP in
      # docs/plans/week_2/nlp_look_candidates/lib/common.rb; the manifest carries
      # its sha256 and #load checks it.
      STOP = %w[
        the and you are was were for that this from into onto with which who whom
        whose there here their they them its his her hers our ours your yours
        have has had been being can could would should will shall may might must
        not but any all some more most very just also than then when where what
        how why about above below over under after before while during
      ].to_set.freeze

      MAX_CONTEXT_WORDS = 48

      class ManifestError < StandardError; end

      class << self
        # One session per directory: loading the graph costs ~110ms and there is
        # no reason to pay it per room.
        def load(dir)
          @cache ||= {}
          @cache[File.expand_path(dir)] ||= build(File.expand_path(dir))
        end

        def reset_cache! = @cache = nil

        private

        def build(dir)
          manifest_path = File.join(dir, "manifest.json")
          # Asymmetric on purpose (plan 9.6): a MISSING model is an honest
          # degraded install and returns []. A model present with unknown
          # parameters is worse than none — it would score every room against
          # the wrong recipe and look like it worked.
          return Null.new("no manifest at #{manifest_path}") unless File.exist?(manifest_path)

          manifest = JSON.parse(File.read(manifest_path))
          onnx     = File.join(dir, manifest.fetch("model_file"))
          unless File.exist?(onnx)
            return Null.new("model file #{manifest["model_file"]} not downloaded " \
                            "(run `rake model:fetch`)")
          end

          if manifest["stopwords_sha256"] && manifest["stopwords_sha256"] != stopwords_sha256
            raise ManifestError, "stopword list drifted from the trained corpus " \
                                 "(manifest #{manifest["stopwords_sha256"][0, 12]}, " \
                                 "code #{stopwords_sha256[0, 12]})"
          end

          new(onnx_path: onnx,
              vocab: JSON.parse(File.read(File.join(dir, manifest.fetch("vocab_file")))),
              threshold: manifest.fetch("threshold"), top_k: manifest.fetch("top_k"),
              max_len: manifest.fetch("max_len"),
              context_fields: manifest.fetch("context_fields"))
        rescue JSON::ParserError, KeyError => e
          raise ManifestError, "#{manifest_path}: #{e.message}"
        end

        def stopwords_sha256
          require "digest"
          Digest::SHA256.hexdigest(STOP.to_a.sort.join(" "))
        end
      end

      attr_reader :threshold, :top_k, :onnx_path, :vocab, :max_len, :context_fields

      def initialize(onnx_path:, vocab:, threshold:, top_k:, max_len:, context_fields:)
        require "onnxruntime"
        @session   = OnnxRuntime::Model.new(onnx_path)
        @onnx_path = onnx_path
        @vocab     = vocab
        @wordpiece = WordPiece.new(vocab)
        @cls       = vocab.fetch("[CLS]")
        @sep       = vocab.fetch("[SEP]")
        @threshold = threshold
        @top_k     = top_k
        @max_len   = max_len
        @context_fields = context_fields
      end

      def available? = true

      # The runtime entry point. `exclude` is Structural's output — exit
      # destination names and entity keywords, subtracted BEFORE we return
      # rather than before we score, because the model was trained on the full
      # description and dropping words from its input would shift every
      # position.
      def call(name:, description:, exit_targets: {}, exclude: Set.new)
        ranked = score(name: name, description: description, exit_targets: exit_targets)
        return [] if ranked.empty?

        ranked
          .reject { |word, _| exclude.include?(word) }
          .select { |_, s| s >= @threshold }
          .first(@top_k)
          .map(&:first)
      end

      # [[word, probability], ...] descending, over the room's whole candidate
      # pool. Separate from #call so the build pipeline can sweep thresholds
      # against exactly the numbers the runtime will produce.
      def score(name:, description:, exit_targets: {})
        pool = candidates(description)
        return [] if pool.empty?

        ids, positions = encode(name, description, exit_targets)
        logits = @session.predict({ "input_ids" => [ids],
                                    "attention_mask" => [Array.new(ids.length, 1)] })["logits"][0]

        best = Hash.new(0.0)
        positions.each do |word, index|
          p = probability(logits[index])
          best[word] = p if p > best[word]
        end
        pool.map { |w| [w, best[w]] }.sort_by { |_, s| -s }
      end

      # The pool a room is scored against: content words of the description,
      # first occurrence wins so positions stay stable.
      def candidates(description)
        seen = Set.new
        description.to_s.downcase.scan(CANDIDATE).reject { |w| STOP.include?(w) }.select { |w| seen.add?(w) }
      end

      private

      # [CLS] <context> [SEP] <description> [SEP], with only description words
      # tracked — the context is there to be attended to, never to be scored.
      def encode(name, description, exit_targets)
        ids       = [@cls]
        positions = []

        context_words(name, exit_targets).first(MAX_CONTEXT_WORDS).each do |word|
          sub = @wordpiece.encode_word(word)
          ids.concat(sub) if ids.length + sub.length + 2 < @max_len
        end
        ids << @sep

        description.to_s.scan(WORD).each do |word|
          sub = @wordpiece.encode_word(word)
          break if ids.length + sub.length + 1 > @max_len

          positions << [word.downcase, ids.length] # the label rides the FIRST subtoken
          ids.concat(sub)
        end
        ids << @sep

        [ids, positions]
      end

      # `sector` is deliberately absent from any shipped manifest: it is a world
      # file field the MUD never prints, so a player-legal runtime cannot fill
      # it. Training with it and serving without it would be a silent train/serve
      # skew — measured as costing nothing to drop (plan 5.1).
      def context_words(name, exit_targets)
        @context_fields.flat_map do |field|
          case field
          when "name"  then name.to_s.scan(WORD)
          when "exits" then exit_targets.values.join(" ").scan(WORD)
          else []
          end
        end
      end

      # Softmax over the two logits; index 1 is "examinable".
      def probability(pair)
        hi = pair[0] > pair[1] ? pair[0] : pair[1]
        a = Math.exp(pair[0] - hi)
        b = Math.exp(pair[1] - hi)
        b / (a + b)
      end

      # Stands in for a model that isn't installed. `look_candidates` is
      # advisory, so its absence degrades one field and never a survey.
      class Null
        def initialize(reason) = @reason = reason
        def available? = false
        def threshold = nil
        def top_k = 0
        def candidates(_description) = []
        def score(**) = []

        def call(**)
          unless @warned
            warn "[boukensha] look_candidates disabled: #{@reason}"
            @warned = true
          end
          []
        end
      end
    end
  end
end
