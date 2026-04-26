// Dev affordance: drop a hand-rolled batch of moodboard directions (with
// generated palette-stripe PNGs, no OpenAI calls) into the active workspace.
// Same disk + memory side effects as a real generation, so the persistence
// pipeline is exercised end-to-end without spending tokens.
//
// Reachable from MoodboardPanel's "Seed dummy" button.

import { appendEvent } from '@/server/memory';
import { encodeStripePng, saveMoodboardPng } from '@/server/moodboard';
import { getWorkspaceOrNull } from '@/server/workspace';

export const runtime = 'nodejs';

type DummySpec = {
  title: string;
  rationale: string;
  brandNotes: string;
  uiNotes: string;
  imagePrompt: string;
  // Hex strings used both for the on-disk stripe PNG and the displayable
  // `palette` column. The labels are appended below.
  paletteHex: string[];
  paletteLabels: string[];
};

const DUMMY_SPECS: DummySpec[] = [
  {
    title: 'Editorial Serif',
    rationale:
      'Confident wordmark-driven brand. Recoleta-style serif paired with a small accent palette and lots of cream space. Reads "thoughtful design tool" rather than "AI gimmick".',
    brandNotes:
      'Lockup is the wordmark plus a single mark. Headlines in serif, all-caps eyebrows in lavender, body copy in a clean grotesk. No gradients in the brand layer.',
    uiNotes:
      'Cream surface, navy text, coral accents on primary actions. Pills for chips, generous radii (12–16px). Minimal shadows; rely on color contrast.',
    imagePrompt: '(seed) palette stripe — navy, cream, coral, peach',
    paletteHex: ['#15172A', '#F5EFE5', '#FE6F4D', '#FFA864'],
    paletteLabels: [
      '#15172A — ink navy',
      '#F5EFE5 — warm cream',
      '#FE6F4D — coral accent',
      '#FFA864 — peach highlight',
    ],
  },
  {
    title: 'Playful Mood',
    rationale:
      'Friendlier sibling — pink does the heavy lifting, with hand-drawn underlines and sparkles. Aimed at the marketing surface ("design is a dance").',
    brandNotes:
      'Marketing copy uses italic serif with hand-drawn underline accents. Mascot illustrations are blob-shaped with simple faces. Sparkle motif appears as a recurring punctuation.',
    uiNotes:
      'Coral and pink dominate. CTAs are pill-shaped with subtle shadow. Empty states get a small mascot illustration.',
    imagePrompt: '(seed) palette stripe — coral, pink, cream, lavender',
    paletteHex: ['#FE6F4D', '#FF5FA3', '#F5EFE5', '#A99CF8'],
    paletteLabels: [
      '#FE6F4D — coral lead',
      '#FF5FA3 — pink pop',
      '#F5EFE5 — warm cream',
      '#A99CF8 — soft lavender',
    ],
  },
  {
    title: 'AI Companion',
    rationale:
      'Conversation-first surface. Lavender purple as the agent color, cream for messages, navy for human voice. Suggestion chips and a single gradient submit button.',
    brandNotes:
      'Agent avatar uses the orange/purple lockup at small size. Tone is helpful-not-cute. Sparkle is the only allowed flourish.',
    uiNotes:
      'Chat surface on cream. Agent bubbles in soft lavender, user bubbles in cream with navy text. Submit button is purple→pink gradient.',
    imagePrompt: '(seed) palette stripe — purple, lavender, cream, navy',
    paletteHex: ['#7568F0', '#A99CF8', '#F5EFE5', '#15172A'],
    paletteLabels: [
      '#7568F0 — agent purple',
      '#A99CF8 — soft lavender',
      '#F5EFE5 — warm cream',
      '#15172A — ink navy',
    ],
  },
  {
    title: 'Notification Punch',
    rationale:
      'High-contrast surface for transient UI — toasts, banners, callouts. Mint and purple pop against a near-black canvas; the wordmark mark stays in cream.',
    brandNotes:
      'Notification card uses a single thick gradient border (purple → mint). Body copy in neutral cream. Icon plate is the brand mark on a cream square.',
    uiNotes:
      'Dark surface bg-#0C0E18. Gradient border on cards (purple to mint). Active-state pills in mint. Body text is cream, secondary in lavender.',
    imagePrompt: '(seed) palette stripe — navy, purple, mint, cream',
    paletteHex: ['#15172A', '#7568F0', '#5DCFAB', '#F5EFE5'],
    paletteLabels: [
      '#15172A — surface',
      '#7568F0 — agent purple',
      '#5DCFAB — mint accent',
      '#F5EFE5 — text cream',
    ],
  },
];

export async function POST() {
  const workspace = getWorkspaceOrNull();
  const directions = [];

  for (const spec of DUMMY_SPECS) {
    const png = encodeStripePng(1536, 1024, spec.paletteHex);
    const base64 = png.toString('base64');

    let relPath: string | undefined;
    if (workspace) {
      try {
        relPath = await saveMoodboardPng(workspace, base64);
        appendEvent({
          type: 'snapshot',
          relPath,
          caption: `moodboard · ${spec.title} (seed)`,
        });
      } catch (err) {
        console.error(
          '[moodboard:seed] failed to persist:',
          err instanceof Error ? err.message : String(err),
        );
      }
    }

    directions.push({
      id: crypto.randomUUID(),
      title: spec.title,
      rationale: spec.rationale,
      palette: spec.paletteLabels,
      brandNotes: spec.brandNotes,
      uiNotes: spec.uiNotes,
      imagePrompt: spec.imagePrompt,
      base64,
      mediaType: 'image/png',
      relPath,
    });
  }

  return Response.json({ directions });
}
