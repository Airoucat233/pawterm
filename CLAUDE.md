# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

# Claude Companion (PawTerm) 项目规范

PawTerm = 一台桥接 server（跑在开发机，调用 `claude` CLI）+ 一个 Flutter 手机 App + 一个 React Web 管理面板。手机/Web 通过 LAN / Tailscale 远程驱动 Claude Code。

---

## 仓库布局（pnpm workspace + Flutter）

- `server/` — Node.js 服务端（npm 包 `pawterm-server`，workspace 名 `@cc/server`）
- `web/` — Vite + React 19 管理面板（`@cc/web`）
- `packages/shared/` — server / web 共享的 TS 类型（`@pawterm/shared`，wire protocol 唯一来源）
- `app/` — Flutter 客户端（Riverpod + xterm；安卓为主，iOS 可打 IPA）
- `docs/` — 设计文档（debug pipeline、streaming response 等）

`pnpm-workspace.yaml` 只覆盖 TS 端三个包；`app/` 单独管。

---

## 常用命令

### 顶层（monorepo 根）

```bash
pnpm install              # 安装 TS 端依赖
pnpm dev                  # 同时跑 server + web
pnpm dev:server           # 只跑 server（端口 8765，监听 config.json）
pnpm dev:web              # 只跑 web
pnpm build                # 全量 build
pnpm typecheck            # 全量 tsc --noEmit
```

### Server 端

```bash
cd server
pnpm test                 # vitest run（一次性）
pnpm test:watch           # vitest watch
pnpm exec vitest run src/__tests__/event-buffer.test.ts   # 跑单个测试文件
```

### App 端（Flutter）

```bash
cd app
flutter pub get
flutter run               # 调试，需连真机/模拟器
```

---

## 构建 & 发布流程

**必须使用已写好的脚本，禁止手动执行 `flutter build` / `gh release` / `npm publish`。**

**所有发布操作（publish.sh / release.sh / build-apk.sh / build-ipa.sh）必须等用户明确说"发布"/"打包"/"release"后才能执行，不得自行决定触发。**

**`git push` 也必须等用户明确说"push"/"推送"后才能执行，不得在提交后自行 push。**

**`git merge` / `git rebase` 也必须等用户明确说"merge"/"合并"后才能执行，不得自行决定触发。**

| 操作 | 脚本 | 说明 |
|---|---|---|
| App 打包（Android APK） | `bash app/scripts/build-apk.sh` | 交互式 bump（same/build/patch/minor/major），更新 `pubspec.yaml`，产物落到 `app/build/app/outputs/flutter-apk/releases/<version>/` |
| App 打包（iOS IPA） | `bash app/scripts/build-ipa.sh` | |
| GitHub Release（App） | `bash app/scripts/release.sh` | 读 pubspec 版本，收集 APK/IPA，调 `gh release create`。**必须先跑打包脚本** |
| Server npm 发布 | `bash server/scripts/publish.sh` | 交互式 bump（same/patch/minor/major），更新 `package.json` → build dist → commit → `npm publish` |

`server/dist/` 在 `.gitignore` 中，不入 git；发布 npm 前 publish 脚本会自动 `npm run build`（tsup）。

---

## 测试 server（端口 8766）

`server/scripts/test-server.sh start|stop|restart|status|logs` 启一个**脱离 shell** 的常驻 server（nohup + disown），跑 `server/config.test.json`。专给**未重打包的 app** 用，**不要随意重启**——客户端连着的会断流。

主开发用 `pnpm dev:server`（8765，监听源码热重载）；测试服用 8766（不热重载，避免连接断）。两套 config、两套 SDK session map，互不影响。

---

## 架构要点

### Server（`server/src/index.ts` 入口）

- Fastify + `@fastify/websocket` + `@fastify/multipart` + CORS
- **认证**：所有 endpoint（除 `/health` 与 `/ws/shell`）必须带 `Authorization: Bearer <token>`，token 在 `~/.config/pawterm/config.json`。`/ws/shell` 在 WS `init` 消息里带 token
- **路径白名单**：所有文件相关 endpoint（`/fs/ls`、`/fs/cat`、`/fs/download`）走 `isPathAllowed()`，根据 `settings.projects[].path` 校验。**改动这块时务必保持白名单约束**——这是 LAN 部署唯一的安全边界
- **Chat 协议双轨**：
  - Flutter App 已迁移到 **REST + SSE**（`chat-rest.ts`，`GET /chat/:id/events`）
  - Web 管理面板还在用 **WebSocket**（`/ws/session`），等迁完再废 WS chat
  - 真实协议类型在 `packages/shared/src/protocol.ts`，server / web 都要从这里 import
- **Shell**：`ws-shell.ts` 用 `node-pty` 起真 PTY，handshake 走 init 消息（含 token + cwd + cols/rows）
- **Claude SDK 会话**：`session-manager.ts` 用 `@anthropic-ai/claude-agent-sdk` 的 streaming `query()`，输入端是 async generator —— 一个 WS 连接对应一个 SDK session，可以中途换 model / permission mode
- **Login shell PATH**：server 启动时跑 `$SHELL -ilc 'echo $PATH'` 抓完整 PATH（包含 nvm/homebrew/flutter 等）。`bypassPermissions` 模式必须额外传 `allowDangerouslySkipPermissions=true`
- **服务管理**：`pawterm-server install|start|stop|...` 在 `service.ts`，用 systemd / launchd 注册自启

### App（`app/lib/main.dart` 入口）

- Material 3 + 自定义 `AppTokens`（`theme.dart`）
- 状态管理：**Riverpod**（`ProviderScope` 包根；store 在 `state/`）
- API 客户端：`api/`（`chat_api.dart`、`sse_client.dart`、`sessions_api.dart` 等），wire 类型对应 shared protocol
- Tab 结构：`screens/tabs/{chat,files,git,shell}_tab.dart`，被 `main_shell.dart` 装配
- 全局 `routeObserver`：让 `ProjectPickerScreen` 在 `didPopNext` 时刷新 session 列表，否则缓存会让标题/最近时间停留在离开前

### Web（`web/src/`）

- Vite + React 18 + Tailwind 3 + Tanstack Query + Zustand
- xterm + addon-fit + addon-web-links 渲终端
- 主要给桌面浏览器做管理；功能比 App 少

---

## 改 wire protocol 的规矩

`packages/shared/src/protocol.ts` 是 server / app / web 三端的共同合约。**任何改动需要三端同步迁移**：

1. 改 `protocol.ts` 类型
2. server 端实现新字段（`chat-rest.ts` / `ws-shell.ts` / `session-manager.ts`）
3. web 端跟（`web/src/api/`）
4. App 端跟（`app/lib/api/protocol.dart`）—— Dart 类型手动同步，没有 codegen

`KNOWN_MODELS` 改了要同时检查 App 端 model 选择器和 Web 端 model 选择器。
