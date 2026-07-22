import { pct } from "../format";

// Port of log_viz's `progress_bar` helper.
export default function ProgressBar({
  used,
  max,
  label,
  danger = false,
}: {
  used: number | null | undefined;
  max: number | null | undefined;
  label: string;
  danger?: boolean;
}) {
  const width = pct(used, max);
  return (
    <div className="budget">
      <div className="budget-label">{label}</div>
      <div className="bar">
        <div className={danger ? "bar-fill danger" : "bar-fill"} style={{ width: `${width}%` }} />
      </div>
    </div>
  );
}
