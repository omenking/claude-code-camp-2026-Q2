# Renders a SessionLog::Parser into the summary and detail JSON shapes
# documented in the mud_monitor spec, §3.1.
class SessionSerializer
  def initialize(parser, live:, bytes:)
    @parser = parser
    @live   = live
    @bytes  = bytes
  end

  def summary
    p       = @parser
    timing  = SessionLog::Timing.new(p).summary
    {
      id: p.id,
      started_at: p.started_at,
      ended_at: p.ended_at,
      duration_ms: timing[:wall_ms],
      live: @live,
      task: p.task,               # the goal text the user typed
      root_task: p.root_task,     # the task that owns depth 0
      tasks: p.task_roster,       # every task that ran, delegations included
      sub_runs: p.sub_runs,
      unclosed_tasks: p.unclosed_tasks,
      models: model_labels,
      turns: p.turn_count_real,
      iterations: p.iteration_count,
      tool_calls: p.tool_calls_count,
      input_tokens: p.total_input_tokens,
      output_tokens: p.total_output_tokens,
      peak_input_tokens: p.peak_input_tokens,
      context_window: p.context_window,
      cost_usd: p.estimated_cost,
      end_reason: p.end_reason,
      stopped: p.stopped?,
      any_limit_tripped: p.any_limit_tripped?,
      timing_source: p.timing_source,
      timing: timing,
      bytes: @bytes
    }
  end

  def detail
    p = @parser
    {
      session: summary,
      snapshot: {
        model: p.model,
        max_iterations: p.iteration_max,
        max_turn_tokens: p.max_turn_tokens,
        context_window: p.context_window
      },
      turns: p.turns,
      usage_series: p.usage_series.map { |pt| usage_point(pt) },
      cost_breakdown: p.cost_breakdown,
      entries: p.entries.map { |e| EntrySerializer.call(e) }
    }
  end

  private

  def model_labels
    labels = @parser.usage_series.map { |pt| model_label(pt.provider, pt.model) }.compact.uniq
    labels = [ model_label(@parser.provider, @parser.model) ].compact if labels.empty?
    labels
  end

  def model_label(provider, model)
    return nil if provider.nil? && model.nil?

    [ provider, model ].compact.join(" / ")
  end

  def usage_point(pt)
    {
      turn: pt.turn, iteration: pt.iteration, input: pt.input, output: pt.output,
      cache_read: pt.cache_read, cache_creation: pt.cache_creation, running: pt.running,
      at: pt.at, task: pt.task, provider: pt.provider, model: pt.model,
      cost_usd: SessionLog::Pricing.cost_for(pt, fallback_model: @parser.model)
    }
  end
end
