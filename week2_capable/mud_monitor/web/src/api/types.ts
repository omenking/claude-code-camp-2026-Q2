export interface SessionSummary {
  id: string;
  started_at: string | null;
  ended_at: string | null;
  duration_ms: number | null;
  live: boolean;
  /** The goal text the user typed. */
  task: string | null;
  /** The task that owns depth 0 — usually "player", but a standalone sub-run is its own root. */
  root_task: string | null;
  /** Every task that ran in this session, delegations included. */
  tasks: string[];
  /** Number of delegated sub-runs (task_start events). */
  sub_runs: number;
  /** Sub-runs whose task_end never arrived — process died mid-delegation. */
  unclosed_tasks: number;
  models: string[];
  turns: number;
  iterations: number;
  tool_calls: number;
  input_tokens: number;
  output_tokens: number;
  peak_input_tokens: number;
  context_window: number | null;
  cost_usd: number | null;
  end_reason: string | null;
  stopped: boolean;
  any_limit_tripped: boolean;
  timing_source: "monotonic" | "wallclock" | "wallclock_coarse";
  timing: TimingSummary;
  bytes: number;
}

export interface TimingSummary {
  p50_tool_ms: number | null;
  p95_tool_ms: number | null;
  p50_model_ms: number | null;
  p95_model_ms: number | null;
  total_idle_ms: number;
  wall_ms: number | null;
  busy_ms: number | null;
}

export interface SessionSnapshot {
  model: string | null;
  max_iterations: number | null;
  max_turn_tokens: number | null;
  context_window: number | null;
}

export interface TurnRow {
  n: number;
  iterations: number | null;
  tokens: number;
  reason: string | null;
  started_at: string | null;
  ended_at: string | null;
  duration_ms: number | null;
}

export interface UsagePoint {
  turn: number;
  iteration: number;
  input: number;
  output: number;
  cache_read: number;
  cache_creation: number;
  running: number;
  at: string | null;
  task: string | null;
  provider: string | null;
  model: string | null;
  cost_usd: number | null;
}

export interface CostBreakdownRow {
  task: string;
  provider: string;
  model: string;
  calls: number;
  input: number;
  output: number;
  cost: number;
  cost_known: boolean;
}

export type EntryType =
  | "user"
  | "assistant"
  | "reasoning"
  | "plan"
  | "tool"
  | "compaction"
  | "turn_end"
  | "task_start"
  | "task_end"
  | "unknown";

export interface Entry {
  seq: number;
  type: EntryType;
  /** The task that produced this entry. Null on logs written before Amendment A. */
  task: string | null;
  /** 0 = root task, 1 = delegated, … */
  depth: number;
  turn: number;
  iteration: number;
  at: string | null;
  dt_ms: number | null;
  duration_ms: number | null;

  // user | assistant | reasoning | plan
  text?: string;

  // assistant
  usage?: Record<string, unknown>;
  stop_reason?: string | null;
  running_turn_tokens?: number;
  provider?: string | null;
  model?: string | null;
  input_tokens?: number;
  output_tokens?: number;
  cost_usd?: number | null;

  // reasoning
  redacted?: boolean;

  // tool
  tool_name?: string;
  tool_args?: Record<string, unknown>;
  tool_result?: string;
  tool_ok?: boolean;
  tool_error?: string | null;
  result_html?: string;

  // compaction
  before?: number;
  dropped?: number;

  // turn_end
  reason?: string | null;
  iterations?: number;
  tokens?: number | null;

  // task_start | task_end
  task_name?: string;
  max_iterations?: number | null;

  // unknown
  raw?: Record<string, unknown>;
}

export interface SessionDetail {
  session: SessionSummary;
  snapshot: SessionSnapshot;
  turns: TurnRow[];
  usage_series: UsagePoint[];
  cost_breakdown: CostBreakdownRow[];
  entries: Entry[];
}

export interface ApiError {
  error: { code: string; message: string };
}

// mode: "command" | "raw" | "poll" | "login" (spec §4.3)
export interface ManagerRecord {
  seq: number;
  at: string | null;
  mono_ms: number | null;
  session: string;
  mode: string;
  tool: string | null;
  args: Record<string, unknown> | null;
  correlation_id: string | null;
  correlation: "exact" | "inferred" | "none";
  sent: string | null;
  received: string | null;
  received_html: string;
  bytes_in: number;
  elapsed_ms: number | null;
  error: string | null;
}

export interface ManagerPage {
  entries: ManagerRecord[];
  next_seq: number;
  eof: boolean;
  live: boolean;
}

// dir: "in" | "out" (spec §4.2)
export interface TelnetRecord {
  seq: number;
  at: string | null;
  mono_ms: number | null;
  session: string;
  dir: "in" | "out";
  bytes: number;
  text: string;
  text_html: string;
  redacted: boolean;
}

export interface TelnetPage {
  entries: TelnetRecord[];
  next_seq: number;
  eof: boolean;
  live: boolean;
}

// cause: "pre_command_drain" | "post_prompt_leftover" | "login" (spec §3.6)
export interface DroppedEvent {
  at: string | null;
  telnet_seqs: number[];
  text: string;
  text_html: string;
  bytes: number;
  between: { after_manager_seq: number | null; before_manager_seq: number | null };
  cause: "pre_command_drain" | "post_prompt_leftover" | "login";
}

export interface DroppedSummary {
  dropped_bytes: number;
  dropped_runs: number;
  received_bytes: number;
  drop_ratio: number | null;
}

export interface DroppedDiff {
  dropped: DroppedEvent[];
  summary: DroppedSummary;
}
