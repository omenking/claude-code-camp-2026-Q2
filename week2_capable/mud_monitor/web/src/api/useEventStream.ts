import { useEffect, useRef, useState } from "react";
import type { SessionSummary } from "./types";

export type StreamStatus = "connecting" | "connected" | "reconnecting" | "ended";

const MIN_BACKOFF_MS = 250;
const MAX_BACKOFF_MS = 5000;

interface HasSeq {
  seq: number;
}

interface UseEventStreamOptions<T extends HasSeq> {
  // Identifies the stream for the effect's dependency array (e.g. a session
  // id, or `${date}:${session}:${mode}` for the manager log) — anything that
  // should force a reconnect from scratch when it changes.
  streamKey: string | undefined;
  // Builds the `/stream` URL for a given resume cursor. Read from a ref, not
  // a dependency, so a new function identity every render doesn't reconnect.
  buildUrl: (afterSeq: number) => string;
  enabled: boolean;
  initialAfterSeq: number;
  onEntry: (entry: T) => void;
  onSummary?: (summary: SessionSummary) => void;
}

// Owns the EventSource lifecycle for a live log tail (spec §5.1, §3.3–3.5).
// Generic over the three log types (session/manager/telnet) — anything that
// carries a `seq`. Resumes from `initialAfterSeq` on first connect and from
// the highest seq actually received on every reconnect, so a dropped
// connection never re-delivers or skips entries — `seenRef` also dedupes
// defensively in case a reconnect's window overlaps the last delivered batch.
//
// Reconnects are driven manually with exponential backoff (250ms -> 5s)
// rather than EventSource's fixed built-in retry, because each attempt also
// needs to rewrite the `?after=` cursor in the URL.
export function useEventStream<T extends HasSeq>({
  streamKey,
  buildUrl,
  enabled,
  initialAfterSeq,
  onEntry,
  onSummary,
}: UseEventStreamOptions<T>): StreamStatus {
  const [status, setStatus] = useState<StreamStatus>("connecting");

  const cursorRef = useRef(initialAfterSeq);
  const seenRef = useRef<Set<number>>(new Set());
  const backoffRef = useRef(MIN_BACKOFF_MS);
  const sourceRef = useRef<EventSource | null>(null);
  const timerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const stoppedRef = useRef(false);

  const onEntryRef = useRef(onEntry);
  const onSummaryRef = useRef(onSummary);
  const buildUrlRef = useRef(buildUrl);
  onEntryRef.current = onEntry;
  onSummaryRef.current = onSummary;
  buildUrlRef.current = buildUrl;

  useEffect(() => {
    if (!enabled || !streamKey) return;

    stoppedRef.current = false;
    cursorRef.current = initialAfterSeq;
    seenRef.current = new Set();
    backoffRef.current = MIN_BACKOFF_MS;
    setStatus("connecting");

    const connect = () => {
      if (stoppedRef.current) return;

      const source = new EventSource(buildUrlRef.current(cursorRef.current));
      sourceRef.current = source;

      source.addEventListener("open", () => {
        backoffRef.current = MIN_BACKOFF_MS;
        setStatus("connected");
      });

      source.addEventListener("entry", (ev) => {
        const entry = JSON.parse((ev as MessageEvent).data) as T;
        if (seenRef.current.has(entry.seq)) return;
        seenRef.current.add(entry.seq);
        cursorRef.current = Math.max(cursorRef.current, entry.seq);
        onEntryRef.current(entry);
      });

      source.addEventListener("session", (ev) => {
        onSummaryRef.current?.(JSON.parse((ev as MessageEvent).data) as SessionSummary);
      });

      source.addEventListener("eof", () => {
        stoppedRef.current = true;
        source.close();
        setStatus("ended");
      });

      source.onerror = () => {
        if (stoppedRef.current) return;
        source.close();
        setStatus("reconnecting");
        const delay = backoffRef.current;
        backoffRef.current = Math.min(delay * 2, MAX_BACKOFF_MS);
        timerRef.current = setTimeout(connect, delay);
      };
    };

    connect();

    return () => {
      stoppedRef.current = true;
      if (timerRef.current) clearTimeout(timerRef.current);
      sourceRef.current?.close();
      sourceRef.current = null;
    };
  }, [streamKey, enabled]);

  return status;
}
