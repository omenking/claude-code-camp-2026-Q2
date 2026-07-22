import type { CSSProperties } from "react";

// Which task produced a given entry (plan §A.5). Colour is derived from the
// name rather than assigned from a fixed list, so a task the monitor has never
// heard of still gets a stable, distinguishable colour the first time it runs —
// the same unknown-passthrough discipline the parser follows.
export function taskHue(task: string): number {
  let hash = 0;
  for (let i = 0; i < task.length; i += 1) hash = (hash * 31 + task.charCodeAt(i)) % 360;
  return hash;
}

export function taskStyle(task: string): CSSProperties {
  const hue = taskHue(task);
  return {
    color: `hsl(${hue} 65% 45%)`,
    borderColor: `hsl(${hue} 45% 55% / 0.5)`,
    background: `hsl(${hue} 65% 50% / 0.12)`,
  };
}

export default function TaskChip({ task, title }: { task: string | null | undefined; title?: string }) {
  if (!task) return null;

  return (
    <span className="task-chip" style={taskStyle(task)} title={title ?? `task: ${task}`}>
      {task}
    </span>
  );
}
