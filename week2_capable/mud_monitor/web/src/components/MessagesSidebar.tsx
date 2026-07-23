import { useCallback, useEffect, useState } from "react";
import { ApiRequestError, fetchSessionMessages } from "../api/client";
import type { ContentBlock, MessageCheckpoint, TimelineMessage, TimelineTool } from "../api/types";
import { formatArgs, formatTime } from "../format";

// Strip CSI/SGR escape sequences for display. The model consumes the raw string
// (codes and all), but the escape bytes render as noise in the browser; the
// text between them is what a human reading the context actually wants to see.
// eslint-disable-next-line no-control-regex
const ANSI = /\x1b\[[0-9;]*m/g;
function clean(text: string): string {
  return text.replace(ANSI, "");
}

// The "why the front was trimmed" line above a checkpoint whose head shrank.
function droppedLabel(marker: MessageCheckpoint["marker"], dropped: number): string {
  const n = `${dropped} message${dropped === 1 ? "" : "s"}`;
  switch (marker) {
    case "clear":
      return `⌫ cleared — ${n} dropped`;
    case "compaction":
      return `↻ compacted — ${n} dropped from the front`;
    default:
      return `↻ trimmed — ${n} dropped from the front`;
  }
}

function ContentBlockView({ block }: { block: ContentBlock }) {
  if (block.type === "text") {
    return <div className="ctx-text">{block.text}</div>;
  }
  if (block.type === "tool_use") {
    return (
      <div className="ctx-tooluse">
        ⚙ {block.name}({formatArgs(block.input)})
      </div>
    );
  }
  if (block.type === "tool_result") {
    const body =
      typeof block.content === "string" ? clean(block.content) : JSON.stringify(block.content, null, 2);
    return (
      <div>
        <div className="ctx-block-tag">
          tool_result{block.tool_use_id ? ` · ${String(block.tool_use_id)}` : ""}
        </div>
        <pre className="ctx-toolresult">{body}</pre>
      </div>
    );
  }
  return <pre className="ctx-text">{JSON.stringify(block, null, 2)}</pre>;
}

function MessageView({ message }: { message: TimelineMessage }) {
  const { role, content } = message;
  return (
    <div className={`ctx-msg ctx-msg-${role}`}>
      <div className="ctx-msg-role">{role}</div>
      <div className="ctx-msg-body">
        {typeof content === "string" ? (
          <pre className="ctx-toolresult">{content}</pre>
        ) : (
          content.map((block, i) => <ContentBlockView key={i} block={block} />)
        )}
      </div>
    </div>
  );
}

// The system prompt + tool schemas — the parts of the payload that never appear
// in the transcript. Constant across a turn, so collapsed by default and only
// flagged when they actually changed on this call.
function PayloadHeader({ cp }: { cp: MessageCheckpoint }) {
  const [showSystem, setShowSystem] = useState(false);
  const [showTools, setShowTools] = useState(false);

  return (
    <>
      {cp.system != null && (
        <div className="ctx-section">
          <button type="button" className="ctx-section-head" onClick={() => setShowSystem((v) => !v)}>
            <span className="ctx-section-caret">{showSystem ? "▾" : "▸"}</span>
            system prompt
            {cp.system_changed ? (
              <span className="ctx-changed">changed</span>
            ) : (
              <span className="ctx-unchanged">unchanged</span>
            )}
          </button>
          {showSystem && <pre className="ctx-system">{cp.system}</pre>}
        </div>
      )}

      {cp.tools != null && cp.tools.length > 0 && (
        <div className="ctx-section">
          <button type="button" className="ctx-section-head" onClick={() => setShowTools((v) => !v)}>
            <span className="ctx-section-caret">{showTools ? "▾" : "▸"}</span>
            tools <span className="ctx-count">{cp.tool_count ?? cp.tools.length}</span>
            {cp.tools_changed ? (
              <span className="ctx-changed">changed</span>
            ) : (
              <span className="ctx-unchanged">unchanged</span>
            )}
          </button>
          {showTools && (
            <div className="ctx-tools">
              {cp.tools.map((t: TimelineTool, i) => (
                <details key={i} className="ctx-tool">
                  <summary>{t.name ?? `tool ${i}`}</summary>
                  <pre className="ctx-toolresult">{JSON.stringify(t, null, 2)}</pre>
                </details>
              ))}
            </div>
          )}
        </div>
      )}
    </>
  );
}

function CheckpointView({ cp }: { cp: MessageCheckpoint }) {
  const [showFull, setShowFull] = useState(false);
  const appended = cp.messages.slice(cp.carried);
  const shown = showFull ? cp.messages : appended;

  return (
    <div className="ctx-checkpoint">
      <div className="ctx-cp-head">
        <span className="ctx-cp-seq">Call {cp.seq}</span>
        <span className="ctx-cp-meta">
          turn {cp.turn} · iter {cp.iteration} · {cp.message_count} msg
          {cp.message_count === 1 ? "" : "s"}
          {cp.model && <> · {cp.model}</>}
          {cp.max_tokens != null && <> · max_tokens {cp.max_tokens}</>}
        </span>
        <span className="ctx-cp-time">{formatTime(cp.at)}</span>
      </div>

      <PayloadHeader cp={cp} />

      {cp.dropped > 0 && <div className="ctx-cp-dropped">{droppedLabel(cp.marker, cp.dropped)}</div>}

      <div className="ctx-cp-toggle">
        <button type="button" className={showFull ? "" : "active"} onClick={() => setShowFull(false)}>
          delta {appended.length > 0 && <span className="ctx-count">+{appended.length}</span>}
        </button>
        <button type="button" className={showFull ? "active" : ""} onClick={() => setShowFull(true)}>
          full <span className="ctx-count">{cp.messages.length}</span>
        </button>
      </div>

      {!showFull && cp.carried > 0 && (
        <div className="ctx-carried">
          ↑ {cp.carried} earlier message{cp.carried === 1 ? "" : "s"} carried unchanged
        </div>
      )}

      {shown.length === 0 ? (
        <div className="ctx-empty">(no new messages on this call)</div>
      ) : (
        shown.map((m, i) => <MessageView key={i} message={m} />)
      )}
    </div>
  );
}

export default function MessagesSidebar({
  id,
  focusSeq,
  onClose,
}: {
  id: string;
  // The request the user clicked (1-based; maps to checkpoint.seq). The sidebar
  // shows exactly this one call, with prev/next to step between requests.
  focusSeq: number;
  onClose: () => void;
}) {
  const [checkpoints, setCheckpoints] = useState<MessageCheckpoint[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);
  const [seq, setSeq] = useState(focusSeq);

  const load = useCallback(() => {
    setLoading(true);
    setError(null);
    fetchSessionMessages(id)
      .then((data) => setCheckpoints(data.checkpoints))
      .catch((err) => setError(err instanceof ApiRequestError ? err.message : String(err)))
      .finally(() => setLoading(false));
  }, [id]);

  useEffect(() => {
    load();
  }, [load]);

  // A click on a different request re-points the drawer without remounting it.
  useEffect(() => {
    setSeq(focusSeq);
  }, [focusSeq]);

  const total = checkpoints?.length ?? 0;
  const current = checkpoints?.find((c) => c.seq === seq) ?? null;
  // "prompt" source means the log predates request-logging: a reconstruction,
  // not the real payload. Say so rather than implying it's exact.
  const reconstruction = current?.source === "prompt";

  return (
    <>
      <div className="ctx-scrim" onClick={onClose} />
      <aside className="ctx-drawer" aria-label="Request payload">
        <header className="ctx-drawer-head">
          <div>
            <div className="ctx-drawer-title">🧠 Request {seq}</div>
            <div className="ctx-drawer-sub">the exact payload sent to the model on this call</div>
          </div>
          <div className="ctx-drawer-actions">
            <button type="button" onClick={() => setSeq((s) => Math.max(1, s - 1))} disabled={seq <= 1} title="Previous request">
              ‹
            </button>
            <button type="button" onClick={() => setSeq((s) => Math.min(total, s + 1))} disabled={total === 0 || seq >= total} title="Next request">
              ›
            </button>
            <button type="button" onClick={load} title="Refresh" disabled={loading}>
              ↻
            </button>
            <button type="button" onClick={onClose} title="Close">
              ✕
            </button>
          </div>
        </header>

        <div className="ctx-drawer-body">
          {error && <p className="error">Failed to load request: {error}</p>}
          {!error && checkpoints == null && <p>Loading…</p>}
          {reconstruction && (
            <div className="ctx-note">
              This session predates request-logging — showing a reconstruction of the message history
              (no system prompt or tool schemas were recorded).
            </div>
          )}
          {!error && checkpoints != null && current == null && (
            <p className="ctx-empty">No payload recorded for this call.</p>
          )}
          {current && <CheckpointView cp={current} />}
        </div>
      </aside>
    </>
  );
}
