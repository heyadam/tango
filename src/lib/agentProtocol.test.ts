import { describe, expect, it, vi } from 'vitest';
import {
  createSubmitBuffer,
  displayToolName,
  summarizeToolInput,
} from './agentProtocol';

describe('summarizeToolInput', () => {
  it('summarizes built-in tools by their identifying argument', () => {
    expect(summarizeToolInput('Bash', { command: 'ls -la' })).toBe('ls -la');
    expect(summarizeToolInput('Read', { file_path: '/a/b.swift' })).toBe(
      '/a/b.swift',
    );
    expect(summarizeToolInput('Grep', { pattern: 'foo.*bar' })).toBe(
      'foo.*bar',
    );
  });

  it('truncates to the first line', () => {
    expect(
      summarizeToolInput('Bash', { command: 'echo hi\nrm -rf /' }),
    ).toBe('echo hi');
    const long = 'x'.repeat(200);
    expect(summarizeToolInput('Bash', { command: long })).toHaveLength(81);
  });

  it('shortens deep file paths', () => {
    const deep = `/Users/someone/dev/project/${'sub/'.repeat(12)}file.swift`;
    const out = summarizeToolInput('Read', { file_path: deep });
    expect(out.startsWith('…/')).toBe(true);
    expect(out.endsWith('file.swift')).toBe(true);
  });

  it('summarizes MCP tools by their identifying ids', () => {
    expect(
      summarizeToolInput('mcp__tango-canvas__add_ui_nodes', {
        screenId: 'LoginView',
        nodes: [],
      }),
    ).toBe('LoginView');
    expect(
      summarizeToolInput('mcp__tango-canvas__update_ui_node', {
        nodeId: 'n1',
        patch: {},
      }),
    ).toBe('n1');
  });

  it('falls back to the first string value, then empty', () => {
    expect(summarizeToolInput('SomethingNew', { foo: 42, bar: 'hi' })).toBe(
      'hi',
    );
    expect(summarizeToolInput('SomethingNew', { foo: 42 })).toBe('');
    expect(summarizeToolInput('SomethingNew', null)).toBe('');
  });
});

describe('displayToolName', () => {
  it('strips the MCP prefix and leaves plain names alone', () => {
    expect(displayToolName('mcp__tango-canvas__set_ui_mock')).toBe(
      'set_ui_mock',
    );
    expect(displayToolName('Bash')).toBe('Bash');
  });
});

describe('createSubmitBuffer', () => {
  it('accumulates chunks and flushes on carriage return', () => {
    const onSubmit = vi.fn();
    const buf = createSubmitBuffer(onSubmit);
    buf.push('import my ');
    buf.push('screens');
    expect(onSubmit).not.toHaveBeenCalled();
    buf.push('\r');
    expect(onSubmit).toHaveBeenCalledExactlyOnceWith('import my screens');
  });

  it('ignores empty submissions and resets after each flush', () => {
    const onSubmit = vi.fn();
    const buf = createSubmitBuffer(onSubmit);
    buf.push('\r');
    expect(onSubmit).not.toHaveBeenCalled();
    buf.push('one');
    buf.push('\r');
    buf.push('two');
    buf.push('\r');
    expect(onSubmit).toHaveBeenNthCalledWith(1, 'one');
    expect(onSubmit).toHaveBeenNthCalledWith(2, 'two');
  });
});
