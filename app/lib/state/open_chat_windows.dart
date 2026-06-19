import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api/agents_api.dart';
import 'projects_store.dart';

enum OpenChatWindowStatus { idle, running, waiting, error }

class OpenChatWindow {
  final CurrentSession session;
  final OpenChatWindowStatus status;

  const OpenChatWindow({
    required this.session,
    this.status = OpenChatWindowStatus.idle,
  });

  String get key => sessionKey(session);

  OpenChatWindow copyWith({
    CurrentSession? session,
    OpenChatWindowStatus? status,
  }) =>
      OpenChatWindow(
        session: session ?? this.session,
        status: status ?? this.status,
      );

  Map<String, dynamic> toJson() => {
        'session': session.toJson(),
      };

  factory OpenChatWindow.fromJson(Map<String, dynamic> json) => OpenChatWindow(
        session: CurrentSession.fromJson(
          Map<String, dynamic>.from(json['session'] ?? const {}),
        ),
      );
}

class OpenChatWindowsState {
  final List<OpenChatWindow> windows;
  final String? currentKey;

  const OpenChatWindowsState({
    this.windows = const [],
    this.currentKey,
  });

  OpenChatWindow? get current {
    final key = currentKey;
    if (key == null) return null;
    for (final window in windows) {
      if (window.key == key) return window;
    }
    return null;
  }

  OpenChatWindowsState copyWith({
    List<OpenChatWindow>? windows,
    String? currentKey,
  }) =>
      OpenChatWindowsState(
        windows: windows ?? this.windows,
        currentKey: currentKey ?? this.currentKey,
      );
}

String sessionKey(CurrentSession session) =>
    sessionKeyFor(session.agent, session.cwd, session.resumeId);

String sessionKeyFor(AgentKind agent, String cwd, String? resumeId) =>
    '${agent.wire}|$cwd|${resumeId ?? "new"}';

/// 当前前台显示 session 的 key（null 表示无选中 session）。
///
/// 这是 per-session live-status provider（session status / thinking tokens /
/// tool progress / tasks）的"读取键"：这些 provider 现在都按 sessionKey 做
/// family 隔离，渲染侧统一用这个 key 读"当前显示的那个 session"的状态，
/// 写入侧用事件所属 runtime 的 key 写——不同 key 天然隔离，后台 session 的
/// 状态结构上不可能串到当前页面。
final currentSessionKeyProvider = Provider<String?>((ref) {
  final session = ref.watch(currentSessionProvider);
  return session == null ? null : sessionKey(session);
});

class OpenChatWindowsNotifier extends StateNotifier<OpenChatWindowsState> {
  OpenChatWindowsNotifier() : super(const OpenChatWindowsState());

  static const _keyPrefix = 'open_chat_windows_v1';
  String? _connectionId;
  bool _loaded = false;

  void open(CurrentSession session) {
    final key = sessionKey(session);
    final next = <OpenChatWindow>[];
    var found = false;
    var changed = state.currentKey != key;
    for (final window in state.windows) {
      if (window.key == key) {
        final updated = window.copyWith(session: session);
        next.add(updated);
        changed = changed ||
            window.session.label != session.label ||
            window.session.resumeId != session.resumeId ||
            window.session.readOnly != session.readOnly ||
            window.session.runtime != session.runtime;
        found = true;
      } else {
        next.add(window);
      }
    }
    if (!found) {
      next.add(OpenChatWindow(session: session));
      changed = true;
    }
    if (!changed) return;
    state = OpenChatWindowsState(windows: next, currentKey: key);
    _save();
  }

  void select(String key) {
    if (state.windows.any((window) => window.key == key)) {
      state = state.copyWith(currentKey: key);
      _save();
    }
  }

  void close(String key) {
    final next = state.windows.where((window) => window.key != key).toList();
    var currentKey = state.currentKey;
    if (currentKey == key) {
      currentKey = next.isEmpty ? null : next.last.key;
    }
    state = OpenChatWindowsState(windows: next, currentKey: currentKey);
    _save();
  }

  void setStatus(String key, OpenChatWindowStatus status) {
    var changed = false;
    final next = [
      for (final window in state.windows)
        if (window.key == key)
          () {
            if (window.status == status) return window;
            changed = true;
            return window.copyWith(status: status);
          }()
        else
          window,
    ];
    if (changed) {
      state = state.copyWith(windows: next);
      _save();
    }
  }

  Future<void> loadForConnection(String connectionId) async {
    if (_connectionId == connectionId && _loaded) return;
    _connectionId = connectionId;
    _loaded = true;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_storageKey(connectionId));
    if (raw == null || raw.isEmpty) {
      state = const OpenChatWindowsState();
      return;
    }
    try {
      final json = jsonDecode(raw) as Map<String, dynamic>;
      final windows = ((json['windows'] as List?) ?? const [])
          .map((item) => OpenChatWindow.fromJson(
                Map<String, dynamic>.from(item as Map),
              ))
          .toList();
      final currentKey = json['currentKey'] as String?;
      final effectiveKey = windows.any((window) => window.key == currentKey)
          ? currentKey
          : windows.isEmpty
              ? null
              : windows.last.key;
      state = OpenChatWindowsState(
        windows: windows,
        currentKey: effectiveKey,
      );
    } catch (_) {
      state = const OpenChatWindowsState();
    }
  }

  Future<void> clearForConnection(String connectionId) async {
    if (_connectionId == connectionId) {
      state = const OpenChatWindowsState();
      _loaded = false;
      _connectionId = null;
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_storageKey(connectionId));
  }

  void clearMemory() {
    state = const OpenChatWindowsState();
    _loaded = false;
    _connectionId = null;
  }

  Future<void> _save() async {
    final connectionId = _connectionId;
    if (connectionId == null || !_loaded) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _storageKey(connectionId),
      jsonEncode({
        'currentKey': state.currentKey,
        'windows': state.windows.map((window) => window.toJson()).toList(),
      }),
    );
  }

  static String _storageKey(String connectionId) => '$_keyPrefix|$connectionId';
}

final openChatWindowsProvider =
    StateNotifierProvider<OpenChatWindowsNotifier, OpenChatWindowsState>(
  (_) => OpenChatWindowsNotifier(),
);
