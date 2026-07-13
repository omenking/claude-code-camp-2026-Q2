require_relative "../errors"

module Boukensha
  module Backends
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
