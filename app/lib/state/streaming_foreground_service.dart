import 'dart:async';
import 'dart:io';

import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter/services.dart';

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

const _nativeNotificationsChannel = MethodChannel('pawterm/notifications');

class ActiveSessionProgress {
  final ChatCompletionPayload payload;
  final String activity;

  const ActiveSessionProgress({
    required this.payload,
    required this.activity,
  });
}

class StreamingForegroundService {
  StreamingForegroundService._();
  static final instance = StreamingForegroundService._();

  final Map<String, ChatCompletionPayload> _active = {};
  final Map<String, String> _activity = {};
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

  Future<void> upsert(ChatCompletionPayload payload, {String? activity}) async {
    _active[payload.key] = payload;
    if (activity != null && activity.isNotEmpty) {
      _activity[payload.key] = activity;
    }
    await _sync();
  }

  Future<void> remove(ChatCompletionPayload payload) async {
    _active.remove(payload.key);
    _activity.remove(payload.key);
    await _sync();
  }

  Future<void> _sync() async {
    if (!Platform.isAndroid) return;
    await init();
    if (_appInForeground || _active.isEmpty) {
      if (await FlutterForegroundTask.isRunningService) {
        await FlutterForegroundTask.stopService();
      }
      await _clearProgressNotification();
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
    return 'PawTerm 正在后台处理';
  }

  String _body() {
    return activeSessionCompactBody(_progressItems());
  }

  List<ActiveSessionProgress> _progressItems() {
    return _active.values
        .map((payload) => ActiveSessionProgress(
              payload: payload,
              activity: _activity[payload.key] ?? '保持连接',
            ))
        .toList(growable: false);
  }

  Future<void> _clearProgressNotification() async {
    try {
      await _nativeNotificationsChannel.invokeMethod<void>(
        'clearActiveSessionProgress',
      );
    } on MissingPluginException {
      // Non-Android platforms and early startup can miss the native channel.
    } on PlatformException {
      // Clearing a notification is best-effort.
    }
  }
}

String activeSessionSummary(List<ActiveSessionProgress> items) {
  if (items.isEmpty) return '没有后台会话';
  final approvals = items.where((item) => item.activity.contains('审批')).length;
  if (approvals > 0) {
    return '${items.length} 个会话运行中，$approvals 个等待审批';
  }
  return items.length == 1 ? '1 个会话运行中' : '${items.length} 个会话运行中';
}

String activeSessionCompactBody(List<ActiveSessionProgress> items) {
  if (items.isEmpty) return '没有后台会话';
  if (items.length == 1) {
    final item = items.first;
    return '${_sessionDisplayName(item.payload)} · ${item.activity}';
  }
  return activeSessionSummary(items);
}

String _sessionDisplayName(ChatCompletionPayload payload) {
  final cwd = payload.cwd.trim();
  final cwdName = _basename(cwd);
  if (cwdName.isNotEmpty) return _shorten(cwdName);
  final label = payload.label.trim();
  if (label.isNotEmpty) return _shorten(label);
  return '未命名会话';
}

String _shorten(String value) {
  const max = 28;
  if (value.length <= max) return value;
  return '${value.substring(0, max - 1)}…';
}

String _basename(String path) {
  if (path.isEmpty) return '';
  final normalized = path.replaceAll('\\', '/');
  final parts = normalized.split('/').where((part) => part.isNotEmpty).toList();
  return parts.isEmpty ? normalized : parts.last;
}
