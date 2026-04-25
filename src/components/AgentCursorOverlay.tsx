'use client';

import { useEffect, useRef, useState } from 'react';
import { terminalBus } from '@/lib/terminalBus';
import type {
  AgentCursorServerMsg,
  InteractiveElement,
} from '@/lib/agentCursorProtocol';
import { openWS } from '@/lib/wsClient';

// Visible "fake mouse" overlay driven by the /ws/agent-cursor channel.
// Server-side MCP tools push commands; this component renders a cursor sprite
// and dispatches the corresponding DOM events at the target element. The
// terminal_type command short-circuits into terminalBus.sendToTerminal so the
// existing PTY pipeline handles it — the overlay is just the messenger.

type Cmd = AgentCursorServerMsg;
type InteractiveInfo = InteractiveElement;

const INTERACTIVE_SELECTOR = [
  'button',
  'a[href]',
  'input',
  'select',
  'textarea',
  'summary',
  '[role="button"]',
  '[role="link"]',
  '[role="checkbox"]',
  '[role="radio"]',
  '[role="tab"]',
  '[role="menuitem"]',
  '[role="combobox"]',
  '[role="textbox"]',
  '[role="switch"]',
  '[role="option"]',
  '[role="slider"]',
  '[tabindex]:not([tabindex="-1"])',
  '[contenteditable=""]',
  '[contenteditable="true"]',
].join(',');

const STABLE_DATA_ATTRS = ['data-testid', 'data-test', 'data-test-id', 'data-cy'];

function isVisible(el: Element): boolean {
  if (!(el instanceof HTMLElement)) return true;
  const rect = el.getBoundingClientRect();
  if (rect.width === 0 || rect.height === 0) return false;
  const style = window.getComputedStyle(el);
  if (style.display === 'none') return false;
  if (style.visibility === 'hidden' || style.visibility === 'collapse') return false;
  if (style.opacity === '0') return false;
  return true;
}

function getRole(el: Element): string {
  const explicit = el.getAttribute('role');
  if (explicit) return explicit;
  const tag = el.tagName.toLowerCase();
  if (tag === 'a' && el.hasAttribute('href')) return 'link';
  if (tag === 'input') {
    const type = (el as HTMLInputElement).type || 'text';
    return `input:${type}`;
  }
  if (tag === 'textarea') return 'textbox';
  if (tag === 'select') return 'combobox';
  return tag;
}

function compactText(text: string | null | undefined, max = 120): string {
  if (!text) return '';
  const collapsed = text.replace(/\s+/g, ' ').trim();
  if (collapsed.length <= max) return collapsed;
  return collapsed.slice(0, max - 1) + '…';
}

function getAccessibleName(el: Element): string {
  const ariaLabel = el.getAttribute('aria-label');
  if (ariaLabel) return compactText(ariaLabel, 80);

  const labelledBy = el.getAttribute('aria-labelledby');
  if (labelledBy) {
    const parts = labelledBy
      .split(/\s+/)
      .map((id) => document.getElementById(id)?.textContent ?? '')
      .filter(Boolean);
    if (parts.length) return compactText(parts.join(' '), 80);
  }

  if (el instanceof HTMLInputElement || el instanceof HTMLTextAreaElement) {
    if (el.id) {
      const label = document.querySelector(`label[for="${CSS.escape(el.id)}"]`);
      if (label?.textContent) return compactText(label.textContent, 80);
    }
    if (el.placeholder) return compactText(el.placeholder, 80);
    if (el.name) return compactText(el.name, 80);
  }

  if (el instanceof HTMLImageElement && el.alt) return compactText(el.alt, 80);

  const text = compactText(el.textContent, 80);
  if (text) return text;

  const title = el.getAttribute('title');
  if (title) return compactText(title, 80);

  return '';
}

function buildSelector(el: Element): string | undefined {
  if (el.id) return `#${CSS.escape(el.id)}`;
  for (const attr of STABLE_DATA_ATTRS) {
    const val = el.getAttribute(attr);
    if (val) return `[${attr}="${val.replace(/"/g, '\\"')}"]`;
  }
  return undefined;
}

function extractInfo(el: Element): InteractiveInfo {
  const rect = el.getBoundingClientRect();
  const cx = rect.left + rect.width / 2;
  const cy = rect.top + rect.height / 2;
  const inViewport =
    rect.bottom > 0 &&
    rect.right > 0 &&
    rect.top < window.innerHeight &&
    rect.left < window.innerWidth;
  const disabled =
    (el as HTMLButtonElement).disabled === true ||
    el.getAttribute('aria-disabled') === 'true';
  return {
    role: getRole(el),
    name: getAccessibleName(el),
    text: compactText(el.textContent, 120),
    rect: {
      x: Math.round(rect.left),
      y: Math.round(rect.top),
      width: Math.round(rect.width),
      height: Math.round(rect.height),
    },
    center: { x: Math.round(cx), y: Math.round(cy) },
    selector: buildSelector(el),
    inViewport,
    disabled,
  };
}

function scoreMatch(info: InteractiveInfo, query: string): number {
  const q = query.toLowerCase();
  const haystack = [info.name, info.text, info.role]
    .filter(Boolean)
    .map((s) => s.toLowerCase());
  let best = 0;
  for (const h of haystack) {
    if (h === q) best = Math.max(best, 100);
    else if (h.startsWith(q)) best = Math.max(best, 60);
    else if (h.includes(q)) best = Math.max(best, 30);
  }
  return best;
}

function inspectDOM(opts: {
  query?: string;
  selector?: string;
  limit?: number;
}): {
  total: number;
  returned: number;
  viewport: { width: number; height: number };
  elements: InteractiveInfo[];
} {
  const root: ParentNode = opts.selector
    ? (document.querySelector(opts.selector) ?? document.body)
    : document.body;

  const candidates = Array.from(root.querySelectorAll(INTERACTIVE_SELECTOR));
  const visible = candidates.filter(isVisible);
  let infos = visible.map(extractInfo);

  if (opts.query) {
    infos = infos
      .map((info) => ({ info, score: scoreMatch(info, opts.query!) }))
      .filter((s) => s.score > 0)
      .sort((a, b) => b.score - a.score)
      .map((s) => s.info);
  } else {
    // Without a query, prefer in-viewport elements at the top.
    infos.sort((a, b) => Number(b.inViewport) - Number(a.inViewport));
  }

  const limit = Math.max(1, Math.min(100, opts.limit ?? 30));
  return {
    total: infos.length,
    returned: Math.min(infos.length, limit),
    viewport: { width: window.innerWidth, height: window.innerHeight },
    elements: infos.slice(0, limit),
  };
}

const DEFAULT_DURATION_MS = 350;

function resolvePoint(
  selector: string | undefined,
  x: number | undefined,
  y: number | undefined,
): { px: number; py: number; el: Element | null } | null {
  if (selector) {
    const el = document.querySelector(selector);
    if (!el) return null;
    const rect = el.getBoundingClientRect();
    return {
      px: rect.left + rect.width / 2,
      py: rect.top + rect.height / 2,
      el,
    };
  }
  if (typeof x === 'number' && typeof y === 'number') {
    const el = document.elementFromPoint(x, y);
    return { px: x, py: y, el };
  }
  return null;
}

function sleep(ms: number): Promise<void> {
  return new Promise((r) => setTimeout(r, ms));
}

export default function AgentCursorOverlay() {
  const cursorRef = useRef<HTMLDivElement | null>(null);
  // Track the agent cursor's logical position so we can chain moves smoothly
  // and so click/type can fall back to "current position" if the caller
  // omitted both selector and coords.
  const posRef = useRef<{ x: number; y: number }>({ x: 80, y: 80 });
  const [connected, setConnected] = useState(false);
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    const ws = openWS('/ws/agent-cursor');

    ws.addEventListener('open', () => setConnected(true));
    ws.addEventListener('close', () => setConnected(false));
    ws.addEventListener('error', () => setConnected(false));

    // Serialize commands so they don't race against each other.
    let queue: Promise<void> = Promise.resolve();

    const moveCursorTo = async (
      px: number,
      py: number,
      durationMs: number,
    ): Promise<void> => {
      const node = cursorRef.current;
      if (!node) {
        posRef.current = { x: px, y: py };
        return;
      }
      node.style.transition = `transform ${durationMs}ms cubic-bezier(0.22, 0.61, 0.36, 1)`;
      node.style.transform = `translate(${px}px, ${py}px)`;
      posRef.current = { x: px, y: py };
      await sleep(durationMs);
    };

    const dispatchClick = (
      el: Element | null,
      px: number,
      py: number,
      button: 'left' | 'right',
    ) => {
      const target = el ?? document.elementFromPoint(px, py);
      if (!target) return;
      const buttonCode = button === 'right' ? 2 : 0;
      const init: MouseEventInit = {
        bubbles: true,
        cancelable: true,
        view: window,
        clientX: px,
        clientY: py,
        button: buttonCode,
      };
      target.dispatchEvent(new MouseEvent('mousedown', init));
      target.dispatchEvent(new MouseEvent('mouseup', init));
      target.dispatchEvent(new MouseEvent('click', init));
    };

    const dispatchType = (el: Element | null, text: string) => {
      const target = (el ?? document.activeElement) as
        | HTMLInputElement
        | HTMLTextAreaElement
        | HTMLElement
        | null;
      if (!target) return;
      if (target instanceof HTMLElement) target.focus();
      // For native form fields, set value + emit input. For everything else
      // (contenteditable, custom widgets), dispatch keyboard events so the
      // app's own handlers run.
      if (
        target instanceof HTMLInputElement ||
        target instanceof HTMLTextAreaElement
      ) {
        const proto =
          target instanceof HTMLInputElement
            ? HTMLInputElement.prototype
            : HTMLTextAreaElement.prototype;
        const setter = Object.getOwnPropertyDescriptor(proto, 'value')?.set;
        const next = (target.value ?? '') + text;
        if (setter) setter.call(target, next);
        else target.value = next;
        target.dispatchEvent(new Event('input', { bubbles: true }));
        target.dispatchEvent(new Event('change', { bubbles: true }));
        return;
      }
      for (const ch of text) {
        target.dispatchEvent(
          new KeyboardEvent('keydown', { key: ch, bubbles: true }),
        );
        target.dispatchEvent(
          new KeyboardEvent('keypress', { key: ch, bubbles: true }),
        );
        target.dispatchEvent(
          new KeyboardEvent('keyup', { key: ch, bubbles: true }),
        );
      }
    };

    const handle = async (cmd: Cmd) => {
      setBusy(true);
      try {
        if (cmd.type === 'inspect') {
          try {
            const result = inspectDOM({
              query: cmd.query,
              selector: cmd.selector,
              limit: cmd.limit,
            });
            ws.send(
              JSON.stringify({
                type: 'inspect_result',
                requestId: cmd.requestId,
                result,
              }),
            );
          } catch (err) {
            ws.send(
              JSON.stringify({
                type: 'inspect_result',
                requestId: cmd.requestId,
                error: err instanceof Error ? err.message : String(err),
              }),
            );
          }
          return;
        }

        if (cmd.type === 'terminal_type') {
          // Default submit:true. Send the text and the Return as separate
          // writes with a short gap — Claude Code's TUI sometimes treats a
          // single fused chunk as a paste and doesn't fire its Enter handler
          // for the trailing \r. Splitting them gives the input loop a tick
          // to process the text before the Enter arrives.
          const submit = cmd.submit !== false;
          terminalBus.sendToTerminal(cmd.text);
          if (submit) {
            await sleep(120);
            terminalBus.sendToTerminal('\r');
          }
          return;
        }

        if (cmd.type === 'move') {
          const point = resolvePoint(cmd.selector, cmd.x, cmd.y);
          if (!point) return;
          await moveCursorTo(point.px, point.py, cmd.durationMs ?? DEFAULT_DURATION_MS);
          return;
        }

        if (cmd.type === 'click') {
          const point = resolvePoint(cmd.selector, cmd.x, cmd.y);
          if (!point) return;
          await moveCursorTo(point.px, point.py, DEFAULT_DURATION_MS);
          // small settle so the user sees the cursor land before the click
          await sleep(80);
          dispatchClick(point.el, point.px, point.py, cmd.button ?? 'left');
          return;
        }

        if (cmd.type === 'type') {
          let target: Element | null = null;
          if (cmd.selector) {
            target = document.querySelector(cmd.selector);
            if (target) {
              const rect = target.getBoundingClientRect();
              await moveCursorTo(
                rect.left + rect.width / 2,
                rect.top + rect.height / 2,
                DEFAULT_DURATION_MS,
              );
            }
          }
          dispatchType(target, cmd.text);
          return;
        }
      } finally {
        setBusy(false);
      }
    };

    ws.addEventListener('message', (ev) => {
      let parsed: Cmd;
      try {
        parsed = JSON.parse(typeof ev.data === 'string' ? ev.data : '') as Cmd;
      } catch {
        return;
      }
      queue = queue.then(() => handle(parsed)).catch(() => undefined);
    });

    return () => {
      try {
        ws.close();
      } catch {
        /* noop */
      }
    };
  }, []);

  return (
    <div
      ref={cursorRef}
      aria-hidden
      data-agent-cursor
      style={{
        position: 'fixed',
        left: 0,
        top: 0,
        width: 18,
        height: 18,
        transform: `translate(${posRef.current.x}px, ${posRef.current.y}px)`,
        pointerEvents: 'none',
        zIndex: 99999,
        opacity: connected ? 1 : 0.35,
        transition: 'transform 350ms cubic-bezier(0.22, 0.61, 0.36, 1)',
      }}
    >
      <svg
        viewBox="0 0 24 24"
        width="18"
        height="18"
        style={{
          filter: busy
            ? 'drop-shadow(0 0 6px rgba(56, 189, 248, 0.85))'
            : 'drop-shadow(0 1px 2px rgba(0,0,0,0.6))',
        }}
      >
        <path
          d="M5 3 L5 19 L9.2 14.8 L11.5 20.5 L13.8 19.6 L11.4 13.9 L17.5 13.9 Z"
          fill={busy ? '#38bdf8' : '#fafafa'}
          stroke="#0a0a0a"
          strokeWidth="1.2"
          strokeLinejoin="round"
        />
      </svg>
    </div>
  );
}
