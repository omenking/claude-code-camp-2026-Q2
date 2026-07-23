import type {
  ApiError,
  DroppedDiff,
  ManagerPage,
  MessagesTimeline,
  SessionDetail,
  SessionSummary,
  TelnetPage,
} from "./types";

class ApiRequestError extends Error {
  constructor(
    public status: number,
    message: string,
  ) {
    super(message);
  }
}

async function get<T>(path: string): Promise<T> {
  const res = await fetch(`/api/v1${path}`);
  if (!res.ok) {
    const body = (await res.json().catch(() => null)) as ApiError | null;
    throw new ApiRequestError(res.status, body?.error?.message ?? `${res.status} ${res.statusText}`);
  }
  return res.json() as Promise<T>;
}

export function fetchSessions(): Promise<{ sessions: SessionSummary[] }> {
  return get("/sessions");
}

export function fetchSession(id: string): Promise<SessionDetail> {
  return get(`/sessions/${encodeURIComponent(id)}`);
}

// The raw message array handed to the model on every call — what the curated
// transcript can't show. On-demand: the sidebar calls this when opened/refreshed.
export function fetchSessionMessages(id: string): Promise<MessagesTimeline> {
  return get(`/sessions/${encodeURIComponent(id)}/messages`);
}

export interface ManagerFilters {
  date?: string;
  session?: string;
  mode?: string;
}

export function fetchManager(filters: ManagerFilters = {}): Promise<ManagerPage> {
  const params = new URLSearchParams();
  if (filters.date) params.set("date", filters.date);
  if (filters.session) params.set("session", filters.session);
  if (filters.mode) params.set("mode", filters.mode);
  const qs = params.toString();
  return get(`/manager${qs ? `?${qs}` : ""}`);
}

export interface TelnetFilters {
  date?: string;
  session?: string;
  dir?: string;
}

export function fetchTelnet(filters: TelnetFilters = {}): Promise<TelnetPage> {
  const params = new URLSearchParams();
  if (filters.date) params.set("date", filters.date);
  if (filters.session) params.set("session", filters.session);
  if (filters.dir) params.set("dir", filters.dir);
  const qs = params.toString();
  return get(`/telnet${qs ? `?${qs}` : ""}`);
}

export interface DroppedFilters {
  date?: string;
  session?: string;
  from?: string;
  to?: string;
}

export function fetchDropped(filters: DroppedFilters = {}): Promise<DroppedDiff> {
  const params = new URLSearchParams();
  if (filters.date) params.set("date", filters.date);
  if (filters.session) params.set("session", filters.session);
  if (filters.from) params.set("from", filters.from);
  if (filters.to) params.set("to", filters.to);
  const qs = params.toString();
  return get(`/diffs/dropped${qs ? `?${qs}` : ""}`);
}

export { ApiRequestError };
