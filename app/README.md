# Claude Companion App

Flutter 移动客户端（iOS / Android）。

## 首次设置

Flutter 项目需要平台壳工程，第一次拉下来要补：

```bash
cd app
flutter create --platforms=ios,android --org=ai.shulex --project-name=claude_companion .
flutter pub get
```

> `--project-name=claude_companion` 是 Dart 强制的 snake_case 包名，不要改。
> 路径上的目录名仍然是 `claude-companion/app`。

## 运行

```bash
flutter run                   # Android 当前设备，默认 flavor=prod
flutter run --flavor dev      # Android dev 包
flutter run -d ios            # 指定 iOS 模拟器
flutter run -d android        # 指定 Android 模拟器，默认 flavor=prod
```

启动后输入服务端地址（同 WiFi 用电脑局域网 IP，例如 `http://192.168.1.42:8765`）。

## 目录结构

```
lib/
├── main.dart
├── api/
│   └── protocol.dart           # WS 消息类型 + JSON ↔ Dart 对象
├── state/
│   └── server_config.dart      # 服务端地址 + 本地持久化
├── screens/
│   ├── server_setup_screen.dart
│   ├── project_picker_screen.dart
│   └── chat_screen.dart
└── widgets/
    ├── message_view.dart       # 消息渲染分发
    ├── tool_call_card.dart     # 工具调用卡片（Read/Edit/Bash/...）
    └── diff_view.dart          # Edit 工具的简易 diff
```
