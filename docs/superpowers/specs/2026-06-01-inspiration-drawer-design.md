# 灵感抽屉与会话文件收藏设计

## 目标

在 AI 会话 streaming 或等待审批时，用户能快速记录突然想到的内容，不打断当前会话。文件类内容单独作为会话级收藏，方便从手机查看 AI 生成或提到的电脑本地文件。

## 范围

- 全局「灵感抽屉」：服务端持久化，支持新增、编辑、归档、删除、查询。
- 会话级「文件收藏」：保存当前会话相关的电脑文件引用，支持从消息里的文件路径加入收藏并打开预览。
- HTML/文件预览第一版通过服务端中转后交给系统浏览器或外部应用打开，不在 App 内嵌 WebView。

不做传统 TODO 命名，不做截止时间、提醒、优先级、拖拽排序。

## 命名

- 功能名：灵感抽屉。
- 数据项：灵感。
- 状态：`active`、`archived`。
- 文件相关能力不归入灵感抽屉，称为会话文件收藏。

## HTTP API 约束

所有新增接口遵守仓库 HTTP API 规范：只使用 `GET` 和 `POST`，URL path 不使用占位符参数。

灵感抽屉接口：

- `GET /api/ideas?status=active|archived|all`
- `POST /api/ideas`

`POST /api/ideas` body:

```json
{
  "action": "create | update | archive | unarchive | delete",
  "id": "optional-id",
  "payload": {
    "text": "灵感内容"
  }
}
```

会话文件收藏接口：

- `GET /api/session-files?sessionId=...`
- `POST /api/session-files`
- `GET /api/file-preview?path=...&cwd=...&sessionId=...`

`POST /api/session-files` body:

```json
{
  "action": "add | remove | update",
  "sessionId": "session-id",
  "id": "optional-id",
  "payload": {
    "path": "/absolute/path/to/file.html",
    "cwd": "/project/root",
    "sourceMessageId": "optional-message-id"
  }
}
```

## 服务端持久化

第一版使用服务端配置目录下的 JSON store，保持和轻量本地服务定位一致。写入采用临时文件加原子 rename，避免进程中断导致文件损坏。

灵感数据是全局的，不绑定项目和会话。文件收藏绑定 `sessionId`，并保留 `cwd` 与绝对路径。

## 安全

文件预览必须走现有项目路径白名单校验。服务端只允许访问配置中允许项目目录下的文件。HTML 预览需要返回临时可访问 URL 或安全转发内容，不能直接让 App 读取电脑本地路径。

## App 交互

灵感抽屉入口放在聊天输入区域附近，适合单手快速打开。抽屉顶部是快速输入框，下方显示 active 灵感列表。每条灵感支持编辑、归档、删除。

AI 消息中识别到电脑绝对路径时，渲染为文件 chip。chip 展示文件名、路径尾部和类型图标，提供「加入会话收藏」和「打开预览」。会话文件收藏从聊天页入口打开，只显示当前会话的文件。

## 验证

- 服务端单测覆盖灵感 CRUD、非法 action、JSON store 持久化。
- 服务端单测覆盖文件预览路径白名单。
- App 侧验证灵感抽屉可新增、编辑、归档、删除，streaming 时打开不影响当前会话。
- App 侧验证消息中的绝对路径会被渲染为文件 chip。
