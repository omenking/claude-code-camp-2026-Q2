import type { UsagePoint } from "../api/types";

// Inline SVG sparkline of per-iteration input tokens across the session.
// Faint vertical lines mark turn boundaries. No JS, no chart library —
// port of log_viz's `sparkline` helper.
export default function Sparkline({
  points,
  max,
  width = 640,
  height = 48,
}: {
  points: UsagePoint[];
  max: number;
  width?: number;
  height?: number;
}) {
  if (points.length < 2) return null;

  const denom = Math.max(max, 1);
  const step = width / (points.length - 1);

  const coords = points
    .map((p, i) => {
      const x = Math.round(i * step * 10) / 10;
      const y = Math.round((height - (p.input / denom) * (height - 4) - 2) * 10) / 10;
      return `${x},${y}`;
    })
    .join(" ");

  const rules = points
    .map((p, i) => (i > 0 && p.iteration === 1 ? i : null))
    .filter((i): i is number => i !== null)
    .map((i) => {
      const x = Math.round(i * step * 10) / 10;
      return <line key={i} className="spark-turn" x1={x} y1={0} x2={x} y2={height} />;
    });

  return (
    <svg
      className="spark"
      viewBox={`0 0 ${width} ${height}`}
      preserveAspectRatio="none"
      role="img"
      aria-label="input tokens per iteration"
    >
      {rules}
      <polyline className="spark-line" points={coords} />
    </svg>
  );
}
