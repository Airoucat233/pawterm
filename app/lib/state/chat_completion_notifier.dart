import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';

import '../api/chat_api.dart';
import '../api/agents_api.dart';
import '../screens/main_shell.dart';
import 'projects_store.dart';

final chatCompletionPulseProvider =
    StateProvider<Map<String, int>>((ref) => const {});

const _nativeNotificationsChannel = MethodChannel('pawterm/notifications');

class ChatCompletionPayload {
  final String cwd;
  final String? resumeId;
  final String label;
  final AgentKind agent;
  final Map<String, dynamic> runtime;

  const ChatCompletionPayload({
    required this.cwd,
    required this.resumeId,
    required this.label,
    required this.agent,
    required this.runtime,
  });

  String get key => '${agent.wire}|$cwd|${resumeId ?? "new"}';

  factory ChatCompletionPayload.fromSession(CurrentSession session) =>
      ChatCompletionPayload(
        cwd: session.cwd,
        resumeId: session.resumeId,
        label: session.label,
        agent: session.agent,
        runtime: session.runtime,
      );

  factory ChatCompletionPayload.fromJson(Map<String, dynamic> json) =>
      ChatCompletionPayload(
        cwd: json['cwd'] as String? ?? '',
        resumeId: json['resume_id'] as String?,
        label: json['label'] as String? ?? '',
        agent: AgentKind.fromWire(json['agent'] as String?),
        runtime: Map<String, dynamic>.from(json['runtime'] ?? const {}),
      );

  Map<String, dynamic> toJson() => {
        'cwd': cwd,
        if (resumeId != null) 'resume_id': resumeId,
        'label': label,
        'agent': agent.wire,
        'runtime': runtime,
      };
}

class ChatCompletionNotifier {
  ChatCompletionNotifier._();
  static final instance = ChatCompletionNotifier._();

  static const _channel = AndroidNotificationChannel(
    'chat_completion',
    'Chat completion',
    description: 'AI turn completion alerts',
    importance: Importance.high,
  );
  static const _approvalChannel = AndroidNotificationChannel(
    'chat_approval',
    'Chat approvals',
    description: 'AI approval requests',
    importance: Importance.high,
  );
  static const _actionDecline = 'approval_decline';
  static const _actionAccept = 'approval_accept';
  static const _actionAcceptForSession = 'approval_accept_for_session';

  final _plugin = FlutterLocalNotificationsPlugin();
  bool _initialized = false;
  WidgetRef? _ref;
  GlobalKey<NavigatorState>? _navigatorKey;
  ChatCompletionPayload? _pendingTap;

  Future<void> init({
    required WidgetRef ref,
    required GlobalKey<NavigatorState> navigatorKey,
  }) async {
    _ref = ref;
    _navigatorKey = navigatorKey;
    if (_initialized) {
      _flushPendingTap();
      return;
    }

    const androidSettings =
        AndroidInitializationSettings('@mipmap/ic_launcher');
    const settings = InitializationSettings(android: androidSettings);
    _nativeNotificationsChannel.setMethodCallHandler((call) async {
      if (call.method == 'notificationTapped') {
        final payload = call.arguments;
        if (payload is String) _handlePayload(payload);
      }
    });
    await _plugin.initialize(
      settings: settings,
      onDidReceiveNotificationResponse: (response) {
        if (response.actionId?.isNotEmpty == true) {
          unawaited(handleApprovalAction(response));
          return;
        }
        _handlePayload(response.payload);
      },
    );
    await _plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(_channel);
    await _plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(_approvalChannel);
    _initialized = true;
    unawaited(_requestAndroidPermissionIfForeground());

    final launchDetails = await _plugin.getNotificationAppLaunchDetails();
    final response = launchDetails?.notificationResponse;
    if (launchDetails?.didNotificationLaunchApp == true && response != null) {
      _handlePayload(response.payload);
    }
    await _handleInitialNativePayload();
    _flushPendingTap();
  }

  Future<void> refreshForegroundPermission() async {
    await _requestAndroidPermissionIfForeground();
  }

  Future<void> clearSessionNotifications() async {
    try {
      await _nativeNotificationsChannel.invokeMethod<void>(
        'clearSessionNotifications',
      );
    } on MissingPluginException {
      // Native notification aggregation is Android-only.
    } on PlatformException catch (err) {
      if (kDebugMode) debugPrint('Clear session notifications failed: $err');
    }
  }

  Future<void> notifyTurnComplete({
    required ChatCompletionPayload payload,
    required bool appInForeground,
  }) async {
    _markPulse(payload);
    if (appInForeground || _appIsVisibleNow()) return;
    final id = payload.key.hashCode & 0x7fffffff;
    final sessionName = _sessionDisplayName(payload);
    final agentName = _agentLabel(payload.agent);
    final title = '$sessionName 有新回复';
    final body = '$agentName 已完成回复';
    final line = '$sessionName · $agentName 已完成回复';
    if (_appIsVisibleNow()) return;
    try {
      await _nativeNotificationsChannel.invokeMethod<void>(
        'addSessionEvent',
        {
          'title': title,
          'line': line,
          'payload': jsonEncode(payload.toJson()),
        },
      );
    } on MissingPluginException {
      await _plugin.show(
        id: id,
        title: title,
        body: body,
        notificationDetails: NotificationDetails(
          android: AndroidNotificationDetails(
            _channel.id,
            _channel.name,
            channelDescription: _channel.description,
            importance: Importance.high,
            priority: Priority.high,
            category: AndroidNotificationCategory.status,
            ticker: 'AI turn complete',
          ),
        ),
        payload: jsonEncode(payload.toJson()),
      );
    }
  }

  Future<void> notifyCodexApproval({
    required ChatCompletionPayload payload,
    required String apiBase,
    required String? token,
    required String uuid,
    required String requestId,
    required String title,
    required String body,
    required bool appInForeground,
  }) async {
    if (appInForeground || _appIsVisibleNow()) return;
    if (!await _canNotifyWithoutPrompt()) return;
    if (_appIsVisibleNow()) return;
    final approvalPayload = {
      'kind': 'codex_approval',
      'api_base': apiBase,
      if (token != null && token.isNotEmpty) 'token': token,
      'uuid': uuid,
      'request_id': requestId,
      'session': payload.toJson(),
    };
    await _plugin.show(
      id: 'approval|${payload.key}|$requestId'.hashCode & 0x7fffffff,
      title: title,
      body: body,
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          _approvalChannel.id,
          _approvalChannel.name,
          channelDescription: _approvalChannel.description,
          importance: Importance.high,
          priority: Priority.high,
          category: AndroidNotificationCategory.recommendation,
          ticker: 'Codex approval required',
          actions: const [
            AndroidNotificationAction(
              _actionDecline,
              '拒绝',
              cancelNotification: true,
            ),
            AndroidNotificationAction(
              _actionAccept,
              '允许本次',
              cancelNotification: true,
            ),
            AndroidNotificationAction(
              _actionAcceptForSession,
              '本会话允许',
              cancelNotification: true,
            ),
          ],
        ),
      ),
      payload: jsonEncode(approvalPayload),
    );
  }

  bool _appIsVisibleNow() {
    final state = WidgetsBinding.instance.lifecycleState;
    return state == AppLifecycleState.resumed;
  }

  Future<void> _requestAndroidPermissionIfForeground() async {
    if (!_appIsVisibleNow()) return;
    final android = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    final enabled = await android?.areNotificationsEnabled();
    if (enabled == true) return;
    await _plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.requestNotificationsPermission();
  }

  Future<bool> _canNotifyWithoutPrompt() async {
    final android = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    final enabled = await android?.areNotificationsEnabled();
    return enabled ?? true;
  }

  Future<void> _handleInitialNativePayload() async {
    try {
      final payload = await _nativeNotificationsChannel
          .invokeMethod<String>('getInitialNotificationPayload');
      _handlePayload(payload);
    } on MissingPluginException {
      // Native notification aggregation is Android-only.
    } on PlatformException catch (err) {
      if (kDebugMode) debugPrint('Initial notification payload failed: $err');
    }
  }

  void _handlePayload(String? raw) {
    if (raw == null || raw.isEmpty) return;
    try {
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      if (decoded['kind'] == 'codex_approval') {
        final session = decoded['session'];
        if (session is Map) {
          _pendingTap = ChatCompletionPayload.fromJson(
              Map<String, dynamic>.from(session));
        }
      } else {
        _pendingTap = ChatCompletionPayload.fromJson(decoded);
      }
      _flushPendingTap();
    } catch (err) {
      if (kDebugMode) debugPrint('Bad notification payload: $err');
    }
  }

  Future<void> handleApprovalAction(NotificationResponse response) async {
    final decision = switch (response.actionId) {
      _actionDecline => 'decline',
      _actionAccept => 'accept',
      _actionAcceptForSession => 'acceptForSession',
      _ => null,
    };
    final raw = response.payload;
    if (decision == null || raw == null || raw.isEmpty) {
      _handlePayload(raw);
      return;
    }
    try {
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      if (decoded['kind'] != 'codex_approval') return;
      final apiBase = decoded['api_base'] as String;
      final token = decoded['token'] as String?;
      final uuid = decoded['uuid'] as String;
      final requestId = decoded['request_id'] as String;
      await ChatApi(apiBase, token: token)
          .answerCodexApproval(uuid, requestId, decision);
      final session = decoded['session'];
      if (session is Map) {
        _markPulse(ChatCompletionPayload.fromJson(
          Map<String, dynamic>.from(session),
        ));
      }
    } catch (err) {
      if (kDebugMode) debugPrint('Bad approval action payload: $err');
      _handlePayload(raw);
    }
  }

  void _flushPendingTap() {
    final payload = _pendingTap;
    final ref = _ref;
    final navigator = _navigatorKey?.currentState;
    if (payload == null || ref == null || navigator == null) return;
    _pendingTap = null;

    ref.read(currentSessionProvider.notifier).state = CurrentSession(
      cwd: payload.cwd,
      label: payload.label,
      resumeId: payload.resumeId,
      agent: payload.agent,
      runtime: payload.runtime.isEmpty ? null : payload.runtime,
    );
    navigator.pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const MainShell()),
      (route) => route.isFirst,
    );
  }

  void _markPulse(ChatCompletionPayload payload) {
    final ref = _ref;
    if (ref == null) return;
    final current = ref.read(chatCompletionPulseProvider);
    ref.read(chatCompletionPulseProvider.notifier).state = {
      ...current,
      payload.key: DateTime.now().millisecondsSinceEpoch,
    };
  }

  String _agentLabel(AgentKind agent) => switch (agent) {
        AgentKind.claude => 'Claude',
        AgentKind.codex => 'Codex',
        AgentKind.gemini => 'Gemini',
      };

  String _sessionDisplayName(ChatCompletionPayload payload) {
    final cwdName = _basename(payload.cwd.trim());
    if (cwdName.isNotEmpty) return _shorten(cwdName);
    final label = payload.label.trim();
    if (label.isNotEmpty) return _shorten(label);
    return '未命名会话';
  }

  String _basename(String path) {
    if (path.isEmpty) return '';
    final normalized = path.replaceAll('\\', '/');
    final parts =
        normalized.split('/').where((part) => part.isNotEmpty).toList();
    return parts.isEmpty ? normalized : parts.last;
  }

  String _shorten(String value) {
    const max = 24;
    if (value.length <= max) return value;
    return '${value.substring(0, max - 1)}…';
  }
}
