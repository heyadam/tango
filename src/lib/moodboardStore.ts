// Module-level store for the moodboard panel. Owns the session (size /
// quality / mode / directions / selectedId), the in-flight generation
// lifecycle (busy / status / error), and the localStorage mirror.
//
// Lives outside the React tree so a generation kicked off in moodboard mode
// keeps running when the user switches to sketch / ui mode (which unmounts
// MoodboardPanel) — the fetch resolves into the store, persists, and is
// visible the next time the panel mounts. Sibling of sketchStore /
// uiMockStore in spirit; richer because it owns an action, not just a cache.

export type MoodboardSize = '1024x1024' | '1536x1024' | '1024x1536';
export type MoodboardQuality = 'low' | 'medium' | 'high' | 'auto';
export type MoodboardMode = 'complete' | 'logo' | 'ui-elements' | 'random';

export type MoodboardDirection = {
  id: string;
  title: string;
  rationale?: string;
  palette?: string[];
  brandNotes?: string;
  uiNotes?: string;
  imagePrompt: string;
  base64: string;
  mediaType: string;
  relPath?: string;
  // Placeholder rows live in the directions array while a generation is in
  // flight so the rail thumbnail + main viewport can render a shimmer in the
  // exact slot the resolved image will occupy. Stripped before persistence.
  pending?: boolean;
};

export type MoodboardSession = {
  size: MoodboardSize;
  quality: MoodboardQuality;
  mode: MoodboardMode;
  selectedId: string | null;
  directions: MoodboardDirection[];
};

export type MoodboardState = {
  loaded: boolean;
  session: MoodboardSession;
  busy: boolean;
  status: string | null;
  error: string | null;
};

const STORAGE_KEY = 'tango:moodboard-session:v1';

const defaultSession: MoodboardSession = {
  size: '1536x1024',
  quality: 'medium',
  mode: 'complete',
  selectedId: null,
  directions: [],
};

const defaultState: MoodboardState = {
  loaded: false,
  session: defaultSession,
  busy: false,
  status: null,
  error: null,
};

let state: MoodboardState = defaultState;
const listeners = new Set<() => void>();

function emit(): void {
  for (const fn of listeners) fn();
}

function setState(updater: (current: MoodboardState) => MoodboardState): void {
  const next = updater(state);
  if (next === state) return;
  state = next;
  emit();
}

function isMode(value: unknown): value is MoodboardMode {
  return (
    value === 'complete' ||
    value === 'logo' ||
    value === 'ui-elements' ||
    value === 'random'
  );
}

function isDirection(value: unknown): value is MoodboardDirection {
  if (!value || typeof value !== 'object') return false;
  const item = value as Record<string, unknown>;
  return (
    typeof item.id === 'string' &&
    typeof item.title === 'string' &&
    (item.rationale === undefined || typeof item.rationale === 'string') &&
    (item.palette === undefined || Array.isArray(item.palette)) &&
    (item.brandNotes === undefined || typeof item.brandNotes === 'string') &&
    (item.uiNotes === undefined || typeof item.uiNotes === 'string') &&
    typeof item.imagePrompt === 'string' &&
    typeof item.base64 === 'string' &&
    typeof item.mediaType === 'string' &&
    (item.relPath === undefined || typeof item.relPath === 'string')
  );
}

function loadSession(): MoodboardSession {
  if (typeof window === 'undefined') return defaultSession;
  try {
    const parsed = JSON.parse(window.localStorage.getItem(STORAGE_KEY) ?? '');
    if (!parsed || typeof parsed !== 'object') return defaultSession;
    const raw = parsed as Partial<MoodboardSession>;
    const directions = Array.isArray(raw.directions)
      ? raw.directions.filter(isDirection)
      : [];
    return {
      size:
        raw.size === '1024x1024' ||
        raw.size === '1536x1024' ||
        raw.size === '1024x1536'
          ? raw.size
          : '1536x1024',
      quality:
        raw.quality === 'low' ||
        raw.quality === 'medium' ||
        raw.quality === 'high' ||
        raw.quality === 'auto'
          ? raw.quality
          : 'medium',
      mode: isMode(raw.mode) ? raw.mode : 'complete',
      selectedId:
        typeof raw.selectedId === 'string'
          ? raw.selectedId
          : (directions[directions.length - 1]?.id ?? null),
      directions,
    };
  } catch {
    return defaultSession;
  }
}

function persistSession(session: MoodboardSession): void {
  if (typeof window === 'undefined') return;
  try {
    // Pending placeholders are an in-memory artifact of an in-flight fetch —
    // never persist them, so a refresh mid-generation doesn't leave a dead
    // shimmer hanging around forever.
    const directions = session.directions.filter((d) => !d.pending);
    const selectedId =
      session.selectedId &&
      directions.some((d) => d.id === session.selectedId)
        ? session.selectedId
        : (directions[directions.length - 1]?.id ?? null);
    const cleaned: MoodboardSession = { ...session, directions, selectedId };
    window.localStorage.setItem(STORAGE_KEY, JSON.stringify(cleaned));
  } catch {
    // quota / private browsing — fall back to in-memory only
  }
}

async function generate(brief: string): Promise<void> {
  const trimmed = brief.trim();
  if (!trimmed || state.busy) return;
  const { size, quality, mode } = state.session;
  const placeholderId = `pending-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;
  const placeholder: MoodboardDirection = {
    id: placeholderId,
    title: 'Generating…',
    imagePrompt: trimmed,
    base64: '',
    mediaType: '',
    pending: true,
  };
  setState((s) => {
    const session: MoodboardSession = {
      ...s.session,
      directions: [...s.session.directions, placeholder],
      selectedId: placeholderId,
    };
    persistSession(session);
    return {
      ...s,
      busy: true,
      error: null,
      status: null,
      session,
    };
  });
  try {
    const res = await fetch('/api/moodboard/directions', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ brief: trimmed, size, quality, mode }),
    });
    const raw = await res.text();
    let body: { directions?: MoodboardDirection[]; error?: string };
    try {
      body = JSON.parse(raw);
    } catch {
      throw new Error(raw || `Generation failed: ${res.status}`);
    }
    if (!res.ok) {
      throw new Error(body.error ?? `Generation failed: ${res.status}`);
    }
    const next = body.directions?.[0];
    if (!next) {
      throw new Error('Generation response did not include a direction.');
    }
    setState((s) => {
      // Swap the placeholder for the resolved direction in place so the rail
      // ordering and selection stay stable.
      const directions = s.session.directions.map((d) =>
        d.id === placeholderId ? next : d,
      );
      const session: MoodboardSession = {
        ...s.session,
        directions,
        selectedId:
          s.session.selectedId === placeholderId
            ? next.id
            : s.session.selectedId,
      };
      persistSession(session);
      return { ...s, session, status: `Added ${next.title}.` };
    });
  } catch (err) {
    setState((s) => {
      const directions = s.session.directions.filter(
        (d) => d.id !== placeholderId,
      );
      const session: MoodboardSession = {
        ...s.session,
        directions,
        selectedId:
          s.session.selectedId === placeholderId
            ? (directions[directions.length - 1]?.id ?? null)
            : s.session.selectedId,
      };
      persistSession(session);
      return {
        ...s,
        session,
        error: err instanceof Error ? err.message : String(err),
      };
    });
  } finally {
    setState((s) => ({ ...s, busy: false }));
  }
}

async function seedDummy(): Promise<void> {
  if (state.busy) return;
  setState((s) => ({ ...s, busy: true, error: null, status: null }));
  try {
    const res = await fetch('/api/moodboard/seed', { method: 'POST' });
    const raw = await res.text();
    let body: { directions?: MoodboardDirection[]; error?: string };
    try {
      body = JSON.parse(raw);
    } catch {
      throw new Error(raw || `Seed failed: ${res.status}`);
    }
    if (!res.ok) {
      throw new Error(body.error ?? `Seed failed: ${res.status}`);
    }
    const directions = body.directions ?? [];
    setState((s) => {
      const session: MoodboardSession = {
        ...s.session,
        directions: [...s.session.directions, ...directions],
        selectedId:
          directions[directions.length - 1]?.id ?? s.session.selectedId,
      };
      persistSession(session);
      return {
        ...s,
        session,
        status: `Seeded ${directions.length} dummy directions.`,
      };
    });
  } catch (err) {
    setState((s) => ({
      ...s,
      error: err instanceof Error ? err.message : String(err),
    }));
  } finally {
    setState((s) => ({ ...s, busy: false }));
  }
}

function updateSession(
  updater: (s: MoodboardSession) => MoodboardSession,
): void {
  setState((s) => {
    const session = updater(s.session);
    if (session === s.session) return s;
    persistSession(session);
    return { ...s, session };
  });
}

export const moodboardStore = {
  ensureLoaded(): void {
    if (state.loaded) return;
    if (typeof window === 'undefined') return;
    state = { ...state, loaded: true, session: loadSession() };
    emit();
  },
  getState(): MoodboardState {
    return state;
  },
  subscribe(cb: () => void): () => void {
    listeners.add(cb);
    return () => {
      listeners.delete(cb);
    };
  },
  updateSession,
  generate,
  seedDummy,
};
