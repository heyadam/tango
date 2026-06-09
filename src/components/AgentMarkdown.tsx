'use client';

// Markdown renderer for assistant messages in the agent chat panel.
// react-markdown + GFM, mapped onto semantic-token styles sized for a compact
// chat pane. Raw HTML stays disabled (react-markdown's default — do not add
// rehype-raw). React.memo'd on `text` so streaming deltas only re-render the
// one bubble that changed.

import { memo } from 'react';
import ReactMarkdown, { type Components } from 'react-markdown';
import remarkGfm from 'remark-gfm';

const remarkPlugins = [remarkGfm];

const components: Components = {
  p: ({ node: _node, ...props }) => <p className="my-1.5" {...props} />,
  ul: ({ node: _node, ...props }) => (
    <ul className="my-1.5 list-disc space-y-0.5 pl-5" {...props} />
  ),
  ol: ({ node: _node, ...props }) => (
    <ol className="my-1.5 list-decimal space-y-0.5 pl-5" {...props} />
  ),
  li: ({ node: _node, ...props }) => <li className="my-0" {...props} />,
  h1: ({ node: _node, ...props }) => (
    <h1 className="mt-3 mb-1 text-base font-semibold first:mt-0" {...props} />
  ),
  h2: ({ node: _node, ...props }) => (
    <h2 className="mt-3 mb-1 text-[0.95rem] font-semibold first:mt-0" {...props} />
  ),
  h3: ({ node: _node, ...props }) => (
    <h3 className="mt-2.5 mb-1 text-sm font-semibold first:mt-0" {...props} />
  ),
  h4: ({ node: _node, ...props }) => (
    <h4 className="mt-2 mb-1 text-sm font-semibold first:mt-0" {...props} />
  ),
  h5: ({ node: _node, ...props }) => (
    <h5 className="mt-2 mb-1 text-sm font-semibold first:mt-0" {...props} />
  ),
  h6: ({ node: _node, ...props }) => (
    <h6 className="mt-2 mb-1 text-sm font-semibold first:mt-0" {...props} />
  ),
  a: ({ node: _node, ...props }) => (
    <a
      className="text-primary underline underline-offset-2"
      target="_blank"
      rel="noreferrer"
      {...props}
    />
  ),
  // Inline code. Fenced blocks render <pre><code> — the pre override below
  // resets these inline styles for its child code element.
  code: ({ node: _node, ...props }) => (
    <code
      className="rounded bg-muted px-1 py-0.5 font-mono text-[0.85em]"
      {...props}
    />
  ),
  pre: ({ node: _node, ...props }) => (
    <pre
      className="my-1.5 overflow-x-auto rounded-md border border-border bg-muted/50 p-2 font-mono text-xs whitespace-pre [&>code]:rounded-none [&>code]:bg-transparent [&>code]:p-0 [&>code]:text-xs"
      {...props}
    />
  ),
  blockquote: ({ node: _node, ...props }) => (
    <blockquote
      className="my-1.5 border-l-2 border-border pl-3 text-muted-foreground"
      {...props}
    />
  ),
  table: ({ node: _node, ...props }) => (
    <div className="my-1.5 overflow-x-auto">
      <table className="w-full border-collapse border border-border" {...props} />
    </div>
  ),
  th: ({ node: _node, ...props }) => (
    <th
      className="border border-border bg-muted/50 px-2 py-1 text-left text-xs font-semibold"
      {...props}
    />
  ),
  td: ({ node: _node, ...props }) => (
    <td className="border border-border px-2 py-1 text-xs" {...props} />
  ),
  hr: ({ node: _node, ...props }) => (
    <hr className="my-2 border-border" {...props} />
  ),
  strong: ({ node: _node, ...props }) => (
    <strong className="font-semibold" {...props} />
  ),
};

const AgentMarkdown = memo(function AgentMarkdown({ text }: { text: string }) {
  return (
    <div className="text-sm leading-relaxed text-foreground [&>*:first-child]:mt-0 [&>*:last-child]:mb-0">
      <ReactMarkdown remarkPlugins={remarkPlugins} components={components}>
        {text}
      </ReactMarkdown>
    </div>
  );
});

export default AgentMarkdown;
