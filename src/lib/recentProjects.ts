// Browser-side recent-projects list for the workspace picker. Server-side
// state.json holds only the *currently active* path; recents are a UX
// convenience and so they live in localStorage.

const KEY = 'tango.workspace.recent';
const MAX = 8;

export type RecentProject = {
  path: string;
  // The basename at time of selection. Cached here so the picker can render
  // without a network round-trip; if a user moves a folder the basename
  // becomes stale until they re-select.
  name: string;
};

function read(): RecentProject[] {
  if (typeof window === 'undefined') return [];
  try {
    const raw = window.localStorage.getItem(KEY);
    if (!raw) return [];
    const parsed = JSON.parse(raw);
    if (!Array.isArray(parsed)) return [];
    return parsed
      .filter(
        (item): item is RecentProject =>
          !!item && typeof item.path === 'string' && typeof item.name === 'string',
      )
      .slice(0, MAX);
  } catch {
    return [];
  }
}

function write(items: RecentProject[]): void {
  if (typeof window === 'undefined') return;
  try {
    window.localStorage.setItem(KEY, JSON.stringify(items.slice(0, MAX)));
  } catch {
    // quota / private browsing — best-effort
  }
}

export const recentProjects = {
  list(): RecentProject[] {
    return read();
  },
  add(item: RecentProject): RecentProject[] {
    const existing = read().filter((r) => r.path !== item.path);
    const next = [item, ...existing].slice(0, MAX);
    write(next);
    return next;
  },
  remove(path: string): RecentProject[] {
    const next = read().filter((r) => r.path !== path);
    write(next);
    return next;
  },
};
