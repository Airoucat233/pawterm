# Claude Companion (PawTerm) 项目规范

## 构建 & 发布流程

**必须使用已写好的脚本，禁止手动执行 flutter build / gh release / npm publish。**

**所有发布操作（publish.sh / release.sh / build-apk.sh / build-ipa.sh）必须等用户明确说"发布"/"打包"/"release"后才能执行，不得自行决定触发。**

**`git push` 也必须等用户明确说"push"/"推送"后才能执行，不得在提交后自行 push。**

### App 打包（Android APK）

```bash
bash app/scripts/build-apk.sh
```

- 交互式选择版本 bump 策略（same / build / patch / minor / major）
- 自动更新 `app/pubspec.yaml` 版本号
- 输出到 `app/build/app/outputs/flutter-apk/releases/<version>/`

### App 打包（iOS IPA）

```bash
bash app/scripts/build-ipa.sh
```

### GitHub Release（App）

```bash
bash app/scripts/release.sh
```

- 读取当前 pubspec 版本，自动收集 APK / IPA 产物
- 调用 `gh release create`，title 中附带 server 版本号
- **必须先跑完打包脚本，再跑 release 脚本**

### 服务端 npm 发布

```bash
bash server/scripts/publish.sh
```

- 交互式选择版本 bump 策略（same / patch / minor / major）
- 自动更新 `server/package.json`、构建 dist、commit 版本变更、`npm publish`

---

## 目录结构关键路径

- `app/`：Flutter 客户端
- `server/`：Node.js 服务端（npm 包 `pawterm-server`）
- `packages/shared/`：客户端和服务端共享的 TypeScript 类型
- `web/`：Web 前端

## 服务端注意事项

- 端口 `8766` 是给未重打包 app 使用的稳定测试服，**不要随意重启**
- `server/dist/` 在 `.gitignore` 中，不入 git；发布 npm 前需先 `npm run build`
