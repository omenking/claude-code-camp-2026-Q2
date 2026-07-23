import { Fragment, useCallback, useEffect, useRef, useState } from "react";
import { Link, useParams } from "react-router";
import { ApiRequestError, fetchSession } from "../api/client";
import type { Entry, SessionDetail as SessionDetailData, SessionSummary } from "../api/types";
import { useEventStream } from "../api/useEventStream";
import Ansi from "../components/Ansi";
import CostTable from "../components/CostTable";
import CtxChip from "../components/CtxChip";
import Duration from "../components/Duration";
import LiveBadge from "../components/LiveBadge";
import MessagesSidebar from "../components/MessagesSidebar";
import ProgressBar from "../components/ProgressBar";
import Sparkline from "../components/Sparkline";
import TaskChip, { taskHue } from "../components/TaskChip";
import { fmtCost, fmtDelta, fmtDuration, fmtTokens, formatArgs, formatTime, pct, pctRaw } from "../format";

const AT_BOTTOM_THRESHOLD_PX = 80;

function isWindowAtBottom() {
  const doc = document.documentElement;
  return doc.scrollHeight - doc.scrollTop - doc.clientHeight < AT_BOTTOM_THRESHOLD_PX;
}

// Port of week1_baseline/log_viz/views/session.erb.
export default function SessionDetail() {
  const { id } = useParams<{ id: string }>();
  const [data, setData] = useState<SessionDetailData | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [entries, setEntries] = useState<Entry[]>([]);
  const [liveSummary, setLiveSummary] = useState<SessionSummary | null>(null);
  const [newestSeq, setNewestSeq] = useState<number | null>(null);
  // Which request's payload the sidebar is showing (1-based request ordinal),
  // or null when the drawer is closed. Set by the inline buttons in the transcript.
  const [focusedRequest, setFocusedRequest] = useState<number | null>(null);
  const stickToBottomRef = useRef(true);

  useEffect(() => {
    if (!id) return;
    setData(null);
    setError(null);
    setEntries([]);
    setLiveSummary(null);
    setNewestSeq(null);
    setFocusedRequest(null);
    fetchSession(id)
      .then((detail) => {
        setData(detail);
        setEntries(detail.entries);
      })
      .catch((err) => setError(err instanceof ApiRequestError ? err.message : String(err)));
  }, [id]);

  const handleEntry = useCallback((entry: Entry) => {
    stickToBottomRef.current = isWindowAtBottom();
    setEntries((prev) => (prev.some((e) => e.seq === entry.seq) ? prev : [ ...prev, entry ]));
    setNewestSeq(entry.seq);
  }, []);

  const streamStatus = useEventStream<Entry>({
    streamKey: id,
    buildUrl: (afterSeq) => `/api/v1/sessions/${encodeURIComponent(id ?? "")}/stream?after=${afterSeq}`,
    enabled: Boolean(data?.session.live),
    initialAfterSeq: data?.entries.at(-1)?.seq ?? 0,
    onEntry: handleEntry,
    onSummary: setLiveSummary,
  });

  useEffect(() => {
    if (stickToBottomRef.current) {
      window.scrollTo({ top: document.documentElement.scrollHeight });
    }
  }, [entries]);

  if (error) {
    return (
      <>
        <Link to="/sessions" className="back">
          ← All sessions
        </Link>
        <p className="error">Failed to load session: {error}</p>
      </>
    );
  }

  if (!data) return <p>Loading…</p>;

  const session = liveSummary ?? data.session;
  const { snapshot, turns, usage_series: usageSeries, cost_breakdown: costBreakdown } = data;
  const largestTurn = turns.length ? turns.reduce((a, b) => (b.tokens > a.tokens ? b : a)) : null;
  const busiestTurn = turns.length
    ? turns.reduce((a, b) => ((b.iterations ?? 0) > (a.iterations ?? 0) ? b : a))
    : null;
  const anyLimitTripped = turns.some((t) => t.reason != null && t.reason !== "completed");
  const largestTripped = turns.some((t) => t.reason === "max_tokens");

  return (
    <>
      <Link to="/sessions" className="back">
        ← All sessions
      </Link>

      <h1>
        Session {session.id}
        {data.session.live && <LiveBadge status={streamStatus} />}
      </h1>
      <p className="meta">
        Started {formatTime(session.started_at)}
        {" · "}
        {/* Live sessions are still accumulating, so the figure is "so far",
            not a final total — say so rather than letting it read as finished. */}
        <span
          className="session-duration"
          title={
            session.timing.busy_ms == null
              ? undefined
              : `${fmtDuration(session.timing.busy_ms)} busy · ${fmtDuration(session.timing.total_idle_ms)} idle`
          }
        >
          {data.session.live ? "running " : ""}
          {fmtDuration(session.duration_ms)}
          {data.session.live ? " so far" : ""}
        </span>
        {session.tasks.length > 0 && (
          <span className="task-roster">
            {session.tasks.map((t) => (
              <TaskChip key={t} task={t} />
            ))}
            {session.sub_runs > 0 && (
              <span className="sub-run-count" title="delegated sub-runs">
                ⑂ {session.sub_runs}
              </span>
            )}
          </span>
        )}
      </p>

      {/* "What is it doing right now" — answerable without reading the transcript. */}
      {data.session.live && entries.length > 0 && entries[entries.length - 1].task && (
        <p className="meta running-task">
          running <TaskChip task={entries[entries.length - 1].task} />
        </p>
      )}

      {session.end_reason &&
        (session.stopped ? (
          <div className="banner banner-warn">⚠ stopped: {session.end_reason}</div>
        ) : (
          <div className="banner banner-ok">✓ completed</div>
        ))}

      <div className="statstrip">
        <div className="statstrip-head">
          <span className="statstrip-model">{session.models.join(", ") || "—"}</span>
          <span className="statstrip-cost">
            cost ≈ {session.cost_usd == null ? "—" : `$${session.cost_usd.toFixed(4)}`}
          </span>
        </div>

        {snapshot.context_window != null && snapshot.context_window > 0 && (
          <ProgressBar
            used={session.peak_input_tokens}
            max={snapshot.context_window}
            label={`Peak context · ${fmtTokens(session.peak_input_tokens)} / ${fmtTokens(snapshot.context_window)} (${pct(session.peak_input_tokens, snapshot.context_window)}%)`}
          />
        )}

        {snapshot.max_turn_tokens != null && snapshot.max_turn_tokens > 0 && largestTurn && (
          <ProgressBar
            used={largestTurn.tokens}
            max={snapshot.max_turn_tokens}
            danger={largestTripped}
            label={`Largest turn · ${fmtTokens(largestTurn.tokens)} / ${fmtTokens(snapshot.max_turn_tokens)} (${pctRaw(largestTurn.tokens, snapshot.max_turn_tokens)}%${largestTripped ? " ⚠ max_tokens" : ""})`}
          />
        )}

        {snapshot.max_iterations != null && busiestTurn && (
          <ProgressBar
            used={busiestTurn.iterations}
            max={snapshot.max_iterations}
            danger={anyLimitTripped && busiestTurn.reason === "max_iterations"}
            label={`Iterations · ${busiestTurn.iterations} / ${snapshot.max_iterations} (turn ${busiestTurn.n})`}
          />
        )}

        <div className="statstrip-total">
          Session total: {fmtTokens(session.input_tokens)} tok in · {fmtTokens(session.output_tokens)} tok out ·
          across {session.turns} turn{session.turns === 1 ? "" : "s"} · {fmtDuration(session.duration_ms)} total
        </div>
      </div>

      <CostTable rows={costBreakdown} />

      {usageSeries.length > 1 && (
        <div className="spark-wrap">
          <div className="spark-label">input tokens / iteration · peak {fmtTokens(session.peak_input_tokens)}</div>
          <Sparkline points={usageSeries} max={session.peak_input_tokens} />
        </div>
      )}

      <div className="transcript">
        <TranscriptEntries
          entries={entries}
          snapshot={snapshot}
          timingSource={session.timing_source}
          newestSeq={newestSeq}
          onOpenRequest={setFocusedRequest}
        />
      </div>

      {focusedRequest != null && id && (
        <MessagesSidebar id={id} focusSeq={focusedRequest} onClose={() => setFocusedRequest(null)} />
      )}
    </>
  );
}

// A delegated sub-run, as rendered: the task_start that opened it, everything
// it produced, and the task_end that closed it (absent when the process died
// mid-delegation — see `open` below).
type GroupNode = { kind: "group"; start: Entry; end: Entry | null; children: TranscriptNode[] };
type TranscriptNode = { kind: "entry"; entry: Entry } | GroupNode;

// Entries arrive flat and ordered — cursors, SSE replay and dropped-strip
// interleaving all depend on that (§A.4). Nesting is a rendering concern, so
// the tree is built here, at render time, from task_start/task_end.
export function buildTranscriptTree(entries: Entry[]): TranscriptNode[] {
  const root: TranscriptNode[] = [];
  const open: GroupNode[] = [];
  const target = () => (open.length ? open[open.length - 1].children : root);

  for (const entry of entries) {
    if (entry.type === "task_start") {
      const group: GroupNode = { kind: "group", start: entry, end: null, children: [] };
      target().push(group);
      open.push(group);
    } else if (entry.type === "task_end") {
      const group = open.pop();
      // A task_end with nothing open is a malformed log, not a reason to drop
      // the record on the floor — render it where it sits.
      if (group) group.end = entry;
      else target().push({ kind: "entry", entry });
    } else {
      target().push({ kind: "entry", entry });
    }
  }

  // Groups still open at EOF close here; the missing task_end is what the
  // header reports as "incomplete" rather than implying a clean finish.
  return root;
}

// Iteration counters restart inside a sub-run, so the marker is decided on the
// flat list (where "the previous entry" is unambiguous) and looked up during
// the recursive render.
function iterationMarkerSeqs(entries: Entry[]): Set<number> {
  const seqs = new Set<number>();
  let lastIteration: number | null = null;
  let lastDepth: number | null = null;

  for (const entry of entries) {
    if (entry.type === "turn_end") continue;
    if (entry.iteration !== lastIteration || entry.depth !== lastDepth) {
      if (entry.type !== "task_start" && entry.type !== "task_end") seqs.add(entry.seq);
      lastIteration = entry.iteration;
      lastDepth = entry.depth;
    }
  }
  return seqs;
}

// Collapse sub-runs by default once there are more than a couple: the player's
// narrative is the spine, and a sub-run is detail you open when a room looks
// wrong.
const COLLAPSE_THRESHOLD = 2;

function TranscriptEntries({
  entries,
  snapshot,
  timingSource,
  newestSeq,
  onOpenRequest,
}: {
  entries: Entry[];
  snapshot: SessionDetailData["snapshot"];
  timingSource: SessionDetailData["session"]["timing_source"];
  newestSeq: number | null;
  onOpenRequest: (requestSeq: number) => void;
}) {
  const nodes = buildTranscriptTree(entries);
  const markers = iterationMarkerSeqs(entries);
  const subRuns = entries.filter((e) => e.type === "task_start").length;

  return (
    <TranscriptNodes
      nodes={nodes}
      snapshot={snapshot}
      coarse={timingSource === "wallclock_coarse"}
      newestSeq={newestSeq}
      markers={markers}
      defaultOpen={subRuns <= COLLAPSE_THRESHOLD}
      onOpenRequest={onOpenRequest}
    />
  );
}

interface NodeProps {
  snapshot: SessionDetailData["snapshot"];
  coarse: boolean;
  newestSeq: number | null;
  markers: Set<number>;
  defaultOpen: boolean;
  onOpenRequest: (requestSeq: number) => void;
}

function TranscriptNodes({ nodes, ...props }: NodeProps & { nodes: TranscriptNode[] }) {
  return (
    <>
      {nodes.map((node) =>
        node.kind === "group" ? (
          <TaskGroup key={`group-${node.start.seq}`} node={node} {...props} />
        ) : (
          <Fragment key={node.entry.seq}>
            {props.markers.has(node.entry.seq) && (
              <div className="iteration-marker">Iteration {node.entry.iteration}</div>
            )}
            <div className={node.entry.seq === props.newestSeq ? "entry-row entry-row-new" : "entry-row"}>
              <div className="entry-gutter-row">
                <Duration
                  at={node.entry.at}
                  dtMs={node.entry.dt_ms}
                  durationMs={node.entry.duration_ms}
                  coarse={props.coarse}
                />
                <TaskChip task={node.entry.task} />
              </div>
              <TranscriptEntry
                entry={node.entry}
                snapshot={props.snapshot}
                onOpenRequest={props.onOpenRequest}
              />
            </div>
          </Fragment>
        ),
      )}
    </>
  );
}

// A delegated sub-run: collapsible, indented, with a left rule down the group
// so a long sub-run's membership stays visible after its header scrolls off.
function TaskGroup({ node, ...props }: NodeProps & { node: GroupNode }) {
  const name = node.start.task_name ?? node.start.task ?? "sub-run";
  const [open, setOpen] = useState(props.defaultOpen);

  // Live mode follows into sub-runs: an entry streaming into this group opens
  // it, so a running delegation is never hidden behind a collapsed header.
  const containsNewest =
    props.newestSeq != null && flatten(node).some((e) => e.seq === props.newestSeq);
  const expanded = open || containsNewest;

  const inner = flatten(node);
  const cost = inner.reduce((sum, e) => sum + (e.cost_usd ?? 0), 0);
  const iterations = inner.reduce((max, e) => Math.max(max, e.iteration ?? 0), 0);
  const incomplete = node.end == null;

  return (
    <div className="task-group" style={{ borderLeftColor: `hsl(${taskHue(name)} 45% 55% / 0.55)` }}>
      <button
        type="button"
        className="task-group-head"
        aria-expanded={expanded}
        onClick={() => setOpen(!expanded)}
      >
        <span className="task-group-caret">{expanded ? "▾" : "▸"}</span>
        <TaskChip task={name} />
        {node.start.model && <span className="task-group-meta">{node.start.model}</span>}
        {node.start.max_iterations != null && (
          <span className="task-group-meta">{node.start.max_iterations} iterations max</span>
        )}
        <span className="task-group-spacer" />
        {node.end?.duration_ms != null && (
          <span className="task-group-meta">{fmtDelta(node.end.duration_ms, props.coarse)}</span>
        )}
        {iterations > 0 && <span className="task-group-meta">{iterations} iter</span>}
        {cost > 0 && <span className="task-group-meta">{fmtCost(cost)}</span>}
        {incomplete && (
          <span className="task-group-incomplete" title="no task_end — the run ended mid-delegation">
            incomplete
          </span>
        )}
      </button>

      {expanded && (
        <div className="task-group-body">
          <TranscriptNodes nodes={node.children} {...props} />
        </div>
      )}
    </div>
  );
}

function flatten(node: GroupNode): Entry[] {
  return node.children.flatMap((child) =>
    child.kind === "group" ? [ child.start, ...flatten(child) ] : [ child.entry ],
  );
}

function TranscriptEntry({
  entry,
  snapshot,
  onOpenRequest,
}: {
  entry: Entry;
  snapshot: SessionDetailData["snapshot"];
  onOpenRequest: (requestSeq: number) => void;
}) {
  switch (entry.type) {
    case "user":
      return (
        <div className="msg msg-user">
          <div className="msg-role">
            <span>User</span>
          </div>
          <div className="msg-body">{entry.text}</div>
        </div>
      );

    case "compaction":
      return (
        <div className="divider divider-compaction">
          ↻ context compacted — {entry.dropped} message{entry.dropped === 1 ? "" : "s"} dropped
        </div>
      );

    case "clear":
      return (
        <div className="divider divider-compaction">
          ⌫ conversation cleared — {entry.dropped} message{entry.dropped === 1 ? "" : "s"} dropped
        </div>
      );

    case "request":
      // The point a model call was made. The button opens the sidebar on THIS
      // request's payload (system + tools + wire messages) — kept out of the
      // transcript body so the narrative stays readable.
      return (
        <div className="request-marker">
          <button
            type="button"
            className="request-btn"
            onClick={() => entry.request_seq != null && onOpenRequest(entry.request_seq)}
            title="View the exact payload sent to the model on this call"
          >
            🧠 view request
            {entry.message_count != null && (
              <span className="request-btn-count">{entry.message_count} msg{entry.message_count === 1 ? "" : "s"}</span>
            )}
          </button>
        </div>
      );

    case "turn_end": {
      const tripped = entry.reason != null && entry.reason !== "completed";
      const hasBar = (snapshot.max_turn_tokens ?? 0) > 0 && entry.tokens != null;
      return (
        <div className={tripped ? "turn-strip danger" : "turn-strip"}>
          <div className="turn-strip-text">
            {tripped ? "⚠" : "✓"} Turn {entry.turn} · {entry.iterations} iteration
            {entry.iterations === 1 ? "" : "s"}
            {entry.tokens != null && <> · {fmtTokens(entry.tokens)} tok</>}
            {tripped && <> · {entry.reason}</>}
          </div>
          {hasBar && (
            <>
              <div className="bar">
                <div
                  className={tripped ? "bar-fill danger" : "bar-fill"}
                  style={{ width: `${pct(entry.tokens, snapshot.max_turn_tokens)}%` }}
                />
              </div>
              <div className="turn-strip-pct">{pctRaw(entry.tokens, snapshot.max_turn_tokens)}%</div>
            </>
          )}
        </div>
      );
    }

    case "plan":
      return (
        <div className="msg msg-assistant msg-preamble">
          <div className="msg-role">
            <span>Plan</span>
            <span className="usage">before tool call</span>
          </div>
          <div className="msg-body">{entry.text}</div>
        </div>
      );

    case "assistant":
      if (entry.text?.startsWith("(tool use")) {
        return (
          <div className="tool-marker">
            <span>{entry.text}</span>
            <CtxChip
              usage={entry.usage}
              running={entry.running_turn_tokens}
              contextWindow={snapshot.context_window}
              maxTurnTokens={snapshot.max_turn_tokens}
              provider={entry.provider}
              model={entry.model}
              costUsd={entry.cost_usd}
            />
          </div>
        );
      }
      return (
        <div className="msg msg-assistant">
          <div className="msg-role">
            <span>Assistant</span>
            <span className="usage">{entry.stop_reason && <>stop: {entry.stop_reason}</>}</span>
          </div>
          <div className="msg-body">{entry.text}</div>
          {entry.usage && (
            <div className="msg-foot">
              <CtxChip
                usage={entry.usage}
                running={entry.running_turn_tokens}
                contextWindow={snapshot.context_window}
                maxTurnTokens={snapshot.max_turn_tokens}
                provider={entry.provider}
                model={entry.model}
                costUsd={entry.cost_usd}
              />
            </div>
          )}
        </div>
      );

    case "reasoning":
      return (
        <div className="msg msg-assistant msg-reasoning">
          <div className="msg-role">
            <span>Reasoning</span>
          </div>
          <div className="msg-body">
            {entry.redacted || !entry.text?.trim() ? (
              <span className="muted">(reasoning hidden)</span>
            ) : (
              entry.text
            )}
          </div>
        </div>
      );

    case "tool":
      return (
        <div className={entry.tool_ok === false ? "tool-call tool-error" : "tool-call"}>
          <div className="tool-name">
            ⚙ {entry.tool_name}({formatArgs(entry.tool_args)})
            {entry.tool_ok === false && <span className="tool-badge">error</span>}
          </div>
          <pre className="tool-result">
            <Ansi html={entry.result_html ?? ""} />
          </pre>
        </div>
      );

    case "unknown":
      return (
        <div className="msg msg-unknown">
          <div className="msg-role">
            <span>{String(entry.raw?.phase ?? "unknown")}</span>
          </div>
          <div className="msg-body">
            <pre>{JSON.stringify(entry.raw, null, 2)}</pre>
          </div>
        </div>
      );

    default:
      return null;
  }
}
