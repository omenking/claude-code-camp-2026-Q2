import { useEffect, useState } from "react";

interface Health {
  ok: boolean;
  telnet_dir: string;
  manager_dir: string;
  sessions_dir: string;
  telnet_logging_enabled: boolean;
  manager_logging_enabled: boolean;
  world_ready: boolean;
  knowledge_attached: boolean;
  live_sessions: number;
}

export default function HealthPage() {
  const [health, setHealth] = useState<Health | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    fetch("/api/v1/health")
      .then((res) => {
        if (!res.ok) throw new Error(`${res.status} ${res.statusText}`);
        return res.json() as Promise<Health>;
      })
      .then(setHealth)
      .catch((err) => setError(String(err)));
  }, []);

  return (
    <>
      <h1>Health</h1>
      {error && <p className="error">API unreachable: {error}</p>}
      {!error && !health && <p>Loading…</p>}
      {health && (
        <dl>
          <dt>status</dt>
          <dd>{health.ok ? "ok" : "not ok"}</dd>
          <dt>sessions_dir</dt>
          <dd>{health.sessions_dir}</dd>
          <dt>telnet logging</dt>
          <dd>{health.telnet_logging_enabled ? "enabled" : "disabled"}</dd>
          <dt>manager logging</dt>
          <dd>{health.manager_logging_enabled ? "enabled" : "disabled"}</dd>
          <dt>world ready</dt>
          <dd>{health.world_ready ? "yes" : "no"}</dd>
          <dt>knowledge attached</dt>
          <dd>{health.knowledge_attached ? "yes" : "no"}</dd>
          <dt>live sessions</dt>
          <dd>{health.live_sessions}</dd>
        </dl>
      )}
    </>
  );
}
