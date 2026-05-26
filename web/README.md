# @pawterm/web

PC 管理后台。Vite + React + Tailwind + react-query + zustand。

## 启动

```bash
# 在 workspace 根目录
pnpm install           # 第一次或依赖变化时
pnpm dev:web           # 单独跑 web
# 或：
pnpm dev               # 同时跑 server + web
```

- 开发地址：http://localhost:5173
- 通过 Vite proxy 把 `/api/*` 转到 `http://localhost:8765`
- WebSocket 也通过同代理走 `/ws/*`

## 跟手机端的关系

两端共享同一个 server，看到的是同一份 session 数据。Web 端默认放 PC 大屏（带左侧 sidebar + 主区分屏），手机端走 Flutter App。
