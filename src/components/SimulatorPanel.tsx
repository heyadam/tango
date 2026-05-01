'use client';

import { useEffect, useState } from 'react';
import { Smartphone } from 'lucide-react';
import { Spinner } from '@/components/ui/spinner';
import type { SimStatus } from '@/server/sim';

const FAST_POLL_MS = 1000;
const SLOW_POLL_MS = 2500;
const FAST_TICKS = 5;

export default function SimulatorPanel() {
  const [status, setStatus] = useState<SimStatus | null>(null);

  useEffect(() => {
    let cancelled = false;
    let timer: ReturnType<typeof setTimeout> | null = null;
    let ticks = 0;
    const controller = new AbortController();

    const settled = (s: SimStatus) =>
      s.phase === 'ready' || s.phase === 'unsupported' || s.phase === 'error';

    const tick = async () => {
      if (cancelled) return;
      try {
        const res = await fetch('/api/sim/status', {
          cache: 'no-store',
          signal: controller.signal,
        });
        if (cancelled) return;
        const data: SimStatus = await res.json();
        if (cancelled) return;
        setStatus(data);
        if (settled(data)) return;
      } catch (err) {
        if (cancelled || (err as Error).name === 'AbortError') return;
        // network error — keep polling at the slow rate
      }
      ticks += 1;
      const delay = ticks < FAST_TICKS ? FAST_POLL_MS : SLOW_POLL_MS;
      timer = setTimeout(tick, delay);
    };

    tick();

    return () => {
      cancelled = true;
      controller.abort();
      if (timer) clearTimeout(timer);
    };
  }, []);

  return (
    <div className="flex h-full w-full flex-col bg-background">
      <div className="flex h-12 shrink-0 items-center gap-1.5 border-b border-border px-3 text-xs font-medium text-foreground">
        <Smartphone className="size-3.5 text-muted-foreground" />
        <span>Simulator</span>
      </div>
      <div className="relative min-h-0 flex-1">
        <SimulatorBody status={status} />
      </div>
    </div>
  );
}

function SimulatorBody({ status }: { status: SimStatus | null }) {
  if (status == null) {
    return <Pending label="Connecting…" />;
  }

  if (status.phase === 'unsupported') {
    return (
      <Notice
        title="macOS only"
        body="The simulator stream uses Apple's simctl and Xcode command-line tools. Run tango on macOS to use this panel."
      />
    );
  }

  if (status.phase === 'error') {
    const looksMissing = /not found|ENOENT/i.test(status.message);
    return (
      <Notice
        title={
          looksMissing ? 'serve-sim not available' : 'Simulator stream error'
        }
        body={status.message}
        hint={
          looksMissing
            ? 'Make sure Node.js and Xcode command-line tools are installed (xcode-select --install). serve-sim is fetched on demand by npx.'
            : null
        }
      />
    );
  }

  if (status.phase === 'starting') {
    return <Pending label="Starting simulator stream…" />;
  }

  return (
    <iframe
      src={status.url}
      title="iOS Simulator"
      // serve-sim is a localhost-only helper, but treat it as untrusted: it's
      // an npx-fetched package whose UI we render in our own origin's iframe.
      // allow-scripts + allow-same-origin keep it functional; dropping
      // allow-top-navigation/allow-popups limits the blast radius if compromised.
      sandbox="allow-scripts allow-same-origin allow-forms"
      allow="clipboard-read; clipboard-write"
      className="h-full w-full border-0 bg-background"
    />
  );
}

function Pending({ label }: { label: string }) {
  return (
    <div
      role="status"
      aria-live="polite"
      className="flex h-full w-full flex-col items-center justify-center gap-2 text-xs text-muted-foreground"
    >
      <Spinner className="size-4" />
      <span>{label}</span>
    </div>
  );
}

function Notice({
  title,
  body,
  hint,
}: {
  title: string;
  body: string;
  hint?: string | null;
}) {
  return (
    <div
      role="status"
      aria-live="polite"
      className="flex h-full w-full flex-col items-center justify-center gap-2 px-6 text-center text-xs text-muted-foreground"
    >
      <div className="text-sm font-medium text-foreground">{title}</div>
      <div className="whitespace-pre-line break-all font-mono text-[11px] text-muted-foreground/80">
        {body}
      </div>
      {hint ? (
        <div className="text-muted-foreground/60">{hint}</div>
      ) : null}
    </div>
  );
}
