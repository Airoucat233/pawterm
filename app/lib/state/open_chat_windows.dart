import 'package:flutter_riverpod/flutter_riverpod.dart';

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

class OpenChatWindowsNotifier extends StateNotifier<OpenChatWindowsState> {
  OpenChatWindowsNotifier() : super(const OpenChatWindowsState());

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
  }

  void select(String key) {
    if (state.windows.any((window) => window.key == key)) {
      state = state.copyWith(currentKey: key);
    }
  }

  void close(String key) {
    final next = state.windows.where((window) => window.key != key).toList();
    var currentKey = state.currentKey;
    if (currentKey == key) {
      currentKey = next.isEmpty ? null : next.last.key;
    }
    state = OpenChatWindowsState(windows: next, currentKey: currentKey);
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
    if (changed) state = state.copyWith(windows: next);
  }
}

final openChatWindowsProvider =
    StateNotifierProvider<OpenChatWindowsNotifier, OpenChatWindowsState>(
  (_) => OpenChatWindowsNotifier(),
);
