// Central, typed accessors for every TANGO_* environment knob (plus the
// server port). One place to see defaults and document semantics — the
// scattered `process.env.X ?? fallback` reads were drifting apart (three
// files re-derived the port with subtly different fallbacks).
//
// Every accessor reads process.env at CALL time, on purpose: this module is
// loaded by BOTH module graphs (custom server and Next route handlers — see
// the globalThis convention in CLAUDE.md), and call-time reads mean the two
// copies can never disagree through captured state. server.ts writes
// TANGO_PORT / TANGO_REPO_ROOT into process.env at boot precisely so both
// graphs see them.
//
// Electron note: this file is the seam where env-var configuration will be
// swapped for app settings — keep new knobs here, not inline.

import type {
  EffortLevel,
  SettingSource,
  ThinkingConfig,
} from '@anthropic-ai/claude-agent-sdk';

// ── server ──────────────────────────────────────────────────────────────────

/** The HTTP/WS port. TANGO_PORT is stamped by server.ts at boot (so route
 * handlers in the other module graph agree); PORT is the operator override. */
export function tangoPort(): number {
  const raw = Number(process.env.TANGO_PORT ?? process.env.PORT ?? 3000);
  return Number.isFinite(raw) && raw > 0 ? raw : 3000;
}

/** Absolute path of the tango repo itself (NOT the user workspace). Stamped
 * by server.ts at boot; null in contexts that never booted the server. */
export function tangoRepoRoot(): string | null {
  return process.env.TANGO_REPO_ROOT ?? null;
}

/** Pinned workspace path (locks the picker). Unset = picker chooses. */
export function pinnedWorkspace(): string | null {
  const raw = process.env.TANGO_WORKSPACE;
  return raw && raw.trim() !== '' ? raw : null;
}

/** Where user-level state (state.json) lives. Default ~/.tango — overridden
 * in tests; Electron will point this at app.getPath('userData'). */
export function stateDirOverride(): string | null {
  return process.env.TANGO_STATE_DIR ?? null;
}

// ── built-in agent (Claude Agent SDK session) ───────────────────────────────

/** Model for the interactive design-loop agent. Speed matters more than
 * ceiling here — see the benchmark notes in CLAUDE.md. */
export function agentModel(): string {
  return process.env.TANGO_AGENT_MODEL ?? 'claude-sonnet-4-6';
}

/** Effort for the built-in agent. Default low: the design loop wants snap
 * over deliberation — benchmarked 5× faster with an identical tool sequence.
 * TANGO_AGENT_EFFORT=low|medium|high|max overrides. */
export function agentEffort(): EffortLevel {
  const raw = process.env.TANGO_AGENT_EFFORT;
  if (raw === 'low' || raw === 'medium' || raw === 'high' || raw === 'max') {
    return raw;
  }
  return 'low';
}

/** Extended thinking for the built-in agent, as an Options spread. Disabled
 * by default — thinking tokens stream at a crawl on subscription logins
 * (~12–30 tok/s measured) and cost minutes before the first canvas
 * mutation. TANGO_AGENT_THINKING=adaptive restores it. */
export function agentThinkingOptions():
  | { thinking: ThinkingConfig }
  | Record<string, never> {
  return process.env.TANGO_AGENT_THINKING === 'adaptive'
    ? {}
    : { thinking: { type: 'disabled' } satisfies ThinkingConfig };
}

/** Setting sources for the embedded agent, as an Options spread. Workspace-
 * scoped by default so the user's global ~/.claude plugins/hooks/skills
 * don't leak into tango's engine (they bloat every turn and fire foreign
 * hooks); TANGO_AGENT_SETTINGS=all reverts to the CLI default. */
export function agentSettingSourcesOptions():
  | { settingSources: SettingSource[] }
  | Record<string, never> {
  return process.env.TANGO_AGENT_SETTINGS === 'all'
    ? {}
    : { settingSources: ['project', 'local'] satisfies SettingSource[] };
}

/** Set TANGO_AGENT_NO_PREWARM=1 to skip the boot-time engine pre-warm. */
export function agentPrewarmDisabled(): boolean {
  return process.env.TANGO_AGENT_NO_PREWARM === '1';
}

// ── fast import (direct-API loop) ───────────────────────────────────────────

/** Model for the Import button's dedicated translation loop. Quality matters
 * more than latency here (screens stream in as they finish). */
export function importModel(): string {
  return process.env.TANGO_IMPORT_MODEL ?? 'claude-opus-4-8';
}
