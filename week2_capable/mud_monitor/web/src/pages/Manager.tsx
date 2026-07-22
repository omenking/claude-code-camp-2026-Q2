import { Fragment, useCallback, useEffect, useMemo, useState } from "react";
import { ApiRequestError, fetchDropped, fetchManager } from "../api/client";
import type { DroppedEvent, DroppedSummary, ManagerRecord } from "../api/types";
import { useEventStream } from "../api/useEventStream";
import Ansi from "../components/Ansi";
import DroppedStrip from "../components/DroppedStrip";
import LiveBadge from "../components/LiveBadge";
import { fmtDelta, fmtAbsolute, fmtBytes, fmtPct, formatArgs, truncate } from "../format";

function todayStamp(): string {
  const d = new Date();
  const pad = (n: number) => String(n).padStart(2, "0");
  return `${d.getFullYear()}${pad(d.getMonth() + 1)}${pad(d.getDate())}`;
}

const MODES = [ "", "command", "raw", "poll", "login" ];

// The standalone view onto ManagerLog (spec §4.3, §5) — every command
// mud_manager actually drove through the socket, independent of what the
// agent's own session log says it saw. This is where "we have no logging in
// mud manager" gets answered directly: the literal text that went out next
// to the literal bytes that came back.
export default function Manager() {
  const [date, setDate] = useState(todayStamp());
  const [sessionFilter, setSessionFilter] = useState("");
  const [modeFilter, setModeFilter] = useState("");
  const [records, setRecords] = useState<ManagerRecord[] | null>(null);
  const [live, setLive] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [newestSeq, setNewestSeq] = useState<number | null>(null);
  const [showDropped, setShowDropped] = useState(true);
  const [dropped, setDropped] = useState<DroppedEvent[] | null>(null);
  const [dropSummary, setDropSummary] = useState<DroppedSummary | null>(null);
  const [dropError, setDropError] = useState<string | null>(null);

  useEffect(() => {
    setRecords(null);
    setError(null);
    fetchManager({ date, session: sessionFilter || undefined, mode: modeFilter || undefined })
      .then((page) => {
        setRecords(page.entries);
        setLive(page.live);
      })
      .catch((err) => setError(err instanceof ApiRequestError ? err.message : String(err)));
  }, [date, sessionFilter, modeFilter]);

  // Independent of `modeFilter` — the drain-loss diff (spec §3.6) has to see
  // every exchange in the session to align correctly, not just the modes
  // currently displayed.
  useEffect(() => {
    setDropped(null);
    setDropSummary(null);
    setDropError(null);
    fetchDropped({ date, session: sessionFilter || "default" })
      .then((diff) => {
        setDropped(diff.dropped);
        setDropSummary(diff.summary);
      })
      .catch((err) => setDropError(err instanceof ApiRequestError ? err.message : String(err)));
  }, [date, sessionFilter]);

  const droppedBySeq = useMemo(() => {
    const map = new Map<number | null, DroppedEvent[]>();
    for (const d of dropped ?? []) {
      const key = d.between.after_manager_seq;
      const list = map.get(key) ?? [];
      list.push(d);
      map.set(key, list);
    }
    return map;
  }, [dropped]);

  const handleEntry = useCallback((record: ManagerRecord) => {
    setRecords((prev) => {
      const list = prev ?? [];
      return list.some((r) => r.seq === record.seq) ? list : [ ...list, record ];
    });
    setNewestSeq(record.seq);
  }, []);

  const streamKey = live ? `${date}:${sessionFilter}:${modeFilter}` : undefined;
  const buildUrl = useMemo(
    () => (afterSeq: number) => {
      const params = new URLSearchParams({ date, after: String(afterSeq) });
      if (sessionFilter) params.set("session", sessionFilter);
      if (modeFilter) params.set("mode", modeFilter);
      return `/api/v1/manager/stream?${params.toString()}`;
    },
    [date, sessionFilter, modeFilter],
  );

  const streamStatus = useEventStream<ManagerRecord>({
    streamKey,
    buildUrl,
    enabled: live,
    initialAfterSeq: records?.at(-1)?.seq ?? 0,
    onEntry: handleEntry,
  });

  return (
    <>
      <h1>
        Manager
        {live && <LiveBadge status={streamStatus} />}
      </h1>
      <p className="meta">Every command mud_manager executed against the MUD, and what came back.</p>

      <div className="manager-filters">
        <label>
          Date
          <input
            type="text"
            value={date}
            onChange={(e) => setDate(e.target.value)}
            placeholder="YYYYMMDD"
            className="manager-filter-date"
          />
        </label>
        <label>
          Session
          <input
            type="text"
            value={sessionFilter}
            onChange={(e) => setSessionFilter(e.target.value)}
            placeholder="all"
          />
        </label>
        <label>
          Mode
          <select value={modeFilter} onChange={(e) => setModeFilter(e.target.value)}>
            {MODES.map((m) => (
              <option key={m} value={m}>
                {m || "all"}
              </option>
            ))}
          </select>
        </label>
        <label className="manager-dropped-toggle" title={modeFilter ? "Only available when mode is 'all'" : ""}>
          <input
            type="checkbox"
            checked={showDropped}
            disabled={Boolean(modeFilter)}
            onChange={(e) => setShowDropped(e.target.checked)}
          />
          Show dropped
        </label>
      </div>

      {dropError && <p className="error">Failed to load dropped diff: {dropError}</p>}

      {showDropped && !modeFilter && dropSummary && (
        <p className="dropped-summary">
          drop ratio <strong>{fmtPct(dropSummary.drop_ratio)}</strong> · {dropSummary.dropped_bytes} B dropped across{" "}
          {dropSummary.dropped_runs} run{dropSummary.dropped_runs === 1 ? "" : "s"} ·{" "}
          {fmtBytes(dropSummary.received_bytes)} received
        </p>
      )}

      {error && <p className="error">Failed to load manager log: {error}</p>}

      {!error && records === null && <p>Loading…</p>}

      {records && records.length === 0 && (
        <p className="empty">
          No manager log entries for {date}. Manager logging is off unless MUD_MANAGER_LOG_DIR is set.
        </p>
      )}

      {records && records.length > 0 && (
        <table className="manager">
          <thead>
            <tr>
              <th>Time</th>
              <th>Session</th>
              <th>Mode</th>
              <th>Tool</th>
              <th>Sent</th>
              <th>Received</th>
              <th className="nowrap">Elapsed</th>
            </tr>
          </thead>
          <tbody>
            {showDropped &&
              !modeFilter &&
              (droppedBySeq.get(null) ?? []).map((d, i) => (
                <tr key={`dropped-lead-${i}`}>
                  <td colSpan={7}>
                    <DroppedStrip event={d} />
                  </td>
                </tr>
              ))}
            {records.map((r) => (
              <Fragment key={r.seq}>
                <tr
                  className={[ r.error ? "manager-row-error" : "", r.seq === newestSeq ? "entry-row-new" : "" ]
                    .filter(Boolean)
                    .join(" ")}
                >
                  <td className="nowrap" title={r.at ?? undefined}>
                    {fmtAbsolute(r.at)}
                  </td>
                  <td className="nowrap">{r.session}</td>
                  <td className="nowrap">{r.mode}</td>
                  <td className="manager-tool">
                    {r.tool ? (
                      <>
                        {r.tool}({formatArgs(r.args)})
                      </>
                    ) : (
                      "—"
                    )}
                  </td>
                  <td className="manager-sent" title={r.sent ?? undefined}>
                    {truncate(r.sent, 40) || "—"}
                  </td>
                  <td className="manager-received">
                    {r.error ? (
                      <span className="manager-error-text">{r.error}</span>
                    ) : (
                      <pre className="manager-received-pre">
                        <Ansi html={r.received_html} />
                      </pre>
                    )}
                  </td>
                  <td className="nowrap">{fmtDelta(r.elapsed_ms)}</td>
                </tr>
                {showDropped &&
                  !modeFilter &&
                  (droppedBySeq.get(r.seq) ?? []).map((d, i) => (
                    <tr key={`dropped-${r.seq}-${i}`}>
                      <td colSpan={7}>
                        <DroppedStrip event={d} />
                      </td>
                    </tr>
                  ))}
              </Fragment>
            ))}
          </tbody>
        </table>
      )}
    </>
  );
}
