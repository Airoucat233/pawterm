import { useCallback, useEffect, useMemo, useState } from 'react';
import type { ReactNode } from 'react';
import clsx from 'clsx';
import {
  Activity,
  Braces,
  CheckCircle2,
  ChevronDown,
  CircleDot,
  Cpu,
  Database,
  KeyRound,
  LogOut,
  QrCode,
  RefreshCw,
  Settings,
  ShieldCheck,
  Smartphone,
  Terminal,
} from 'lucide-react';
import type { LucideIcon } from 'lucide-react';
import type { AdminEvent, AgentInfo, PairedDevice, Project } from '@pawterm/shared';
import { useAdminStore } from './store';
import {
  approvePair,
  ApiError,
  createAdminLoginCode,
  denyPair,
  exchangeAdminLoginCode,
  fetchAgents,
  fetchProjects,
  fetchQr,
  openPairWindow,
  revokeDevice,
  setAdminPassword,
} from './api';
import { useAdminAccessRenew, useAdminSSE, useDevicesPoll, useHealthPing } from './useAdminData';

type ThemeMode = 'dark' | 'light';
type ViewId = 'overview' | 'pairing' | 'devices' | 'agents' | 'projects' | 'events' | 'settings';
const THEME_STORAGE_KEY = 'pawterm-admin-theme';

const pageMeta: Record<ViewId, { title: string; subtitle: string }> = {
  overview: {
    title: '服务概览',
    subtitle: '查看 PawTerm Server 状态、配对入口和当前资源规模。',
  },
  pairing: {
    title: '设备配对',
    subtitle: '通过 QR claim 或 6 位 PIN 让手机获得 device token。',
  },
  devices: {
    title: '设备管理',
    subtitle: '查看已配对设备、last seen，并撤销不再信任的设备。',
  },
  agents: {
    title: 'Agent Runtime',
    subtitle: '查看 Claude、Codex 等 provider 的运行状态和默认 runtime。',
  },
  projects: {
    title: '项目白名单',
    subtitle: '查看 config.json 中允许访问的项目路径。',
  },
  events: {
    title: '事件流',
    subtitle: '查看 Web Admin 收到的实时 admin events 和原始 payload。',
  },
  settings: {
    title: '管理设置',
    subtitle: '设置 admin 密码、查看本地配置入口和断开当前后台会话。',
  },
};

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
  const token = useAdminStore((s) => s.token);
  const online = useAdminStore((s) => s.serverOnline);
  const hostname = useAdminStore((s) => s.hostname);
  const serverId = useAdminStore((s) => s.serverId);
  const port = useAdminStore((s) => s.port);
  const devices = useAdminStore((s) => s.devices);
  const events = useAdminStore((s) => s.events);
  const clearToken = useAdminStore((s) => s.clearToken);
  const [activeView, setActiveView] = useState<ViewId>('overview');
  const [pairSignal, setPairSignal] = useState(0);
  const [toast, setToast] = useState<string | null>(null);
  const [agents, setAgents] = useState<AgentInfo[]>([]);
  const [projects, setProjects] = useState<Project[]>([]);
  const [resourcesError, setResourcesError] = useState<string | null>(null);
  const [resourcesLoading, setResourcesLoading] = useState(false);

  const displayHost = (hostname ?? window.location.hostname) || 'localhost';
  const displayPort = (port ?? Number(window.location.port)) || 18765;
  const accessExpiresAt = useAdminStore((s) => s.tokenExpiresAt);

  const showToast = useCallback((message: string) => {
    setToast(message);
    window.setTimeout(() => setToast(null), 3200);
  }, []);

  const loadResources = useCallback(async () => {
    if (!token) return;
    setResourcesLoading(true);
    setResourcesError(null);
    try {
      const [nextAgents, nextProjects] = await Promise.all([fetchAgents(token), fetchProjects(token)]);
      setAgents(nextAgents);
      setProjects(nextProjects);
    } catch (err) {
      if (err instanceof ApiError && (err.status === 401 || err.status === 403)) {
        clearToken();
        return;
      }
      setResourcesError('资源列表加载失败');
    } finally {
      setResourcesLoading(false);
    }
  }, [token, clearToken]);

  useEffect(() => {
    void loadResources();
  }, [loadResources]);

  function openPairing() {
    setActiveView('pairing');
    setPairSignal((n) => n + 1);
  }

  const page = pageMeta[activeView];

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

          <button className="admin-switcher" type="button" onClick={() => setActiveView('overview')}>
            <span>active server</span>
            <strong>
              {displayHost}:{displayPort}
              <ChevronDown size={14} />
            </strong>
          </button>

          <NavGroup
            title="管理"
            activeView={activeView}
            onSelect={setActiveView}
            items={[
              ['overview', '服务概览', Activity],
              ['pairing', '设备配对', QrCode],
              ['devices', '设备管理', Smartphone],
            ]}
          />
          <NavGroup
            title="资源"
            activeView={activeView}
            onSelect={setActiveView}
            items={[
              ['agents', 'Agents', Cpu],
              ['projects', 'Projects', Database],
              ['events', '事件流', Terminal],
            ]}
          />
          <NavGroup
            title="系统"
            activeView={activeView}
            onSelect={setActiveView}
            items={[['settings', '设置', Settings]]}
          />
        </aside>

        <main className="admin-main">
          <header className="admin-page-header">
            <div>
              <div className="admin-crumb">PawTerm / Web Admin / {activeView}</div>
              <h2>{page.title}</h2>
              <p>{page.subtitle}</p>
            </div>
            <div className="admin-top-actions">
              <StatusPill online={online} />
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
            </div>
          </header>

          {activeView === 'overview' && (
            <OverviewPage
              online={online}
              displayHost={displayHost}
              displayPort={displayPort}
              serverId={serverId}
              agents={agents}
              projects={projects}
              devices={devices}
              events={events}
              resourcesError={resourcesError}
              resourcesLoading={resourcesLoading}
              onRefreshResources={loadResources}
              onOpenPairing={openPairing}
              onOpenEvents={() => setActiveView('events')}
              onOpenSettings={() => setActiveView('settings')}
            />
          )}
          {activeView === 'pairing' && <PairingPage autoOpenSignal={pairSignal} />}
          {activeView === 'devices' && <DevicesPage />}
          {activeView === 'agents' && (
            <AgentsPage agents={agents} loading={resourcesLoading} error={resourcesError} onRefresh={loadResources} />
          )}
          {activeView === 'projects' && (
            <ProjectsPage projects={projects} loading={resourcesLoading} error={resourcesError} onRefresh={loadResources} />
          )}
          {activeView === 'events' && <EventsPage />}
          {activeView === 'settings' && (
            <SettingsPage
              tokenExpiresAt={accessExpiresAt}
              serverId={serverId}
              displayHost={displayHost}
              displayPort={displayPort}
              onDisconnect={clearToken}
              onToast={showToast}
            />
          )}
        </main>
      </div>
      <PairRequestModal />
      {toast && <div className="admin-toast">{toast}</div>}
    </div>
  );
}

function NavGroup({
  title,
  items,
  activeView,
  onSelect,
}: {
  title: string;
  items: Array<[ViewId, string, LucideIcon]>;
  activeView: ViewId;
  onSelect: (view: ViewId) => void;
}) {
  return (
    <div className="admin-nav-group">
      <div className="admin-nav-title">{title}</div>
      {items.map(([view, label, Icon]) => (
        <button
          key={view}
          className={clsx('admin-nav-item', activeView === view && 'active')}
          type="button"
          onClick={() => onSelect(view)}
        >
          <span>
            <Icon size={13} />
          </span>
          {label}
        </button>
      ))}
    </div>
  );
}

function OverviewPage({
  online,
  displayHost,
  displayPort,
  serverId,
  agents,
  projects,
  devices,
  events,
  resourcesError,
  resourcesLoading,
  onRefreshResources,
  onOpenPairing,
  onOpenEvents,
  onOpenSettings,
}: {
  online: boolean;
  displayHost: string;
  displayPort: number;
  serverId: string | null;
  agents: AgentInfo[];
  projects: Project[];
  devices: PairedDevice[];
  events: Array<{ id: string; event: AdminEvent; receivedAt: number }>;
  resourcesError: string | null;
  resourcesLoading: boolean;
  onRefreshResources: () => Promise<void>;
  onOpenPairing: () => void;
  onOpenEvents: () => void;
  onOpenSettings: () => void;
}) {
  const serverStatus = events.find((entry) => entry.event.type === 'server_status')?.event;
  const activeDevices = serverStatus?.type === 'server_status' ? serverStatus.activeDevices : null;
  const readyAgents = agents.filter((agent) => agent.status === 'ready').length;

  return (
    <div className="admin-page-stack">
      <section className="admin-service-hero compact">
        <div className="admin-hero-head">
          <div>
            <div className="admin-eyebrow">
              <span className="admin-pulse" />
              local server
            </div>
            <h2>本地 Agent 控制台</h2>
            <p>
              当前连接到 <strong>{displayHost}:{displayPort}</strong>。这里管理 Web Admin 已经具备的能力：
              手机配对、设备撤销、Agent runtime、项目白名单和实时事件流。
            </p>
          </div>
          <StatusPill online={online} />
        </div>
        <div className="admin-actions">
          <button className="admin-button primary" type="button" onClick={onOpenPairing}>
            <QrCode size={14} />
            打开配对窗口
          </button>
          <button className="admin-button" type="button" onClick={onOpenEvents}>
            <Terminal size={14} />
            查看事件流
          </button>
          <button className="admin-button" type="button" onClick={onOpenSettings}>
            <Settings size={14} />
            管理设置
          </button>
        </div>
      </section>

      <section className="admin-metrics">
        <StatCard label="Server" value={online ? 'online' : 'offline'} foot={serverId ? `id ${serverId.slice(-8)}` : '等待 health'} tone={online ? 'green' : 'red'} />
        <StatCard label="Agents" value={`${readyAgents}/${agents.length}`} foot="ready / total" tone="purple" />
        <StatCard label="Projects" value={String(projects.length)} foot="config allow-list" tone="blue" />
        <StatCard label="Devices" value={String(devices.length)} foot={activeDevices == null ? 'paired devices' : `${activeDevices} active`} tone="yellow" />
      </section>

      <section className="admin-page-grid">
        <div className="admin-card">
          <div className="admin-card-head">
            <div>
              <div className="admin-card-title">资源状态</div>
              <div className="admin-card-sub">来自 /api/agents 与 /api/projects，不展示后端尚未实现的功能</div>
            </div>
            <button className="admin-icon-button" type="button" onClick={() => void onRefreshResources()} disabled={resourcesLoading}>
              <RefreshCw size={14} />
            </button>
          </div>
          {resourcesError ? (
            <div className="admin-empty">{resourcesError}</div>
          ) : (
            <div className="admin-resource-summary">
              {agents.map((agent) => (
                <div key={agent.kind} className="admin-summary-row">
                  <div className={clsx('admin-resource-icon', agent.kind)}>{agent.kind.slice(0, 2).toUpperCase()}</div>
                  <div className="min-w-0">
                    <strong>{agent.label}</strong>
                    <span>{describeRuntime(agent.defaultRuntime)}</span>
                  </div>
                  <span className={clsx('admin-badge', agent.status === 'ready' ? 'green' : 'red')}>{agent.status}</span>
                </div>
              ))}
              {agents.length === 0 && <div className="admin-empty">暂无 agent runtime</div>}
            </div>
          )}
        </div>
        <EventPanel limit={6} />
      </section>
    </div>
  );
}

function StatCard({
  label,
  value,
  foot,
  tone,
}: {
  label: string;
  value: string;
  foot: string;
  tone: 'green' | 'blue' | 'yellow' | 'red' | 'purple';
}) {
  return (
    <div className={clsx('admin-card admin-metric', `tone-${tone}`)}>
      <div className="admin-metric-label">{label}</div>
      <div className="admin-metric-value">{value}</div>
      <div className="admin-metric-foot">{foot}</div>
    </div>
  );
}

function PairingPage({ autoOpenSignal }: { autoOpenSignal: number }) {
  const pairQueue = useAdminStore((s) => s.pairQueue);

  return (
    <div className="admin-page-grid pairing">
      <PairingPanel autoOpenSignal={autoOpenSignal} />
      <div className="admin-card">
        <div className="admin-card-head">
          <div>
            <div className="admin-card-title">待确认请求</div>
            <div className="admin-card-sub">手机通过配对入口发起后，会在这里弹窗确认</div>
          </div>
          <span className="admin-badge yellow">{pairQueue.length}</span>
        </div>
        {pairQueue.length === 0 ? (
          <div className="admin-empty">暂无待确认设备</div>
        ) : (
          <div className="admin-device-list">
            {pairQueue.map((request) => (
              <div key={request.requestId} className="admin-device-row">
                <Smartphone size={15} />
                <div className="min-w-0">
                  <strong>{request.deviceName}</strong>
                  <span>{request.ip} · {request.deviceId.slice(-10)}</span>
                </div>
                <span className="admin-badge yellow">{relativeTime(request.createdAt)}</span>
              </div>
            ))}
          </div>
        )}
      </div>
    </div>
  );
}

function DevicesPage() {
  return (
    <div className="admin-page-stack">
      <DevicesPanel />
    </div>
  );
}

function AgentsPage({
  agents,
  loading,
  error,
  onRefresh,
}: {
  agents: AgentInfo[];
  loading: boolean;
  error: string | null;
  onRefresh: () => Promise<void>;
}) {
  return (
    <div className="admin-page-stack">
      <div className="admin-card">
        <div className="admin-card-head">
          <div>
            <div className="admin-card-title">Agent Runtime</div>
            <div className="admin-card-sub">保留 Claude / Codex / Gemini 各自的原生 runtime 定义</div>
          </div>
          <button className="admin-icon-button" type="button" onClick={() => void onRefresh()} disabled={loading}>
            <RefreshCw size={14} />
          </button>
        </div>
        {error ? (
          <div className="admin-empty">{error}</div>
        ) : agents.length === 0 ? (
          <div className="admin-empty">暂无 agent runtime</div>
        ) : (
          <div className="admin-agent-grid">
            {agents.map((agent) => (
              <AgentCard key={agent.kind} agent={agent} />
            ))}
          </div>
        )}
      </div>
    </div>
  );
}

function AgentCard({ agent }: { agent: AgentInfo }) {
  const capabilities = Object.entries(agent.capabilities).filter(([, enabled]) => enabled);
  return (
    <article className="admin-agent-card">
      <div className="admin-agent-head">
        <div className={clsx('admin-resource-icon', agent.kind)}>{agent.kind.slice(0, 2).toUpperCase()}</div>
        <div className="min-w-0">
          <h3>{agent.label}</h3>
          <p>{agent.statusMessage || describeRuntime(agent.defaultRuntime)}</p>
        </div>
        <span className={clsx('admin-badge', agent.status === 'ready' ? 'green' : 'red')}>{agent.status}</span>
      </div>
      <KeyValues rows={runtimeRows(agent.defaultRuntime)} />
      <div className="admin-capability-list">
        {capabilities.map(([name]) => (
          <span key={name} className="admin-badge blue">
            <CheckCircle2 size={12} />
            {name}
          </span>
        ))}
      </div>
    </article>
  );
}

function ProjectsPage({
  projects,
  loading,
  error,
  onRefresh,
}: {
  projects: Project[];
  loading: boolean;
  error: string | null;
  onRefresh: () => Promise<void>;
}) {
  return (
    <div className="admin-page-stack">
      <div className="admin-card">
        <div className="admin-card-head">
          <div>
            <div className="admin-card-title">项目白名单</div>
            <div className="admin-card-sub">当前仅展示 config.json 中的 projects；新增/删除项目应走配置文件或后续专门 API</div>
          </div>
          <button className="admin-icon-button" type="button" onClick={() => void onRefresh()} disabled={loading}>
            <RefreshCw size={14} />
          </button>
        </div>
        {error ? (
          <div className="admin-empty">{error}</div>
        ) : projects.length === 0 ? (
          <div className="admin-empty">暂无白名单项目</div>
        ) : (
          <div className="admin-table">
            {projects.map((project) => (
              <div className="admin-table-row" key={project.path}>
                <div className="admin-resource-icon project">{project.name.slice(0, 2).toUpperCase()}</div>
                <div className="min-w-0">
                  <strong>{project.name}</strong>
                  <span>{project.path}</span>
                </div>
                <span className="admin-badge blue">allow-list</span>
              </div>
            ))}
          </div>
        )}
      </div>
    </div>
  );
}

function EventsPage() {
  const events = useAdminStore((s) => s.events);
  const [selectedId, setSelectedId] = useState<string | null>(null);
  const selected = events.find((entry) => entry.id === selectedId) ?? events[0] ?? null;

  useEffect(() => {
    if (!selectedId && events[0]) setSelectedId(events[0].id);
  }, [events, selectedId]);

  return (
    <div className="admin-page-grid events">
      <div className="admin-card">
        <div className="admin-card-head">
          <div>
            <div className="admin-card-title">实时事件</div>
            <div className="admin-card-sub">这里展示 admin event 原始 type，不做通用重命名</div>
          </div>
          <span className="admin-badge green">live</span>
        </div>
        {events.length === 0 ? (
          <div className="admin-empty">等待实时事件</div>
        ) : (
          <div className="admin-timeline selectable">
            {events.map(({ id, event, receivedAt }) => (
              <button
                key={id}
                type="button"
                className={clsx('admin-event-row', selected?.id === id && 'selected')}
                onClick={() => setSelectedId(id)}
              >
                <span className={clsx('admin-event-dot', eventTone(event))} />
                <div className="min-w-0">
                  <p>{eventTitle(event)}</p>
                  <small>{eventMeta(event)}</small>
                </div>
                <time>{relativeTime(receivedAt)}</time>
              </button>
            ))}
          </div>
        )}
      </div>
      <RawEventPanel event={selected?.event ?? null} />
    </div>
  );
}

function SettingsPage({
  tokenExpiresAt,
  serverId,
  displayHost,
  displayPort,
  onDisconnect,
  onToast,
}: {
  tokenExpiresAt: number | null;
  serverId: string | null;
  displayHost: string;
  displayPort: number;
  onDisconnect: () => void;
  onToast: (message: string) => void;
}) {
  return (
    <div className="admin-page-grid settings">
      <div className="admin-card">
        <div className="admin-card-head">
          <div>
            <div className="admin-card-title">Admin 会话</div>
            <div className="admin-card-sub">Web Admin 使用 Bearer admin_access_token，过期前自动续期</div>
          </div>
          <ShieldCheck size={17} />
        </div>
        <KeyValues
          rows={[
            ['Server', `${displayHost}:${displayPort}`],
            ['Server ID', serverId ? serverId.slice(-12) : 'unknown'],
            ['Access token', tokenExpiresAt ? `expires ${formatDate(tokenExpiresAt)}` : 'session only'],
            ['Auth header', 'Authorization: Bearer aat-...'],
          ]}
        />
        <div className="admin-settings-actions">
          <button
            className="admin-button"
            type="button"
            onClick={() => onToast('浏览器不能直接打开本机编辑器。请用 Mac App 的 Edit Config，或编辑 PAWTERM_CONFIG 指向的 config.json。')}
          >
            <Braces size={14} />
            config.json 位置说明
          </button>
          <button className="admin-button danger" type="button" onClick={onDisconnect}>
            <LogOut size={14} />
            断开后台会话
          </button>
        </div>
      </div>
      <AdminPasswordPanel />
    </div>
  );
}

function EventPanel({ limit }: { limit: number }) {
  const events = useAdminStore((s) => s.events);

  return (
    <div className="admin-card">
      <div className="admin-card-head">
        <div>
          <div className="admin-card-title">最近事件</div>
          <div className="admin-card-sub">展示原生 admin event type</div>
        </div>
        <span className="admin-badge green">live</span>
      </div>
      {events.length === 0 ? (
        <div className="admin-empty">等待实时事件</div>
      ) : (
        <div className="admin-timeline">
          {events.slice(0, limit).map(({ id, event, receivedAt }) => (
            <div key={id} className="admin-event-row">
              <span className={clsx('admin-event-dot', eventTone(event))} />
              <div className="min-w-0">
                <p>{eventTitle(event)}</p>
                <small>{eventMeta(event)}</small>
              </div>
              <time>{relativeTime(receivedAt)}</time>
            </div>
          ))}
        </div>
      )}
    </div>
  );
}

function PairingPanel({ autoOpenSignal }: { autoOpenSignal: number }) {
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

  useEffect(() => {
    if (autoOpenSignal > 0) void showPin();
    // showPin intentionally uses fresh token/loading state for this signal.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [autoOpenSignal]);

  return (
    <div className="admin-card admin-pairing-card" id="admin-pairing">
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
    <div className="admin-card admin-password-panel" id="admin-password">
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

function runtimeRows(runtime: AgentInfo['defaultRuntime']): Array<[string, React.ReactNode]> {
  if (runtime.agent === 'claude') {
    return [
      ['agent', runtime.agent],
      ['permission_mode', runtime.permission_mode],
      ['model', runtime.model ?? 'default'],
    ];
  }
  if (runtime.agent === 'codex') {
    return [
      ['agent', runtime.agent],
      ['sandbox', runtime.sandbox],
      ['approval_policy', runtime.approval_policy],
      ['reasoning_effort', runtime.reasoning_effort ?? 'default'],
      ['model', runtime.model ?? 'default'],
    ];
  }
  return [
    ['agent', runtime.agent],
    ['approval_policy', runtime.approval_policy ?? 'default'],
    ['model', runtime.model ?? 'default'],
  ];
}

function describeRuntime(agent: AgentInfo['defaultRuntime']): string {
  if (agent.agent === 'claude') {
    return `permission_mode=${agent.permission_mode}${agent.model ? ` · model=${agent.model}` : ''}`;
  }
  if (agent.agent === 'codex') {
    return `sandbox=${agent.sandbox} · approval_policy=${agent.approval_policy}`;
  }
  return agent.approval_policy ? `approval_policy=${agent.approval_policy}` : 'runtime schema ready';
}

function eventTone(event: AdminEvent): 'green' | 'blue' | 'yellow' | 'red' {
  if (event.type === 'device_paired' || event.type === 'device_connected' || event.type === 'server_status') return 'green';
  if (event.type === 'pair_request') return 'yellow';
  if (event.type === 'device_revoked' || event.type === 'device_disconnected') return 'red';
  return 'blue';
}

function eventTitle(event: AdminEvent): string {
  if (event.type === 'pair_request') return `pair_request · ${event.deviceName}`;
  if (event.type === 'device_paired') return `device_paired · ${event.name}`;
  if (event.type === 'device_revoked') return `device_revoked · ${event.deviceId.slice(-8)}`;
  if (event.type === 'device_connected') return `device_connected · ${event.deviceId.slice(-8)}`;
  if (event.type === 'device_disconnected') return `device_disconnected · ${event.deviceId.slice(-8)}`;
  return 'server_status';
}

function eventMeta(event: AdminEvent): string {
  if (event.type === 'pair_request') return `${event.ip} · ${event.deviceId.slice(-8)}`;
  if (event.type === 'server_status') return `paired=${event.pairedDevices} active=${event.activeDevices}`;
  return JSON.stringify(event);
}

function relativeTime(ms: number): string {
  const seconds = Math.max(0, Math.round((Date.now() - ms) / 1000));
  if (seconds < 60) return `${seconds}s`;
  const minutes = Math.round(seconds / 60);
  if (minutes < 60) return `${minutes}m`;
  return `${Math.round(minutes / 60)}h`;
}

function RawEventPanel({ event }: { event: AdminEvent | null }) {
  return (
    <div className="admin-logbox">
      <div className="admin-logbar">
        <span>raw admin event</span>
        <span>JSON</span>
      </div>
      <pre>{event ? JSON.stringify(event, null, 2) : '等待实时事件'}</pre>
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
  const [theme, setThemeState] = useState<ThemeMode>(() => {
    const stored = window.localStorage.getItem(THEME_STORAGE_KEY);
    return stored === 'dark' || stored === 'light' ? stored : 'light';
  });
  useAdminAccessRenew();
  useHealthPing();
  useDevicesPoll();
  useAdminSSE();

  const setTheme = useCallback((mode: ThemeMode) => {
    window.localStorage.setItem(THEME_STORAGE_KEY, mode);
    setThemeState(mode);
  }, []);

  const bodyClass = useMemo(() => (theme === 'light' ? 'light' : ''), [theme]);

  return (
    <TokenGate>
      <div className={bodyClass}>
        <Shell theme={theme} setTheme={setTheme} />
      </div>
    </TokenGate>
  );
}
