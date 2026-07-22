require "test_helper"

class StreamGateTest < ActiveSupport::TestCase
  test "raises AtCapacity once max concurrent holders is reached" do
    gate = StreamGate.new(max: 1)

    gate.acquire do
      assert_raises(StreamGate::AtCapacity) { gate.acquire { flunk "should not run" } }
    end
  end

  test "releases its slot after the block finishes, even if it raises" do
    gate = StreamGate.new(max: 1)

    assert_raises(RuntimeError) { gate.acquire { raise "boom" } }

    ran = false
    gate.acquire { ran = true }
    assert ran
  end
end
