import 'dart:async';
import 'dart:io';

import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import '../api/agents_api.dart';
import 'chat_completion_notifier.dart';

@pragma('vm:entry-point')
void startStreamingForegroundTask() {
  FlutterForegroundTask.setTaskHandler(_StreamingForegroundTaskHandler());
}

class _StreamingForegroundTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {}
}

class StreamingForegroundService {
  StreamingForegroundService._();
  static final instance = StreamingForegroundService._();

  final Map<String, ChatCompletionPayload> _active = {};
  bool _initialized = false;
  bool _appInForeground = true;

  Future<void> init() async {
    if (_initialized || !Platform.isAndroid) return;
    FlutterForegroundTask.initCommunicationPort();
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'streaming_turns',
        channelName: 'Active AI turns',
        channelDescription: 'Keeps active AI turn streams connected',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
        onlyAlertOnce: true,
      ),
      iosNotificationOptions: const IOSNotificationOptions(),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.repeat(30000),
        autoRunOnBoot: false,
        autoRunOnMyPackageReplaced: false,
        allowWakeLock: true,
        allowWifiLock: true,
      ),
    );
    _initialized = true;
    unawaited(_ensureNotificationPermission());
  }

  Future<void> setAppInForeground(bool value) async {
    _appInForeground = value;
    await _sync();
  }

  Future<void> upsert(ChatCompletionPayload payload) async {
    _active[payload.key] = payload;
    await _sync();
  }

  Future<void> remove(ChatCompletionPayload payload) async {
    _active.remove(payload.key);
    await _sync();
  }

  Future<void> _sync() async {
    if (!Platform.isAndroid) return;
    await init();
    if (_appInForeground || _active.isEmpty) {
      if (await FlutterForegroundTask.isRunningService) {
        await FlutterForegroundTask.stopService();
      }
      return;
    }

    final title = _title();
    final body = _body();
    if (await FlutterForegroundTask.isRunningService) {
      await FlutterForegroundTask.updateService(
        notificationTitle: title,
        notificationText: body,
      );
      return;
    }
    await _ensureNotificationPermission();
    await FlutterForegroundTask.startService(
      serviceId: 8765,
      serviceTypes: const [ForegroundServiceTypes.dataSync],
      notificationTitle: title,
      notificationText: body,
      callback: startStreamingForegroundTask,
    );
  }

  Future<void> _ensureNotificationPermission() async {
    final permission =
        await FlutterForegroundTask.checkNotificationPermission();
    if (permission != NotificationPermission.granted) {
      await FlutterForegroundTask.requestNotificationPermission();
    }
  }

  String _title() {
    if (_active.length == 1) {
      final payload = _active.values.first;
      return '${_agentLabel(payload.agent)} 正在回复';
    }
    return '${_active.length} 个会话正在回复';
  }

  String _body() {
    if (_active.length == 1) {
      final payload = _active.values.first;
      return payload.label.isEmpty ? payload.cwd : payload.label;
    }
    return _active.values
        .take(3)
        .map((payload) => payload.label.isEmpty ? payload.cwd : payload.label)
        .join(' · ');
  }

  String _agentLabel(AgentKind agent) => switch (agent) {
        AgentKind.claude => 'Claude',
        AgentKind.codex => 'Codex',
        AgentKind.gemini => 'Gemini',
      };
}
