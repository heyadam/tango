'use client';

import { useCallback, useEffect, useMemo, useState } from 'react';
import {
  Check,
  ImagePlus,
  RefreshCw,
  Send,
  Sparkles,
  WandSparkles,
} from 'lucide-react';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from '@/components/ui/select';
import { Textarea } from '@/components/ui/textarea';
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
};

type Session = {
  brief: string;
  count: number;
  size: MoodboardSize;
  quality: MoodboardQuality;
  winnerId: string | null;
  directions: MoodboardDirection[];
};

const STORAGE_KEY = 'tango:moodboard-session:v1';

const defaultSession: Session = {
  brief: '',
  count: 3,
  size: '1536x1024',
  quality: 'medium',
  winnerId: null,
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
    typeof item.mediaType === 'string'
  );
}

function loadSession(): Session {
  if (typeof window === 'undefined') return defaultSession;
  try {
    const parsed = JSON.parse(window.localStorage.getItem(STORAGE_KEY) ?? '');
    if (!parsed || typeof parsed !== 'object') return defaultSession;
    const raw = parsed as Partial<Session>;
    return {
      brief: typeof raw.brief === 'string' ? raw.brief : '',
      count:
        raw.count === 1 ||
        raw.count === 2 ||
        raw.count === 3 ||
        raw.count === 4
          ? raw.count
          : 3,
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
      winnerId: typeof raw.winnerId === 'string' ? raw.winnerId : null,
      directions: Array.isArray(raw.directions)
        ? raw.directions.filter(isDirection)
        : [],
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

function paletteText(direction: MoodboardDirection): string {
  return direction.palette.join('\n');
}

function paletteSwatches(palette: string[]): string[] {
  return palette
    .map((item) => item.match(/#[0-9a-f]{6}\b/i)?.[0])
    .filter((hex): hex is string => Boolean(hex))
    .slice(0, 6);
}

function handoffPrompt(
  brief: string,
  relPath: string,
  direction: MoodboardDirection,
): string {
  return `Use this winning moodboard direction as the source of truth for the next branding/UI pass.

Image: ${relPath}

Original brief:
${brief || '(No original brief was provided.)'}

Winning direction:
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
  const [busy, setBusy] = useState<'all' | string | null>(null);
  const [handoffBusy, setHandoffBusy] = useState(false);
  const [status, setStatus] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    setSession(loadSession());
    setLoaded(true);
  }, []);

  useEffect(() => {
    if (!loaded) return;
    window.localStorage.setItem(STORAGE_KEY, JSON.stringify(session));
  }, [loaded, session]);

  const winner = useMemo(
    () =>
      session.directions.find((direction) => direction.id === session.winnerId) ??
      null,
    [session.directions, session.winnerId],
  );

  const updateDirection = useCallback(
    (id: string, patch: Partial<MoodboardDirection>) => {
      setSession((current) => ({
        ...current,
        directions: current.directions.map((direction) =>
          direction.id === id ? { ...direction, ...patch } : direction,
        ),
      }));
    },
    [],
  );

  const requestDirections = useCallback(
    async (brief: string, count: number) => {
      const res = await fetch('/api/moodboard/directions', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          brief,
          count,
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
      if (!body.directions) {
        throw new Error('Generation response did not include directions.');
      }
      return body.directions;
    },
    [session.quality, session.size],
  );

  const generateAll = useCallback(async () => {
    const brief = session.brief.trim();
    if (!brief || busy) return;
    setBusy('all');
    setError(null);
    setStatus(null);
    try {
      const directions = await requestDirections(brief, session.count);
      setSession((current) => ({
        ...current,
        directions,
        winnerId: directions[0]?.id ?? null,
      }));
      setStatus(`Generated ${directions.length} directions.`);
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err));
    } finally {
      setBusy(null);
    }
  }, [busy, requestDirections, session.brief, session.count]);

  const regenerateOne = useCallback(
    async (direction: MoodboardDirection) => {
      if (busy) return;
      setBusy(direction.id);
      setError(null);
      setStatus(null);
      const brief = [
        session.brief,
        `Regenerate only this direction as a stronger visual concept: ${direction.title}.`,
        `Rationale: ${direction.rationale}`,
        `Palette: ${direction.palette.join(', ')}`,
        `Brand notes: ${direction.brandNotes}`,
        `UI notes: ${direction.uiNotes}`,
        `Preferred image prompt: ${direction.imagePrompt}`,
      ].join('\n\n');
      try {
        const [next] = await requestDirections(brief, 1);
        if (!next) throw new Error('No replacement direction returned.');
        updateDirection(direction.id, { ...next, id: direction.id });
        setStatus(`Regenerated ${direction.title}.`);
      } catch (err) {
        setError(err instanceof Error ? err.message : String(err));
      } finally {
        setBusy(null);
      }
    },
    [busy, requestDirections, session.brief, updateDirection],
  );

  const sendWinner = useCallback(async () => {
    if (!winner || handoffBusy) return;
    setHandoffBusy(true);
    setError(null);
    setStatus(null);
    try {
      const blob = base64ToBlob(winner.base64, winner.mediaType);
      const { relPath } = await writeSnapshot(blob);
      terminalBus.submitToTerminal(handoffPrompt(session.brief, relPath, winner));
      setStatus(`Sent ${winner.title} to Claude.`);
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err));
    } finally {
      setHandoffBusy(false);
    }
  }, [handoffBusy, session.brief, winner]);

  return (
    <div className="flex h-full min-h-0 flex-col bg-neutral-900 text-neutral-100">
      <div className="shrink-0 border-b border-neutral-800 bg-neutral-950/70 px-4 py-3">
        <div className="flex flex-col gap-3 lg:flex-row lg:items-end">
          <label className="min-w-0 flex-1">
            <span className="mb-1.5 flex items-center gap-1.5 text-xs font-medium text-neutral-300">
              <WandSparkles className="size-3.5 text-emerald-300" />
              Creative brief
            </span>
            <Textarea
              value={session.brief}
              onChange={(event) =>
                setSession((current) => ({
                  ...current,
                  brief: event.target.value,
                }))
              }
              placeholder="Brand, product, audience, vibe, constraints, competitors..."
              className="min-h-20 resize-none border-neutral-700 bg-neutral-900 text-sm text-neutral-100 placeholder:text-neutral-500 focus-visible:ring-emerald-500/30"
            />
          </label>

          <div className="grid shrink-0 grid-cols-3 gap-2 lg:w-[380px]">
            <label className="space-y-1.5">
              <span className="text-xs font-medium text-neutral-400">Count</span>
              <Select
                value={String(session.count)}
                onValueChange={(value) =>
                  setSession((current) => ({
                    ...current,
                    count: Number(value),
                  }))
                }
              >
                <SelectTrigger className="h-9 w-full border-neutral-700 bg-neutral-900 text-neutral-100">
                  <SelectValue />
                </SelectTrigger>
                <SelectContent>
                  {[1, 2, 3, 4].map((count) => (
                    <SelectItem key={count} value={String(count)}>
                      {count}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
            </label>
            <label className="space-y-1.5">
              <span className="text-xs font-medium text-neutral-400">Quality</span>
              <Select
                value={session.quality}
                onValueChange={(value) =>
                  setSession((current) => ({
                    ...current,
                    quality: value as MoodboardQuality,
                  }))
                }
              >
                <SelectTrigger className="h-9 w-full border-neutral-700 bg-neutral-900 text-neutral-100">
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
            <Button
              onClick={generateAll}
              disabled={!session.brief.trim() || Boolean(busy)}
              className="mt-6 h-9 bg-emerald-300 text-neutral-950 hover:bg-emerald-200"
            >
              {busy === 'all' ? (
                <RefreshCw className="size-4 animate-spin" />
              ) : (
                <Sparkles className="size-4" />
              )}
              Generate
            </Button>
          </div>
        </div>

        {(status || error) && (
          <div className="mt-2 font-mono text-[11px]">
            {error ? (
              <span className="text-red-300">{error}</span>
            ) : (
              <span className="text-emerald-300">{status}</span>
            )}
          </div>
        )}
      </div>

      <div className="min-h-0 flex-1 overflow-auto p-4">
        {session.directions.length === 0 ? (
          <div className="flex h-full min-h-[360px] items-center justify-center">
            <div className="max-w-md text-center">
              <div className="mx-auto mb-4 flex size-12 items-center justify-center rounded-md border border-neutral-700 bg-neutral-950">
                <ImagePlus className="size-6 text-neutral-400" />
              </div>
              <h2 className="text-base font-semibold text-neutral-100">
                Generate divergent creative directions
              </h2>
              <p className="mt-2 text-sm leading-6 text-neutral-400">
                Use Moodboard mode to explore competing brand and UI territories,
                then pick the strongest one and hand it to Claude Code.
              </p>
            </div>
          </div>
        ) : (
          <div className="grid gap-4 xl:grid-cols-2 2xl:grid-cols-3">
            {session.directions.map((direction, index) => {
              const selected = direction.id === session.winnerId;
              const swatches = paletteSwatches(direction.palette);
              return (
                <article
                  key={direction.id}
                  className={cn(
                    'overflow-hidden rounded-md border bg-neutral-950 shadow-sm',
                    selected ? 'border-emerald-300/70' : 'border-neutral-800',
                  )}
                >
                  <div className="relative aspect-[3/2] bg-neutral-900">
                    <img
                      src={imageSrc(direction)}
                      alt={direction.title}
                      className="h-full w-full object-cover"
                    />
                    <div className="absolute left-2 top-2 rounded bg-neutral-950/85 px-2 py-1 font-mono text-[10px] text-neutral-300">
                      Direction {index + 1}
                    </div>
                    {selected && (
                      <div className="absolute right-2 top-2 flex items-center gap-1 rounded bg-emerald-300 px-2 py-1 text-[11px] font-medium text-neutral-950">
                        <Check className="size-3" />
                        Winner
                      </div>
                    )}
                  </div>

                  <div className="space-y-3 p-3">
                    <Input
                      value={direction.title}
                      onChange={(event) =>
                        updateDirection(direction.id, {
                          title: event.target.value,
                        })
                      }
                      className="h-9 border-neutral-700 bg-neutral-900 text-sm font-semibold text-neutral-100"
                    />

                    {swatches.length > 0 && (
                      <div className="flex gap-1.5">
                        {swatches.map((hex) => (
                          <span
                            key={hex}
                            title={hex}
                            className="h-5 flex-1 rounded border border-white/15"
                            style={{ backgroundColor: hex }}
                          />
                        ))}
                      </div>
                    )}

                    <label className="block space-y-1">
                      <span className="text-[11px] font-medium uppercase text-neutral-500">
                        Rationale
                      </span>
                      <Textarea
                        value={direction.rationale}
                        onChange={(event) =>
                          updateDirection(direction.id, {
                            rationale: event.target.value,
                          })
                        }
                        className="min-h-24 resize-none border-neutral-700 bg-neutral-900 text-xs text-neutral-200"
                      />
                    </label>

                    <label className="block space-y-1">
                      <span className="text-[11px] font-medium uppercase text-neutral-500">
                        Palette
                      </span>
                      <Textarea
                        value={paletteText(direction)}
                        onChange={(event) =>
                          updateDirection(direction.id, {
                            palette: event.target.value
                              .split('\n')
                              .map((item) => item.trim())
                              .filter(Boolean),
                          })
                        }
                        className="min-h-20 resize-none border-neutral-700 bg-neutral-900 font-mono text-xs text-neutral-200"
                      />
                    </label>

                    <div className="grid gap-3 md:grid-cols-2">
                      <label className="block space-y-1">
                        <span className="text-[11px] font-medium uppercase text-neutral-500">
                          Brand notes
                        </span>
                        <Textarea
                          value={direction.brandNotes}
                          onChange={(event) =>
                            updateDirection(direction.id, {
                              brandNotes: event.target.value,
                            })
                          }
                          className="min-h-28 resize-none border-neutral-700 bg-neutral-900 text-xs text-neutral-200"
                        />
                      </label>
                      <label className="block space-y-1">
                        <span className="text-[11px] font-medium uppercase text-neutral-500">
                          UI notes
                        </span>
                        <Textarea
                          value={direction.uiNotes}
                          onChange={(event) =>
                            updateDirection(direction.id, {
                              uiNotes: event.target.value,
                            })
                          }
                          className="min-h-28 resize-none border-neutral-700 bg-neutral-900 text-xs text-neutral-200"
                        />
                      </label>
                    </div>

                    <label className="block space-y-1">
                      <span className="text-[11px] font-medium uppercase text-neutral-500">
                        Image prompt
                      </span>
                      <Textarea
                        value={direction.imagePrompt}
                        onChange={(event) =>
                          updateDirection(direction.id, {
                            imagePrompt: event.target.value,
                          })
                        }
                        className="min-h-24 resize-none border-neutral-700 bg-neutral-900 font-mono text-[11px] text-neutral-300"
                      />
                    </label>

                    <div className="flex flex-wrap gap-2">
                      <Button
                        variant={selected ? 'default' : 'outline'}
                        size="sm"
                        onClick={() =>
                          setSession((current) => ({
                            ...current,
                            winnerId: direction.id,
                          }))
                        }
                        className={cn(
                          selected &&
                            'bg-emerald-300 text-neutral-950 hover:bg-emerald-200',
                        )}
                      >
                        <Check className="size-4" />
                        Pick winner
                      </Button>
                      <Button
                        variant="outline"
                        size="sm"
                        onClick={() => regenerateOne(direction)}
                        disabled={Boolean(busy)}
                        className="border-neutral-700 bg-neutral-900 text-neutral-200 hover:bg-neutral-800 hover:text-neutral-100"
                      >
                        {busy === direction.id ? (
                          <RefreshCw className="size-4 animate-spin" />
                        ) : (
                          <RefreshCw className="size-4" />
                        )}
                        Regenerate
                      </Button>
                    </div>
                  </div>
                </article>
              );
            })}
          </div>
        )}
      </div>

      <div className="flex shrink-0 items-center justify-between gap-3 border-t border-neutral-800 bg-neutral-950 px-4 py-3">
        <div className="min-w-0 text-xs text-neutral-400">
          {winner ? (
            <span className="truncate">Winner: {winner.title}</span>
          ) : (
            <span>Pick a winner to hand off a direction.</span>
          )}
        </div>
        <Button
          onClick={sendWinner}
          disabled={!winner || handoffBusy}
          className="h-9 bg-sky-300 text-neutral-950 hover:bg-sky-200"
        >
          {handoffBusy ? (
            <RefreshCw className="size-4 animate-spin" />
          ) : (
            <Send className="size-4" />
          )}
          Send winner to Claude
        </Button>
      </div>
    </div>
  );
}
