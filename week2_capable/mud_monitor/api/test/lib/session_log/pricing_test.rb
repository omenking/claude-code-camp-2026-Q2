require "test_helper"

module SessionLog
  class PricingTest < ActiveSupport::TestCase
    Point = Struct.new(:cost_usd, :model, :input, :output, :cache_read, :cache_creation, keyword_init: true)

    test "a known model computes cost from input/output/cache rates" do
      point = Point.new(cost_usd: nil, model: "claude-haiku-4-5", input: 1_000_000, output: 1_000_000,
                         cache_read: 0, cache_creation: 0)

      assert_in_delta 6.0, Pricing.cost_for(point), 0.0001
    end

    test "an unknown model returns nil, never a fake zero" do
      point = Point.new(cost_usd: nil, model: "some-unlisted-model", input: 100, output: 100,
                         cache_read: 0, cache_creation: 0)

      assert_nil Pricing.cost_for(point)
    end

    test "falls back to the session-level model when the point has none" do
      point = Point.new(cost_usd: nil, model: nil, input: 1_000_000, output: 0, cache_read: 0, cache_creation: 0)

      assert_in_delta 1.0, Pricing.cost_for(point, fallback_model: "claude-haiku-4-5"), 0.0001
    end

    test "a logger-emitted cost_usd is preferred over the local rate table" do
      point = Point.new(cost_usd: 0.0042, model: "claude-haiku-4-5", input: 1_000_000, output: 1_000_000,
                         cache_read: 0, cache_creation: 0)

      assert_equal 0.0042, Pricing.cost_for(point)
    end
  end
end
