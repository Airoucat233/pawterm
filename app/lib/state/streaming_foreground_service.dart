import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'chat_completion_notifier.dart';

const _nativeNotificationsChannel = MethodChannel('pawterm/notifications');

class ActiveSessionProgress {
  final ChatCompletionPayload payload;
  final String activity;

  const ActiveSessionProgress({
    required this.payload,
    required this.activity,
  });
}

/// 后台「会话仪表盘」：一条常驻通知，多会话各占一行（name — 实时状态），
/// 完成的会话该行翻成「✓ 已完成」并 heads-up，稍后移除；其余继续。
///
/// 由原生 [DashboardForegroundService] 承载（前台服务保活 + InboxStyle 多行
/// 通知），本类通过 `pawterm/notifications` 方法通道 start/update/stopDashboard。
/// 仅在 App 切后台且有进行中/刚完成会话时显示。
class StreamingForegroundService {
  StreamingForegroundService._();
  static final instance = StreamingForegroundService._();

  /// sessionKey -> 会话载荷
  final Map<String, ChatCompletionPayload> _active = {};

  /// sessionKey -> 实时状态文案（思考中 / 调用工具X / 回复中 …）
  final Map<String, String> _activity = {};

  /// 已完成、常驻里显示「✓ 已完成」的 sessionKey（回前台才清）
  final Set<String> _done = {};

  /// 等待审批的 sessionKey -> requestId（行显示「⏳ 等待审批」+ 允许/拒绝按钮）
  final Map<String, String> _approvals = {};

  bool _appInForeground = true;
  bool _running = false; // 原生仪表盘前台服务是否在跑

  /// 路由更新节流：避免高频状态刷新过度发通知
  DateTime? _lastPush;
  static const _cooldown = Duration(milliseconds: 1200);
  Timer? _coalesce;

  /// 兼容启动调用：仪表盘改由原生前台服务承载，无需再初始化
  /// flutter_foreground_task；电池豁免延后到首个 turn(前台)时申请。
  Future<void> init() async {}

  Future<void> setAppInForeground(bool value) async {
    _appInForeground = value;
    // 回前台 = 用户已看到 → 清掉「已完成」的会话行（运行中/待审批保留）。
    if (value) _clearDoneSessions();
    await _sync(alert: false);
  }

  void _clearDoneSessions() {
    for (final key in _done.toList()) {
      _active.remove(key);
      _activity.remove(key);
    }
    _done.clear();
  }

  /// 实时查 App 是否在前台可见（绕开 _appInForeground 标志的更新竞态）。
  bool _isAppVisibleNow() =>
      WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;

  Future<void> upsert(ChatCompletionPayload payload, {String? activity}) async {
    _active[payload.key] = payload;
    if (activity != null && activity.isNotEmpty) {
      _activity[payload.key] = activity;
    }
    _cancelDone(payload.key); // 又活跃了：撤销「已完成」展示
    await _sync(alert: false);
  }

  Future<void> remove(ChatCompletionPayload payload) async {
    _active.remove(payload.key);
    _activity.remove(payload.key);
    _cancelDone(payload.key);
    await _sync(alert: false);
  }

  /// 一轮完成：把该会话行翻成「✓ 已完成」并让仪表盘 heads-up，
  /// [_doneLinger] 后移除该行（其余进行中的会话不受影响）。
  Future<void> complete(ChatCompletionPayload payload) async {
    final key = payload.key;
    // 已标记完成过就跳过——避免重连补播/重复触发再弹一条「已完成」。
    if (_done.contains(key)) return;
    final text = '${_sessionDisplayName(payload)} 已完成回复';
    final pj = _encodePayload(payload.toJson());
    if (!_active.containsKey(key)) {
      // fallback：key 没匹配但只有一个活跃，认为就是它
      if (_active.length == 1) {
        final only = _active.keys.single;
        if (_done.contains(only)) return;
        _markDone(only);
        await _sync(alert: true, alertText: text, alertPayload: pj);
      }
      return;
    }
    _markDone(key);
    await _sync(alert: true, alertText: text, alertPayload: pj);
  }

  void _markDone(String key) {
    _done.add(key);
    _activity[key] = '✓ 已完成';
    // 不自动移除：常驻仪表盘保留「✓ 已完成」行，回前台时由 _clearDoneSessions 清。
  }

  void _cancelDone(String key) {
    _done.remove(key);
  }

  /// 某会话出现待审批：行显示「⏳ 等待审批」+ 允许/拒绝按钮，并 heads-up。
  Future<void> setApproval(
      ChatCompletionPayload payload, String requestId) async {
    _active[payload.key] = payload;
    _approvals[payload.key] = requestId;
    _cancelDone(payload.key);
    await _sync(
      alert: true,
      alertText: '${_sessionDisplayName(payload)} 需要审批',
      alertPayload: _encodePayload(payload.toJson()),
    );
  }

  /// 审批已解决（用户在 App 内或别处响应）：撤销该行的待审批态。
  Future<void> clearApproval(ChatCompletionPayload payload) async {
    if (_approvals.remove(payload.key) != null) {
      await _sync(alert: false);
    }
  }

  /// 从通知里直接审批后按 uuid 清除（回调只拿到 payload，不便重建 key 时用）。
  Future<void> clearApprovalByUuid(String uuid) async {
    String? key;
    for (final e in _active.entries) {
      if (e.value.resumeId == uuid) {
        key = e.key;
        break;
      }
    }
    if (key != null && _approvals.remove(key) != null) {
      await _sync(alert: false);
    }
  }

  Future<void> clear() async {
    _active.clear();
    _activity.clear();
    _done.clear();
    _approvals.clear();
    await _sync(alert: false);
  }

  /// 把当前状态推到原生仪表盘。前台 / 无会话时停掉前台服务。
  /// [alert] = true（完成/审批事件）让通知再次 heads-up；普通状态更新静默 + 节流。
  Future<void> _sync({
    required bool alert,
    String? alertText,
    String? alertPayload,
  }) async {
    if (!Platform.isAndroid) return;

    // 完成/审批事件：后台时独立发一条瞬态悬浮通知，不受仪表盘显隐/早退影响。
    // 进了 App(resumed=可见)就不弹——除了 _appInForeground 标志，再实时查一次
    // 生命周期，规避回前台重连补播时标志还没置 true 的竞态。
    if (alert &&
        alertText != null &&
        alertText.isNotEmpty &&
        !_appInForeground &&
        !_isAppVisibleNow()) {
      try {
        await _nativeNotificationsChannel.invokeMethod('dashboardEvent', {
          'text': alertText,
          if (alertPayload != null) 'payload': alertPayload,
        });
      } on PlatformException {
        // best-effort
      } on MissingPluginException {
        // non-Android / early startup
      }
    }

    if (_appInForeground || _isAppVisibleNow() || _active.isEmpty) {
      _coalesce?.cancel();
      if (_running) {
        try {
          await _nativeNotificationsChannel.invokeMethod('stopDashboard');
        } on PlatformException {
          // best-effort
        } on MissingPluginException {
          // non-Android / early startup
        }
        _running = false;
      }
      return;
    }

    // 事件(alert)立即推；普通更新节流，避免高频发通知。
    if (!alert) {
      final now = DateTime.now();
      if (_lastPush != null && now.difference(_lastPush!) < _cooldown) {
        _coalesce?.cancel();
        _coalesce = Timer(_cooldown, () => unawaited(_sync(alert: false)));
        return;
      }
    }
    _coalesce?.cancel();
    _lastPush = DateTime.now();

    // 结构化每会话：name + 实时状态 + 深链载荷 + phase（done 行显示已完成）。
    final sessions = _active.values.map((p) {
      final waiting = _approvals.containsKey(p.key);
      return <String, Object?>{
        'name': _sessionDisplayName(p),
        'status': waiting ? '⏳ 等待审批' : (_activity[p.key] ?? '运行中'),
        'payload': _encodePayload(p.toJson()),
        'agent': p.agent.wire,
        'phase': waiting
            ? 'approval'
            : (_done.contains(p.key) ? 'done' : 'running'),
        'request_id': _approvals[p.key] ?? '',
      };
    }).toList(growable: false);
    final title = 'PawTerm · ${_active.length} 个会话';

    try {
      await _nativeNotificationsChannel.invokeMethod(
        _running ? 'updateDashboard' : 'startDashboard',
        {
          'title': title,
          'sessions': sessions,
          'alert': alert,
        },
      );
      _running = true;
    } on PlatformException {
      // best-effort
    } on MissingPluginException {
      // non-Android / early startup
    }
  }

  // ChatCompletionPayload.toJson 是 Map；原生只需要透传字符串做深链。
  String _encodePayload(Map<String, dynamic> json) => jsonEncode(json);

  /// 当前是否已豁免电池优化（设置页展示状态用）。
  Future<bool> isBatteryExempt() async {
    if (!Platform.isAndroid) return true;
    try {
      return await FlutterForegroundTask.isIgnoringBatteryOptimizations;
    } catch (_) {
      return false;
    }
  }

  /// 用户在设置里**主动**请求电池优化豁免（会拉起系统设置页）。
  /// 默认不自动弹——平时仅靠前台服务尽力保活，想要更强后台保障的用户自行开启。
  Future<void> requestBatteryExemption() async {
    if (!Platform.isAndroid) return;
    try {
      final ignoring =
          await FlutterForegroundTask.isIgnoringBatteryOptimizations;
      if (!ignoring) {
        await FlutterForegroundTask.requestIgnoreBatteryOptimization();
      }
    } catch (_) {}
  }

}

String activeSessionSummary(List<ActiveSessionProgress> items) {
  if (items.isEmpty) return '没有后台会话';
  final approvals = items.where((item) => item.activity.contains('审批')).length;
  if (approvals > 0) {
    return '${items.length} 个会话，$approvals 个等待审批';
  }
  return items.length == 1 ? '1 个会话运行中' : '${items.length} 个会话运行中';
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
  const max = 22;
  if (value.length <= max) return value;
  return '${value.substring(0, max - 1)}…';
}

String _basename(String path) {
  if (path.isEmpty) return '';
  final normalized = path.replaceAll('\\', '/');
  final parts = normalized.split('/').where((part) => part.isNotEmpty).toList();
  return parts.isEmpty ? normalized : parts.last;
}
