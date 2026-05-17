# Chat 视图 UX 完善 实现 Plan（Spec A）

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 [Spec A](../specs/2026-05-17-chat-view-ux-polish-design.md) 的四项 chat 视图改进落地：按钮黑白风、附件上传、tool 输出对象 JSON 修复、AskUserQuestion 交互渲染。

**Architecture:** Server 侧在现有 Fastify + claude-agent-sdk 上加 `/upload` 端点和一个自定义 MCP server (`ask-user-question`)；Client 侧扩展 `_Composer` 并新增 `AskUserQuestionWidget`；WS 协议新增 `answer_question` 一种 client→server 消息。引入 vitest 给 server 端纯函数加最小测试。

**Tech Stack:** Flutter (Dart), TypeScript + Fastify 5, `@anthropic-ai/claude-agent-sdk` 0.2.141, vitest（新引入）, `@fastify/multipart`（新引入）, `file_picker` Flutter pub 包（新引入）。

---

## 文件结构

**新建：**
- `server/src/upload.ts` — `POST /upload` Fastify route handler
- `server/src/ask-user-tool.ts` — `AskUserQuestionRegistry` 类 + `makeAskUserMcpServer()` 工厂
- `server/src/__tests__/serialize.test.ts` — `normalizeToolResultContent` 的快照测试
- `server/src/__tests__/ask-user-tool.test.ts` — `AskUserQuestionRegistry` 单元测试
- `server/vitest.config.ts` — vitest 配置
- `app/lib/api/upload_api.dart` — Flutter 上传 HTTP 客户端
- `app/lib/widgets/ask_user_question.dart` — `AskUserQuestionWidget`（live + answered 双态）

**修改：**
- `server/package.json` — 加 `vitest` (dev) + `@fastify/multipart` + `zod` 显式依赖
- `server/src/serialize.ts` — 重写 `normalizeToolResultContent`
- `server/src/index.ts` — 注册 multipart 插件 + `/upload` 路由
- `server/src/session-manager.ts` — 注入 askRegistry + mcpServers + `answerQuestion()` 方法
- `server/src/ws-chat.ts` — 每 socket 一个 registry + `answer_question` case + 断线 cleanup
- `packages/shared/src/protocol.ts` — `ChatClientMessage` 加 `answer_question` 一支
- `app/pubspec.yaml` — 加 `file_picker: ^8.0.0` 依赖
- `app/lib/screens/tabs/chat_tab.dart` — `_SendOrStopButton` 改造 + `_Composer` 加附件 + 加 `_sendAnswerQuestion()`
- `app/lib/widgets/message_view.dart` — `ToolUseBlock` 分发新增 AskUserQuestion 分支

---

## Pre-flight：清理工作树

工作树当前有未提交的改动（早先的气泡 / 主题改动 + 用户自己的 `_pending` 队列）。开工前必须先处理。

- [ ] **Step 0.1: 看当前未提交改动**

Run: `git status --short`

Expected output（应该看到这类输出）:
```
 M app/lib/api/protocol.dart
 M app/lib/screens/tabs/chat_tab.dart
 M app/lib/theme.dart
 M app/lib/widgets/message_view.dart
 M app/lib/widgets/...
 M packages/shared/src/protocol.ts
 M server/src/ws-chat.ts
```

- [ ] **Step 0.2: 决定如何处理**

如果这些是之前讨论过的 "气泡柔化 + theme 选择色 + 用户的 _pending 队列" —— 先单独 commit 一次再开工：

```bash
git add app/lib/widgets/message_view.dart app/lib/theme.dart app/lib/screens/tabs/chat_tab.dart
git commit -m "feat(chat): soften user bubble, set text selection theme, add pending queue"
```

如果还有别的杂项，按你的判断分别 commit 或 stash。

**继续之前** 必须满足：`git status --short` 输出为空（或只剩明确无关此 plan 的内容）。

- [ ] **Step 0.3: 锁定 spec 已合并**

Run: `git log --oneline -3`

Expected: 看到 `docs(spec): add chat-view UX polish design (Spec A)` 这个 commit。

---

## Task 1: §3 tool_result JSON 修复 + 引入 vitest

**目标**：先做最小、收益最直接的一项。引入 vitest 顺便给序列化层兜底测试。

**Files:**
- Modify: `server/package.json`
- Create: `server/vitest.config.ts`
- Create: `server/src/__tests__/serialize.test.ts`
- Modify: `server/src/serialize.ts:150-162`

### Step 1.1: 装 vitest

- [ ] Run:

```bash
cd /Users/airoucat/workspace/shulex/claude-companion/server
pnpm add -D vitest
```

Expected: `package.json` 出现 `"vitest": "^x.y.z"` 在 `devDependencies` 里。

### Step 1.2: 加 vitest 配置

- [ ] Create `server/vitest.config.ts`:

```ts
import { defineConfig } from 'vitest/config';

export default defineConfig({
  test: {
    include: ['src/**/__tests__/*.test.ts'],
    environment: 'node',
  },
});
```

### Step 1.3: 加 test 脚本

- [ ] 修改 `server/package.json`，在 `scripts` 里加：

```json
"test": "vitest run",
"test:watch": "vitest"
```

最终 `scripts` 字段应该是（基于现有内容增量）：
```json
"scripts": {
  "dev": "tsx watch src/index.ts",
  "build": "tsc -p tsconfig.json",
  "start": "node dist/index.js",
  "typecheck": "tsc --noEmit",
  "test": "vitest run",
  "test:watch": "vitest",
  "postinstall": "node scripts/fix-pty-perms.cjs"
}
```

### Step 1.4: 写失败测试

- [ ] Create `server/src/__tests__/serialize.test.ts`:

```ts
import { describe, expect, it } from 'vitest';
import { messageToWire } from '../serialize.js';

describe('normalizeToolResultContent (via messageToWire user msg)', () => {
  function wireToolResultContent(content: unknown) {
    const wire = messageToWire({
      type: 'user',
      message: {
        role: 'user',
        content: [{ type: 'tool_result', tool_use_id: 'x', content, is_error: false }],
      },
    });
    return (wire.content[0] as any).content;
  }

  it('passes plain strings through unchanged', () => {
    expect(wireToolResultContent('hello')).toBe('hello');
  });

  it('preserves text blocks with string text', () => {
    expect(wireToolResultContent([{ type: 'text', text: 'abc' }])).toEqual([
      { type: 'text', text: 'abc' },
    ]);
  });

  it('JSON-stringifies object-shaped text fields (this is the [object Object] bug)', () => {
    const result = wireToolResultContent([{ type: 'text', text: { a: 1, b: [2, 3] } }]);
    expect(result).toEqual([
      { type: 'text', text: '{\n  "a": 1,\n  "b": [\n    2,\n    3\n  ]\n}' },
    ]);
  });

  it('JSON-stringifies entire object items without text field', () => {
    const result = wireToolResultContent([{ some: 'data', nested: { x: 1 } }]);
    expect(result).toEqual([
      {
        type: 'text',
        text: '{\n  "some": "data",\n  "nested": {\n    "x": 1\n  }\n}',
      },
    ]);
  });

  it('JSON-stringifies whole-object content (non-array, non-string)', () => {
    expect(wireToolResultContent({ k: 'v' })).toBe('{\n  "k": "v"\n}');
  });

  it('preserves image content blocks as-is', () => {
    const img = { type: 'image', source: { data: 'b64...', media_type: 'image/png' } };
    expect(wireToolResultContent([img])).toEqual([img]);
  });

  it('handles null content', () => {
    expect(wireToolResultContent(null)).toBeNull();
  });
});
```

### Step 1.5: 跑测试确认失败

- [ ] Run:

```bash
cd /Users/airoucat/workspace/shulex/claude-companion/server
pnpm test
```

Expected: 5/7 测试失败（"JSON-stringifies object-shaped text fields"、"JSON-stringifies entire object items"、"JSON-stringifies whole-object content"、"preserves image content blocks"、和 null 之外的对象 case），因为当前实现用 `String(obj)`。

### Step 1.6: 修 serialize.ts

- [ ] Modify `server/src/serialize.ts`，把 `normalizeToolResultContent` 整体替换为：

```ts
function normalizeToolResultContent(content: unknown): any {
  if (content == null) return null;
  if (typeof content === 'string') return content;
  if (Array.isArray(content)) {
    return content.map((item: any) => {
      if (item && typeof item === 'object' && item.type === 'image') {
        // Preserve image blocks as-is — they have base64 source we shouldn't stringify.
        return item;
      }
      if (item && typeof item === 'object' && 'text' in item) {
        const t = item.text;
        const text = typeof t === 'string' ? t : JSON.stringify(t, null, 2);
        return { type: 'text', text };
      }
      // Anything else (including raw JSON objects from MCP tools): stringify whole item.
      return { type: 'text', text: JSON.stringify(item, null, 2) };
    });
  }
  if (typeof content === 'object') {
    return JSON.stringify(content, null, 2);
  }
  return String(content);
}
```

### Step 1.7: 跑测试确认通过

- [ ] Run:

```bash
pnpm test
```

Expected: 7/7 PASS.

### Step 1.8: 跑 typecheck

- [ ] Run:

```bash
pnpm typecheck
```

Expected: 无 error。

### Step 1.9: Commit

- [ ] Run:

```bash
cd /Users/airoucat/workspace/shulex/claude-companion
git add server/package.json server/vitest.config.ts server/src/__tests__/serialize.test.ts server/src/serialize.ts
git commit -m "$(cat <<'EOF'
fix(serialize): JSON.stringify object tool_result content

Replaces String(obj) with JSON.stringify(obj, null, 2) so MCP tools
returning structured data no longer render as "[object Object]" in
the client. Image blocks are preserved as-is.

Adds vitest + snapshot tests for normalizeToolResultContent.
EOF
)"
```

---

## Task 2: §1 发送 / 停止按钮黑白风改造

**目标**：替换 `_SendOrStopButton` 的视觉规格。无 server / 协议改动。

**Files:**
- Modify: `app/lib/screens/tabs/chat_tab.dart::_SendOrStopButton`（当前约在 990-1031 行）

### Step 2.1: 替换 _SendOrStopButton 实现

- [ ] Open `app/lib/screens/tabs/chat_tab.dart`，找到 `_SendOrStopButton` 类（grep `class _SendOrStopButton`），整段替换为：

```dart
/// 输入框右侧的 40×40 圆形按钮（黑白主题，对照 cxclaw）。
/// - busy=false → 发送上箭头
/// - busy=true  → 停止方块（同一种背景，仅图标变）
/// - 不可用    → 浅灰
class _SendOrStopButton extends StatefulWidget {
  final bool busy;
  final bool canSend;
  final VoidCallback onSubmit;
  final VoidCallback onStop;
  const _SendOrStopButton({
    required this.busy,
    required this.canSend,
    required this.onSubmit,
    required this.onStop,
  });

  @override
  State<_SendOrStopButton> createState() => _SendOrStopButtonState();
}

class _SendOrStopButtonState extends State<_SendOrStopButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    final dark = Theme.of(context).brightness == Brightness.dark;

    // 主题色：亮模式黑底，暗模式近白底。按下时 / 不可用时颜色降级。
    final Color bg;
    final Color fg;
    if (!widget.canSend && !widget.busy) {
      bg = dark ? t.borderSubt : const Color(0xFFD0D5DD);
      fg = dark ? t.textDim : Colors.white;
    } else {
      bg = dark ? t.text : const Color(0xFF101828);
      fg = dark ? const Color(0xFF0B1210) : Colors.white;
    }

    return GestureDetector(
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) => setState(() => _pressed = false),
      onTapCancel: () => setState(() => _pressed = false),
      onTap: widget.busy
          ? widget.onStop
          : (widget.canSend ? widget.onSubmit : null),
      child: AnimatedScale(
        scale: _pressed ? 0.96 : 1.0,
        duration: const Duration(milliseconds: 100),
        curve: Curves.easeOut,
        child: Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: bg,
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.15),
                blurRadius: 6,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          alignment: Alignment.center,
          child: widget.busy
              ? Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(
                    color: fg,
                    borderRadius: BorderRadius.circular(2),
                  ),
                )
              : Icon(Icons.arrow_upward_rounded, size: 18, color: fg),
        ),
      ),
    );
  }
}
```

### Step 2.2: 跑 flutter analyze 确认无 error

- [ ] Run:

```bash
cd /Users/airoucat/workspace/shulex/claude-companion/app
flutter analyze lib/screens/tabs/chat_tab.dart
```

Expected: 无 error。若有 `_attempting` 未使用的 warning，是预存在的，跟本任务无关。

### Step 2.3: 手动 smoke

- [ ] Run app（`flutter run`），亮 / 暗模式各看一遍：
  - 没输入文字 → 按钮浅灰
  - 输入文字 → 按钮黑/白主色，箭头清晰
  - 发送中 → 按钮变方块（同色），点击可中断
  - 按下时有 scale 反馈

### Step 2.4: Commit

- [ ] Run:

```bash
git add app/lib/screens/tabs/chat_tab.dart
git commit -m "style(composer): black-white send/stop button (cxclaw-style)"
```

---

## Task 3: §2 Server 端 `/upload` 端点

**目标**：把附件接到 server 的 cwd 下。

**Files:**
- Modify: `server/package.json`
- Create: `server/src/upload.ts`
- Modify: `server/src/index.ts:1-20, 167-170`

### Step 3.1: 装 multipart 插件

- [ ] Run:

```bash
cd /Users/airoucat/workspace/shulex/claude-companion/server
pnpm add @fastify/multipart
```

Expected: `package.json` 加 `"@fastify/multipart": "^9.x.x"`（具体版本号 pnpm 决定）。

### Step 3.2: 写 upload.ts

- [ ] Create `server/src/upload.ts`:

```ts
import type { FastifyInstance, FastifyRequest, FastifyReply } from 'fastify';
import { mkdir, writeFile } from 'node:fs/promises';
import { join, resolve } from 'node:path';

import { isPathAllowed } from './config.js';

const MAX_FILE_BYTES = 25 * 1024 * 1024; // 25 MB

/**
 * Sanitize a filename so it stays a single path segment.
 * - drop path separators
 * - keep ASCII letters / digits / . - _ ; replace others with _
 * - collapse repeats; trim leading dots (no hidden files)
 */
function sanitize(name: string): string {
  const base = name.replace(/[/\\]/g, '');
  let out = '';
  for (const ch of base) {
    out += /[A-Za-z0-9._\-]/.test(ch) ? ch : '_';
  }
  out = out.replace(/_+/g, '_').replace(/^\.+/, '');
  return out || 'file';
}

function timestamp(): string {
  const d = new Date();
  const pad = (n: number, w = 2) => String(n).padStart(w, '0');
  return (
    `${d.getFullYear()}${pad(d.getMonth() + 1)}${pad(d.getDate())}-` +
    `${pad(d.getHours())}${pad(d.getMinutes())}${pad(d.getSeconds())}-` +
    `${pad(d.getMilliseconds(), 3)}`
  );
}

export async function registerUpload(app: FastifyInstance): Promise<void> {
  app.post('/upload', async (req: FastifyRequest, reply: FastifyReply) => {
    const cwd = (req.query as { cwd?: string }).cwd;
    if (!cwd) {
      reply.code(400);
      return { error: 'cwd required' };
    }
    const abs = resolve(cwd);
    if (!isPathAllowed(abs)) {
      reply.code(403);
      return { error: 'cwd not allowed' };
    }

    const part = await req.file({ limits: { fileSize: MAX_FILE_BYTES } });
    if (!part) {
      reply.code(400);
      return { error: 'no file' };
    }

    const buf = await part.toBuffer();
    if (part.file.truncated) {
      reply.code(413);
      return { error: `file exceeds ${MAX_FILE_BYTES} bytes` };
    }

    const dir = join(abs, '.claude', 'attachments');
    await mkdir(dir, { recursive: true });
    const filename = `${timestamp()}-${sanitize(part.filename)}`;
    const dest = join(dir, filename);
    await writeFile(dest, buf);

    return { path: dest, size: buf.length };
  });
}
```

### Step 3.3: 注册到 index.ts

- [ ] Modify `server/src/index.ts`：

在文件顶部 import 区域加：
```ts
import multipart from '@fastify/multipart';
import { registerUpload } from './upload.js';
```

在 `await app.register(websocketPlugin);` 这行之后（约 23 行）加：
```ts
await app.register(multipart, { limits: { fileSize: 25 * 1024 * 1024 } });
```

在 `await registerSessionsApi(app);` 这行之后（约 168 行）加：
```ts
await registerUpload(app);
```

### Step 3.4: 跑 typecheck

- [ ] Run:

```bash
pnpm typecheck
```

Expected: 无 error。

### Step 3.5: 手动 smoke（启动 server + curl）

- [ ] 启 server（独立 terminal）：

```bash
pnpm dev
```

等到 `Claude Companion server v0.2.0 on http://...`。

- [ ] 准备一个测试文件 + 一个 `cwd`（需要是 config 里 whitelisted 的项目）：

```bash
# 用你配置文件里某个 project 路径替换 <CWD>
echo "hello attachment" > /tmp/test.txt
curl -F "file=@/tmp/test.txt" "http://localhost:8787/upload?cwd=$(echo <CWD> | jq -sRr @uri)"
```

Expected: 返回 `{"path":"<CWD>/.claude/attachments/2026...-test.txt","size":16}`。
检查文件确实落地：`ls -la <CWD>/.claude/attachments/`。

- [ ] 再验证拒绝路径：

```bash
curl -F "file=@/tmp/test.txt" "http://localhost:8787/upload?cwd=/tmp"
```

Expected：HTTP 403，`{"error":"cwd not allowed"}`（除非你恰好 whitelist 了 `/tmp`）。

- [ ] 验证超大文件被拒：

```bash
dd if=/dev/zero of=/tmp/big.bin bs=1M count=26
curl -F "file=@/tmp/big.bin" "http://localhost:8787/upload?cwd=<CWD>"
```

Expected: HTTP 413 + `{"error":"file exceeds ..."}`。

### Step 3.6: Commit

- [ ] Run:

```bash
git add server/package.json server/pnpm-lock.yaml server/src/upload.ts server/src/index.ts
# 注意如果 pnpm-lock.yaml 在仓库根目录就 git add 根目录的 lock
git commit -m "feat(server): POST /upload endpoint for chat attachments"
```

---

## Task 4: §2 Client 端附件上传集成

**目标**：composer 加 `+` 按钮 + 上传 chip 行 + 发送时拼接路径。

**Files:**
- Modify: `app/pubspec.yaml`
- Create: `app/lib/api/upload_api.dart`
- Modify: `app/lib/screens/tabs/chat_tab.dart` (`_Composer` + 新增 `_AttachmentChip` + `_AttachmentState`)

### Step 4.1: 加 file_picker 依赖

- [ ] Modify `app/pubspec.yaml`，在 `dependencies:` 下加：

```yaml
  file_picker: ^8.0.0
```

- [ ] Run:

```bash
cd /Users/airoucat/workspace/shulex/claude-companion/app
flutter pub get
```

Expected: 无 error，`pubspec.lock` 更新。

### Step 4.2: 写 upload_api.dart

- [ ] Create `app/lib/api/upload_api.dart`:

```dart
import 'dart:io';

import 'package:http/http.dart' as http;
import 'dart:convert';

class UploadedFile {
  final String path;
  final int size;
  UploadedFile({required this.path, required this.size});

  factory UploadedFile.fromJson(Map<String, dynamic> json) =>
      UploadedFile(path: json['path'] as String, size: json['size'] as int);
}

class UploadException implements Exception {
  final int status;
  final String message;
  UploadException(this.status, this.message);
  @override
  String toString() => 'UploadException($status): $message';
}

class UploadApi {
  final String httpBase;
  UploadApi(this.httpBase);

  Future<UploadedFile> upload(File file, String cwd) async {
    final uri = Uri.parse('$httpBase/upload').replace(queryParameters: {'cwd': cwd});
    final req = http.MultipartRequest('POST', uri);
    req.files.add(await http.MultipartFile.fromPath('file', file.path));
    final streamed = await req.send();
    final resp = await http.Response.fromStream(streamed);
    if (resp.statusCode >= 200 && resp.statusCode < 300) {
      return UploadedFile.fromJson(jsonDecode(resp.body) as Map<String, dynamic>);
    }
    String msg = resp.body;
    try {
      msg = (jsonDecode(resp.body) as Map<String, dynamic>)['error']?.toString() ?? resp.body;
    } catch (_) {}
    throw UploadException(resp.statusCode, msg);
  }
}
```

### Step 4.3: 在 chat_tab.dart 加附件状态模型

- [ ] 在 `chat_tab.dart` 顶部（其它类定义之间，建议放在 `_HistoryPage` 后面）加：

```dart
enum _AttachmentStatus { uploading, ready, failed }

class _AttachmentState {
  final String localName;
  final String localPath;
  String? remotePath;
  String? errorMsg;
  _AttachmentStatus status;
  _AttachmentState({
    required this.localName,
    required this.localPath,
    required this.status,
    this.remotePath,
    this.errorMsg,
  });
}
```

### Step 4.4: 在 _ChatTabState 加附件管理逻辑

- [ ] 在 `_ChatTabState` 类里（与 `_pending` 同区域）加状态：

```dart
final List<_AttachmentState> _attachments = [];
```

- [ ] 加方法（放在类的末尾、`dispose()` 之前任意位置都行）：

```dart
Future<void> _pickAndUploadAttachments() async {
  // 延迟 import，避免顶部加 file_picker import 用不上时也被分析。
  // 但 Dart 没法做 lazy import，所以还是顶部加：
  //   import 'package:file_picker/file_picker.dart';
  // —— 这一步在 step 4.5 做。
  final result = await FilePicker.platform.pickFiles(allowMultiple: true);
  if (result == null) return;
  final session = ref.read(currentSessionProvider);
  if (session == null) return;
  final config = ref.read(activeConnectionProvider);
  if (config == null) return;
  final api = UploadApi(config.httpBase);
  for (final pickedFile in result.files) {
    final path = pickedFile.path;
    if (path == null) continue;
    final state = _AttachmentState(
      localName: pickedFile.name,
      localPath: path,
      status: _AttachmentStatus.uploading,
    );
    setState(() => _attachments.add(state));
    // 不 await：并行上传
    unawaited(_uploadOne(api, state, session.cwd));
  }
}

Future<void> _uploadOne(UploadApi api, _AttachmentState state, String cwd) async {
  try {
    final result = await api.upload(File(state.localPath), cwd);
    if (!mounted) return;
    setState(() {
      state.remotePath = result.path;
      state.status = _AttachmentStatus.ready;
    });
  } catch (e) {
    if (!mounted) return;
    setState(() {
      state.errorMsg = e.toString();
      state.status = _AttachmentStatus.failed;
    });
  }
}

void _removeAttachment(_AttachmentState a) {
  setState(() => _attachments.remove(a));
}

Future<void> _retryAttachment(_AttachmentState a) async {
  final session = ref.read(currentSessionProvider);
  final config = ref.read(activeConnectionProvider);
  if (session == null || config == null) return;
  setState(() {
    a.status = _AttachmentStatus.uploading;
    a.errorMsg = null;
  });
  await _uploadOne(UploadApi(config.httpBase), a, session.cwd);
}

bool get _attachmentsAllReady =>
    _attachments.every((a) => a.status == _AttachmentStatus.ready);
```

### Step 4.5: 顶部加 imports

- [ ] 在 `chat_tab.dart` 顶部 import 区追加：

```dart
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import '../../api/upload_api.dart';
```

（如果已有 `dart:io` / `dart:async` 则跳过对应行；`unawaited` 在 `dart:async`）

### Step 4.6: 改 _submit 把附件路径拼进文本

- [ ] 找到 `chat_tab.dart` 里的 `_submit()`（grep `void _submit`）方法，在准备发送 text 之前增加附件拼接逻辑。具体位置：取出 `text` 之后、`_channel!.sink.add(...)` 之前。

把发送文本组装替换为：
```dart
final raw = _textController.text.trim();
final attachLines = _attachments
    .where((a) => a.status == _AttachmentStatus.ready && a.remotePath != null)
    .map((a) => '`${a.remotePath!}`')
    .toList();
final text = attachLines.isEmpty
    ? raw
    : '$raw\n\n附件：\n${attachLines.join('\n')}';
if (text.isEmpty) return;
// ... 现有的 _channel sink.add 走 text 这个变量
```

发送成功后清空附件（`_textController.clear();` 那行附近加）：
```dart
setState(() => _attachments.clear());
```

发送禁用条件加上"附件全 ready"，把发送按钮调用点的 `canSend` 表达式改为：
```dart
final canSend = _connected && !_busy && _attachmentsAllReady;
```

（注：当前代码 `canSend` 在 `_Composer.build()` 内由 `connected && !busy` 决定；改这处后还要把 `_attachmentsAllReady` 通过参数传给 `_Composer`）

### Step 4.7: 改 _Composer 接收附件状态 + 加 chip 行 + 加 `+` 按钮

- [ ] 改 `_Composer` 构造器，新增参数：

```dart
class _Composer extends ConsumerWidget {
  final TextEditingController controller;
  final bool connected;
  final bool busy;
  final List<_AttachmentState> attachments;
  final bool attachmentsAllReady;
  final VoidCallback onPickAttachment;
  final void Function(_AttachmentState) onRemoveAttachment;
  final void Function(_AttachmentState) onRetryAttachment;
  final VoidCallback onSubmit;
  final VoidCallback onStop;
  final void Function(ModelOption) onSwitchModel;
  final void Function(CcPermissionMode) onSwitchPermissionMode;
  const _Composer({
    required this.controller,
    required this.connected,
    required this.busy,
    required this.attachments,
    required this.attachmentsAllReady,
    required this.onPickAttachment,
    required this.onRemoveAttachment,
    required this.onRetryAttachment,
    required this.onSubmit,
    required this.onStop,
    required this.onSwitchModel,
    required this.onSwitchPermissionMode,
  });
  // ...
}
```

- [ ] 在 `_Composer.build()` 内，把现有的 `Column(children: [...])` 内容调整为三段（附件行 / 文本框行 / 工具栏行）：

```dart
return SafeArea(
  top: false,
  child: Padding(
    padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
    child: Container(
      decoration: BoxDecoration(
        color: t.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: t.border, width: 0.5),
      ),
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 6),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 附件 chip 行（非空时显示）
          if (attachments.isNotEmpty) ...[
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final a in attachments)
                    _AttachmentChip(
                      state: a,
                      onRemove: () => onRemoveAttachment(a),
                      onRetry: () => onRetryAttachment(a),
                    ),
                ],
              ),
            ),
          ],
          // 输入框 + 发送按钮
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: TextField(
                  controller: controller,
                  minLines: 2,
                  maxLines: 6,
                  enabled: connected,
                  cursorColor: t.accent,
                  style: TextStyle(fontSize: 14, color: t.text, height: 1.4),
                  decoration: InputDecoration(
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    disabledBorder: InputBorder.none,
                    isDense: true,
                    filled: false,
                    contentPadding: const EdgeInsets.symmetric(vertical: 4),
                    hintText: connected ? 'Ask Claude…' : 'Connecting…',
                    hintStyle: TextStyle(color: t.textDim, fontSize: 14),
                  ),
                  textInputAction: TextInputAction.newline,
                  keyboardType: TextInputType.multiline,
                ),
              ),
              const SizedBox(width: 8),
              _SendOrStopButton(
                busy: busy,
                canSend: connected && !busy && attachmentsAllReady,
                onSubmit: onSubmit,
                onStop: onStop,
              ),
            ],
          ),
          const SizedBox(height: 4),
          // 工具栏
          Row(
            children: [
              // [+] 上传按钮
              GestureDetector(
                onTap: connected ? onPickAttachment : null,
                child: Container(
                  width: 32,
                  height: 32,
                  alignment: Alignment.center,
                  child: Icon(
                    Icons.add_rounded,
                    size: 20,
                    color: connected ? t.textMuted : t.textDim,
                  ),
                ),
              ),
              const SizedBox(width: 4),
              _PermissionModePicker(
                current: ref.watch(permissionModeProvider),
                onPick: onSwitchPermissionMode,
              ),
              _ModelPicker(current: model, onPick: onSwitchModel),
              const Spacer(),
            ],
          ),
        ],
      ),
    ),
  ),
);
```

### Step 4.8: 写 _AttachmentChip 组件

- [ ] 在 `chat_tab.dart` 文件末尾（或紧跟 `_SendOrStopButton` 后）新增：

```dart
class _AttachmentChip extends StatelessWidget {
  final _AttachmentState state;
  final VoidCallback onRemove;
  final VoidCallback onRetry;
  const _AttachmentChip({
    required this.state,
    required this.onRemove,
    required this.onRetry,
  });

  IconData _iconForName(String name) {
    final lower = name.toLowerCase();
    if (RegExp(r'\.(png|jpg|jpeg|webp|heic|heif|gif|bmp)$').hasMatch(lower)) {
      return Icons.image_outlined;
    }
    if (lower.endsWith('.pdf')) return Icons.picture_as_pdf_outlined;
    if (RegExp(r'\.(ts|tsx|js|jsx|py|dart|go|rs|java|c|cpp|h|hpp|json|yaml|yml|md|sh)$').hasMatch(lower)) {
      return Icons.code;
    }
    return Icons.insert_drive_file_outlined;
  }

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    final failed = state.status == _AttachmentStatus.failed;
    return Container(
      height: 28,
      padding: const EdgeInsets.only(left: 8, right: 4),
      decoration: BoxDecoration(
        color: t.surfaceHi,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: failed ? t.error.withValues(alpha: 0.5) : t.border,
          width: 0.5,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(_iconForName(state.localName), size: 14, color: t.textMuted),
          const SizedBox(width: 6),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 200),
            child: Text(
              state.localName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: t.text),
            ),
          ),
          const SizedBox(width: 6),
          if (state.status == _AttachmentStatus.uploading)
            const SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(strokeWidth: 1.5),
            )
          else if (failed)
            GestureDetector(
              onTap: onRetry,
              child: Icon(Icons.error_outline, size: 14, color: t.error),
            )
          else
            GestureDetector(
              onTap: onRemove,
              child: Icon(Icons.close_rounded, size: 14, color: t.textMuted),
            ),
        ],
      ),
    );
  }
}
```

### Step 4.9: 把新参数传给 _Composer 的调用点

- [ ] 找到 `_ChatTabState` 里调用 `_Composer(...)` 的地方（在 `build()` 里），改成：

```dart
_Composer(
  controller: _textController,
  connected: _connected,
  busy: _busy,
  attachments: _attachments,
  attachmentsAllReady: _attachmentsAllReady,
  onPickAttachment: _pickAndUploadAttachments,
  onRemoveAttachment: _removeAttachment,
  onRetryAttachment: _retryAttachment,
  onSubmit: _submit,
  onStop: _onStop,
  onSwitchModel: _onSwitchModel,
  onSwitchPermissionMode: _onSwitchPermissionMode,
)
```

### Step 4.10: 跑 flutter analyze

- [ ] Run:

```bash
flutter analyze lib/screens/tabs/chat_tab.dart lib/api/upload_api.dart
```

Expected: 无 error。

### Step 4.11: 手动 smoke

- [ ] 启 server + app（如果还没起）：
  - server: `cd server && pnpm dev`
  - app: `cd app && flutter run`
- [ ] 打开 chat tab，点 `+`，选 1 个图片 + 1 个 PDF
  - 期望：两个 chip 都先 spinner，然后变成 ×
  - 期望：发送按钮在所有 chip ready 之前禁用
- [ ] 输入"看看这两个文件" + 按发送
  - 期望：消息发出去，文本里看到 `附件：` + 两个路径
  - 期望：Claude 收到后可以 `Read` 文件
- [ ] 模拟失败：关掉 server，再点 + 上传
  - 期望：chip 变红，tap 重试

### Step 4.12: Commit

- [ ] Run:

```bash
git add app/pubspec.yaml app/pubspec.lock app/lib/api/upload_api.dart app/lib/screens/tabs/chat_tab.dart
git commit -m "feat(composer): attachment upload with path injection"
```

---

## Task 5: §4 协议层 — 新增 `answer_question` 消息类型

**目标**：先把 wire 协议落地，后续 server/client 都按这个 contract 实现。

**Files:**
- Modify: `packages/shared/src/protocol.ts`

### Step 5.1: 扩展 ChatClientMessage

- [ ] Modify `packages/shared/src/protocol.ts`，把 `ChatClientMessage` 加一支：

```ts
export type ChatClientMessage =
  | { type: 'init'; cwd: string; permission_mode?: PermissionMode; resume?: string; model?: string }
  | { type: 'user_message'; text: string }
  | { type: 'set_model'; model: string }
  | { type: 'set_permission_mode'; mode: PermissionMode }
  | { type: 'interrupt' }
  | { type: 'ping' }
  | {
      type: 'answer_question';
      tool_use_id: string;
      answers: Record<string, string>;
      annotations?: Record<string, { preview?: string; notes?: string }>;
    };
```

### Step 5.2: typecheck

- [ ] Run:

```bash
cd /Users/airoucat/workspace/shulex/claude-companion
pnpm -r typecheck
```

Expected: 无 error。

### Step 5.3: Commit

- [ ] Run:

```bash
git add packages/shared/src/protocol.ts
git commit -m "feat(protocol): add answer_question client message type"
```

---

## Task 6: §4 Server — AskUserQuestionRegistry + 单元测试

**目标**：纯逻辑类，先写测试。

**Files:**
- Create: `server/src/ask-user-tool.ts`（只先放 Registry 类，工厂在 Task 7 加）
- Create: `server/src/__tests__/ask-user-tool.test.ts`

### Step 6.1: 装 zod 显式依赖

zod 是 SDK 的 peer，但我们自己也用，显式声明：

- [ ] Run:

```bash
cd /Users/airoucat/workspace/shulex/claude-companion/server
pnpm add zod
```

### Step 6.2: 写测试

- [ ] Create `server/src/__tests__/ask-user-tool.test.ts`:

```ts
import { describe, expect, it, vi } from 'vitest';
import { AskUserQuestionRegistry } from '../ask-user-tool.js';

describe('AskUserQuestionRegistry', () => {
  it('resolves the registered promise when answer() is called', async () => {
    const r = new AskUserQuestionRegistry();
    const promise = r.register('id1');
    const ok = r.answer('id1', 'hello');
    expect(ok).toBe(true);
    const result = await promise;
    expect(result.content).toEqual([{ type: 'text', text: 'hello' }]);
  });

  it('answer() returns false for unknown tool_use_id', () => {
    const r = new AskUserQuestionRegistry();
    expect(r.answer('nope', 'x')).toBe(false);
  });

  it('rejectAll() rejects all pending promises', async () => {
    const r = new AskUserQuestionRegistry();
    const p1 = r.register('a');
    const p2 = r.register('b');
    r.rejectAll('socket closed');
    await expect(p1).rejects.toThrow('socket closed');
    await expect(p2).rejects.toThrow('socket closed');
  });

  it('answer() after rejectAll() returns false', () => {
    const r = new AskUserQuestionRegistry();
    r.register('a').catch(() => {}); // swallow rejection
    r.rejectAll('x');
    expect(r.answer('a', 'late')).toBe(false);
  });

  it('register times out after the configured ms', async () => {
    vi.useFakeTimers();
    const r = new AskUserQuestionRegistry({ timeoutMs: 1000 });
    const p = r.register('id1').catch((e) => e);
    vi.advanceTimersByTime(1001);
    const err = await p;
    expect(err).toBeInstanceOf(Error);
    expect((err as Error).message).toMatch(/30 minutes|within/i);
    vi.useRealTimers();
  });
});
```

### Step 6.3: 写最小 Registry 实现让测试通过

- [ ] Create `server/src/ask-user-tool.ts`:

```ts
import type { CallToolResult } from '@anthropic-ai/claude-agent-sdk/sdk-tools.js';

type Resolver = (result: CallToolResult) => void;
type Rejecter = (err: Error) => void;

const DEFAULT_TIMEOUT_MS = 30 * 60 * 1000;

export class AskUserQuestionRegistry {
  private pending = new Map<string, { resolve: Resolver; reject: Rejecter; timer: NodeJS.Timeout }>();
  private readonly timeoutMs: number;

  constructor(opts: { timeoutMs?: number } = {}) {
    this.timeoutMs = opts.timeoutMs ?? DEFAULT_TIMEOUT_MS;
  }

  register(toolUseId: string): Promise<CallToolResult> {
    return new Promise<CallToolResult>((resolve, reject) => {
      const timer = setTimeout(() => {
        if (this.pending.has(toolUseId)) {
          this.pending.delete(toolUseId);
          reject(new Error(`User did not answer within ${Math.round(this.timeoutMs / 60000)} minutes`));
        }
      }, this.timeoutMs);
      this.pending.set(toolUseId, { resolve, reject, timer });
    });
  }

  answer(toolUseId: string, formatted: string): boolean {
    const entry = this.pending.get(toolUseId);
    if (!entry) return false;
    clearTimeout(entry.timer);
    this.pending.delete(toolUseId);
    entry.resolve({ content: [{ type: 'text', text: formatted }] });
    return true;
  }

  rejectAll(reason: string): void {
    for (const [, { reject, timer }] of this.pending) {
      clearTimeout(timer);
      reject(new Error(reason));
    }
    this.pending.clear();
  }
}
```

⚠️ 如果 `@anthropic-ai/claude-agent-sdk/sdk-tools.js` 的子路径 export 不可用（取决于 SDK 的 `exports` 字段），fallback：

```ts
// 定义本地 CallToolResult，不 import：
type CallToolResult = { content: Array<{ type: 'text'; text: string }> };
```

### Step 6.4: 跑测试

- [ ] Run:

```bash
pnpm test
```

Expected: 7（serialize）+ 5（registry）= 12 PASS。

### Step 6.5: typecheck

- [ ] Run:

```bash
pnpm typecheck
```

Expected: 无 error。

### Step 6.6: Commit

- [ ] Run:

```bash
git add server/package.json server/pnpm-lock.yaml server/src/ask-user-tool.ts server/src/__tests__/ask-user-tool.test.ts
git commit -m "feat(server): AskUserQuestionRegistry for pending tool calls"
```

---

## Task 7: §4 Server — ask-user-tool MCP 工厂 + Zod schema

**Files:**
- Modify: `server/src/ask-user-tool.ts`（加 `makeAskUserMcpServer()` 工厂）

### Step 7.1: 加 Zod schema + tool 工厂

- [ ] 在 `server/src/ask-user-tool.ts` 末尾追加：

```ts
import { createSdkMcpServer, tool } from '@anthropic-ai/claude-agent-sdk';
import { z } from 'zod';

const optionSchema = z.object({
  label: z.string().describe('The display text for this option that the user will see and select.'),
  description: z.string().describe('Explanation of what this option means.'),
  preview: z.string().optional().describe('Optional preview content rendered when this option is focused. Use for mockups, code snippets, or visual comparisons.'),
});

const questionSchema = z.object({
  question: z.string().describe('The complete question to ask the user. Should be clear, specific, and end with a question mark.'),
  header: z.string().describe('Very short label displayed as a chip/tag (max 12 chars).'),
  options: z.array(optionSchema).min(2).max(4).describe('The available choices for this question. Must have 2-4 options.'),
  multiSelect: z.boolean().default(false).describe('Set to true to allow the user to select multiple options.'),
});

const inputSchema = {
  questions: z.array(questionSchema).min(1).max(4).describe('Questions to ask the user (1-4 questions)'),
};

const TOOL_DESCRIPTION = `Use this tool when you need to ask the user questions during execution. This allows you to:
1. Gather user preferences or requirements
2. Clarify ambiguous instructions
3. Get decisions on implementation choices as you work
4. Offer choices to the user about what direction to take.

Usage notes:
- Users will always be able to select "Other" to provide custom text input
- Use multiSelect: true to allow multiple answers to be selected for a question
- If you recommend a specific option, make that the first option in the list and add "(Recommended)" at the end of the label
`;

export function makeAskUserMcpServer(registry: AskUserQuestionRegistry) {
  return createSdkMcpServer({
    name: 'ask-user-question',
    tools: [
      tool(
        'AskUserQuestion',
        TOOL_DESCRIPTION,
        inputSchema,
        async (_input, extra: unknown) => {
          // extra typed by SDK as MCP server context; tool_use_id at extra.toolUseId
          const toolUseId = (extra as { toolUseId?: string })?.toolUseId;
          if (!toolUseId) {
            throw new Error('No toolUseId in MCP context');
          }
          return registry.register(toolUseId);
        },
      ),
    ],
  });
}

// Format question answers into the cc-style result string the SDK will pass to Claude.
export function formatAnswers(
  questionsAnswered: Record<string, string>,
  annotations?: Record<string, { preview?: string; notes?: string }>,
): string {
  const parts: string[] = [];
  for (const [question, answer] of Object.entries(questionsAnswered)) {
    const seg: string[] = [`Q: ${question}`, `A: ${answer}`];
    const ann = annotations?.[question];
    if (ann?.preview) seg.push(`selected preview:\n${ann.preview}`);
    if (ann?.notes) seg.push(`notes:\n${ann.notes}`);
    parts.push(seg.join('\n'));
  }
  return `User has answered your questions:\n\n${parts.join('\n\n')}\n\nYou can now continue with the user's answers in mind.`;
}
```

### Step 7.2: 给 formatAnswers 加测试

- [ ] 在 `server/src/__tests__/ask-user-tool.test.ts` 末尾追加：

```ts
import { formatAnswers } from '../ask-user-tool.js';

describe('formatAnswers', () => {
  it('formats single question single answer', () => {
    const out = formatAnswers({ 'Which library?': 'date-fns' });
    expect(out).toContain('Q: Which library?');
    expect(out).toContain('A: date-fns');
    expect(out).toContain('User has answered your questions:');
    expect(out).toContain('You can now continue');
  });

  it('separates multiple questions with blank line', () => {
    const out = formatAnswers({ Q1: 'A1', Q2: 'A2' });
    expect(out).toMatch(/Q: Q1\nA: A1\n\nQ: Q2\nA: A2/);
  });

  it('includes preview when annotation present', () => {
    const out = formatAnswers(
      { 'Which layout?': 'Sidebar' },
      { 'Which layout?': { preview: '```\n[ nav | content ]\n```' } },
    );
    expect(out).toContain('selected preview:');
    expect(out).toContain('[ nav | content ]');
  });
});
```

### Step 7.3: 跑测试 + typecheck

- [ ] Run:

```bash
pnpm test && pnpm typecheck
```

Expected: 15 PASS（+3 formatAnswers）；typecheck 无 error。

⚠️ 如果 `tool()` 签名跟我假设的不一样（特别是第 4 个参数 extra 的类型），调整：
- 看 `node_modules/@anthropic-ai/claude-agent-sdk/sdk.d.ts` 第 5632 行附近的 `function tool<Schema>(_name, _description, _inputSchema, _handler, _extras?)`
- handler 第二个参数实际签名是 `extra: unknown`；从中取 `toolUseId` 是常见 MCP 模式但需要类型 cast

### Step 7.4: Commit

- [ ] Run:

```bash
git add server/src/ask-user-tool.ts server/src/__tests__/ask-user-tool.test.ts
git commit -m "feat(server): AskUserQuestion MCP tool factory + formatAnswers"
```

---

## Task 8: §4 Server — 把 askRegistry 接入 ChatSession + ws-chat

**Files:**
- Modify: `server/src/session-manager.ts`
- Modify: `server/src/ws-chat.ts`

### Step 8.1: ChatSession 注入 askRegistry

- [ ] Modify `server/src/session-manager.ts`：

顶部加 import：
```ts
import { AskUserQuestionRegistry, makeAskUserMcpServer } from './ask-user-tool.js';
```

修改构造器签名：
```ts
constructor(opts: {
  cwd: string;
  permissionMode: PermissionMode;
  resume?: string;
  model?: string;
  askRegistry: AskUserQuestionRegistry;
}) {
  this.cwd = opts.cwd;
  this.permissionMode = opts.permissionMode;
  this.resume = opts.resume;
  this.model = opts.model;
  this.askRegistry = opts.askRegistry;
}
```

并加字段：
```ts
private readonly askRegistry: AskUserQuestionRegistry;
```

修改 `start()` 的 `options` 构造：
```ts
const options: Options = {
  cwd: this.cwd,
  permissionMode: this.permissionMode,
  includePartialMessages: true,
  mcpServers: {
    'ask-user-question': makeAskUserMcpServer(this.askRegistry),
  },
  ...(bypassing ? { allowDangerouslySkipPermissions: true } : {}),
  ...(this.resume ? { resume: this.resume } : {}),
  ...(this.model ? { model: this.model } : {}),
};
```

加新方法（与 `pushUserMessage` 同区域）：
```ts
answerQuestion(
  toolUseId: string,
  answers: Record<string, string>,
  annotations?: Record<string, { preview?: string; notes?: string }>,
): boolean {
  // formatAnswers is imported from ask-user-tool.ts above
  return this.askRegistry.answer(toolUseId, formatAnswers(answers, annotations));
}
```

并在顶部 import 区加：
```ts
import { formatAnswers } from './ask-user-tool.js';
```

### Step 8.2: ws-chat.ts 创建 registry per socket + handle answer_question

- [ ] Modify `server/src/ws-chat.ts`：

顶部 import 区加：
```ts
import { AskUserQuestionRegistry } from './ask-user-tool.js';
```

在 `handleChatSocket` 函数开头（在 `let session...` 那行之后）加：
```ts
const askRegistry = new AskUserQuestionRegistry();
```

`init` case 里 `new ChatSession({...})` 加 `askRegistry`：
```ts
session = new ChatSession({
  cwd,
  permissionMode,
  resume: msg.resume,
  model: msg.model,
  askRegistry,
});
```

在 switch 内加 case（位置：`'interrupt'` 之后）：
```ts
case 'answer_question': {
  if (!session) {
    send({ type: 'error', message: 'Session not initialized' });
    return;
  }
  const ok = session.answerQuestion(msg.tool_use_id, msg.answers, msg.annotations);
  if (!ok) {
    // 答得太晚或没注册过，不致命，记 log
    // 用 console.warn 即可；这条不通过 send 上报给 client
    console.warn('answer_question: no pending tool', msg.tool_use_id);
  }
  break;
}
```

`socket.on('close')` 和 `on('error')` 里加：
```ts
askRegistry.rejectAll('socket closed');
```

### Step 8.3: typecheck + 跑测试

- [ ] Run:

```bash
cd /Users/airoucat/workspace/shulex/claude-companion/server
pnpm typecheck && pnpm test
```

Expected: 无 error；15 测试仍 PASS。

### Step 8.4: 手动 smoke

- [ ] 启 server，让 Claude 主动调 AskUserQuestion（最简单的方式：在 prompt 里要求"请用 AskUserQuestion 工具向我问一个问题"）
- [ ] 用 `wscat` 或 app 连接，观察 ws 流：
  - 应该看到 `assistant` 消息里 `tool_use` 块，`name` 是 `mcp__ask-user-question__AskUserQuestion`，`input` 是 question 数组
  - 等待客户端响应（此时 server tool handler 挂起）
- [ ] 模拟客户端发送：
  ```json
  {"type":"answer_question","tool_use_id":"<id from tool_use>","answers":{"<question text>":"<picked label>"}}
  ```
- [ ] 应该看到后续 `user` 消息（tool_result）和 Claude 继续生成

### Step 8.5: Commit

- [ ] Run:

```bash
git add server/src/session-manager.ts server/src/ws-chat.ts
git commit -m "feat(server): wire AskUserQuestion MCP tool into ChatSession + ws-chat"
```

---

## Task 9: §4 Client — AskUserQuestionWidget skeleton + dispatch

**目标**：先把"已答态"和"路由分发"接好，确认整条链路通；live form 留到 Task 10。

**Files:**
- Create: `app/lib/widgets/ask_user_question.dart`
- Modify: `app/lib/widgets/message_view.dart`

### Step 9.1: 写 AskUserQuestionWidget 骨架（仅 answered state）

- [ ] Create `app/lib/widgets/ask_user_question.dart`:

```dart
import 'package:flutter/material.dart';

import '../api/protocol.dart';
import '../theme.dart';

class AskUserQuestionWidget extends StatefulWidget {
  final ToolUseBlock toolUse;
  /// 已配对的 tool_result；非空 = answered 态
  final ToolResultBlock? answeredResult;
  /// 提交回调：把答案 + annotations 通过 ws 发回 server
  final void Function(
    String toolUseId,
    Map<String, String> answers,
    Map<String, Map<String, String>>? annotations,
  ) onSubmit;

  const AskUserQuestionWidget({
    super.key,
    required this.toolUse,
    required this.answeredResult,
    required this.onSubmit,
  });

  @override
  State<AskUserQuestionWidget> createState() => _AskUserQuestionWidgetState();
}

class _AskUserQuestionWidgetState extends State<AskUserQuestionWidget> {
  late final List<_Question> _questions;

  @override
  void initState() {
    super.initState();
    _questions = _parseQuestions(widget.toolUse.input);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    final answered = widget.answeredResult != null;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: t.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: t.border, width: 0.5),
      ),
      child: Opacity(
        opacity: answered ? 0.75 : 1.0,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final q in _questions) ...[
              _QuestionPanel(question: q, readOnly: answered),
              const SizedBox(height: 24),
            ],
            if (answered)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  '（已答）',
                  style: TextStyle(color: t.textDim, fontSize: 12),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _Question {
  final String question;
  final String header;
  final bool multiSelect;
  final List<_Option> options;
  _Question({
    required this.question,
    required this.header,
    required this.multiSelect,
    required this.options,
  });
}

class _Option {
  final String label;
  final String description;
  final String? preview;
  _Option({required this.label, required this.description, this.preview});
}

List<_Question> _parseQuestions(Map<String, dynamic> input) {
  final list = (input['questions'] as List?) ?? [];
  return list.map((q) {
    final m = q as Map<String, dynamic>;
    final opts = (m['options'] as List).map((o) {
      final om = o as Map<String, dynamic>;
      return _Option(
        label: om['label'] as String,
        description: om['description'] as String? ?? '',
        preview: om['preview'] as String?,
      );
    }).toList();
    return _Question(
      question: m['question'] as String,
      header: m['header'] as String,
      multiSelect: (m['multiSelect'] as bool?) ?? false,
      options: opts,
    );
  }).toList();
}

class _QuestionPanel extends StatelessWidget {
  final _Question question;
  final bool readOnly;
  const _QuestionPanel({required this.question, required this.readOnly});

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            // header chip
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: t.accentSubt,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                question.header,
                style: TextStyle(
                  fontSize: 10,
                  color: t.accent,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                question.question,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: t.text,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        // 占位：options 渲染在 Task 10 实现
        for (final o in question.options)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: t.surfaceHi,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(o.label, style: TextStyle(fontSize: 14, color: t.text, fontWeight: FontWeight.w500)),
                  if (o.description.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        o.description,
                        style: TextStyle(fontSize: 12, color: t.textMuted),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}
```

### Step 9.2: 在 message_view.dart 增加分发分支

- [ ] Modify `app/lib/widgets/message_view.dart`：

顶部 import 加：
```dart
import 'ask_user_question.dart';
```

`MessageView` 类需要接受一个回调来发回答案。改它的构造：
```dart
class MessageView extends StatelessWidget {
  final IncomingMessage message;
  final Map<String, ToolResultBlock>? toolResults;
  final void Function(
    String toolUseId,
    Map<String, String> answers,
    Map<String, Map<String, String>>? annotations,
  )? onAnswerQuestion;

  const MessageView({
    super.key,
    required this.message,
    this.toolResults,
    this.onAnswerQuestion,
  });
  // ...
}
```

在 `_renderBlock(context, b)` 内（用 grep 找到 `_renderBlock` 方法），最前面的 `if (b is ToolUseBlock)` 分支改为：

```dart
if (b is ToolUseBlock) {
  if (b.name.endsWith('AskUserQuestion') && onAnswerQuestion != null) {
    final answered = toolResults?[b.id];
    return AskUserQuestionWidget(
      toolUse: b,
      answeredResult: answered,
      onSubmit: onAnswerQuestion!,
    );
  }
  return ToolCallCard(toolUse: b, result: toolResults?[b.id]);
}
```

⚠️ 若现有代码没有这种结构，搜 `ToolCallCard(` 的调用点替换即可。

### Step 9.3: 在 chat_tab.dart 把回调挂上去

- [ ] 找到 `MessageView(...)` 的调用点（grep `MessageView(`），加 `onAnswerQuestion` 参数：

```dart
MessageView(
  message: msg,
  toolResults: toolResults,
  onAnswerQuestion: _sendAnswerQuestion,
)
```

在 `_ChatTabState` 加方法：

```dart
void _sendAnswerQuestion(
  String toolUseId,
  Map<String, String> answers,
  Map<String, Map<String, String>>? annotations,
) {
  if (_channel == null) return;
  _channel!.sink.add(jsonEncode({
    'type': 'answer_question',
    'tool_use_id': toolUseId,
    'answers': answers,
    if (annotations != null) 'annotations': annotations,
  }));
}
```

`jsonEncode` 在 `dart:convert`，已在文件顶部 import 过。

### Step 9.4: flutter analyze

- [ ] Run:

```bash
flutter analyze lib/widgets/ask_user_question.dart lib/widgets/message_view.dart lib/screens/tabs/chat_tab.dart
```

Expected: 无 error。

### Step 9.5: 手动 smoke

- [ ] 启 server + app
- [ ] 让 Claude 调 AskUserQuestion
- [ ] 看到一张卡片，question + header chip + options 都渲染了；点 option 暂时无反应（live form 留到下个 task）
- [ ] 等 30 min 超时后看到 Claude 继续生成 + cardanswered

### Step 9.6: Commit

- [ ] Run:

```bash
git add app/lib/widgets/ask_user_question.dart app/lib/widgets/message_view.dart app/lib/screens/tabs/chat_tab.dart
git commit -m "feat(chat): AskUserQuestion widget skeleton + dispatch"
```

---

## Task 10: §4 Client — Live form（单 Q 单选立即提交 + multi-select / 多 Q 提交按钮模式）

**目标**：让卡片可交互。

**Files:**
- Modify: `app/lib/widgets/ask_user_question.dart`

### Step 10.1: 改写 _AskUserQuestionWidgetState 加交互状态

- [ ] 在 `_AskUserQuestionWidgetState` 内添加：

```dart
/// 用户当前选择：questionIdx → 选中的 option label 集合
/// 单选时集合 size ≤ 1；多选时可多。
final List<Set<String>> _selections = [];
/// 自定义文本（"Other" 输入），questionIdx → 文本（与 _selections 互斥：选择 'Other' 后写入）
final Map<int, String> _customTexts = {};
bool _submitted = false;
```

`initState()` 末尾加：
```dart
for (int i = 0; i < _questions.length; i++) {
  _selections.add(<String>{});
}
```

### Step 10.2: 决定模式（即时 vs form）

- [ ] 加 getter：

```dart
bool get _isFormMode {
  if (_questions.length > 1) return true;
  return _questions.any((q) => q.multiSelect);
}
```

### Step 10.3: 改 build() 处理 live 态

- [ ] 把 `build()` 中 `Opacity` 包裹的 children 调整：

```dart
child: Column(
  crossAxisAlignment: CrossAxisAlignment.stretch,
  children: [
    for (int i = 0; i < _questions.length; i++) ...[
      _QuestionInteractivePanel(
        index: i,
        question: _questions[i],
        readOnly: answered || _submitted,
        selected: _selections[i],
        customText: _customTexts[i],
        onTapOption: (label) => _onTapOption(i, label),
        onCustomTextSubmitted: (text) => _onCustomText(i, text),
      ),
      if (i < _questions.length - 1) const SizedBox(height: 24),
    ],
    if (!answered && _isFormMode && !_submitted) ...[
      const SizedBox(height: 16),
      _SubmitButton(
        enabled: _canSubmit(),
        onTap: _submit,
      ),
    ],
    if (answered)
      Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Text(
          '（已答）',
          style: TextStyle(color: t.textDim, fontSize: 12),
        ),
      ),
  ],
),
```

### Step 10.4: 加交互方法

- [ ] 在 `_AskUserQuestionWidgetState` 加：

```dart
void _onTapOption(int qIdx, String label) {
  final q = _questions[qIdx];
  setState(() {
    if (q.multiSelect) {
      if (_selections[qIdx].contains(label)) {
        _selections[qIdx].remove(label);
      } else {
        _selections[qIdx].add(label);
      }
      // 取消自定义文本（如果之前选过）
      _customTexts.remove(qIdx);
    } else {
      _selections[qIdx]
        ..clear()
        ..add(label);
      _customTexts.remove(qIdx);
    }
  });
  // 单 Q 单选 + 非 form 模式：立即提交
  if (!_isFormMode && !q.multiSelect) {
    _submit();
  }
}

void _onCustomText(int qIdx, String text) {
  if (text.isEmpty) return;
  setState(() {
    _customTexts[qIdx] = text;
    _selections[qIdx]
      ..clear()
      ..add('__OTHER__');
  });
  if (!_isFormMode) {
    _submit();
  }
}

bool _canSubmit() {
  for (int i = 0; i < _questions.length; i++) {
    if (_selections[i].isEmpty && _customTexts[i] == null) return false;
  }
  return true;
}

void _submit() {
  if (_submitted || widget.answeredResult != null) return;
  if (!_canSubmit()) return;

  final answers = <String, String>{};
  final annotations = <String, Map<String, String>>{};
  for (int i = 0; i < _questions.length; i++) {
    final q = _questions[i];
    final selected = _selections[i];
    final custom = _customTexts[i];
    String answer;
    if (custom != null && selected.contains('__OTHER__')) {
      answer = custom;
    } else if (q.multiSelect) {
      answer = selected.join(', ');
    } else {
      answer = selected.first;
    }
    answers[q.question] = answer;
    // 把所选 option 的 preview 一并回传（仅单选有 preview）
    if (!q.multiSelect && !selected.contains('__OTHER__')) {
      final picked = q.options.firstWhere(
        (o) => o.label == selected.first,
        orElse: () => _Option(label: '', description: ''),
      );
      if (picked.preview != null) {
        annotations[q.question] = {'preview': picked.preview!};
      }
    }
  }
  setState(() => _submitted = true);
  widget.onSubmit(
    widget.toolUse.id,
    answers,
    annotations.isEmpty ? null : annotations,
  );
}
```

### Step 10.5: 实现 _QuestionInteractivePanel

- [ ] 在文件末尾追加（替换前一版的占位 `_QuestionPanel`，可以删掉）：

```dart
class _QuestionInteractivePanel extends StatelessWidget {
  final int index;
  final _Question question;
  final bool readOnly;
  final Set<String> selected;
  final String? customText;
  final void Function(String label) onTapOption;
  final void Function(String text) onCustomTextSubmitted;

  const _QuestionInteractivePanel({
    required this.index,
    required this.question,
    required this.readOnly,
    required this.selected,
    required this.customText,
    required this.onTapOption,
    required this.onCustomTextSubmitted,
  });

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // header + question
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: t.accentSubt,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                question.header,
                style: TextStyle(
                  fontSize: 10,
                  color: t.accent,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                question.question,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: t.text,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        // options
        for (final o in question.options)
          _OptionTile(
            option: o,
            selected: selected.contains(o.label),
            multiSelect: question.multiSelect,
            disabled: readOnly,
            onTap: () {
              if (readOnly) return;
              onTapOption(o.label);
            },
          ),
        // "Other" 一行
        _OtherTile(
          selected: selected.contains('__OTHER__'),
          customText: customText,
          disabled: readOnly,
          onTap: () async {
            if (readOnly) return;
            final result = await showDialog<String>(
              context: context,
              builder: (ctx) => _CustomInputDialog(initial: customText ?? ''),
            );
            if (result != null && result.isNotEmpty) {
              onCustomTextSubmitted(result);
            }
          },
        ),
        // readOnly 时展示用户当时选了什么
        if (readOnly && selected.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8, left: 4),
            child: Text(
              selected.contains('__OTHER__')
                  ? '→ 你输入了：${customText ?? ''}'
                  : '→ 你选了：${selected.join(', ')}',
              style: TextStyle(fontSize: 12, color: t.textMuted),
            ),
          ),
      ],
    );
  }
}

class _OptionTile extends StatelessWidget {
  final _Option option;
  final bool selected;
  final bool multiSelect;
  final bool disabled;
  final VoidCallback onTap;
  const _OptionTile({
    required this.option,
    required this.selected,
    required this.multiSelect,
    required this.disabled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: GestureDetector(
        onTap: disabled ? null : onTap,
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: selected ? t.accentSubt : t.surfaceHi,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: selected ? t.accent.withValues(alpha: 0.5) : Colors.transparent,
              width: 1,
            ),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (multiSelect)
                Padding(
                  padding: const EdgeInsets.only(right: 8, top: 2),
                  child: Icon(
                    selected ? Icons.check_box : Icons.check_box_outline_blank,
                    size: 18,
                    color: selected ? t.accent : t.textMuted,
                  ),
                ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      option.label,
                      style: TextStyle(fontSize: 14, color: t.text, fontWeight: FontWeight.w500),
                    ),
                    if (option.description.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          option.description,
                          style: TextStyle(fontSize: 12, color: t.textMuted),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                ),
              ),
              // Preview 触发图标（Task 11 接 bottom sheet）
              if (option.preview != null)
                Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: Icon(Icons.visibility_outlined, size: 18, color: t.textMuted),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _OtherTile extends StatelessWidget {
  final bool selected;
  final String? customText;
  final bool disabled;
  final VoidCallback onTap;
  const _OtherTile({
    required this.selected,
    required this.customText,
    required this.disabled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: GestureDetector(
        onTap: disabled ? null : onTap,
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: selected ? t.accentSubt : t.surfaceHi,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: selected ? t.accent.withValues(alpha: 0.5) : Colors.transparent,
              width: 1,
            ),
          ),
          child: Row(
            children: [
              Icon(Icons.edit_outlined, size: 16, color: t.textMuted),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  selected && customText != null && customText!.isNotEmpty
                      ? customText!
                      : '自定义…',
                  style: TextStyle(
                    fontSize: 14,
                    fontStyle: FontStyle.italic,
                    color: selected ? t.text : t.textMuted,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CustomInputDialog extends StatefulWidget {
  final String initial;
  const _CustomInputDialog({required this.initial});

  @override
  State<_CustomInputDialog> createState() => _CustomInputDialogState();
}

class _CustomInputDialogState extends State<_CustomInputDialog> {
  late final TextEditingController _c;

  @override
  void initState() {
    super.initState();
    _c = TextEditingController(text: widget.initial);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return AlertDialog(
      backgroundColor: t.surface,
      title: Text('自定义输入', style: TextStyle(color: t.text, fontSize: 16)),
      content: TextField(
        controller: _c,
        autofocus: true,
        cursorColor: t.accent,
        style: TextStyle(color: t.text, fontSize: 14),
        decoration: InputDecoration(
          hintText: '输入你的回答…',
          hintStyle: TextStyle(color: t.textDim),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text('取消', style: TextStyle(color: t.textMuted)),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(_c.text.trim()),
          child: Text('确定', style: TextStyle(color: t.accent)),
        ),
      ],
    );
  }
}

class _SubmitButton extends StatelessWidget {
  final bool enabled;
  final VoidCallback onTap;
  const _SubmitButton({required this.enabled, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    final bg = enabled
        ? (dark ? t.text : const Color(0xFF101828))
        : (dark ? t.borderSubt : const Color(0xFFD0D5DD));
    final fg = enabled
        ? (dark ? const Color(0xFF0B1210) : Colors.white)
        : (dark ? t.textDim : Colors.white);
    return GestureDetector(
      onTap: enabled ? onTap : null,
      child: Container(
        height: 40,
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(10),
        ),
        alignment: Alignment.center,
        child: Text(
          '提交',
          style: TextStyle(color: fg, fontSize: 14, fontWeight: FontWeight.w600),
        ),
      ),
    );
  }
}
```

记得删除上一版的占位 `_QuestionPanel` 类（被 `_QuestionInteractivePanel` 替代）。

### Step 10.6: flutter analyze

- [ ] Run:

```bash
flutter analyze lib/widgets/ask_user_question.dart
```

Expected: 无 error。如果 `dark` 变量在 `_QuestionInteractivePanel.build` 被声明但未用，删掉。

### Step 10.7: 手动 smoke

- [ ] 让 Claude 调 AskUserQuestion (单 Q 单选)，tap option → 立即提交、卡片冻结、Claude 继续
- [ ] 让 Claude 调 multiSelect 版本 → option 出现 checkbox，必须按"提交"才发
- [ ] 让 Claude 一次问 2 个 question → form 模式
- [ ] 选 "自定义…" → 弹 dialog 输入 → 提交后回传成自定义文本

### Step 10.8: Commit

- [ ] Run:

```bash
git add app/lib/widgets/ask_user_question.dart
git commit -m "feat(chat): AskUserQuestion interactive form (single/multi/Other)"
```

---

## Task 11: §4 Client — Preview bottom sheet

**Files:**
- Modify: `app/lib/widgets/ask_user_question.dart::_OptionTile`

### Step 11.1: 给 _OptionTile preview 图标加 onTap

- [ ] 把 `_OptionTile` 改为 `StatefulWidget` 或直接外层包 `GestureDetector` —— 但 preview 图标在右侧需要独立 hitTest。最稳妥：把它包成独立可点的 button：

修改 `_OptionTile` 的 preview 部分：

```dart
// 替换：
if (option.preview != null)
  Padding(
    padding: const EdgeInsets.only(left: 8),
    child: Icon(Icons.visibility_outlined, size: 18, color: t.textMuted),
  ),

// 改为：
if (option.preview != null)
  GestureDetector(
    behavior: HitTestBehavior.opaque,
    onTap: () => _showPreview(context, option.label, option.preview!),
    child: Padding(
      padding: const EdgeInsets.only(left: 8),
      child: Icon(Icons.visibility_outlined, size: 18, color: t.textMuted),
    ),
  ),
```

在 `_OptionTile` 类内 / 或顶级函数：

```dart
void _showPreview(BuildContext context, String optionLabel, String preview) {
  final t = AppTokens.of(context);
  // HTML 检测：粗暴判断 < + > 配对模式
  final looksHtml = RegExp(r'<\s*\w+[^>]*>').hasMatch(preview);
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (ctx) {
      return DraggableScrollableSheet(
        initialChildSize: 0.9,
        minChildSize: 0.5,
        maxChildSize: 0.95,
        expand: false,
        builder: (ctx2, scroll) {
          return Container(
            decoration: BoxDecoration(
              color: t.surface,
              borderRadius: const BorderRadius.vertical(top: Radius.circular(18)),
            ),
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  child: Container(
                    width: 36, height: 4,
                    decoration: BoxDecoration(color: t.border, borderRadius: BorderRadius.circular(2)),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          optionLabel,
                          style: TextStyle(color: t.text, fontSize: 15, fontWeight: FontWeight.w600),
                        ),
                      ),
                      IconButton(
                        icon: Icon(Icons.close_rounded, color: t.textMuted),
                        onPressed: () => Navigator.of(ctx2).pop(),
                      ),
                    ],
                  ),
                ),
                Divider(color: t.borderSubt, height: 1, thickness: 0.5),
                Expanded(
                  child: SingleChildScrollView(
                    controller: scroll,
                    padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
                    child: looksHtml
                        ? Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Container(
                                padding: const EdgeInsets.all(8),
                                margin: const EdgeInsets.only(bottom: 12),
                                decoration: BoxDecoration(
                                  color: t.warning.withValues(alpha: 0.1),
                                  borderRadius: BorderRadius.circular(6),
                                  border: Border.all(color: t.warning.withValues(alpha: 0.3)),
                                ),
                                child: Text(
                                  'Preview 是 HTML，暂不支持富文本渲染，显示原文：',
                                  style: TextStyle(fontSize: 11, color: t.warning),
                                ),
                              ),
                              SelectableText(
                                preview,
                                style: TextStyle(
                                  fontFamily: 'monospace',
                                  fontSize: 12,
                                  color: t.textMuted,
                                ),
                              ),
                            ],
                          )
                        : MarkdownBody(
                            data: preview,
                            styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(ctx2)),
                          ),
                  ),
                ),
              ],
            ),
          );
        },
      );
    },
  );
}
```

顶部 imports 加（若未有）：
```dart
import 'package:flutter_markdown/flutter_markdown.dart';
```

### Step 11.2: flutter analyze

- [ ] Run:

```bash
flutter analyze lib/widgets/ask_user_question.dart
```

Expected: 无 error。

### Step 11.3: 手动 smoke

- [ ] 让 Claude 用 AskUserQuestion 给 option 加 markdown preview（在 prompt 里要求："给每个选项加一段 markdown 代码块作为 preview"）
- [ ] tap 选项右侧 👁 图标 → 弹底部 sheet，markdown 渲染正常
- [ ] 下拉关闭 / tap × 关闭

### Step 11.4: Commit

- [ ] Run:

```bash
git add app/lib/widgets/ask_user_question.dart
git commit -m "feat(chat): AskUserQuestion preview bottom sheet (markdown + HTML fallback)"
```

---

## Task 12: 端到端验收 + 收尾

### Step 12.1: 全量分析

- [ ] Run:

```bash
cd /Users/airoucat/workspace/shulex/claude-companion
pnpm -r typecheck
cd app && flutter analyze
```

Expected: 全部无 error。

### Step 12.2: 全量测试

- [ ] Run:

```bash
cd /Users/airoucat/workspace/shulex/claude-companion/server
pnpm test
```

Expected: 15 PASS。

### Step 12.3: 端到端 smoke

依次跑完整流程：

- [ ] 启 server 和 app
- [ ] 亮 / 暗模式分别打开
- [ ] 按钮：观察发送 / 停止按钮的黑白主题渲染
- [ ] 附件：选 1 图 + 1 PDF + 1 文本，看 chip 上传过程，发送，让 Claude `Read` 图和 PDF
- [ ] 对象 tool 输出：让 Claude 跑一个返回 JSON 的 MCP 工具或 `WebSearch`，观察输出是美化 JSON 而不是 `[object Object]`
- [ ] AskUserQuestion 完整流程：
  - 单 Q 单选 instant submit
  - 单 Q 多选 + 提交
  - 多 Q form
  - 自定义输入
  - preview bottom sheet（让 Claude 给某个 option 带 markdown preview）
- [ ] 验证所有 commit log：

```bash
git log --oneline | head -20
```

Expected: 看到 12 个本 plan 的 commit + Pre-flight 的 1 个清理 commit + Spec commit。

### Step 12.4: 最后清理 commit（如果有）

如果实施过程中产生了零散修复（typo / lint），最后归一个 commit：

- [ ] Run:

```bash
git add -A
git status --short  # 确认范围
git commit -m "chore: misc polish from Spec A implementation"
```

---

## Self-Review

**Spec coverage check**：

| Spec section | 对应 Task |
|---|---|
| §1 按钮 | Task 2 |
| §2 附件 | Task 3 (server) + Task 4 (client) |
| §3 JSON 修复 | Task 1 |
| §4.1-4.2 架构 + Server | Task 6 + 7 + 8 |
| §4.3 协议 | Task 5 |
| §4.3-4.4 Client 渲染 | Task 9 (skeleton) + 10 (form) + 11 (preview) |
| §4.6 妥协 | 已记入 |

**Placeholder scan**：plan 内无 TBD / TODO / "fill in"。每个 code step 都有完整代码。每个测试 step 都有 expected output。

**Type consistency**：
- `_AttachmentState` / `_AttachmentStatus` 在 Task 4 定义后在 Task 4.7、4.8 一致使用
- `AskUserQuestionRegistry` 的 `register / answer / rejectAll` 签名在 Task 6 定义后 Task 8 一致使用
- `_Question / _Option` 内部模型在 Task 9 定义后 Task 10 沿用
- `MessageView.onAnswerQuestion` 签名 Task 9 定义后 chat_tab 在 Step 9.3 一致传入
