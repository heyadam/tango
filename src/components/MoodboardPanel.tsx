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
type MoodboardMode = 'complete' | 'logo' | 'ui-elements' | 'random';

const modeLabels: Record<MoodboardMode, string> = {
  complete: 'Full moodboard',
  logo: 'App logo',
  'ui-elements': 'UI elements',
  random: 'Random',
};

const modePlaceholders: Record<MoodboardMode, string> = {
  complete: 'Describe the brand, product, audience, vibe, constraints…',
  logo: 'Describe the app and the feel of the logo…',
  'ui-elements': 'Describe the product and which UI elements to explore…',
  random: 'Describe the rough territory you want inspiration from…',
};

// Only title + imagePrompt are universally present. The rest are mode-dependent
// — full moodboards include all of them; logo / random typically include none.
type MoodboardDirection = {
  id: string;
  title: string;
  rationale?: string;
  palette?: string[];
  brandNotes?: string;
  uiNotes?: string;
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
  mode: MoodboardMode;
  selectedId: string | null;
  directions: MoodboardDirection[];
};

const STORAGE_KEY = 'tango:moodboard-session:v1';

const defaultSession: Session = {
  size: '1536x1024',
  quality: 'medium',
  mode: 'complete',
  selectedId: null,
  directions: [],
};

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

function paletteSwatches(palette: string[] | undefined): string[] {
  if (!palette) return [];
  return palette
    .map((item) => item.match(/#[0-9a-f]{6}\b/i)?.[0])
    .filter((hex): hex is string => Boolean(hex))
    .slice(0, 6);
}

function handoffPrompt(
  relPath: string,
  direction: MoodboardDirection,
): string {
  const sections: string[] = [
    `Use this design as the source of truth for the next branding/UI pass.`,
    ``,
    `Image: ${relPath}`,
    ``,
    `Direction:`,
    direction.title,
  ];
  if (direction.rationale) {
    sections.push('', 'Rationale:', direction.rationale);
  }
  if (direction.palette && direction.palette.length > 0) {
    sections.push(
      '',
      'Palette:',
      direction.palette.map((item) => `- ${item}`).join('\n'),
    );
  }
  if (direction.brandNotes) {
    sections.push('', 'Brand notes:', direction.brandNotes);
  }
  if (direction.uiNotes) {
    sections.push('', 'UI notes:', direction.uiNotes);
  }
  sections.push(
    '',
    'Generation prompt:',
    direction.imagePrompt,
    '',
    'Please inspect the image file, then turn this into concrete branding and UI recommendations.',
  );
  return sections.join('\n');
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
            mode: session.mode,
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
    [busy, session.mode, session.quality, session.size],
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
    <div className="flex h-full min-h-0 bg-background text-foreground">
      <aside className="flex w-20 shrink-0 flex-col items-center gap-2 border-r border-border bg-background py-3">
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
                        ? 'border-foreground'
                        : 'border-border hover:border-foreground/40',
                    )}
                  >
                    <div className="aspect-square w-full bg-card">
                      <img
                        src={imageSrc(direction)}
                        alt={direction.title}
                        className={cn(
                          'h-full w-full object-cover',
                          active ? '' : 'opacity-70 group-hover:opacity-100',
                        )}
                      />
                    </div>
                    <div className="absolute left-1 top-1 rounded bg-background/80 px-1 font-mono text-[9px] text-foreground">
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
        <header className="flex h-12 shrink-0 items-center justify-between gap-3 border-b border-border bg-background px-4">
          <div className="flex min-w-0 items-center gap-3">
            <h1 className="text-sm font-semibold text-foreground">Moodboard</h1>
            {selected && (
              <>
                <span className="text-muted-foreground/60">·</span>
                <span className="truncate text-sm text-foreground/90">
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
          <div className="grid shrink-0 grid-cols-[auto_auto] items-end gap-3 border-b border-border bg-background/80 px-4 py-3">
            <label className="space-y-1">
              <span className="text-[11px] font-medium uppercase text-muted-foreground">
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
                <SelectTrigger className="h-9 w-36">
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
              <span className="text-[11px] font-medium uppercase text-muted-foreground">
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
                <SelectTrigger className="h-9 w-28">
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

        <div className="relative flex min-h-0 flex-1 flex-col items-center justify-center bg-background p-6">
          {selected ? (
            <div className="flex h-full w-full flex-col items-center justify-center gap-3">
              <div className="relative flex min-h-0 w-full flex-1 items-center justify-center">
                <img
                  src={imageSrc(selected)}
                  alt={selected.title}
                  className="max-h-full max-w-full rounded-md object-contain shadow-xl"
                />
                {busy && (
                  <div className="pointer-events-none absolute right-3 top-3 flex items-center gap-2 rounded-md bg-card/90 px-3 py-1.5 text-xs text-foreground shadow">
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
                        className="size-4 rounded-full border border-foreground/15"
                        style={{ backgroundColor: hex }}
                      />
                    ))}
                  </div>
                ) : (
                  <span className="text-xs text-muted-foreground/60">No palette</span>
                )}

                <Button
                  variant="ghost"
                  size="sm"
                  onClick={() => setDetailsOpen((v) => !v)}
                  aria-pressed={detailsOpen}
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
                <div className="grid w-full max-w-3xl shrink-0 gap-3 rounded-md border border-border bg-card/60 p-3 text-xs text-foreground/90 sm:grid-cols-2">
                  {selected.rationale && (
                    <div className="space-y-1">
                      <div className="text-[10px] font-medium uppercase text-muted-foreground">
                        Rationale
                      </div>
                      <p className="leading-5 text-foreground/90">
                        {selected.rationale}
                      </p>
                    </div>
                  )}
                  {selected.palette && selected.palette.length > 0 && (
                    <div className="space-y-1">
                      <div className="text-[10px] font-medium uppercase text-muted-foreground">
                        Palette
                      </div>
                      <p className="font-mono text-[11px] leading-5 text-foreground/90">
                        {selected.palette.join(', ')}
                      </p>
                    </div>
                  )}
                  {selected.brandNotes && (
                    <div className="space-y-1">
                      <div className="text-[10px] font-medium uppercase text-muted-foreground">
                        Brand notes
                      </div>
                      <p className="leading-5 text-foreground/90">
                        {selected.brandNotes}
                      </p>
                    </div>
                  )}
                  {selected.uiNotes && (
                    <div className="space-y-1">
                      <div className="text-[10px] font-medium uppercase text-muted-foreground">
                        UI notes
                      </div>
                      <p className="leading-5 text-foreground/90">
                        {selected.uiNotes}
                      </p>
                    </div>
                  )}
                  <div className="sm:col-span-2 space-y-1">
                    <div className="text-[10px] font-medium uppercase text-muted-foreground">
                      Image prompt
                    </div>
                    <p className="font-mono text-[11px] leading-5 text-muted-foreground">
                      {selected.imagePrompt || '—'}
                    </p>
                  </div>
                </div>
              )}
            </div>
          ) : (
            <div className="flex max-w-md flex-col items-center text-center">
              <div className="mb-4 flex size-12 items-center justify-center rounded-md border border-border bg-card">
                <ImagePlus className="size-6 text-muted-foreground" />
              </div>
              <h2 className="text-base font-semibold text-foreground">
                Describe a creative direction to start
              </h2>
              <p className="mt-2 text-sm leading-6 text-muted-foreground">
                Type a brief below. Tango generates one direction at a time and
                keeps every result in the rail on the left so you can flip back
                later.
              </p>
              <Button
                variant="ghost"
                size="sm"
                onClick={seedDummy}
                disabled={busy}
                className="mt-4"
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

        <div className="shrink-0 border-t border-border bg-background px-4 py-3">
          <div className="flex items-center gap-2 rounded-xl border border-border bg-card p-1.5">
            <Select
              value={session.mode}
              onValueChange={(value) =>
                setSession((current) => ({
                  ...current,
                  mode: value as MoodboardMode,
                }))
              }
            >
              <SelectTrigger
                aria-label="Generation mode"
                className="h-9 w-44 shrink-0"
              >
                <SelectValue />
              </SelectTrigger>
              <SelectContent>
                {(Object.keys(modeLabels) as MoodboardMode[]).map((mode) => (
                  <SelectItem key={mode} value={mode}>
                    {modeLabels[mode]}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
            <Textarea
              ref={inputRef}
              value={draft}
              onChange={(event) => setDraft(event.target.value)}
              onKeyDown={handleKeyDown}
              placeholder={
                hasDirections
                  ? 'Describe another direction…'
                  : modePlaceholders[session.mode]
              }
              className="min-h-9 flex-1 resize-none border-0 bg-transparent px-2 py-2 text-sm leading-5 shadow-none focus-visible:ring-0"
              rows={1}
            />
            <Button
              size="icon"
              onClick={submit}
              disabled={busy || !draft.trim()}
              aria-label="Generate"
              className="shrink-0"
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
                <span className="text-pink-700">{error}</span>
              ) : (
                <span className="text-muted-foreground">{status}</span>
              )}
            </div>
          )}
        </div>
      </div>
    </div>
  );
}
