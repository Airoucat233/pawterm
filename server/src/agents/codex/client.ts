import { spawn, type ChildProcessWithoutNullStreams } from 'node:child_process';
import { createInterface, type Interface } from 'node:readline';
import type { Readable, Writable } from 'node:stream';

import { buildAgentEnv } from '../../agent-env.js';

type PendingRequest = {
  resolve: (value: unknown) => void;
  reject: (error: Error) => void;
};
export type CodexServerRequest = {
  id: string | number;
  method: string;
  params?: unknown;
};
type NotificationHandler = (notification: { method: string; params?: unknown }) => void;
type RequestHandler = (request: CodexServerRequest) => void;
type CloseHandler = (error: Error) => void;

export class CodexJsonRpcClient {
  private nextId = 1;
  private readonly pending = new Map<number, PendingRequest>();
  private readonly notificationHandlers = new Set<NotificationHandler>();
  private readonly requestHandlers = new Set<RequestHandler>();
  private readonly closeHandlers = new Set<CloseHandler>();
  private readonly rl: Interface;
  private closed = false;

  constructor(private readonly io: { input: Readable; output: Writable }) {
    this.rl = createInterface({ input: io.input });
    this.rl.on('line', (line) => this.handleLine(line));
    this.rl.on('close', () => this.close(new Error('Codex JSON-RPC input closed')));
    io.input.on('end', () => this.close(new Error('Codex JSON-RPC input closed')));
    io.input.on('close', () => this.close(new Error('Codex JSON-RPC input closed')));
    io.input.on('error', (err) => this.close(err));
    io.output.on('error', (err) => this.close(err));
  }

  request(method: string, params: unknown): Promise<unknown> {
    if (this.closed) return Promise.reject(new Error('Codex JSON-RPC client is closed'));
    const id = this.nextId++;
    const payload = { jsonrpc: '2.0', id, method, params };
    let line: string;
    try {
      line = `${JSON.stringify(payload)}\n`;
    } catch (err) {
      return Promise.reject(err);
    }
    const promise = new Promise<unknown>((resolve, reject) => {
      this.pending.set(id, { resolve, reject });
    });
    try {
      this.io.output.write(line);
    } catch (err) {
      const pending = this.pending.get(id);
      this.pending.delete(id);
      pending?.reject(err instanceof Error ? err : new Error(String(err)));
    }
    return promise;
  }

  notify(method: string, params?: unknown): void {
    if (this.closed) throw new Error('Codex JSON-RPC client is closed');
    const payload = params === undefined
      ? { jsonrpc: '2.0', method }
      : { jsonrpc: '2.0', method, params };
    this.io.output.write(`${JSON.stringify(payload)}\n`);
  }

  respond(id: string | number, result: unknown): void {
    if (this.closed) throw new Error('Codex JSON-RPC client is closed');
    this.io.output.write(`${JSON.stringify({ jsonrpc: '2.0', id, result })}\n`);
  }

  reject(id: string | number, code: number, message: string): void {
    if (this.closed) throw new Error('Codex JSON-RPC client is closed');
    this.io.output.write(`${JSON.stringify({ jsonrpc: '2.0', id, error: { code, message } })}\n`);
  }

  onRequest(handler: RequestHandler): () => void {
    this.requestHandlers.add(handler);
    return () => this.requestHandlers.delete(handler);
  }

  onNotification(handler: NotificationHandler): () => void {
    this.notificationHandlers.add(handler);
    return () => this.notificationHandlers.delete(handler);
  }

  onClose(handler: CloseHandler): () => void {
    this.closeHandlers.add(handler);
    return () => this.closeHandlers.delete(handler);
  }

  close(error = new Error('Codex JSON-RPC client closed')): void {
    if (this.closed) return;
    this.closed = true;
    for (const pending of this.pending.values()) {
      pending.reject(error);
    }
    this.pending.clear();
    this.notificationHandlers.clear();
    for (const handler of this.closeHandlers) {
      try {
        handler(error);
      } catch {
        // Isolate close observers from transport cleanup.
      }
    }
    this.closeHandlers.clear();
  }

  private handleLine(line: string): void {
    if (!line.trim()) return;
    let msg: any;
    try {
      msg = JSON.parse(line);
    } catch {
      return;
    }
    if (typeof msg.id === 'number') {
      const pending = this.pending.get(msg.id);
      if (!pending && msg.method) {
        this.handleRequest(msg);
        return;
      }
      if (!pending) return;
      this.pending.delete(msg.id);
      if (msg.error) pending.reject(new Error(JSON.stringify(msg.error)));
      else pending.resolve(msg.result);
      return;
    }
    if (msg.id !== undefined && msg.method) {
      this.handleRequest(msg);
      return;
    }
    if (msg.method) {
      for (const handler of this.notificationHandlers) {
        try {
          handler(msg);
        } catch {
          // Isolate handler bugs from the transport read loop.
        }
      }
    }
  }

  private handleRequest(msg: { id: string | number; method: string; params?: unknown }): void {
    if (this.requestHandlers.size === 0) {
      this.reject(msg.id, -32601, `Unhandled Codex app-server request: ${msg.method}`);
      return;
    }
    for (const handler of this.requestHandlers) {
      try {
        handler({ id: msg.id, method: msg.method, params: msg.params });
      } catch (err) {
        this.reject(msg.id, -32603, err instanceof Error ? err.message : String(err));
      }
    }
  }
}

export class CodexAppServerProcess {
  private child?: ChildProcessWithoutNullStreams;
  private client?: CodexJsonRpcClient;
  private initPromise?: Promise<CodexJsonRpcClient>;

  constructor(private readonly spawnCodex: typeof spawn = spawn) {}

  start(): CodexJsonRpcClient {
    if (this.client) return this.client;
    const child = this.spawnCodex('codex', ['app-server', '--listen', 'stdio://'], {
      stdio: ['pipe', 'pipe', 'pipe'],
      env: buildAgentEnv(),
    }) as ChildProcessWithoutNullStreams;
    this.child = child;
    child.stderr.on('data', () => {});
    this.client = new CodexJsonRpcClient({
      input: child.stdout,
      output: child.stdin,
    });
    const client = this.client;
    const clear = () => {
      if (this.child === child) this.child = undefined;
      if (this.client === client) {
        this.client = undefined;
        this.initPromise = undefined;
      }
    };
    child.on('error', (err) => {
      client.close(err);
      clear();
    });
    child.on('exit', (code, signal) => {
      client.close(new Error(`Codex app-server exited: code=${code ?? 'null'} signal=${signal ?? 'null'}`));
      clear();
    });
    return this.client;
  }

  startInitialized(): Promise<CodexJsonRpcClient> {
    const client = this.start();
    if (this.initPromise) return this.initPromise;
    this.initPromise = this.initialize(client).catch((err) => {
      if (this.client === client) {
        client.close(err instanceof Error ? err : new Error(String(err)));
        this.child?.kill('SIGTERM');
        this.child = undefined;
        this.client = undefined;
        this.initPromise = undefined;
      }
      throw err;
    });
    return this.initPromise;
  }

  stop(): void {
    this.client?.close(new Error('Codex app-server stopped'));
    this.child?.kill('SIGTERM');
    this.child = undefined;
    this.client = undefined;
    this.initPromise = undefined;
  }

  private async initialize(client: CodexJsonRpcClient): Promise<CodexJsonRpcClient> {
    await client.request('initialize', {
      clientInfo: {
        name: 'pawterm-server',
        title: 'PawTerm',
        version: process.env.npm_package_version ?? '0.0.0',
      },
      capabilities: null,
    });
    client.notify('initialized');
    return client;
  }
}
