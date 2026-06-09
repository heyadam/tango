// Zod schemas for the UISpec wire/persistence shape. Single source of truth
// shared by the MCP tool inputs (src/server/mcp.ts) and the design-file
// persistence validator (src/server/uiMockPersist.ts) — keep aligned with the
// TypeScript types in src/lib/uiMockProtocol.ts.

import * as z from 'zod/v4';

// Strict enum on `type` and required positioning so callers get a useful
// validation error instead of nodes silently rendering as `null`.
export const uiNodeTypeEnum = z.enum([
  'div',
  'text',
  'heading',
  'Button',
  'Input',
  'Textarea',
  'Badge',
  'Separator',
  'Image',
  'Icon',
]);

export const uiNodeSchema = z.object({
  id: z.string().min(1),
  type: uiNodeTypeEnum,
  x: z.number(),
  y: z.number(),
  width: z.number().positive(),
  height: z.number().positive(),
  text: z.string().optional(),
  className: z.string().optional(),
  style: z.record(z.string(), z.union([z.string(), z.number()])).optional(),
  props: z.record(z.string(), z.unknown()).optional(),
});

export const uiScreenSchema = z.object({
  id: z.string().min(1),
  title: z.string().min(1),
  frame: z.object({
    w: z.number().int().positive(),
    h: z.number().int().positive(),
  }),
  nodes: z.array(uiNodeSchema),
});

export const uiSpecSchema = z.object({
  screens: z.array(uiScreenSchema),
});

// Partial node for `update_ui_node` — every field of a node except `id`
// (immutable). All optional so callers can patch just what changed.
export const uiNodePatchSchema = z.object({
  type: uiNodeTypeEnum.optional(),
  x: z.number().optional(),
  y: z.number().optional(),
  width: z.number().positive().optional(),
  height: z.number().positive().optional(),
  text: z.string().optional(),
  className: z.string().optional(),
  style: z.record(z.string(), z.union([z.string(), z.number()])).optional(),
  props: z.record(z.string(), z.unknown()).optional(),
});
