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
  | "clear"
  | "request"
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

  // compaction | clear
  before?: number;
  dropped?: number;

  // request (a marker that opens the sidebar at the matching checkpoint)
  request_seq?: number;
  message_count?: number;

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

// ---- message timeline (the raw array fed to the model) ------------------
// A single content block inside an assistant message. `input`/`name`/`id` are
// present on tool_use; `text` on text blocks. Kept permissive because the log
// passes provider content through untouched.
export interface ContentBlock {
  type: string;
  text?: string;
  name?: string;
  id?: string;
  input?: Record<string, unknown>;
  content?: unknown;
  [key: string]: unknown;
}

// One logged message: role + content, where content is a plain string
// (user / tool_result) or an array of content blocks (assistant).
export interface TimelineMessage {
  role: string;
  content: string | ContentBlock[];
}

// A logged tool definition (provider wire shape — permissive across backends).
export interface TimelineTool {
  name?: string;
  description?: string;
  input_schema?: Record<string, unknown>;
  [key: string]: unknown;
}

// One model call: the complete payload the model saw, plus how the message
// array changed since the previous call.
//   source          "request" = the definitive body (system + tool schemas +
//                   wire messages); "prompt" = a legacy reconstruction (no
//                   system/tools, role+content only).
//   system/tools    carried-forward constants; *_changed says whether this call
//                   is where they actually changed (the logger dedups them).
//   messages.slice(carried)  the appended tail (the delta); `dropped` is how
//                   many fell off the front and `marker` says why.
export interface MessageCheckpoint {
  seq: number;
  source: "request" | "prompt";
  turn: number;
  iteration: number;
  at: string | null;
  model: string | null;
  max_tokens: number | null;
  system: string | null;
  system_changed: boolean;
  tools: TimelineTool[] | null;
  tool_count: number | null;
  tools_changed: boolean;
  message_count: number;
  dropped: number;
  carried: number;
  marker: "compaction" | "clear" | "trim" | null;
  messages: TimelineMessage[];
}

export interface MessagesTimeline {
  checkpoints: MessageCheckpoint[];
  live: boolean;
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
