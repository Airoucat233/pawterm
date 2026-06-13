import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

class PrefsNotifier extends StateNotifier<ThemeMode> {
  PrefsNotifier() : super(ThemeMode.system) {
    _load();
  }

  static const _themeKey = 'theme_mode';

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final v = prefs.getString(_themeKey);
    state = switch (v) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    };
  }

  Future<void> setTheme(ThemeMode mode) async {
    state = mode;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        _themeKey,
        switch (mode) {
          ThemeMode.light => 'light',
          ThemeMode.dark => 'dark',
          _ => 'system',
        });
  }
}

final prefsProvider =
    StateNotifierProvider<PrefsNotifier, ThemeMode>((ref) => PrefsNotifier());

/// SDK 权限模式，复刻 claude-code CLI 的 4 个档。
/// 协议 wire string 跟 server 一致：`default` / `acceptEdits` / `plan` / `bypassPermissions`。
enum CcPermissionMode {
  defaultMode('default'),
  acceptEdits('acceptEdits'),
  plan('plan'),
  bypass('bypassPermissions');

  final String wire;
  const CcPermissionMode(this.wire);

  static CcPermissionMode fromWire(String? s) {
    for (final m in values) {
      if (m.wire == s) return m;
    }
    return CcPermissionMode.bypass;
  }
}

class PermissionModeNotifier extends StateNotifier<CcPermissionMode> {
  PermissionModeNotifier() : super(CcPermissionMode.bypass) {
    _load();
  }

  static const _key = 'permission_mode_v1';

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final v = prefs.getString(_key);
    state = CcPermissionMode.fromWire(v);
  }

  Future<void> set(CcPermissionMode mode) async {
    state = mode;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, mode.wire);
  }
}

final permissionModeProvider =
    StateNotifierProvider<PermissionModeNotifier, CcPermissionMode>(
  (_) => PermissionModeNotifier(),
);

class PrereleaseChannelNotifier extends StateNotifier<bool> {
  PrereleaseChannelNotifier() : super(false) {
    _load();
  }

  // Keep the old key so existing users do not lose their channel preference.
  static const _key = 'dev_channel';

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    state = prefs.getBool(_key) ?? false;
  }

  Future<void> set(bool value) async {
    state = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_key, value);
  }
}

final prereleaseChannelProvider =
    StateNotifierProvider<PrereleaseChannelNotifier, bool>(
        (_) => PrereleaseChannelNotifier());

class FileToolCardsExpandedNotifier extends StateNotifier<bool> {
  FileToolCardsExpandedNotifier() : super(true) {
    _load();
  }

  static const _key = 'file_tool_cards_expanded_v1';

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    state = prefs.getBool(_key) ?? true;
  }

  Future<void> set(bool value) async {
    state = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_key, value);
  }
}

final fileToolCardsExpandedProvider =
    StateNotifierProvider<FileToolCardsExpandedNotifier, bool>(
  (_) => FileToolCardsExpandedNotifier(),
);

class ScrollToBottomOnSessionSwitchNotifier extends StateNotifier<bool> {
  ScrollToBottomOnSessionSwitchNotifier() : super(true) {
    _load();
  }

  static const _key = 'scroll_to_bottom_on_session_switch_v1';

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    state = prefs.getBool(_key) ?? true;
  }

  Future<void> set(bool value) async {
    state = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_key, value);
  }
}

final scrollToBottomOnSessionSwitchProvider =
    StateNotifierProvider<ScrollToBottomOnSessionSwitchNotifier, bool>(
  (_) => ScrollToBottomOnSessionSwitchNotifier(),
);

enum BottomTabId {
  chat('chat'),
  shell('shell'),
  files('files');

  final String wire;
  const BottomTabId(this.wire);

  static BottomTabId? fromWire(String value) {
    for (final tab in values) {
      if (tab.wire == value) return tab;
    }
    return null;
  }
}

class BottomTabOrderNotifier extends StateNotifier<List<BottomTabId>> {
  BottomTabOrderNotifier() : super(defaultOrder) {
    _load();
  }

  static const _key = 'bottom_tab_order_v1';
  static const defaultOrder = [
    BottomTabId.chat,
    BottomTabId.shell,
    BottomTabId.files,
  ];

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    state = _normalize(
      prefs.getStringList(_key)?.map(BottomTabId.fromWire).toList(),
    );
  }

  Future<void> set(List<BottomTabId> order) async {
    state = _normalize(order);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_key, state.map((tab) => tab.wire).toList());
  }

  static List<BottomTabId> _normalize(List<BottomTabId?>? raw) {
    final result = <BottomTabId>[];
    for (final tab in raw ?? const <BottomTabId?>[]) {
      if (tab != null && !result.contains(tab)) result.add(tab);
    }
    for (final tab in defaultOrder) {
      if (!result.contains(tab)) result.add(tab);
    }
    return result;
  }
}

final bottomTabOrderProvider =
    StateNotifierProvider<BottomTabOrderNotifier, List<BottomTabId>>(
  (_) => BottomTabOrderNotifier(),
);
