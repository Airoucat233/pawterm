import { EventEmitter } from 'node:events';
import { PassThrough } from 'node:stream';
import { describe, expect, it, vi } from 'vitest';
import { CodexAppServerProcess, CodexJsonRpcClient } from '../agents/codex/client.js';

describe('CodexJsonRpcClient', () => {
  it('resolves responses by id', async () => {
    const input = new PassThrough();
    const output = new PassThrough();
    const client = new CodexJsonRpcClient({ input, output });
    const promise = client.request('thread/list', { limit: 1 });
    const written = output.read()?.toString() ?? '';
    const request = JSON.parse(written.trim());
    input.write(`${JSON.stringify({ id: request.id, result: { data: [], nextCursor: null, backwardsCursor: null } })}\n`);
    await expect(promise).resolves.toEqual({ data: [], nextCursor: null, backwardsCursor: null });
  });

  it('emits notifications without resolving a request', async () => {
    const input = new PassThrough();
    const output = new PassThrough();
    const client = new CodexJsonRpcClient({ input, output });
    const notifications: unknown[] = [];
    client.onNotification((n) => notifications.push(n));
    input.write(`${JSON.stringify({ method: 'item/agentMessage/delta', params: { delta: 'a' } })}\n`);
    expect(notifications).toEqual([{ method: 'item/agentMessage/delta', params: { delta: 'a' } }]);
  });

  it('ignores malformed lines and keeps resolving later responses', async () => {
    const input = new PassThrough();
    const output = new PassThrough();
    const client = new CodexJsonRpcClient({ input, output });
    const promise = client.request('thread/list', { limit: 1 });
    const request = JSON.parse((output.read()?.toString() ?? '').trim());

    input.write('not json\n');
    input.write(`${JSON.stringify({ id: request.id, result: { ok: true } })}\n`);

    await expect(promise).resolves.toEqual({ ok: true });
  });

  it('rejects pending requests when input closes', async () => {
    const input = new PassThrough();
    const output = new PassThrough();
    const client = new CodexJsonRpcClient({ input, output });
    const promise = client.request('thread/list', { limit: 1 });

    input.destroy();

    await expect(promise).rejects.toThrow(/closed/);
  });

  it('notifies close handlers when input closes', async () => {
    const input = new PassThrough();
    const output = new PassThrough();
    const client = new CodexJsonRpcClient({ input, output });
    const closes: string[] = [];
    client.onClose((err) => closes.push(err.message));

    input.destroy();

    await new Promise<void>((resolve) => setImmediate(resolve));
    expect(closes).toEqual(['Codex JSON-RPC input closed']);
  });

  it('rejects circular request params without leaking the request', async () => {
    const input = new PassThrough();
    const output = new PassThrough();
    const client = new CodexJsonRpcClient({ input, output });
    const params: any = {};
    params.self = params;

    await expect(client.request('thread/list', params)).rejects.toThrow();
  });

  it('isolates notification handler errors', async () => {
    const input = new PassThrough();
    const output = new PassThrough();
    const client = new CodexJsonRpcClient({ input, output });
    const notifications: unknown[] = [];
    client.onNotification(() => {
      throw new Error('handler failed');
    });
    client.onNotification((n) => notifications.push(n));

    input.write(`${JSON.stringify({ method: 'item/agentMessage/delta', params: { delta: 'a' } })}\n`);

    expect(notifications).toEqual([{ method: 'item/agentMessage/delta', params: { delta: 'a' } }]);
  });
});

describe('CodexAppServerProcess', () => {
  it('creates a new client after the child exits', () => {
    const children: any[] = [];
    const spawnCodex = vi.fn(() => {
      const child = new EventEmitter() as any;
      child.stdin = new PassThrough();
      child.stdout = new PassThrough();
      child.stderr = new PassThrough();
      child.kill = vi.fn();
      children.push(child);
      return child;
    });
    const process = new CodexAppServerProcess(spawnCodex as any);

    const first = process.start();
    children[0].emit('exit', 1, null);
    const second = process.start();

    expect(second).not.toBe(first);
    expect(children).toHaveLength(2);
  });
});
