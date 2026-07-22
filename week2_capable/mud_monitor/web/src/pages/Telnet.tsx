import { useCallback, useEffect, useMemo, useState } from "react";
import { ApiRequestError, fetchTelnet } from "../api/client";
import type { TelnetRecord } from "../api/types";
import { useEventStream } from "../api/useEventStream";
import Ansi from "../components/Ansi";
import LiveBadge from "../components/LiveBadge";
import { fmtAbsolute } from "../format";

function todayStamp(): string {
  const d = new Date();
  const pad = (n: number) => String(n).padStart(2, "0");
  return `${d.getFullYear()}${pad(d.getMonth() + 1)}${pad(d.getDate())}`;
}

const DIRS = [ "", "in", "out" ];

// The standalone view onto TelnetLog (spec §4.2, §5) — every byte that
// actually crossed the socket, both directions, independent of what
// mud_manager or the agent chose to keep. This is the layer that sees the
// login dance and the chatter `drain` throws away between commands.
export default function Telnet() {
  const [date, setDate] = useState(todayStamp());
  const [sessionFilter, setSessionFilter] = useState("");
  const [dirFilter, setDirFilter] = useState("");
  const [records, setRecords] = useState<TelnetRecord[] | null>(null);
  const [live, setLive] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [newestSeq, setNewestSeq] = useState<number | null>(null);

  useEffect(() => {
    setRecords(null);
    setError(null);
    fetchTelnet({ date, session: sessionFilter || undefined, dir: dirFilter || undefined })
      .then((page) => {
        setRecords(page.entries);
        setLive(page.live);
      })
      .catch((err) => setError(err instanceof ApiRequestError ? err.message : String(err)));
  }, [date, sessionFilter, dirFilter]);

  const handleEntry = useCallback((record: TelnetRecord) => {
    setRecords((prev) => {
      const list = prev ?? [];
      return list.some((r) => r.seq === record.seq) ? list : [ ...list, record ];
    });
    setNewestSeq(record.seq);
  }, []);

  const streamKey = live ? `${date}:${sessionFilter}:${dirFilter}` : undefined;
  const buildUrl = useMemo(
    () => (afterSeq: number) => {
      const params = new URLSearchParams({ date, after: String(afterSeq) });
      if (sessionFilter) params.set("session", sessionFilter);
      if (dirFilter) params.set("dir", dirFilter);
      return `/api/v1/telnet/stream?${params.toString()}`;
    },
    [date, sessionFilter, dirFilter],
  );

  const streamStatus = useEventStream<TelnetRecord>({
    streamKey,
    buildUrl,
    enabled: live,
    initialAfterSeq: records?.at(-1)?.seq ?? 0,
    onEntry: handleEntry,
  });

  return (
    <>
      <h1>
        Telnet
        {live && <LiveBadge status={streamStatus} />}
      </h1>
      <p className="meta">Every byte that crossed the socket, both directions, in true chronological order.</p>

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
          Direction
          <select value={dirFilter} onChange={(e) => setDirFilter(e.target.value)}>
            {DIRS.map((d) => (
              <option key={d} value={d}>
                {d || "all"}
              </option>
            ))}
          </select>
        </label>
      </div>

      {error && <p className="error">Failed to load telnet log: {error}</p>}

      {!error && records === null && <p>Loading…</p>}

      {records && records.length === 0 && (
        <p className="empty">
          No telnet log entries for {date}. Telnet logging is off unless MUD_TELNET_LOG_DIR is set.
        </p>
      )}

      {records && records.length > 0 && (
        <table className="manager">
          <thead>
            <tr>
              <th>Time</th>
              <th>Session</th>
              <th>Dir</th>
              <th className="nowrap">Bytes</th>
              <th>Text</th>
            </tr>
          </thead>
          <tbody>
            {records.map((r) => (
              <tr
                key={r.seq}
                className={[
                  r.dir === "out" ? "telnet-row-out" : "",
                  r.seq === newestSeq ? "entry-row-new" : "",
                ]
                  .filter(Boolean)
                  .join(" ")}
              >
                <td className="nowrap" title={r.at ?? undefined}>
                  {fmtAbsolute(r.at)}
                </td>
                <td className="nowrap">{r.session}</td>
                <td className="nowrap">{r.dir}</td>
                <td className="nowrap">{r.bytes}</td>
                <td className="manager-received">
                  {r.redacted ? (
                    <span className="manager-error-text">&lt;redacted&gt;</span>
                  ) : (
                    <pre className="manager-received-pre">
                      <Ansi html={r.text_html} />
                    </pre>
                  )}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
    </>
  );
}
