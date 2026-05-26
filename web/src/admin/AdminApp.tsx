import { useCallback, useEffect, useMemo, useState } from 'react';
import type { ReactNode } from 'react';
import clsx from 'clsx';
import {
  Activity,
  Braces,
  ChevronDown,
  CircleDot,
  Cpu,
  Database,
  FileCode,
  GitBranch,
  KeyRound,
  Play,
  RefreshCw,
  Search,
  Server,
  Settings,
  ShieldCheck,
  Smartphone,
  Terminal,
  X,
} from 'lucide-react';
import type { LucideIcon } from 'lucide-react';
import type { AdminEvent, PairedDevice } from '@pawterm/shared';
import { useAdminStore } from './store';
import {
  approvePair,
  createAdminLoginCode,
  denyPair,
  exchangeAdminLoginCode,
  fetchQr,
  openPairWindow,
  revokeDevice,
  setAdminPassword,
} from './api';
import { useAdminAccessRenew, useAdminSSE, useDevicesPoll, useHealthPing } from './useAdminData';

type ThemeMode = 'dark' | 'light';

function TokenGate({ children }: { children: ReactNode }) {
  const token = useAdminStore((s) => s.token);
  const setToken = useAdminStore((s) => s.setToken);
  const [input, setInput] = useState('');
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);

  useEffect(() => {
    const params = new URLSearchParams(window.location.search);
    const code = params.get('admin_login_code');
    if (!code || token) return;

    let alive = true;
    setLoading(true);
    setError(null);
    exchangeAdminLoginCode(code)
      .then((access) => {
        if (!alive) return;
        setToken(access.token, access.expiresAt);
        window.history.replaceState(null, '', window.location.pathname || '/admin');
      })
      .catch(() => {
        if (!alive) return;
        setError('登录码已失效，请从 Mac App 或 pawterm-server admin 重新打开。');
        window.history.replaceState(null, '', window.location.pathname || '/admin');
      })
      .finally(() => {
        if (alive) setLoading(false);
      });
    return () => {
      alive = false;
    };
  }, [token, setToken]);

  if (token) return <>{children}</>;

  const connect = async () => {
    const rootToken = input.trim();
    if (!rootToken || loading) return;
    setLoading(true);
    setError(null);
    try {
      const code = await createAdminLoginCode(rootToken);
      const access = await exchangeAdminLoginCode(code);
      setToken(access.token, access.expiresAt);
    } catch {
      setError('认证失败，请检查 admin token 或管理密码。');
    } finally {
      setLoading(false);
    }
  };

  return (
    <main className="admin-railway min-h-screen grid place-items-center p-6">
      <section className="admin-token-card">
        <div className="admin-brand compact">
          <div className="admin-mark">P</div>
          <div>
            <h1>PawTerm Admin</h1>
            <p>Agent Control Plane</p>
          </div>
        </div>
        <p className="admin-token-copy">
          输入 admin token 或管理密码进入控制台。浏览器只保存临时 admin access token，
          不保存 config 里的 root token。
        </p>
        <input
          type="password"
          value={input}
          onChange={(e) => setInput(e.target.value)}
          onKeyDown={(e) => e.key === 'Enter' && void connect()}
          placeholder="sk-..."
          className="admin-input"
          autoFocus
        />
        {error && <div className="admin-token-error">{error}</div>}
        <button
          type="button"
          onClick={() => void connect()}
          disabled={loading || !input.trim()}
          className="admin-button primary w-full"
        >
          <KeyRound size={14} />
          {loading ? '连接中...' : '连接'}
        </button>
      </section>
    </main>
  );
}

function StatusPill({ online }: { online: boolean }) {
  return (
    <span className={clsx('admin-badge', online ? 'green' : 'red')}>
      <span className="admin-dot" />
      {online ? 'online' : 'offline'}
    </span>
  );
}

function Shell({ theme, setTheme }: { theme: ThemeMode; setTheme: (mode: ThemeMode) => void }) {
  const online = useAdminStore((s) => s.serverOnline);
  const hostname = useAdminStore((s) => s.hostname);
  const serverId = useAdminStore((s) => s.serverId);
  const port = useAdminStore((s) => s.port);
  const devices = useAdminStore((s) => s.devices);
  const events = useAdminStore((s) => s.events);
  const clearToken = useAdminStore((s) => s.clearToken);

  const displayHost = (hostname ?? window.location.hostname) || 'localhost';
  const displayPort = (port ?? Number(window.location.port)) || 8765;
  const shortId = serverId ? serverId.slice(-8) : '--------';

  return (
    <div className={clsx('admin-railway', theme === 'light' && 'light')}>
      <div className="admin-layout">
        <aside className="admin-sidebar">
          <div className="admin-brand">
            <div className="admin-mark">P</div>
            <div>
              <h1>PawTerm</h1>
              <p>Agent Control Plane</p>
            </div>
          </div>

          <button className="admin-switcher" type="button">
            <span>active server</span>
            <strong>
              {displayHost}
              <ChevronDown size={14} />
            </strong>
          </button>

          <NavGroup
            title="Workspace"
            items={[
              ['Overview', Activity, true],
              ['Projects', Database, false],
              ['Agents', Cpu, false],
              ['Runs', GitBranch, false],
            ]}
          />
          <NavGroup
            title="Operations"
            items={[
              ['Devices', Smartphone, false],
              ['Logs', Terminal, false],
              ['Config', FileCode, false],
              ['Settings', Settings, false],
            ]}
          />
        </aside>

        <main className="admin-main">
          <header className="admin-topbar">
            <div className="admin-crumb">
              PawTerm / <strong>claude-companion</strong> / production
            </div>
            <div className="admin-search">
              <Search size={14} />
              搜索 project、session、tool event
              <kbd>⌘ K</kbd>
            </div>
            <div className="admin-theme-toggle" aria-label="主题切换">
              <button
                type="button"
                className={clsx(theme === 'dark' && 'active')}
                onClick={() => setTheme('dark')}
              >
                暗色
              </button>
              <button
                type="button"
                className={clsx(theme === 'light' && 'active')}
                onClick={() => setTheme('light')}
              >
                日间
              </button>
            </div>
          </header>

          <section className="admin-hero-grid">
            <div className="admin-service-hero">
              <div className="admin-hero-head">
                <div>
                  <div className="admin-eyebrow">
                    <span className="admin-pulse" />
                    server running
                  </div>
                  <h2>本地 Agent 服务正在运行</h2>
                  <p>
                    当前连接到 <strong>{displayHost}:{displayPort}</strong>，Web Admin 统一管理配对、
                    项目白名单、Agent runtime 与原始事件流。
                  </p>
                </div>
                <StatusPill online={online} />
              </div>
              <div className="admin-actions">
                <button className="admin-button primary" type="button">
                  <Play size={14} />
                  打开配对窗口
                </button>
                <button className="admin-button" type="button">
                  <Terminal size={14} />
                  查看运行日志
                </button>
                <button className="admin-button" type="button">
                  <Braces size={14} />
                  编辑 config.json
                </button>
              </div>
            </div>
            <ActivityCard />
          </section>

          <section className="admin-metrics">
            <Metric label="Active runs" value="3" foot="2 Claude · 1 Codex" />
            <Metric label="Projects" value="4" foot="全部在 allow-list 内" />
            <Metric label="Paired devices" value={String(devices.length)} foot="设备连接与撤销" />
            <Metric label="Raw events" value={String(events.length)} foot="保留原生事件名" />
          </section>

          <section className="admin-content-grid">
            <ResourcePanel />
            <EventPanel />
          </section>

          <section className="admin-lower-grid">
            <PairingPanel />
            <DevicesPanel />
          </section>
        </main>

        <aside className="admin-inspector">
          <div className="admin-inspector-head">
            <h2>Claude Code</h2>
            <p>当前选中的 Agent service。这里像 Railway 的 service inspector，展示 runtime、能力、最近事件和原始 payload。</p>
          </div>
          <KeyValues
            rows={[
              ['Status', <StatusPill key="status" online={online} />],
              ['Runtime', 'acceptEdits'],
              ['Model', 'claude-sonnet-4-6'],
              ['Server ID', shortId],
              ['Devices', String(devices.length)],
            ]}
          />
          <AdminPasswordPanel />
          <RawPreview />
          <div className="admin-inspector-actions">
            <button className="admin-button" type="button" onClick={clearToken}>
              <X size={14} />
              Disconnect admin
            </button>
          </div>
        </aside>
      </div>
      <PairRequestModal />
    </div>
  );
}

function NavGroup({
  title,
  items,
}: {
  title: string;
  items: Array<[string, LucideIcon, boolean]>;
}) {
  return (
    <div className="admin-nav-group">
      <div className="admin-nav-title">{title}</div>
      {items.map(([label, Icon, active]) => (
        <button key={label} className={clsx('admin-nav-item', active && 'active')} type="button">
          <span>
            <Icon size={13} />
          </span>
          {label}
        </button>
      ))}
    </div>
  );
}

function ActivityCard() {
  const heights = [22, 42, 36, 58, 76, 48, 66, 81, 57, 33, 69, 92, 51, 28, 45, 73, 61, 39];
  return (
    <div className="admin-card admin-activity-card">
      <div className="admin-card-title">过去 30 分钟</div>
      <div className="admin-card-sub">turns / tool calls / device events</div>
      <div className="admin-activity-bars">
        {heights.map((height, index) => (
          <div key={index} className="admin-bar" style={{ height: `${height}%` }} />
        ))}
      </div>
    </div>
  );
}

function Metric({ label, value, foot }: { label: string; value: string; foot: string }) {
  return (
    <div className="admin-card admin-metric">
      <div className="admin-metric-label">{label}</div>
      <div className="admin-metric-value">{value}</div>
      <div className="admin-metric-foot">{foot}</div>
    </div>
  );
}

const resources = [
  ['CL', 'Claude Code', 'permission_mode=acceptEdits · model=claude-sonnet-4-6', 'ready', 'green', 'claude'],
  ['CX', 'Codex', 'sandbox=workspace-write · approval_policy=on-request', 'ready', 'green', 'codex'],
  ['GM', 'Gemini', 'provider slot reserved · runtime schema ready', 'disabled', '', 'gemini'],
  ['PT', 'claude-companion', '/Users/airoucat/workspace/shulex/claude-companion', '4 sessions', 'blue', 'project'],
] as const;

function ResourcePanel() {
  return (
    <div className="admin-card">
      <div className="admin-card-head">
        <div>
          <div className="admin-card-title">服务资源</div>
          <div className="admin-card-sub">像 Railway service 一样管理 project 与 agent runtime</div>
        </div>
        <div className="admin-tabs">
          <button className="active" type="button">Agents</button>
          <button type="button">Projects</button>
          <button type="button">Devices</button>
        </div>
      </div>
      <div className="admin-resource-list">
        {resources.map(([abbr, title, subtitle, badge, badgeTone, tone], index) => (
          <div key={title} className={clsx('admin-resource', index === 0 && 'selected')}>
            <div className={clsx('admin-resource-icon', tone)}>{abbr}</div>
            <div className="min-w-0">
              <h3>{title}</h3>
              <p>{subtitle}</p>
            </div>
            <span className={clsx('admin-badge', badgeTone)}>{badge}</span>
          </div>
        ))}
      </div>
    </div>
  );
}

function EventPanel() {
  const liveEvents = [
    ['green', 'Claude · Bash', 'pnpm --filter pawterm-server run typecheck', '12s'],
    ['blue', 'Codex · commandExecution', 'flutter analyze · app/lib/screens/tabs/chat_tab.dart', '1m'],
    ['yellow', 'Codex · fileChange', 'server/src/config.ts · RawServerConfig', '4m'],
    ['red', 'Claude · TodoWrite', 'Task 13 · Flutter Chat Agent Runtime', '9m'],
  ] as const;
  return (
    <div className="admin-card">
      <div className="admin-card-head">
        <div>
          <div className="admin-card-title">运行时间线</div>
          <div className="admin-card-sub">展示原生 tool/event 名称，不做通用重命名</div>
        </div>
        <span className="admin-badge green">live</span>
      </div>
      <div className="admin-timeline">
        {liveEvents.map(([tone, title, meta, time]) => (
          <div key={title} className="admin-event-row">
            <span className={clsx('admin-event-dot', tone)} />
            <div className="min-w-0">
              <p>{title}</p>
              <small>{meta}</small>
            </div>
            <time>{time}</time>
          </div>
        ))}
      </div>
    </div>
  );
}

function PairingPanel() {
  const token = useAdminStore((s) => s.token);
  const [qrSvg, setQrSvg] = useState<string | null>(null);
  const [expiresAt, setExpiresAt] = useState<number | null>(null);
  const [pin, setPin] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const loadQr = useCallback(async () => {
    if (!token) return;
    setLoading(true);
    setError(null);
    try {
      const data = await fetchQr(token);
      setQrSvg(data.svg);
      setExpiresAt(data.expiresAt ?? null);
    } catch {
      setError('QR unavailable');
    } finally {
      setLoading(false);
    }
  }, [token]);

  useEffect(() => {
    void loadQr();
  }, [loadQr]);

  useEffect(() => {
    if (!expiresAt) return;
    const ms = expiresAt - Date.now();
    const timer = window.setTimeout(() => void loadQr(), Math.max(ms + 500, 1000));
    return () => window.clearTimeout(timer);
  }, [expiresAt, loadQr]);

  async function showPin() {
    if (!token) return;
    setLoading(true);
    try {
      const data = await openPairWindow(token);
      setPin(data.pin);
      setError(null);
    } catch {
      setError('Could not open pairing window');
    } finally {
      setLoading(false);
    }
  }

  return (
    <div className="admin-card admin-pairing-card">
      <div className="admin-card-head">
        <div>
          <div className="admin-card-title">配对入口</div>
          <div className="admin-card-sub">短期 claim / PIN，不暴露永久 token</div>
        </div>
        <button className="admin-icon-button" type="button" onClick={() => void loadQr()} disabled={loading}>
          <RefreshCw size={14} />
        </button>
      </div>
      <div className="admin-qr-box">
        {error ? (
          <span className="admin-error">{error}</span>
        ) : qrSvg ? (
          <div dangerouslySetInnerHTML={{ __html: qrSvg }} />
        ) : (
          <span className="admin-muted">loading...</span>
        )}
      </div>
      {pin ? (
        <div className="admin-pin">
          <span>6-digit PIN</span>
          <strong>{pin}</strong>
          <small>valid 5 min</small>
        </div>
      ) : (
        <button className="admin-link-button" type="button" onClick={() => void showPin()} disabled={loading}>
          或使用 6 位 PIN
        </button>
      )}
    </div>
  );
}

function DevicesPanel() {
  const token = useAdminStore((s) => s.token);
  const devices = useAdminStore((s) => s.devices);
  const removeDevice = useAdminStore((s) => s.removeDevice);
  const [revoking, setRevoking] = useState<string | null>(null);

  async function handleRevoke(deviceId: string) {
    if (!token) return;
    setRevoking(deviceId);
    try {
      await revokeDevice(token, deviceId);
      removeDevice(deviceId);
    } finally {
      setRevoking(null);
    }
  }

  return (
    <div className="admin-card">
      <div className="admin-card-head">
        <div>
          <div className="admin-card-title">已配对设备</div>
          <div className="admin-card-sub">last seen、撤销与配对事件</div>
        </div>
        <span className="admin-badge">{devices.length}</span>
      </div>
      {devices.length === 0 ? (
        <div className="admin-empty">暂无已配对设备</div>
      ) : (
        <div className="admin-device-list">
          {devices.map((device) => (
            <DeviceRow
              key={device.deviceId}
              device={device}
              revoking={revoking === device.deviceId}
              onRevoke={() => void handleRevoke(device.deviceId)}
            />
          ))}
        </div>
      )}
    </div>
  );
}

function DeviceRow({
  device,
  revoking,
  onRevoke,
}: {
  device: PairedDevice;
  revoking: boolean;
  onRevoke: () => void;
}) {
  return (
    <div className="admin-device-row">
      <Smartphone size={15} />
      <div className="min-w-0">
        <strong>{device.name}</strong>
        <span>{formatDate(device.lastSeen) || 'never seen'}</span>
      </div>
      <button type="button" onClick={onRevoke} disabled={revoking}>
        {revoking ? 'revoking...' : 'revoke'}
      </button>
    </div>
  );
}

function KeyValues({ rows }: { rows: Array<[string, React.ReactNode]> }) {
  return (
    <div className="admin-kv-list">
      {rows.map(([key, value]) => (
        <div className="admin-kv" key={key}>
          <span>{key}</span>
          <strong>{value}</strong>
        </div>
      ))}
    </div>
  );
}

function AdminPasswordPanel() {
  const token = useAdminStore((s) => s.token);
  const [password, setPassword] = useState('');
  const [confirm, setConfirm] = useState('');
  const [status, setStatus] = useState<string | null>(null);
  const [statusKind, setStatusKind] = useState<'ok' | 'error'>('ok');
  const [saving, setSaving] = useState(false);

  const canSave = password.length >= 8 && /[a-zA-Z]/.test(password) && /[0-9]/.test(password) && password === confirm;

  async function save() {
    if (!token || !canSave || saving) return;
    setSaving(true);
    setStatus(null);
    try {
      await setAdminPassword(token, password);
      setPassword('');
      setConfirm('');
      setStatusKind('ok');
      setStatus('管理密码已更新');
    } catch {
      setStatusKind('error');
      setStatus('设置失败，请确认当前 admin 会话仍有效');
    } finally {
      setSaving(false);
    }
  }

  return (
    <div className="admin-password-panel">
      <div className="admin-card-title">管理密码</div>
      <div className="admin-card-sub">保存在 config.json 中的是 scrypt hash，不写明文密码。</div>
      <input
        type="password"
        className="admin-input"
        value={password}
        onChange={(e) => setPassword(e.target.value)}
        placeholder="至少 8 位，包含字母和数字"
      />
      <input
        type="password"
        className="admin-input"
        value={confirm}
        onChange={(e) => setConfirm(e.target.value)}
        onKeyDown={(e) => e.key === 'Enter' && void save()}
        placeholder="再次输入"
      />
      {status && <div className={statusKind === 'ok' ? 'admin-token-note' : 'admin-token-error'}>{status}</div>}
      <button className="admin-button primary w-full" type="button" disabled={!canSave || saving} onClick={() => void save()}>
        <KeyRound size={14} />
        {saving ? '保存中...' : '设置密码'}
      </button>
    </div>
  );
}

function RawPreview() {
  return (
    <div className="admin-logbox">
      <div className="admin-logbar">
        <span>raw event preview</span>
        <span>JSON</span>
      </div>
      <pre>{`{
  "agent": "claude",
  "type": "assistant",
  "content": [{
    "type": "tool_use",
    "name": "Bash",
    "input": {
      "command": "pnpm dev"
    },
    "raw_payload": "{...}"
  }]
}`}</pre>
    </div>
  );
}

function PairRequestModal() {
  const token = useAdminStore((s) => s.token);
  const pairQueue = useAdminStore((s) => s.pairQueue);
  const dequeuePairRequest = useAdminStore((s) => s.dequeuePairRequest);
  const [acting, setActing] = useState(false);
  const current = pairQueue[0];

  if (!current) return null;

  async function handle(action: 'approve' | 'deny') {
    if (!token || !current) return;
    setActing(true);
    try {
      if (action === 'approve') await approvePair(token, current.requestId);
      else await denyPair(token, current.requestId);
    } finally {
      setActing(false);
      dequeuePairRequest();
    }
  }

  return (
    <div className="admin-modal-backdrop">
      <section className="admin-modal">
        <div className="admin-eyebrow yellow">
          <CircleDot size={13} />
          pair request
        </div>
        <h2>{current.deviceName}</h2>
        <KeyValues
          rows={[
            ['IP', current.ip],
            ['Device', current.deviceId.slice(-10)],
            ['Queued', `${Math.max(1, Math.round((Date.now() - current.createdAt) / 1000))}s ago`],
          ]}
        />
        <div className="admin-modal-actions">
          <button className="admin-button primary" disabled={acting} onClick={() => void handle('approve')}>
            Approve
          </button>
          <button className="admin-button danger" disabled={acting} onClick={() => void handle('deny')}>
            Deny
          </button>
        </div>
      </section>
    </div>
  );
}

function formatDate(ms: number | null): string {
  if (!ms) return '';
  return new Date(ms).toLocaleString(undefined, {
    month: 'short',
    day: 'numeric',
    hour: '2-digit',
    minute: '2-digit',
  });
}

export default function AdminApp() {
  const [theme, setTheme] = useState<ThemeMode>('dark');
  useAdminAccessRenew();
  useHealthPing();
  useDevicesPoll();
  useAdminSSE();

  const bodyClass = useMemo(() => (theme === 'light' ? 'light' : ''), [theme]);

  return (
    <TokenGate>
      <div className={bodyClass}>
        <Shell theme={theme} setTheme={setTheme} />
      </div>
    </TokenGate>
  );
}
