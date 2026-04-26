'use client';

import {
  useCallback,
  useEffect,
  useMemo,
  useRef,
  useState,
  type KeyboardEvent,
} from 'react';
import {
  ArrowUp,
  ChevronDown,
  ChevronUp,
  ImagePlus,
  RefreshCw,
  Send,
  Settings2,
  Sparkles,
} from 'lucide-react';
import { Button } from '@/components/ui/button';
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from '@/components/ui/select';
import { Textarea } from '@/components/ui/textarea';
import {
  Tooltip,
  TooltipContent,
  TooltipTrigger,
} from '@/components/ui/tooltip';
import { writeSnapshot } from '@/lib/designSnapshot';
import { terminalBus } from '@/lib/terminalBus';
import { cn } from '@/lib/utils';

type MoodboardSize = '1024x1024' | '1536x1024' | '1024x1536';
type MoodboardQuality = 'low' | 'medium' | 'high' | 'auto';

type MoodboardDirection = {
  id: string;
  title: string;
  rationale: string;
  palette: string[];
  brandNotes: string;
  uiNotes: string;
  imagePrompt: string;
  base64: string;
  mediaType: string;
  // Set when the server persisted the image into the workspace's
  // design-scratch/moodboard/ folder. Undefined when no workspace was active
  // at generation time.
  relPath?: string;
};

type Session = {
  size: MoodboardSize;
  quality: MoodboardQuality;
  selectedId: string | null;
  directions: MoodboardDirection[];
};

const STORAGE_KEY = 'tango:moodboard-session:v1';

const defaultSession: Session = {
  size: '1536x1024',
  quality: 'medium',
  selectedId: null,
  directions: [],
};

function isDirection(value: unknown): value is MoodboardDirection {
  if (!value || typeof value !== 'object') return false;
  const item = value as Record<string, unknown>;
  return (
    typeof item.id === 'string' &&
    typeof item.title === 'string' &&
    typeof item.rationale === 'string' &&
    Array.isArray(item.palette) &&
    typeof item.brandNotes === 'string' &&
    typeof item.uiNotes === 'string' &&
    typeof item.imagePrompt === 'string' &&
    typeof item.base64 === 'string' &&
    typeof item.mediaType === 'string' &&
    (item.relPath === undefined || typeof item.relPath === 'string')
  );
}

function loadSession(): Session {
  if (typeof window === 'undefined') return defaultSession;
  try {
    const parsed = JSON.parse(window.localStorage.getItem(STORAGE_KEY) ?? '');
    if (!parsed || typeof parsed !== 'object') return defaultSession;
    const raw = parsed as Partial<Session>;
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

function imageSrc(direction: MoodboardDirection): string {
  return `data:${direction.mediaType};base64,${direction.base64}`;
}

function base64ToBlob(base64: string, mediaType: string): Blob {
  const binary = atob(base64);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i += 1) {
    bytes[i] = binary.charCodeAt(i);
  }
  return new Blob([bytes], { type: mediaType });
}

function paletteSwatches(palette: string[]): string[] {
  return palette
    .map((item) => item.match(/#[0-9a-f]{6}\b/i)?.[0])
    .filter((hex): hex is string => Boolean(hex))
    .slice(0, 6);
}

function handoffPrompt(
  relPath: string,
  direction: MoodboardDirection,
): string {
  return `Use this moodboard direction as the source of truth for the next branding/UI pass.

Image: ${relPath}

Direction:
${direction.title}

Rationale:
${direction.rationale}

Palette:
${direction.palette.map((item) => `- ${item}`).join('\n')}

Brand notes:
${direction.brandNotes}

UI notes:
${direction.uiNotes}

Generation prompt:
${direction.imagePrompt}

Please inspect the image file, then turn this direction into concrete branding and UI recommendations.`;
}

export default function MoodboardPanel() {
  const [session, setSession] = useState<Session>(defaultSession);
  const [loaded, setLoaded] = useState(false);
  // Single-flight: the API can only run one generation at a time anyway, and
  // the UI needs to know whether to disable the input/buttons.
  const [busy, setBusy] = useState(false);
  const [handoffBusy, setHandoffBusy] = useState(false);
  const [status, setStatus] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [draft, setDraft] = useState('');
  const [optionsOpen, setOptionsOpen] = useState(false);
  const [detailsOpen, setDetailsOpen] = useState(false);
  const inputRef = useRef<HTMLTextAreaElement | null>(null);

  useEffect(() => {
    setSession(loadSession());
    setLoaded(true);
  }, []);

  useEffect(() => {
    if (!loaded) return;
    window.localStorage.setItem(STORAGE_KEY, JSON.stringify(session));
  }, [loaded, session]);

  const selected = useMemo(() => {
    if (session.directions.length === 0) return null;
    return (
      session.directions.find((d) => d.id === session.selectedId) ??
      session.directions[session.directions.length - 1]
    );
  }, [session.directions, session.selectedId]);

  const generate = useCallback(
    async (brief: string) => {
      const trimmed = brief.trim();
      if (!trimmed || busy) return;
      setBusy(true);
      setError(null);
      setStatus(null);
      try {
        const res = await fetch('/api/moodboard/directions', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({
            brief: trimmed,
            size: session.size,
            quality: session.quality,
          }),
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
        setSession((current) => ({
          ...current,
          directions: [...current.directions, next],
          selectedId: next.id,
        }));
        setStatus(`Added ${next.title}.`);
      } catch (err) {
        setError(err instanceof Error ? err.message : String(err));
      } finally {
        setBusy(false);
      }
    },
    [busy, session.quality, session.size],
  );

  const seedDummy = useCallback(async () => {
    if (busy) return;
    setBusy(true);
    setError(null);
    setStatus(null);
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
      // Append to the bank rather than replacing — seed is just a fast way to
      // bulk-load some history without spending image-gen tokens.
      setSession((current) => ({
        ...current,
        directions: [...current.directions, ...directions],
        selectedId:
          directions[directions.length - 1]?.id ?? current.selectedId,
      }));
      setStatus(`Seeded ${directions.length} dummy directions.`);
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err));
    } finally {
      setBusy(false);
    }
  }, [busy]);

  const sendSelected = useCallback(async () => {
    if (!selected || handoffBusy) return;
    setHandoffBusy(true);
    setError(null);
    setStatus(null);
    try {
      // Prefer the server-persisted file if generation captured one — avoids a
      // duplicate copy in design-scratch/. Fall back to writing a snapshot for
      // older sessions whose directions predate the persist change.
      const relPath = selected.relPath
        ? selected.relPath
        : (
            await writeSnapshot(
              base64ToBlob(selected.base64, selected.mediaType),
            )
          ).relPath;
      terminalBus.submitToTerminal(handoffPrompt(relPath, selected));
      setStatus(`Sent ${selected.title} to Claude.`);
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err));
    } finally {
      setHandoffBusy(false);
    }
  }, [handoffBusy, selected]);

  const submit = useCallback(() => {
    const text = draft.trim();
    if (!text || busy) return;
    void generate(text);
    setDraft('');
  }, [busy, draft, generate]);

  const handleKeyDown = useCallback(
    (event: KeyboardEvent<HTMLTextAreaElement>) => {
      if (event.key === 'Enter' && !event.shiftKey) {
        event.preventDefault();
        submit();
      }
    },
    [submit],
  );

  const swatches = selected ? paletteSwatches(selected.palette) : [];
  const hasDirections = session.directions.length > 0;

  return (
    <div className="flex h-full min-h-0 bg-neutral-950 text-neutral-100">
      <aside className="flex w-20 shrink-0 flex-col items-center gap-2 border-r border-neutral-900 bg-neutral-950 py-3">
        <div className="flex w-full flex-1 flex-col items-center gap-2 overflow-y-auto px-2">
          {session.directions.map((direction, index) => {
            const active = direction.id === session.selectedId;
            return (
              <Tooltip key={direction.id}>
                <TooltipTrigger asChild>
                  <button
                    type="button"
                    onClick={() =>
                      setSession((current) => ({
                        ...current,
                        selectedId: direction.id,
                      }))
                    }
                    aria-label={`Select ${direction.title}`}
                    aria-pressed={active}
                    className={cn(
                      'group relative w-full overflow-hidden rounded-md border transition-colors',
                      active
                        ? 'border-neutral-100'
                        : 'border-neutral-800 hover:border-neutral-600',
                    )}
                  >
                    <div className="aspect-square w-full bg-neutral-900">
                      <img
                        src={imageSrc(direction)}
                        alt={direction.title}
                        className={cn(
                          'h-full w-full object-cover',
                          active ? '' : 'opacity-70 group-hover:opacity-100',
                        )}
                      />
                    </div>
                    <div className="absolute left-1 top-1 rounded bg-neutral-950/80 px-1 font-mono text-[9px] text-neutral-300">
                      {index + 1}
                    </div>
                  </button>
                </TooltipTrigger>
                <TooltipContent side="right">{direction.title}</TooltipContent>
              </Tooltip>
            );
          })}
        </div>
      </aside>

      <div className="relative flex min-w-0 flex-1 flex-col">
        <header className="flex h-12 shrink-0 items-center justify-between gap-3 border-b border-neutral-900 bg-neutral-950 px-4">
          <div className="flex min-w-0 items-center gap-3">
            <h1 className="text-sm font-semibold text-neutral-100">Moodboard</h1>
            {selected && (
              <>
                <span className="text-neutral-700">·</span>
                <span className="truncate text-sm text-neutral-300">
                  {selected.title}
                </span>
              </>
            )}
          </div>
          <div className="flex items-center gap-2">
            <Tooltip>
              <TooltipTrigger asChild>
                <Button
                  variant="ghost"
                  size="icon-sm"
                  onClick={() => setOptionsOpen((v) => !v)}
                  aria-pressed={optionsOpen}
                  aria-label="Options"
                  className="text-neutral-400 hover:text-neutral-100"
                >
                  <Settings2 className="size-4" />
                </Button>
              </TooltipTrigger>
              <TooltipContent side="bottom">Options</TooltipContent>
            </Tooltip>
            <Button
              size="sm"
              onClick={sendSelected}
              disabled={!selected || handoffBusy}
              className="h-8 bg-emerald-300 text-neutral-950 hover:bg-emerald-200 disabled:bg-neutral-800 disabled:text-neutral-500"
            >
              {handoffBusy ? (
                <RefreshCw className="size-3.5 animate-spin" />
              ) : (
                <Send className="size-3.5" />
              )}
              Send to Claude
            </Button>
          </div>
        </header>

        {optionsOpen && (
          <div className="grid shrink-0 grid-cols-[auto_auto] items-end gap-3 border-b border-neutral-900 bg-neutral-950/80 px-4 py-3">
            <label className="space-y-1">
              <span className="text-[11px] font-medium uppercase text-neutral-500">
                Size
              </span>
              <Select
                value={session.size}
                onValueChange={(value) =>
                  setSession((current) => ({
                    ...current,
                    size: value as MoodboardSize,
                  }))
                }
              >
                <SelectTrigger className="h-9 w-36 border-neutral-800 bg-neutral-900 text-neutral-100">
                  <SelectValue />
                </SelectTrigger>
                <SelectContent>
                  <SelectItem value="1536x1024">1536 × 1024</SelectItem>
                  <SelectItem value="1024x1024">1024 × 1024</SelectItem>
                  <SelectItem value="1024x1536">1024 × 1536</SelectItem>
                </SelectContent>
              </Select>
            </label>
            <label className="space-y-1">
              <span className="text-[11px] font-medium uppercase text-neutral-500">
                Quality
              </span>
              <Select
                value={session.quality}
                onValueChange={(value) =>
                  setSession((current) => ({
                    ...current,
                    quality: value as MoodboardQuality,
                  }))
                }
              >
                <SelectTrigger className="h-9 w-28 border-neutral-800 bg-neutral-900 text-neutral-100">
                  <SelectValue />
                </SelectTrigger>
                <SelectContent>
                  {['medium', 'high', 'low', 'auto'].map((quality) => (
                    <SelectItem key={quality} value={quality}>
                      {quality}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
            </label>
          </div>
        )}

        <div className="relative flex min-h-0 flex-1 flex-col items-center justify-center bg-neutral-950 p-6">
          {selected ? (
            <div className="flex h-full w-full flex-col items-center justify-center gap-3">
              <div className="relative flex min-h-0 w-full flex-1 items-center justify-center">
                <img
                  src={imageSrc(selected)}
                  alt={selected.title}
                  className="max-h-full max-w-full rounded-md object-contain shadow-xl"
                />
                {busy && (
                  <div className="pointer-events-none absolute right-3 top-3 flex items-center gap-2 rounded-md bg-neutral-900/90 px-3 py-1.5 text-xs text-neutral-200 shadow">
                    <RefreshCw className="size-3.5 animate-spin" />
                    Generating…
                  </div>
                )}
              </div>

              <div className="flex w-full max-w-3xl items-center justify-between gap-3 px-1">
                {swatches.length > 0 ? (
                  <div className="flex items-center gap-1.5">
                    {swatches.map((hex) => (
                      <span
                        key={hex}
                        title={hex}
                        className="size-4 rounded-full border border-white/15"
                        style={{ backgroundColor: hex }}
                      />
                    ))}
                  </div>
                ) : (
                  <span className="text-xs text-neutral-600">No palette</span>
                )}

                <Button
                  variant="ghost"
                  size="sm"
                  onClick={() => setDetailsOpen((v) => !v)}
                  aria-pressed={detailsOpen}
                  className="h-8 text-neutral-400 hover:text-neutral-100"
                >
                  {detailsOpen ? (
                    <ChevronUp className="size-3.5" />
                  ) : (
                    <ChevronDown className="size-3.5" />
                  )}
                  Details
                </Button>
              </div>

              {detailsOpen && (
                <div className="grid w-full max-w-3xl shrink-0 gap-3 rounded-md border border-neutral-800 bg-neutral-900/60 p-3 text-xs text-neutral-300 sm:grid-cols-2">
                  <div className="space-y-1">
                    <div className="text-[10px] font-medium uppercase text-neutral-500">
                      Rationale
                    </div>
                    <p className="leading-5 text-neutral-300">
                      {selected.rationale || '—'}
                    </p>
                  </div>
                  <div className="space-y-1">
                    <div className="text-[10px] font-medium uppercase text-neutral-500">
                      Palette
                    </div>
                    <p className="font-mono text-[11px] leading-5 text-neutral-300">
                      {selected.palette.join(', ') || '—'}
                    </p>
                  </div>
                  <div className="space-y-1">
                    <div className="text-[10px] font-medium uppercase text-neutral-500">
                      Brand notes
                    </div>
                    <p className="leading-5 text-neutral-300">
                      {selected.brandNotes || '—'}
                    </p>
                  </div>
                  <div className="space-y-1">
                    <div className="text-[10px] font-medium uppercase text-neutral-500">
                      UI notes
                    </div>
                    <p className="leading-5 text-neutral-300">
                      {selected.uiNotes || '—'}
                    </p>
                  </div>
                  <div className="sm:col-span-2 space-y-1">
                    <div className="text-[10px] font-medium uppercase text-neutral-500">
                      Image prompt
                    </div>
                    <p className="font-mono text-[11px] leading-5 text-neutral-400">
                      {selected.imagePrompt || '—'}
                    </p>
                  </div>
                </div>
              )}
            </div>
          ) : (
            <div className="flex max-w-md flex-col items-center text-center">
              <div className="mb-4 flex size-12 items-center justify-center rounded-md border border-neutral-800 bg-neutral-900">
                <ImagePlus className="size-6 text-neutral-500" />
              </div>
              <h2 className="text-base font-semibold text-neutral-100">
                Describe a creative direction to start
              </h2>
              <p className="mt-2 text-sm leading-6 text-neutral-400">
                Type a brief below. Tango generates one direction at a time and
                keeps every result in the rail on the left so you can flip back
                later.
              </p>
              <Button
                variant="ghost"
                size="sm"
                onClick={seedDummy}
                disabled={busy}
                className="mt-4 h-8 text-neutral-400 hover:text-neutral-100"
              >
                {busy ? (
                  <RefreshCw className="size-3.5 animate-spin" />
                ) : (
                  <Sparkles className="size-3.5" />
                )}
                Seed dummy data
              </Button>
            </div>
          )}
        </div>

        <div className="shrink-0 border-t border-neutral-900 bg-neutral-950 px-4 py-3">
          <div className="flex items-end gap-2 rounded-xl border border-neutral-800 bg-neutral-900 p-2">
            <Textarea
              ref={inputRef}
              value={draft}
              onChange={(event) => setDraft(event.target.value)}
              onKeyDown={handleKeyDown}
              placeholder={
                hasDirections
                  ? 'Describe another direction…'
                  : 'Describe the brand, product, audience, vibe, constraints…'
              }
              className="min-h-9 resize-none border-0 bg-transparent px-1 py-1.5 text-sm text-neutral-100 shadow-none focus-visible:ring-0 placeholder:text-neutral-500"
              rows={1}
            />
            <Button
              size="icon-sm"
              onClick={submit}
              disabled={busy || !draft.trim()}
              aria-label="Generate"
              className="shrink-0 bg-neutral-100 text-neutral-950 hover:bg-white disabled:bg-neutral-800 disabled:text-neutral-500"
            >
              {busy ? (
                <RefreshCw className="size-4 animate-spin" />
              ) : hasDirections ? (
                <ArrowUp className="size-4" />
              ) : (
                <Sparkles className="size-4" />
              )}
            </Button>
          </div>

          {(status || error) && (
            <div className="mt-2 px-1 font-mono text-[11px]">
              {error ? (
                <span className="text-red-300">{error}</span>
              ) : (
                <span className="text-neutral-400">{status}</span>
              )}
            </div>
          )}
        </div>
      </div>
    </div>
  );
}
