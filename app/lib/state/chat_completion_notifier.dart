import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/agents_api.dart';
import '../screens/main_shell.dart';
import 'projects_store.dart';

final chatCompletionPulseProvider =
    StateProvider<Map<String, int>>((ref) => const {});

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
    await _plugin.initialize(
      settings: settings,
      onDidReceiveNotificationResponse: (response) {
        _handlePayload(response.payload);
      },
    );
    await _plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(_channel);
    _initialized = true;

    final launchDetails = await _plugin.getNotificationAppLaunchDetails();
    final response = launchDetails?.notificationResponse;
    if (launchDetails?.didNotificationLaunchApp == true && response != null) {
      _handlePayload(response.payload);
    }
    _flushPendingTap();
  }

  Future<void> notifyTurnComplete({
    required ChatCompletionPayload payload,
    required bool appInForeground,
  }) async {
    _markPulse(payload);
    if (appInForeground) return;
    await _ensureAndroidPermission();
    await _plugin.show(
      id: payload.key.hashCode & 0x7fffffff,
      title: '${_agentLabel(payload.agent)} 已完成回复',
      body: payload.label.isEmpty ? payload.cwd : payload.label,
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

  Future<void> _ensureAndroidPermission() async {
    await _plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.requestNotificationsPermission();
  }

  void _handlePayload(String? raw) {
    if (raw == null || raw.isEmpty) return;
    try {
      _pendingTap = ChatCompletionPayload.fromJson(
        jsonDecode(raw) as Map<String, dynamic>,
      );
      _flushPendingTap();
    } catch (err) {
      if (kDebugMode) debugPrint('Bad notification payload: $err');
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
}
