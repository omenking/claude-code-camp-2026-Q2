module SessionLog
  # Per-MTok input/output rates. Cache reads bill at ~0.1x input, cache
  # writes at ~1.25x input. Unknown models return nil cost (never a fake
  # zero), rendered by the client as em-dash.
  module Pricing
    MODEL_PRICES = {
      "claude-fable-5"    => { input: 10.0, output: 50.0 },
      "claude-opus-4-8"   => { input: 5.0,  output: 25.0 },
      "claude-opus-4-7"   => { input: 5.0,  output: 25.0 },
      "claude-opus-4-6"   => { input: 5.0,  output: 25.0 },
      "claude-sonnet-4-6" => { input: 3.0,  output: 15.0 },
      "claude-haiku-4-5"  => { input: 1.0,  output: 5.0 }
    }.freeze

    # point responds to: cost_usd, model, input, output, cache_read, cache_creation
    def self.cost_for(point, fallback_model: nil)
      return point.cost_usd unless point.cost_usd.nil?

      rates = MODEL_PRICES[point.model || fallback_model]
      return nil unless rates

      input_rate  = rates[:input] / 1_000_000.0
      output_rate = rates[:output] / 1_000_000.0
      point.input * input_rate +
        point.output * output_rate +
        point.cache_read * input_rate * 0.1 +
        point.cache_creation * input_rate * 1.25
    end
  end
end
