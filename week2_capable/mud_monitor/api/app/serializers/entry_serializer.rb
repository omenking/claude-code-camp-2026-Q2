# Renders a SessionLog::Parser::Entry into the JSON shape the transcript UI
# consumes. Plain-text fields (user/assistant/reasoning/plan text) are sent
# raw — React escapes them on render. Only `tool_result` carries real ANSI
# escape codes, so only it gets a pre-rendered `result_html` companion field.
class EntrySerializer
  def self.call(entry)
    # `task` and `depth` ride on every entry, streamed ones included, so a live
    # transcript can render nesting without waiting for the group to close.
    base = {
      seq: entry.seq,
      type: entry.type,
      task: entry.task,
      depth: entry.depth,
      turn: entry.turn,
      iteration: entry.iteration,
      at: entry.at,
      dt_ms: entry.dt_ms,
      duration_ms: entry.duration_ms
    }

    base.merge(type_fields(entry))
  end

  def self.type_fields(entry)
    case entry.type
    when :user
      { text: entry.text }
    when :compaction
      { before: entry.before, dropped: entry.dropped }
    when :clear
      { before: entry.before, dropped: entry.dropped }
    when :request
      { request_seq: entry.request_seq, message_count: entry.message_count }
    when :reasoning
      { text: entry.text, redacted: entry.redacted }
    when :plan
      { text: entry.text }
    when :assistant
      {
        text: entry.text, stop_reason: entry.stop_reason, usage: entry.usage,
        running_turn_tokens: entry.running_turn_tokens,
        provider: entry.provider, model: entry.model,
        input_tokens: entry.input_tokens, output_tokens: entry.output_tokens,
        cost_usd: entry.cost_usd
      }
    when :tool
      {
        tool_name: entry.tool_name, tool_args: entry.tool_args,
        tool_result: entry.tool_result, tool_ok: entry.tool_ok, tool_error: entry.tool_error,
        result_html: Ansi.to_html(entry.tool_result)
      }
    when :turn_end
      { reason: entry.reason, iterations: entry.iterations, tokens: entry.tokens }
    when :task_start
      {
        task_name: entry.task_name, model: entry.model, provider: entry.provider,
        max_iterations: entry.max_iterations
      }
    when :task_end
      { task_name: entry.task_name }
    when :unknown
      { raw: entry.raw }
    else
      {}
    end
  end
end
