import { durationClass, fmtAbsolute, fmtDelta } from "../format";

// The per-entry timing gutter (spec §5.1): absolute time on hover, the gap
// since the previous entry, and a colour-ramped duration pill. Coarse
// (1s-resolution, pre-§4.1) sessions render `~Ns` in muted text rather than a
// precise-looking `0ms` — the sub-second figure would be a lie.
export default function Duration({
  at,
  dtMs,
  durationMs,
  coarse,
}: {
  at: string | null;
  dtMs: number | null;
  durationMs: number | null;
  coarse: boolean;
}) {
  return (
    <div className="entry-gutter">
      <span className="entry-gutter-at" title={at ?? undefined}>
        {fmtAbsolute(at)}
      </span>
      {dtMs != null && <span className="entry-gutter-dt">+{fmtDelta(dtMs, coarse)}</span>}
      {durationMs != null && (
        <span className={`entry-gutter-pill ${durationClass(durationMs, coarse)}`}>
          {fmtDelta(durationMs, coarse)}
        </span>
      )}
    </div>
  );
}
