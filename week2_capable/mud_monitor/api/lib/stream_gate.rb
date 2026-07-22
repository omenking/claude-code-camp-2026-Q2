# Caps the number of concurrent SSE connections a single mud_monitor process
# will hold open (spec §3.3) — each open stream pins a Puma thread for as
# long as the client stays connected, so an unbounded number of tabs left on
# a live transcript would eventually starve the thread pool.
class StreamGate
  class AtCapacity < StandardError; end

  def initialize(max:)
    @max   = max
    @mutex = Mutex.new
    @count = 0
  end

  # Raises AtCapacity (without touching the count) if the cap is already
  # reached; otherwise holds a slot for the duration of the block, releasing
  # it even if the block raises.
  def acquire
    @mutex.synchronize do
      raise AtCapacity if @count >= @max

      @count += 1
    end

    begin
      yield
    ensure
      @mutex.synchronize { @count -= 1 }
    end
  end
end
