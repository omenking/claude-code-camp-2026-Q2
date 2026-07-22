# Mud Monitor

Unified observability app: Rails 8 API (SQLite) + Vite/React/TS frontend.
Spec: `docs/plans/week_2/mud_monitor.md`.

Status: through **Phase 5** (§9 of the spec). Session API + React transcript
(ported from `week1_baseline/log_viz`), ms timestamps + timing gutter, SSE live
tailing, `ManagerLog` (`/manager`, every command mud_manager actually executed
against the MUD), and `TelnetLog` (`/telnet`, every byte that crossed the
socket in both directions, independent of what the manager or agent layer
kept). Both logs are off by default (`MUD_MANAGER_LOG_DIR` /
`MUD_TELNET_LOG_DIR` unset). No dropped/reshaped diffs, correlation ids, or
world pages yet — those land in later phases.

## Run

```
bin/setup   # bundle install + npm ci + db:prepare
bin/dev     # api on :3000, web on :5173 (proxies /api -> :3000)
```

Open http://localhost:5173.

## Layout

- `api/` — Rails API-only app (`app/controllers/api/v1`, `config/database.yml`)
- `web/` — Vite + React + TS app (mirrors `week0_explore/preview/web`'s stack)
- `Procfile.dev` — the two dev processes, run via `bin/dev` (foreman)
