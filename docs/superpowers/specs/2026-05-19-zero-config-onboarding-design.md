# Zero-config onboarding — 设计文档

> 状态：approved by user (2026-05-19)
> 分支：`feat/zero-config-onboarding`
> 范围：本 spec 覆盖 slice 1-5（server + app）。slice 6（Homebrew tap）作为后续独立 PR，原因：tap 需要独立 `homebrew-pawterm` 仓库。

## 目标

把 PawTerm 的"首次连接"和"跨网络续连"做成零配置体验。打开 App 点"扫描"即可发现局域网内的 server，用一次 PIN 配对就能拿到长期凭证，之后换 Wi-Fi / Tailscale IP 变了，App 也能凭 `serverId` 自动匹配并续连。

## 需求

1. **LAN 自动发现**：App 端按钮触发，自动扫描局域网内的 server，列出后用户选连
2. **首次配对认证**：类似蓝牙配对的安全握手 —— 头戴式无 GUI 的 server 需要带外（out-of-band）凭据（PIN 或 QR）
3. **设备级凭证持久化**：首次配对后绑定到稳定的服务标识，跨网络 IP 变化仍可直连
4. **（推迟）Homebrew 安装**：`brew install` + `brew services start pawterm-server` 模式 —— 作为后续 PR

---

## 架构概览

两个新的核心概念把四个需求串起来：

- **`serverId`**：server 端持久化在 `~/.config/pawterm/config.json` 的 UUIDv4，首次启动生成后不变。mDNS 广播 + `/health` 响应里都带它。
- **`deviceToken`**：每台手机配对后服务端颁发的长期凭证。绑定 `serverId`，不绑定 IP。

原来的 `settings.token` 改名/复用为 **`adminToken`**：保留给 Web 管理面板和 QR-claim 路径使用。鉴权中间件接受 `adminToken` **或** 任一活跃 `deviceToken`。

---

## Slice 详细设计

### Slice 1 — Server：serverId 持久化 + /health 增强

**改 `server/src/config.ts`**：

`ServerSettings` 新增 `serverId: string`。`loadConfig()` 在首次启动或读到旧 config 时通过 `crypto.randomUUID()` 生成并写回 config.json：

```json
{
  "host": "0.0.0.0",
  "port": 8765,
  "permission_mode": "...",
  "server_id": "8e3b7a90-...",
  "token": "sk-...",
  "projects": [...]
}
```

**改 `server/src/index.ts` `/health`**：返回 `{ status, version, hostname, serverId }`。`packages/shared/src/protocol.ts` 中的 `HealthResponse` 类型同步加 `serverId` 字段（可选，向后兼容）。

**测试**：新增 `server/src/__tests__/config.test.ts`，验证首次启动生成 serverId、二次启动复用同一 ID。

### Slice 2 — Server：mDNS 广播

新增依赖：`bonjour-service` (pure-JS, MIT)。

**新增 `server/src/mdns.ts`**：导出 `startMdns({ port, serverId, hostname, version, getPairingState }): () => void`，返回停止函数。注册：

- 服务类型：`_pawterm._tcp.local`
- 服务名：`PawTerm on <hostname>`
- TXT 记录：`serverId`、`version`、`pairing` (`open` / `closed`)

`pairing` 是动态字段 —— 当 PIN 配对窗口开启时为 `open`，否则 `closed`。靠重新发布 TXT 实现（bonjour-service 支持）。

**改 `server/src/index.ts`**：启动监听后调用 `startMdns(...)`，将停止函数挂到 SIGTERM/SIGINT cleanup。

### Slice 3 — Server：PIN 配对协议 + 多设备 token

**配对窗口模型**：

- 状态在 server 进程内存里：`pairingWindow: { pin: string; expiresAt: number } | null`
- 触发器：用户在任何 shell 跑 `pawterm-server pair`。这个新子命令做的是 IPC：
  - 优先：发 HTTP `POST /admin/pair-window` 给正在跑的 server（`Authorization: Bearer <adminToken>`），让 server 进入配对态
  - 兜底：如果 admin 接口失败，把命令降级为"在终端单独跑一个临时配对服务"是过度设计 —— 直接报错让用户检查 server 是否在跑
- server 进入配对态后：生成 6 位数字 PIN，写入 stdout（不要写日志文件，避免日志泄露），并通过同一 HTTP 响应回传给 `pawterm-server pair` 命令，让该 CLI 在调用方终端显示 PIN。窗口 5 分钟，首次成功配对后立即关闭。

**新协议**（加进 `packages/shared/src/protocol.ts`）：

```ts
// /admin/pair-window —— 由 pawterm-server pair CLI 调用，需要 adminToken
export interface PairWindowRequest {}
export interface PairWindowResponse { pin: string; expiresAt: number }

// /pair/start —— 手机端调用，无需任何 token；PIN 是带外凭据
export interface PairStartRequest { deviceId: string; deviceName: string; pin: string }
export type PairStartResponse =
  | { ok: true; deviceToken: string; serverId: string }
  | { ok: false; error: 'bad_pin' | 'pairing_closed' | 'rate_limited' };

// /pair/qr-claim —— 手机端调用，Authorization: Bearer <adminToken>（QR 模式）
export interface PairQrClaimRequest { deviceId: string; deviceName: string }
export interface PairQrClaimResponse { deviceToken: string; serverId: string }

// /admin/devices —— GET 列出，DELETE 吊销，需要 adminToken
export interface PairedDevice {
  deviceId: string;
  name: string;
  pairedAt: number;  // epoch ms
  lastSeen: number | null;
}
```

**速率限制**：`/pair/start` 同一 IP 失败 5 次后冷却 60 秒。防爆破。

**deviceToken 生成**：`'dt-' + randomBytes(24).toString('hex')`。持久化到 config.json 的 `paired_devices` 字段：

```json
{
  "paired_devices": [
    {
      "device_id": "...",
      "name": "Norman's Pixel",
      "device_token": "dt-...",
      "paired_at": 1716095940000,
      "last_seen": 1716100000000
    }
  ]
}
```

**鉴权中间件改造**（`server/src/index.ts` 的 onRequest hook）：

```ts
const isAdmin = token === settings.adminToken;
const matchedDevice = settings.pairedDevices.find(d => d.deviceToken === token);
if (!isAdmin && !matchedDevice) reply.code(401).send(...);
if (matchedDevice) {
  matchedDevice.lastSeen = Date.now();
  // 异步持久化，不阻塞请求
}
```

`/admin/*` 路径只接受 adminToken，其他路径两类都接受。

**`pawterm-server pair` CLI**：

新增 `server/src/pair-cli.ts`。命令行体验：

```
$ pawterm-server pair

▶ requesting pairing window from local pawterm server...
✓ window open for 5 minutes

  Enter this PIN on your phone:

      ┌────────────────┐
      │   3 8  4 1 9 2 │
      └────────────────┘

  Waiting for device... (Ctrl+C to cancel)
```

CLI 通过轮询 `/admin/devices` 看新设备出现，出现后打印 "✓ paired: <name>" 并退出。

### Slice 4 — App：扫描 LAN + 配对 UI

**新增依赖**：`nsd: ^2.5.0`（mDNS 浏览，dart-native，Android + iOS）。

**新增 `app/lib/state/lan_scanner.dart`**：

`LanScanResult { String serverId; String name; String host; int port; String version; bool pairingOpen; bool alreadyPaired; }`

`Stream<List<LanScanResult>> scan()`：
1. 启动 `nsd` browse `_pawterm._tcp.local`，超时 3 秒
2. 同时启动子网扫描兜底：从 `connectivity_plus` + `network_info_plus` 拿到本机 IPv4 / 子网，构造 IP 列表，`Future.wait` 并发请 `/health`（限并发 30，单次 1.5s），命中后合并到结果集（按 serverId 去重）
3. 边发现边发射快照

**改 `app/lib/screens/add_connection_sheet.dart`**：

加新按钮"扫描局域网"。点击进入 `lan_scan_sheet.dart`（新文件）：
- 顶部 spinner + 已发现数量
- 列表：每行 hostname / serverId 后 6 位 / "已配对" 标签（如果 prefs 里有 serverId 匹配）/ "open" 配对状态
- 点击未配对项 → `pair_sheet.dart`：

**`pair_sheet.dart` 二选一**：

- "用 QR 扫描" —— 复用现有的 `qr_scan_screen.dart`，扫到 `pawterm://...?token=...` 后调 `/pair/qr-claim`
- "输入 PIN" —— 6 位数字输入框，调 `/pair/start`

成功后存 PairedServer 到 prefs，跳转主界面。

**已配对项**直接连接。

### Slice 5 — App：跨网络黏性重连

**改 `app/lib/state/server_config.dart`**：

模型升级为 `PairedServer`：

```dart
class PairedServer {
  final String serverId;     // 稳定标识
  final String deviceToken;  // 长期凭证
  final String name;
  final String host;         // 最近一次成功的 host:port
  final int port;
  final List<String> recentHosts; // 历史 host，离线时兜底用
  final DateTime lastSeen;
}
```

存到 SharedPreferences key `paired_servers`（JSON list）。

**自动续连逻辑**（启动时 + 网络切换时，用 `connectivity_plus` 监听）：

1. 拿出所有 PairedServer
2. 后台跑 `LanScanner.scan()` 3 秒
3. 对每个找到的 `LanScanResult`，按 `serverId` 匹配 PairedServer
4. 匹配上的 → 更新 `host` 字段、把旧 host 加到 `recentHosts`、保存
5. 当前激活的 PairedServer 如果 host 变了 → 触发 reconnect（重建 SSE / WS 连接）
6. 都没扫到 → 尝试 `recentHosts` 里的每个 host 跑 `/health` 探活

UI 表现：右上角连接状态指示器；切换网络时短暂"正在重连…"。

### Slice 6 — Homebrew tap（推迟到后续 PR）

不在本次范围。后续 PR 会做：
- 建 `Airoucat233/homebrew-pawterm` 仓库
- 写 `Formula/pawterm-server.rb`（depends_on `node@20`，含 `service` 块）
- `server/src/service.ts` 检测 brew 模式后委托给 `brew services`
- 新增 `server/scripts/release-brew.sh`

### Slice 8 — Web Admin 调试中心 + Phone-triggered 配对 + 自动 open 浏览器

**追加进本 PR**（2026-05-19 决定）—— 用户希望"一次到位"避免碎片化调试。

**Server 端新增**：

- `GET /admin/qr` (adminToken) → `{ content: string, svg: string }` —— content 是 `pawterm://...?token=...`，svg 是 inline SVG QR 字符串（库：`qrcode` npm 包）
- `POST /pair/request` (no auth) → body `{ deviceId, deviceName }` → 返回 `{ requestId, pollUrl }`；server 内存里存一条 `PairRequest { requestId, deviceId, deviceName, ip, createdAt, status: 'pending'|'approved'|'denied'|'expired' }`，60 秒过期；同时通过 SSE 推 `pair_request` 事件
- `POST /admin/pair-approve` (adminToken) → body `{ requestId }` → 标记 approved，颁发 deviceToken
- `POST /admin/pair-deny` (adminToken) → body `{ requestId }` → 标记 denied
- `GET /pair/poll/:requestId` (no auth) → 长轮询 30s，状态变化即返回 `{ status, deviceToken? }`
- `GET /admin/events` SSE (adminToken) → server-sent events：`pair_request`、`device_paired`、`device_revoked`、`device_connected`、`device_disconnected`、`server_status`
- 启动时若 `process.env.PAWTERM_NO_OPEN` 不为 `1`，调用 `open` (macOS) / `xdg-open` (Linux) 打开 `http://localhost:<port>/admin?token=<adminToken>`（仅 host=localhost/127.0.0.1/0.0.0.0 时）

**速率限制**：`/pair/request` 同一 IP 30 秒内只允许 1 个请求；总待批准请求数上限 5（防 spam）。

**Wire 协议**新增（`packages/shared/src/protocol.ts`）：

```ts
export interface QrResponse { content: string; svg: string }

export interface PairRequestRequest { deviceId: string; deviceName: string }
export interface PairRequestResponse { requestId: string; pollUrl: string }
export type PairPollResponse =
  | { status: 'pending' }
  | { status: 'approved'; deviceToken: string; serverId: string }
  | { status: 'denied' | 'expired' };

export type AdminEvent =
  | { type: 'pair_request'; requestId: string; deviceId: string; deviceName: string; ip: string; createdAt: number }
  | { type: 'device_paired'; deviceId: string; name: string }
  | { type: 'device_revoked'; deviceId: string }
  | { type: 'device_connected'; deviceId: string }
  | { type: 'device_disconnected'; deviceId: string }
  | { type: 'server_status'; pairedDevices: number; activeDevices: number };
```

**Web Admin 重做**（`web/src/`）：

单页面，黑色专业主题，包含：
- 顶部条：server 状态（🟢/🟡/🔴）、host:port、serverId 短码
- 左卡：大 QR 码 SVG 渲染、QR 内容下方有 "or use 6-digit PIN" 链接（点击触发 `/admin/pair-window` 显示 PIN）
- 右卡：状态摘要（port、serverId、device 计数、network IP）
- 中卡：已配对设备列表，每项有 "Revoke" 按钮
- 底卡：实时日志面板，订阅 `/admin/events` SSE，每条事件渲染成一行（时间戳 + icon + 描述）
- 配对请求 Modal：收到 `pair_request` 事件时弹出，居中遮罩，显示设备名 + IP，两个按钮 [✓ 批准] [✗ 拒绝]，调对应 admin endpoint

技术栈仍是已有的 Vite + React 18 + Tailwind 3 + Zustand。

**App 端**：

- 改 `pair_sheet.dart`：默认 tab 改成"请求配对"（auto request），原"输入 PIN"作为 fallback
- 新 flow：调 `POST /pair/request` → 显示"等待开发机批准…"loading + cancel → 长轮询 `/pair/poll/<id>` → 拿到 deviceToken 即完成

**SwiftBar plugin**（可选加分项，`scripts/swiftbar/pawterm.5s.sh`）：

```bash
#!/bin/bash
TOKEN=$(jq -r .token ~/.config/pawterm/config.json 2>/dev/null)
[ -z "$TOKEN" ] && echo "🐾 not configured" && exit
STATUS=$(curl -sf "http://localhost:8765/health" 2>/dev/null)
if [ -z "$STATUS" ]; then echo "🐾⚫"; exit; fi
DEVICES=$(curl -sf -H "Authorization: Bearer $TOKEN" "http://localhost:8765/admin/devices" | jq 'length')
echo "🐾 $DEVICES devices"
echo "---"
echo "Open Admin | href=http://localhost:8765/admin?token=$TOKEN"
echo "Show QR | href=http://localhost:8765/admin?token=$TOKEN#qr"
```

文件名前缀 `pawterm.5s.sh` 让 SwiftBar 每 5 秒刷新。

---

### Slice 7 — 自动更新（推迟到后续 PR）

**需求**：App 和 Server 各自支持"检查更新 → 一键更新"。

**Server 端（Node.js）**：

- 复用现有 `pawterm-server` CLI 的 `update` 子命令（`server/src/service.ts` 已有）—— 它做 `npm install -g pawterm-server@latest` 然后 `restart`
- 新增"自动检查"：server 启动时（以及之后每 24 小时）异步查 npm registry `https://registry.npmjs.org/pawterm-server/latest` 拿 `version`，与 `__SERVER_VERSION__` 比较
- 比较结果通过新 endpoint `GET /admin/update-status` 暴露给 App：
  ```ts
  interface UpdateStatus {
    currentVersion: string;
    latestVersion: string | null;   // null = 未联网或 npm 暂未响应
    updateAvailable: boolean;
    canSelfUpdate: boolean;          // true 当且仅当 server 是 npm 全局装或 brew 装
  }
  ```
- 新增 `POST /admin/update` (adminToken) → 触发 `update` 命令并立刻 200 OK（更新会让进程重启，App 端用心跳检测重连）
- brew 模式（slice 6 后）：`canSelfUpdate=true`，`update` 走 `brew upgrade pawterm-server && brew services restart pawterm-server`
- npm 模式：`canSelfUpdate=true`，走 `npm install -g pawterm-server@latest && pawterm-server restart`
- npx / pnpm 临时模式：`canSelfUpdate=false`，App 端只显示"有新版本"提示，按钮变灰，提示用户手动更新

**App 端（Flutter）**：

- GitHub Releases API 查最新版：`https://api.github.com/repos/Airoucat233/pawterm/releases/latest`（异步、5 分钟缓存）
- 对比 `package_info_plus` 拿到的当前 versionName
- 设置页加"检查更新"按钮 + 启动时静默检查
- 有新版 → 显示红点 + 提示"v0.x.x 可用，点击下载"
- 点击：调用 url_launcher 打开 release page 的 APK 链接（Android 浏览器接管下载 + 安装提示）
  - 进阶（如果时间够）：用 `flutter_inappwebview` 或新增 `app/lib/utils/apk_installer.dart` 直接调 Android `Intent.ACTION_INSTALL_PACKAGE`，免去用户切到浏览器
- 同时增加"检查服务器更新"卡片：调 `/admin/update-status` 显示 server 当前/最新版本；`updateAvailable && canSelfUpdate` 时显示"更新服务端"按钮；点击 → `POST /admin/update`，UI 显示"更新中…" + 心跳轮询 `/health` 看 version 跳变后退出 spinner

**Wire 协议**（加进 `protocol.ts`，但实施推迟）：

```ts
export interface UpdateStatus { ... }   // 见上
export interface UpdateTriggerResponse { ok: boolean; reason?: string }
```

**为何推迟**：自更涉及进程重启 + 跨平台权限（Android APK 安装需 `REQUEST_INSTALL_PACKAGES` 权限），单独一片好测试。本次 PR 已经很大。

---

## 兼容性

- **现有 QR 流程不变**：扫码拿 adminToken → `/pair/qr-claim` 是新路径，App 端走它换成 deviceToken。老 App（拿到 adminToken 直接用）仍可工作 —— adminToken 仍能通过鉴权
- **现有手动 IP + token 入口保留**：扫描失败时用户可以手动加
- **server 的 launchd/systemd `install` CLI 不动**：slice 6 才改

## 失败模式

- mDNS 在企业 Wi-Fi 被屏蔽 → 子网扫描兜底
- PIN 过期 / 输错 → 服务端 60 秒冷却防爆破，UI 显示明确错误
- 网络切换中间态（IP 暂无）→ App 端用 `recentHosts` 做 fallback 探活
- adminToken 泄露 → 用户重新跑 `pawterm-server pair --revoke-all` 即可吊销所有设备并轮换 token（管理 CLI 在 slice 3 加）

## 测试

- **Server unit (vitest)**：config.test.ts（serverId 持久化）、pair.test.ts（PIN 校验 / 速率限制 / 窗口过期 / deviceToken 颁发）
- **Server 集成**：手动跑 `pnpm dev:server`，curl 验各 endpoint
- **App**：`flutter analyze` 必过；功能验证靠用户手动测试（打 APK 后）

## 范围之外

- iOS 适配（nsd 包支持，但本次不验）
- App 端 PIN 输入的 UX 打磨（仅做能用版本，不做防误触动画）
- Web 管理面板的设备列表 UI（slice 3 提供 API，Web UI 后续）
