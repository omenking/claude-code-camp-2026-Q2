// Port of week1_baseline/log_viz/lib/log_viz/app.rb's helpers block.

export function formatTime(iso: string | null): string {
  if (!iso) return "?";
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return iso;
  return d.toLocaleString(undefined, {
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
    hour12: false,
  });
}

export function truncate(text: string | null | undefined, length = 100): string {
  const flat = (text ?? "").replace(/\s+/g, " ").trim();
  return flat.length > length ? `${flat.slice(0, length)}…` : flat;
}

export function formatArgs(args: Record<string, unknown> | null | undefined): string {
  if (!args || Object.keys(args).length === 0) return "";
  return Object.entries(args)
    .map(([k, v]) => `${k}: ${JSON.stringify(v)}`)
    .join(", ");
}

export function fmtTokens(n: number | null | undefined): string {
  const v = n ?? 0;
  return v >= 1000 ? `${(v / 1000).toFixed(1)}k` : String(v);
}

export function pct(used: number | null | undefined, max: number | null | undefined): number {
  const m = max ?? 0;
  if (m <= 0) return 0;
  return Math.min(Math.round(((used ?? 0) / m) * 100), 100);
}

// Uncapped percentage for labels — shows >100% when a budget is exceeded.
export function pctRaw(used: number | null | undefined, max: number | null | undefined): number {
  const m = max ?? 0;
  if (m <= 0) return 0;
  return Math.round(((used ?? 0) / m) * 100);
}

export function fmtCost(n: number | null | undefined): string {
  return n == null ? "—" : `$${n.toFixed(4)}`;
}

export function fmtCostCell(cost: number | null | undefined, known: boolean): string {
  if (cost == null || !known) return "—";
  return fmtCost(cost);
}

// HH:MM:SS for the timing gutter; full ISO is left for the title/hover attr.
export function fmtAbsolute(iso: string | null | undefined): string {
  if (!iso) return "?";
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return iso;
  return d.toLocaleTimeString(undefined, { hour: "2-digit", minute: "2-digit", second: "2-digit", hour12: false });
}

// A gap or duration in ms, human scaled. `coarse` sessions (§4.1 — 1s-resolution
// `at` with no mono_ms) render as a muted `~Ns` rather than a precise-looking
// `0ms`, since sub-second timing is genuinely unknowable for them.
export function fmtDelta(ms: number | null | undefined, coarse = false): string {
  if (ms == null) return "—";
  if (coarse) return `~${Math.max(1, Math.round(ms / 1000))}s`;
  if (ms < 1000) return `${Math.round(ms)}ms`;
  if (ms < 60_000) return `${(ms / 1000).toFixed(1)}s`;
  const totalSec = Math.round(ms / 1000);
  return `${Math.floor(totalSec / 60)}m ${totalSec % 60}s`;
}

export function fmtBytes(n: number | null | undefined): string {
  const v = n ?? 0;
  if (v >= 1_000_000) return `${(v / 1_000_000).toFixed(1)} MB`;
  if (v >= 1000) return `${(v / 1000).toFixed(1)} KB`;
  return `${v} B`;
}

// A 0..1 ratio (or null when there's no data to divide) rendered as a
// percentage — null must stay "—", never a fake "0%" (spec §3.6: drop_ratio
// is the headline number, so it can't lie about having zero data).
export function fmtPct(ratio: number | null | undefined): string {
  return ratio == null ? "—" : `${(ratio * 100).toFixed(1)}%`;
}

// Colour-ramp class for the duration pill, by magnitude.
export function durationClass(ms: number | null | undefined, coarse = false): string {
  if (ms == null) return "";
  if (coarse) return "duration-coarse";
  if (ms < 500) return "duration-fast";
  if (ms < 2000) return "duration-normal";
  if (ms < 8000) return "duration-slow";
  return "duration-very-slow";
}
