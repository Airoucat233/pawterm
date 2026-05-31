# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

# Claude Companion (PawTerm) 项目规范

PawTerm = 一台桥接 server（跑在开发机，调用 `claude` CLI）+ 一个 Flutter 手机 App + 一个 React Web 管理面板。手机/Web 通过 LAN / Tailscale 远程驱动 Claude Code。

---

## 仓库布局（pnpm workspace + Flutter）

- `server/` — Node.js 服务端（npm 包 `pawterm-server`，workspace 名 `@cc/server`）
- `web/` — Vite + React 18 管理面板（`@pawterm/web`）
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
flutter run               # 调试 Android，默认 flavor=prod；dev 用 --flavor dev
```

---

## 构建 & 发布流程

**必须使用已写好的脚本，禁止手动执行 `flutter build` / `gh release` / `npm publish`。**

**所有发布操作（publish.sh / release.sh / build-apk.sh / build-ipa.sh）必须等用户明确说"发布"/"打包"/"release"后才能执行，不得自行决定触发。**

**`git push` 也必须等用户明确说"push"/"推送"后才能执行，不得在提交后自行 push。**

**`git merge` / `git rebase` 也必须等用户明确说"merge"/"合并"后才能执行，不得自行决定触发。**

### 标准分支发布流程

发布采用三段式分支模型：

- `feature/*`：开发分支。只做功能开发、修复和本地验证，不发布。
- `feature/next`：集成和预发布分支。所有 feature 先合入 `feature/next`，验证通过后发 prerelease。
- `main`：稳定发布分支。只从 `feature/next` 合入确认过的版本，验证通过后发正式 release。

#### 1. feature 分支：开发与本地验证

从 `feature/next` 拉 feature：

```bash
git checkout feature/next
git pull origin feature/next
git checkout -b feature/xxx
```

开发时按影响范围验证。通用验证：

```bash
pnpm dev
pnpm typecheck
pnpm test:server
pnpm build
```

只改 server 时：

```bash
pnpm dev:server
pnpm typecheck:server
pnpm test:server
pnpm build:server
```

改 App / Mac 时额外验证对应构建：

```bash
pnpm build:app
pnpm build:mac
```

feature 验证通过后，提交并合入 `feature/next`。不得从 feature 直接合入 `main`。

#### 2. feature/next 分支：集成与 prerelease

`feature/next` 是预发布分支。feature 合入后先跑完整验证：

```bash
git checkout feature/next
git pull origin feature/next

pnpm typecheck
pnpm test:server
pnpm build
```

确认无问题后，按需要发布 prerelease：

```bash
pnpm release:pre          # App / GitHub prerelease
pnpm release:server:pre   # Server / npm prerelease dist-tag
```

预发布语义：

- App tag：`prerelease-v{semver}`
- Server tag：`prerelease-server-v{version}`
- npm dist-tag：`prerelease`

`release:pre` 和 `release:server:pre` 只能在 `feature/next` 执行。不要从 feature 分支发 prerelease。

#### 3. main 分支：稳定 release

确认 `feature/next` 的 prerelease 可用后，才把 `feature/next` 合入 `main`：

```bash
git checkout main
git pull origin main
git merge --no-ff feature/next
```

正式发布前再跑完整验证：

```bash
pnpm typecheck
pnpm test:server
pnpm build
```

验证通过后，按需要发布正式版：

```bash
pnpm release          # App / GitHub release
pnpm release:server   # Server / npm latest
```

正式发布语义：

- App tag：`release-v{semver}`
- Server tag：`release-server-v{version}`
- npm dist-tag：默认 `latest`
- 如果 Server 当前版本是 `X.Y.Z-prerelease.N`，正式发布应 promote 成 `X.Y.Z`，不得把 prerelease 版本发到 `latest`。

`release` 和 `release:server` 只能在 `main` 执行。`main` 只接受从 `feature/next` 合并，不直接接 feature。

### 发布方式 A：本地构建 → 上传

适合想在本地验证产物再发出去的场景。

```bash
bash app/scripts/build-apk.sh --prod # 交互式 bump → 构建正式 APK → dist/
bash mac/scripts/build.sh --prod     # 交互式 bump（可选 same）→ 构建 PawTerm.app → dist/
bash scripts/release.sh --local      # 检查 dist/ 产物 → gh release create → push tag
                                     # tag 会触发 CI，但 CI 检测到 release 已存在会跳过构建
```

### 发布方式 B：CI 构建

适合直接让 CI 打包的场景，本地只负责 bump + 推 tag。

```bash
bash scripts/release.sh              # 交互式 bump → commit → push main → push tag → CI 构建
```

### 预发布与本地 dev 包

- GitHub Release 只发布正式 App 包名：Android `com.airoucat.pawterm`、macOS `com.airoucat.pawterm`。
- 稳定版 tag：`release-v{semver}`；预发布 tag：`prerelease-v{semver}`。
- `scripts/release.sh --prerelease` 发布预发布，仍然构建正式 App 包名，供 App 内“预发布频道”覆盖升级。
- `app/scripts/build-apk.sh --dev` 只用于本地开发包，Android 包名 `com.airoucat.pawterm.dev`，显示名 `PawTerm Dev`，默认只构建 arm64，并通过 `pawtermAbiFilter=arm64-v8a` 过滤 Android 原生依赖 ABI；产物留在 `app/build/app/outputs/flutter-apk/`，不得上传 GitHub Release。
- `mac/scripts/build.sh --dev [--install]` 只用于本地 `PawTermDev.app`，bundle id `com.airoucat.pawterm.dev`，不得上传 GitHub Release。
- 正式 Mac App 菜单里有 `Prerelease channel` 开关；关闭时检查 `release-v*` latest，打开时检查 `prerelease-v*`。
- Mac dev build 不检查 GitHub App 更新，只保留 server 更新检查，避免提示安装正式版覆盖开发版语义。
- `scripts/release.sh --dev` 仅是旧参数兼容别名，新增用法必须写 `--prerelease`。
- Android 正式/预发布 release 不得使用 debug key；CI 需要 `ANDROID_KEYSTORE_BASE64`、`ANDROID_KEYSTORE_PASSWORD`、`ANDROID_KEY_ALIAS`、`ANDROID_KEY_PASSWORD` secrets，本地可用 `app/android/key.properties`。

### Server 发布（独立）

```bash
bash server/scripts/publish.sh              # main 分支：交互式 bump/promote → commit → push → npm publish latest
bash server/scripts/publish.sh --prerelease # feature/next 分支：交互式 bump → push → npm publish prerelease dist-tag
```

Server 没有独立 dev 安装身份，预发布会覆盖同一个 `pawterm-server` 全局包；不要再用 dev 命名。Server 预发布版本后缀为 `-prerelease.N`，git tag 为 `prerelease-server-v{version}`，npm dist-tag 为 `prerelease`，安装命令为 `npm install -g pawterm-server@prerelease`。`--dev` 只保留为旧参数兼容别名。

### 脚本一览

| 脚本 | 说明 |
|---|---|
| `app/scripts/build-apk.sh --prod` | bump + 构建正式 APK，产物到 `dist/`；`CI=true` 时跳过 bump |
| `app/scripts/build-apk.sh --dev` | 本地构建 arm64 `PawTerm Dev` APK，产物名 `pawterm-dev-*`，不复制到 `dist/`；需要全 ABI 时加 `--all-abi` |
| `mac/scripts/build.sh --prod` | bump + 构建 PawTerm.app zip，产物到 `dist/`；`CI=true` 时跳过 bump |
| `mac/scripts/build.sh --dev [--install]` | 本地构建/安装 PawTermDev.app，不发布 |
| `scripts/release.sh --local` | 验证 `dist/` 产物精确匹配当前版本 → gh release create → push tag |
| `scripts/release.sh` | 交互式 bump → commit pubspec → push main → push tag → CI 构建 |
| `scripts/release.sh --prerelease` | 在 `feature/next` 上交互式 bump → push `feature/next` → push `prerelease-v*` tag → CI 构建预发布 |
| `server/scripts/publish.sh` | 交互式 bump → commit package.json → push → npm publish latest |
| `server/scripts/publish.sh --prerelease` | 在 `feature/next` 上交互式 bump → push `feature/next` → push `prerelease-server-v*` tag → npm publish `--tag prerelease` |

`dist/` 文件命名：`pawterm-{app-version}-arm64-v8a.apk`、`pawterm-{app-version}-armeabi-v7a.apk`、`PawTerm-{mac-version}-mac.zip`。app 版本来自 `pubspec.yaml`，mac 版本独立来自 `mac/Info.plist`。

`server/dist/` 和 `server/dist-web/` 在 `.gitignore` 中，不入 git；publish.sh 发布前必须先构建 `web/dist`，再执行 server build，把 Web 管理面板复制进 npm 包。

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
