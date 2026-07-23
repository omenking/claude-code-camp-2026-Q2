import { useEffect, useState } from "react";
import { Link } from "react-router";
import { ApiRequestError, fetchSessions } from "../api/client";
import type { SessionSummary } from "../api/types";
import TaskChip from "../components/TaskChip";
import { fmtCost, fmtDuration, formatTime, pct, truncate } from "../format";

// Port of week1_baseline/log_viz/views/index.erb.
export default function Sessions() {
  const [sessions, setSessions] = useState<SessionSummary[] | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    fetchSessions()
      .then((body) => setSessions(body.sessions))
      .catch((err) => setError(err instanceof ApiRequestError ? err.message : String(err)));
  }, []);

  return (
    <>
      <h1>Sessions</h1>

      {error && <p className="error">Failed to load sessions: {error}</p>}

      {!error && sessions === null && <p>Loading…</p>}

      {sessions && sessions.length === 0 && <p className="empty">No session logs found.</p>}

      {sessions && sessions.length > 0 && (
        <table className="sessions">
          <thead>
            <tr>
              <th>Started</th>
              <th className="nowrap">Duration</th>
              <th>Session ID</th>
              <th>Task</th>
              <th>Model(s)</th>
              <th>Iterations</th>
              <th>Tokens (in / out)</th>
              <th className="nowrap">Peak ctx</th>
              <th className="nowrap">Cost</th>
            </tr>
          </thead>
          <tbody>
            {sessions.map((session) => (
              <tr key={session.id}>
                <td className="nowrap">{formatTime(session.started_at)}</td>
                <td className="nowrap duration-cell" title={`ended ${formatTime(session.ended_at)}`}>
                  {fmtDuration(session.duration_ms)}
                </td>
                <td>
                  <Link to={`/sessions/${session.id}`}>{session.id}</Link>
                  {session.any_limit_tripped && (
                    <span className="limit-flag" title="a turn tripped a limit">
                      ⚠
                    </span>
                  )}
                </td>
                <td className="task">
                  <div className="task-roster">
                    {session.tasks.map((t) => (
                      <TaskChip key={t} task={t} />
                    ))}
                    {session.sub_runs > 0 && (
                      <span className="sub-run-count" title={`${session.sub_runs} delegated sub-runs`}>
                        ⑂ {session.sub_runs}
                      </span>
                    )}
                  </div>
                  <div className="task-goal">{truncate(session.task, 70)}</div>
                </td>
                <td className="model-list">{truncate(session.models.join(", "), 54)}</td>
                <td className="nowrap">{session.iterations}</td>
                <td className="nowrap">
                  {session.input_tokens} / {session.output_tokens}
                </td>
                <td className="nowrap">
                  {session.context_window && session.context_window > 0
                    ? `${pct(session.peak_input_tokens, session.context_window)}%`
                    : "—"}
                </td>
                <td className="nowrap">{fmtCost(session.cost_usd)}</td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
    </>
  );
}
