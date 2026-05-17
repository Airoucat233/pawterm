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
    await prefs.setString(_themeKey, switch (mode) {
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
