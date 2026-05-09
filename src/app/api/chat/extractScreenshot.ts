// Pure helpers for unwrapping the result of `screenshot_canvas` (and any other
// MCP image-returning tool) once the AI SDK MCP client has converted the raw
// CallToolResult into the model-output shape. Exposed so `route.ts` is thinner
// and so each branch is unit-testable.

export type ImagePart = { data: string; mimeType: string };

type ContentPart =
  | { type: 'text'; text?: string }
  | { type: 'image'; data?: string; mimeType?: string }
  | { type: string; [k: string]: unknown };

type CallToolResultLike = {
  content?: ContentPart[];
  isError?: boolean;
};

export function isErrorResult(result: unknown): boolean {
  return Boolean((result as CallToolResultLike | null)?.isError);
}

// When the MCP tool returned `{isError:true, content:[{type:'text', text:'...'}]}`,
// pull out the human-readable failure text. Falls back to a generic message.
export function errorTextFromResult(result: unknown): string {
  const content = (result as CallToolResultLike | null)?.content ?? [];
  for (const part of content) {
    if (
      part &&
      (part as { type?: string }).type === 'text' &&
      typeof (part as { text?: string }).text === 'string'
    ) {
      return (part as { text: string }).text;
    }
  }
  return 'tool returned an error with no message';
}

export function extractScreenshotImage(result: unknown): ImagePart | null {
  if (isErrorResult(result)) return null;
  const content = (result as CallToolResultLike | null)?.content ?? [];
  for (const part of content) {
    if (
      part &&
      (part as { type?: string }).type === 'image' &&
      typeof (part as { data?: string }).data === 'string' &&
      typeof (part as { mimeType?: string }).mimeType === 'string'
    ) {
      return {
        data: (part as { data: string }).data,
        mimeType: (part as { mimeType: string }).mimeType,
      };
    }
  }
  return null;
}
