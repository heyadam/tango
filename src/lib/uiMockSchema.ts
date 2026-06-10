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
  'rect',
  'ellipse',
  'line',
  'arrow',
  'triangle',
  'star',
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
  group: z.string().min(1).optional(),
});

export const uiGroupSchema = z.object({
  id: z.string().min(1),
  name: z.string().min(1),
});

export const uiScreenSchema = z.object({
  id: z.string().min(1),
  title: z.string().min(1),
  frame: z.object({
    w: z.number().int().positive(),
    h: z.number().int().positive(),
  }),
  nodes: z.array(uiNodeSchema),
  groups: z.array(uiGroupSchema).optional(),
  sourceFile: z.string().min(1).optional(),
  sourceHash: z.string().min(1).optional(),
});

export const uiColorTokenSchema = z.object({
  name: z.string().min(1),
  value: z.string().min(1),
  count: z.number().optional(),
});

export const uiTextStyleTokenSchema = z.object({
  name: z.string().min(1),
  size: z.number().positive(),
  weight: z.number().optional(),
  family: z.string().optional(),
  count: z.number().optional(),
});

export const uiDesignSystemSchema = z.object({
  colors: z.array(uiColorTokenSchema).optional(),
  typography: z.array(uiTextStyleTokenSchema).optional(),
  spacing: z.array(z.number()).optional(),
  radii: z.array(z.number()).optional(),
  icons: z.array(z.string().min(1)).optional(),
  notes: z.array(z.string().min(1)).optional(),
});

export const uiComponentSchema = z.object({
  id: z.string().min(1),
  name: z.string().min(1),
  description: z.string().optional(),
  frame: z.object({
    w: z.number().int().positive(),
    h: z.number().int().positive(),
  }),
  nodes: z.array(uiNodeSchema).min(1),
  usedBy: z.array(z.string().min(1)).optional(),
  sourceFile: z.string().min(1).optional(),
});

// designSystem/components are purely-additive optional fields — old
// design.json files and old browser snapshots stay valid without a
// FILE_VERSION bump (see uiMockPersist MIGRATIONS).
export const uiSpecSchema = z.object({
  screens: z.array(uiScreenSchema),
  designSystem: uiDesignSystemSchema.optional(),
  components: z.array(uiComponentSchema).optional(),
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
