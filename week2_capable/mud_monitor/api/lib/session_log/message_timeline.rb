require "json"

module SessionLog
  # Reconstructs *what the model was actually handed* on every model call.
  #
  # The definitive source is the `request` event (boukensha logs the exact
  # `to_api_payload` body at the moment of invocation): system prompt, full tool
  # schemas, and messages in provider wire format. `system`/`tools` are logged in
  # full only when they change (the logger dedups constants), so this walker
  # carries the last value forward across `*_unchanged` events.
  #
  # Logs written before `request` landed carry only `prompt` events — a
  # reconstruction of Context#messages (role + content, no system, no tool
  # schemas, no wire transform). Those still parse: if a file has no `request`
  # events we fall back to `prompt`, and each checkpoint reports source: "prompt"
  # so the UI can say "this is a reconstruction, not the real payload".
  #
  # Either way the message array is append-only except for front-trimming
  # (compaction/clear drop from the head; the loop appends to the tail), so a
  # checkpoint's delta from its predecessor is "dropped N from the front" +
  # "appended these to the tail", with an unchanged window carried between.
  class MessageTimeline
    Checkpoint = Struct.new(
      :seq, :source,            # "request" (definitive) | "prompt" (reconstruction)
      :turn, :iteration, :at,
      :model, :max_tokens,
      :system, :system_changed, # the carried-forward system prompt + whether it changed here
      :tools, :tool_count, :tools_changed,
      :message_count, :dropped, :carried, :marker,
      :messages,                # the full array on this call
      keyword_init: true
    )

    attr_reader :id, :path, :checkpoints

    def self.load(path)
      new(path).tap(&:parse!)
    end

    def initialize(path)
      @path        = path
      @id          = File.basename(path, ".jsonl")
      @checkpoints = []
    end

    def parse!
      request_cps = []
      prompt_cps  = []
      turn = 0
      iter = 0
      pending_req    = nil     # compaction/clear seen since the last request
      pending_prompt = nil     # …and since the last prompt (tracked separately so
                               # the two builders don't steal each other's marker)
      prev_req    = []
      prev_prompt = []
      sys  = nil               # carried system prompt across *_unchanged events
      tools = nil
      tool_count = 0
      rseq = 0
      pseq = 0

      File.foreach(@path) do |line|
        line = line.strip
        next if line.empty?

        event = begin
          JSON.parse(line)
        rescue JSON::ParserError
          next
        end

        case event["phase"]
        when "turn"
          turn = event["n"].to_i
        when "iteration"
          iter = event["n"].to_i
        when "compaction"
          pending_req = pending_prompt = "compaction"
        when "clear"
          pending_req = pending_prompt = "clear"
        when "request"
          messages = event["messages"] || []
          delta    = diff(prev_req, messages)

          sys_changed = event.key?("system")
          sys = event["system"] if sys_changed

          tools_changed = event.key?("tools")
          if tools_changed
            tools      = event["tools"]
            tool_count = event["tool_count"] || tools.size
          elsif event["tool_count"]
            tool_count = event["tool_count"]
          end

          request_cps << Checkpoint.new(
            seq: rseq += 1, source: "request",
            turn: turn, iteration: iter, at: event["at"],
            model: event["model"], max_tokens: event["max_tokens"],
            system: sys, system_changed: sys_changed,
            tools: tools, tool_count: tool_count, tools_changed: tools_changed,
            message_count: messages.size,
            dropped: delta[:dropped], carried: delta[:carried],
            marker: pending_req || (delta[:dropped].positive? ? "trim" : nil),
            messages: messages
          )
          prev_req    = messages
          pending_req = nil
        when "prompt"
          messages = event["messages"] || []
          delta    = diff(prev_prompt, messages)

          prompt_cps << Checkpoint.new(
            seq: pseq += 1, source: "prompt",
            turn: turn, iteration: iter, at: event["at"],
            model: nil, max_tokens: nil,
            system: nil, system_changed: false,
            tools: nil, tool_count: event["tool_count"], tools_changed: false,
            message_count: messages.size,
            dropped: delta[:dropped], carried: delta[:carried],
            marker: pending_prompt || (delta[:dropped].positive? ? "trim" : nil),
            messages: messages
          )
          prev_prompt    = messages
          pending_prompt = nil
        end
      end

      # Prefer the definitive request log; fall back to the reconstruction only
      # for legacy sessions that never logged one.
      @checkpoints = request_cps.any? ? request_cps : prompt_cps
    end

    private

    # Smallest front-trim of `prev` whose remainder is a prefix of `curr`, so the
    # carried window is maximised and whatever of `curr` sticks out past it is the
    # appended tail. k == prev.size always matches, so a hard reset falls out as
    # "dropped everything, all of curr is new".
    def diff(prev, curr)
      (0..prev.size).each do |k|
        remaining = prev[k..] || []
        next unless curr[0, remaining.size] == remaining

        return { dropped: k, carried: remaining.size }
      end
      { dropped: prev.size, carried: 0 }
    end
  end
end
