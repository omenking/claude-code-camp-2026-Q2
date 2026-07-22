import type { StreamStatus } from "../api/useEventStream";

const LABELS: Record<StreamStatus, string> = {
  connecting: "connecting…",
  connected: "live",
  reconnecting: "reconnecting…",
  ended: "ended",
};

export default function LiveBadge({ status }: { status: StreamStatus }) {
  return (
    <span className={`live-badge live-badge-${status}`}>
      <span className="live-badge-dot" />
      {LABELS[status]}
    </span>
  );
}
