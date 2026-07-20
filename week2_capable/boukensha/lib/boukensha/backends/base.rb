require_relative "../errors"

module Boukensha
  module Backends
    # Common base for all provider backends.
    #
    # Normalized response contract
    # ----------------------------
    # Every backend's #parse_response returns:
    #
    #   { stop_reason: "tool_use" | "end_turn",
    #     content: [ <block>, <block>, ... ] }
    #
    # where each block is one of:
    #
    #   { "type" => "reasoning",
    #     "text"      => "<human-readable reasoning, may be empty>",
    #     "signature" => "<opaque provider token, optional>",  # round-trip only
    #     "redacted"  => true | false }                        # optional
    #
    #   { "type" => "text", "text" => "..." }
    #
    #   { "type" => "tool_use", "id" => ..., "name" => ..., "input" => {...} }
    #
    # Reasoning blocks come FIRST in content, before text and tool_use (matching
    # Anthropic's native ordering). `text` is what the viewer renders and may be
    # empty (redacted/omitted reasoning). `signature`/`redacted` are opaque
    # carry-through for providers that require the block echoed back unchanged
    # (Anthropic thinking signatures, Gemini thoughtSignature) — consumers never
    # interpret them. Backends that don't accept reasoning back in a request drop
    # these blocks when rebuilding assistant turns.
    class Base
      attr_reader :model

      def self.models
        const_get(:MODELS)
      rescue NameError
        raise NotImplementedError, "#{self} must define MODELS"
      end

      def self.model_info(model)
        models[model.to_s]
      end

      def self.validate_model!(model)
        model = model.to_s
        return model if model_info(model)

        supported = models.keys.sort.join(", ")
        raise UnsupportedModelError, "#{name} does not support model #{model.inspect}. Supported models: #{supported}"
      end

      def model_info
        @model_info
      end

      def context_window
        model_info.fetch(:context_window)
      end

      def input_token_cost_per_million
        model_info.fetch(:cost_per_million).fetch(:input)
      end

      def output_token_cost_per_million
        model_info.fetch(:cost_per_million).fetch(:output)
      end

      def usage_unit
        model_info.fetch(:usage_unit)
      end

      def usage_level
        model_info[:usage_level]
      end

      def estimate_cost(input_tokens:, output_tokens:)
        return nil unless input_token_cost_per_million && output_token_cost_per_million

        ((input_tokens * input_token_cost_per_million) +
          (output_tokens * output_token_cost_per_million)) / 1_000_000.0
      end

      private

      def configure_model(model)
        @model = self.class.validate_model!(model)
        @model_info = self.class.model_info(@model)
      end
    end
  end
end
