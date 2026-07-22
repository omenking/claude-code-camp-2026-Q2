import { useEffect, useState } from "react";
import { Link } from "react-router";
import { ApiRequestError, fetchDropped, fetchSessions } from "../api/client";
import type { DroppedSummary, SessionSummary } from "../api/types";
import { fmtBytes, fmtCost, fmtPct, formatTime, truncate } from "../format";

interface Health {
  ok: boolean;
  telnet_logging_enabled: boolean;
  manager_logging_enabled: boolean;
  world_ready: boolean;
  live_sessions: number;
}

function todayStamp(): string {
  const d = new Date();
  const pad = (n: number) => String(n).padStart(2, "0");
  return `${d.getFullYear()}${pad(d.getMonth() + 1)}${pad(d.getDate())}`;
}

// The landing page (spec §5): live sessions, recent sessions, and the
// headline drop_ratio number from §3.6 — how much of the MUD's output never
// reached a tool call, made visible by Diff::TelnetManager instead of
// silently vanishing into `drain`.
export default function Dashboard() {
  const [health, setHealth] = useState<Health | null>(null);
  const [sessions, setSessions] = useState<SessionSummary[] | null>(null);
  const [dropSummary, setDropSummary] = useState<DroppedSummary | null>(null);
  const [dropError, setDropError] = useState<string | null>(null);

  useEffect(() => {
    fetch("/api/v1/health")
      .then((res) => res.json() as Promise<Health>)
      .then(setHealth)
      .catch(() => setHealth(null));
    fetchSessions()
      .then((body) => setSessions(body.sessions))
      .catch(() => setSessions([]));
    fetchDropped({ date: todayStamp(), session: "default" })
      .then((diff) => setDropSummary(diff.summary))
      .catch((err) => setDropError(err instanceof ApiRequestError ? err.message : String(err)));
  }, []);

  const recent = (sessions ?? []).slice(0, 5);

  return (
    <>
      <h1>Dashboard</h1>

      <div className="stat-grid">
        <div className="stat-tile">
          <div className="stat-tile-label">Live sessions</div>
          <div className="stat-tile-value">{health ? health.live_sessions : "—"}</div>
        </div>
        <div className="stat-tile">
          <div className="stat-tile-label">Drop ratio (today, default session)</div>
          <div className="stat-tile-value">{dropError ? "—" : fmtPct(dropSummary?.drop_ratio)}</div>
          {dropSummary && !dropError && (
            <div className="stat-tile-sub">
              {fmtBytes(dropSummary.dropped_bytes)} dropped across {dropSummary.dropped_runs} run
              {dropSummary.dropped_runs === 1 ? "" : "s"}
            </div>
          )}
        </div>
        <div className="stat-tile">
          <div className="stat-tile-label">Telnet logging</div>
          <div className="stat-tile-value">{health?.telnet_logging_enabled ? "on" : "off"}</div>
        </div>
        <div className="stat-tile">
          <div className="stat-tile-label">Manager logging</div>
          <div className="stat-tile-value">{health?.manager_logging_enabled ? "on" : "off"}</div>
        </div>
      </div>

      {dropError && (
        <p className="error">
          Failed to load drop diff: {dropError} — see <Link to="/manager">Manager</Link> for per-session detail.
        </p>
      )}

      <h2>Recent sessions</h2>
      {sessions === null && <p>Loading…</p>}
      {sessions && sessions.length === 0 && <p className="empty">No session logs found.</p>}
      {recent.length > 0 && (
        <table className="sessions">
          <thead>
            <tr>
              <th>Started</th>
              <th>Session ID</th>
              <th>Task</th>
              <th className="nowrap">Cost</th>
            </tr>
          </thead>
          <tbody>
            {recent.map((s) => (
              <tr key={s.id}>
                <td className="nowrap">{formatTime(s.started_at)}</td>
                <td>
                  <Link to={`/sessions/${s.id}`}>{s.id}</Link>
                  {s.live && <span className="live-dot" title="live" />}
                </td>
                <td className="task">{truncate(s.task, 80)}</td>
                <td className="nowrap">{fmtCost(s.cost_usd)}</td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
      {sessions && sessions.length > 5 && (
        <p className="meta">
          <Link to="/sessions">All {sessions.length} sessions →</Link>
        </p>
      )}
    </>
  );
}
