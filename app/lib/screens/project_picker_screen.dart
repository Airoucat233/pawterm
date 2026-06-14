import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';

import '../api/agents_api.dart';
import '../api/projects_api.dart';
import '../api/sessions_api.dart';
import '../main.dart' show routeObserver;
import '../state/agents_store.dart';
import '../state/chat_completion_notifier.dart';
import '../state/open_chat_windows.dart';
import '../state/projects_store.dart';
import '../state/server_config.dart';
import '../state/streaming_foreground_service.dart';
import '../theme.dart';
import '../widgets/agent_badge.dart';
import '../widgets/agent_picker_sheet.dart';
import 'add_project_sheet.dart';
import 'main_shell.dart';

class ProjectPickerScreen extends ConsumerStatefulWidget {
  const ProjectPickerScreen({super.key});

  @override
  ConsumerState<ProjectPickerScreen> createState() =>
      _ProjectPickerScreenState();
}

enum _PhaseStatus { connecting, ready, failed }

class _ConnectionAttempt {
  final Connection connection;
  final String url;
  final int index;

  const _ConnectionAttempt({
    required this.connection,
    required this.url,
    required this.index,
  });

  String get displayUrl => url.replaceFirst(RegExp(r'^https?://'), '');
}

class _ConnectionAttemptResult {
  final _ConnectionAttempt attempt;
  final String message;
  final int? statusCode;
  final bool ok;

  const _ConnectionAttemptResult({
    required this.attempt,
    required this.message,
    this.statusCode,
  }) : ok = false;

  const _ConnectionAttemptResult.ok({
    required this.attempt,
  })  : message = '已连接',
        statusCode = null,
        ok = true;
}

class _ProbeResult {
  final bool ok;
  final String message;
  final int? statusCode;

  const _ProbeResult.ok()
      : ok = true,
        message = '',
        statusCode = null;

  const _ProbeResult.fail(this.message, {this.statusCode}) : ok = false;
}

class _ProjectPickerScreenState extends ConsumerState<ProjectPickerScreen>
    with RouteAware {
  final Set<String> _expanded = {};
  _PhaseStatus _phase = _PhaseStatus.connecting;
  String? _connectError;
  bool _needsRepair = false;
  bool _allowExitPop = false;
  List<_ConnectionAttempt> _attempts = const [];
  _ConnectionAttempt? _currentAttempt;
  final List<_ConnectionAttemptResult> _failedAttempts = [];
  _ConnectionAttemptResult? _successfulAttempt;

  @override
  void initState() {
    super.initState();
    _checkConnection();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 订阅当前 Route 的生命周期 — 用户 push 进 MainShell 再 pop 回来时
    // didPopNext 会被调用，用于刷新 session 列表。
    final route = ModalRoute.of(context);
    if (route is PageRoute<dynamic>) {
      routeObserver.subscribe(this, route);
    }
  }

  @override
  void dispose() {
    routeObserver.unsubscribe(this);
    super.dispose();
  }

  @override
  void didPopNext() {
    // 从 MainShell 返回到 ProjectPickerScreen 那一刻：
    // 用户可能新建/续上了某个 session，把 title/last-modified 更新了。
    // sessionsProvider 默认会缓存——这里强制让所有已展开项目重新拉取。
    // 未展开的项目不动（首次展开时本来就会触发 fetch）。
    for (final path in _expanded) {
      ref.invalidate(sessionsProvider(path));
    }
  }

  Future<void> _checkConnection() async {
    final active = ref.read(activeConnectionProvider);
    if (active == null) return;
    final attempts = _buildConnectionAttempts(
      active: active,
      connections: ref.read(connectionsProvider),
    );
    setState(() {
      _phase = _PhaseStatus.connecting;
      _connectError = null;
      _needsRepair = false;
      _attempts = attempts;
      _currentAttempt = attempts.isNotEmpty ? attempts.first : null;
      _failedAttempts.clear();
      _successfulAttempt = null;
    });

    final start = DateTime.now();
    for (final attempt in attempts) {
      if (!mounted) return;
      setState(() => _currentAttempt = attempt);

      final result = await _probeAttempt(attempt);
      if (!mounted) return;
      if (result.ok) {
        setState(() {
          _successfulAttempt = _ConnectionAttemptResult.ok(attempt: attempt);
          _currentAttempt = null;
        });
        final elapsed = DateTime.now().difference(start);
        const minVisible = Duration(milliseconds: 650);
        if (elapsed < minVisible) {
          await Future.delayed(minVisible - elapsed);
        } else {
          await Future.delayed(const Duration(milliseconds: 180));
        }
        if (!mounted) return;

        final notifier = ref.read(connectionsProvider.notifier);
        var connected = attempt.connection;
        if (_normalizeUrl(connected.url) != _normalizeUrl(attempt.url)) {
          connected =
              await notifier.updateUrl(connected.id, attempt.url) ?? connected;
        }
        await notifier.touch(connected.id);
        connected = ref
                .read(connectionsProvider)
                .where((c) => c.id == connected.id)
                .firstOrNull ??
            connected.copyWith(lastConnected: DateTime.now());
        ref.read(activeConnectionProvider.notifier).state = connected;
        await ref
            .read(openChatWindowsProvider.notifier)
            .loadForConnection(connected.id);
        if (!mounted) return;
        final restoredSession =
            ref.read(openChatWindowsProvider).current?.session;
        if (restoredSession != null) {
          ref.read(currentSessionProvider.notifier).state = restoredSession;
          ref.read(selectedProjectProvider.notifier).state = Project(
            name: _projectNameFromSession(restoredSession),
            path: restoredSession.cwd,
          );
          setState(() {
            _phase = _PhaseStatus.ready;
            _needsRepair = false;
            _connectError = null;
          });
          Navigator.of(context).push(
            CupertinoPageRoute(builder: (_) => const MainShell()),
          );
          return;
        }
        setState(() {
          _phase = _PhaseStatus.ready;
          _needsRepair = false;
          _connectError = null;
        });
        return;
      }

      _failedAttempts.add(_ConnectionAttemptResult(
        attempt: attempt,
        message: result.message,
        statusCode: result.statusCode,
      ));
    }

    if (!mounted) return;
    final hasAuthFailure = _failedAttempts.any((e) => e.statusCode == 401);
    setState(() {
      _connectError =
          hasAuthFailure ? '服务端已拒绝令牌，配对信息已失效' : '保存的地址都无法连接，请检查网络或重新配对';
      _phase = _PhaseStatus.failed;
      _needsRepair = hasAuthFailure;
      _currentAttempt = null;
      _successfulAttempt = null;
    });
  }

  Future<_ProbeResult> _probeAttempt(_ConnectionAttempt attempt) async {
    try {
      final resp = await http
          .get(Uri.parse('${attempt.url}/health'),
              headers: attempt.connection.authHeaders)
          .timeout(const Duration(seconds: 3));
      if (resp.statusCode == 200) {
        if (attempt.connection.serverId == null) {
          return const _ProbeResult.ok();
        }
        try {
          final body = jsonDecode(resp.body) as Map<String, dynamic>;
          final serverId = body['serverId'] as String?;
          if (serverId == null ||
              serverId.isEmpty ||
              serverId == attempt.connection.serverId) {
            return const _ProbeResult.ok();
          }
          return const _ProbeResult.fail('不是同一台服务端');
        } catch (_) {
          return const _ProbeResult.ok();
        }
      }
      if (resp.statusCode == 401) {
        return const _ProbeResult.fail('令牌失效', statusCode: 401);
      }
      return _ProbeResult.fail('HTTP ${resp.statusCode}',
          statusCode: resp.statusCode);
    } catch (_) {
      return const _ProbeResult.fail('连接超时');
    }
  }

  List<_ConnectionAttempt> _buildConnectionAttempts({
    required Connection active,
    required List<Connection> connections,
  }) {
    final byId = {for (final c in connections) c.id: c};
    final activeFresh = byId[active.id] ?? active;
    final ordered = <Connection>[
      activeFresh,
      ...connections.where((c) => c.id != activeFresh.id),
    ];
    ordered.sort((a, b) {
      if (a.id == activeFresh.id) return -1;
      if (b.id == activeFresh.id) return 1;
      final at = a.lastConnected;
      final bt = b.lastConnected;
      if (at != null && bt != null) return bt.compareTo(at);
      if (at != null) return -1;
      if (bt != null) return 1;
      return a.name.compareTo(b.name);
    });

    final seen = <String>{};
    final attempts = <_ConnectionAttempt>[];
    for (final conn in ordered) {
      final urls = <String>[
        _normalizeUrl(conn.url),
        ...conn.pinnedUrls.map(_normalizeUrl),
        ...conn.recentUrls.map(_normalizeUrl),
      ];
      for (final url in urls) {
        final normalized = _normalizeUrl(url);
        if (normalized.isEmpty) continue;
        final key = '${conn.id}|$normalized';
        if (!seen.add(key)) continue;
        attempts.add(_ConnectionAttempt(
          connection: conn,
          url: normalized,
          index: attempts.length,
        ));
      }
    }
    return attempts;
  }

  static String _projectNameFromSession(CurrentSession session) {
    final path = session.cwd.trim().replaceAll('\\', '/');
    final parts = path.split('/').where((part) => part.isNotEmpty).toList();
    if (parts.isNotEmpty) return parts.last;
    return session.label.trim().isNotEmpty ? session.label : '项目';
  }

  static String _normalizeUrl(String url) =>
      url.trim().replaceFirst(RegExp(r'/$'), '');

  @override
  Widget build(BuildContext context) {
    final conn = ref.watch(activeConnectionProvider)!;
    final t = AppTokens.of(context);

    return PopScope(
      canPop: _allowExitPop || _phase != _PhaseStatus.ready,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _phase == _PhaseStatus.ready) {
          _confirmExitConnection();
        }
      },
      child: Scaffold(
        body: SafeArea(
          bottom: false,
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 280),
            switchInCurve: Curves.easeOut,
            switchOutCurve: Curves.easeIn,
            child: _phase == _PhaseStatus.ready
                ? _readyView(context, conn, t)
                : _connectingView(context, conn, t),
          ),
        ),
      ),
    );
  }

  Widget _connectingView(BuildContext context, Connection conn, AppTokens t) {
    return _ConnectingView(
      key: const ValueKey('connecting'),
      conn: conn,
      currentAttempt: _currentAttempt,
      totalAttempts: _attempts.length,
      failedAttempts: List.unmodifiable(_failedAttempts),
      successfulAttempt: _successfulAttempt,
      error: _phase == _PhaseStatus.failed ? _connectError : null,
      needsRepair: _needsRepair,
      onBack: () => Navigator.of(context).pop(),
      onRetry: _checkConnection,
      onRepair: () => Navigator.of(context).pop('repair'),
    );
  }

  Widget _readyView(BuildContext context, Connection conn, AppTokens t) {
    final projectsAsync = ref.watch(projectsProvider);
    ref.watch(agentsProvider);
    return Column(
      key: const ValueKey('ready'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _TopBar(
          conn: conn,
          onExitConnection: _confirmExitConnection,
          onRefresh: () {
            ref.invalidate(projectsProvider);
            for (final p in _expanded) {
              ref.invalidate(sessionsProvider(p));
            }
          },
          onAdd: () => _showAddSheet(context),
        ),
        Divider(color: t.borderSubt, height: 0.5, thickness: 0.5),
        Expanded(
          child: projectsAsync.when(
            loading: () =>
                const Center(child: CircularProgressIndicator(strokeWidth: 2)),
            error: (e, _) => _ErrorState(
              message: e.toString(),
              onRetry: () => ref.invalidate(projectsProvider),
            ),
            data: (projects) => _ProjectList(
              projects: projects,
              expanded: _expanded,
              onToggle: (path) => setState(() {
                if (_expanded.contains(path)) {
                  _expanded.remove(path);
                } else {
                  _expanded.add(path);
                }
              }),
              onNewSession: _enterProject,
              onPickSession: _enterProjectWithSession,
              onAdd: () => _showAddSheet(context),
              onDelete: _confirmAndDelete,
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _confirmExitConnection() async {
    final conn = ref.read(activeConnectionProvider);
    if (conn == null) {
      _popProjectPicker();
      return;
    }
    final t = AppTokens.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: t.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text('退出连接', style: TextStyle(color: t.text, fontSize: 16)),
        content: Text(
          '退出后会断开当前连接并停止后台通知状态。已打开的会话会保留，下次进入这台连接时继续显示。',
          style: TextStyle(color: t.textMuted, fontSize: 13, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text('取消', style: TextStyle(color: t.textMuted)),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: FilledButton.styleFrom(backgroundColor: t.error),
            child: const Text('退出'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _exitConnection(conn);
  }

  Future<void> _exitConnection(Connection conn) async {
    ref.read(currentSessionProvider.notifier).state = null;
    ref.read(selectedProjectProvider.notifier).state = null;
    ref.read(activeConnectionProvider.notifier).state = null;
    ref.read(openChatWindowsProvider.notifier).clearMemory();
    ref.read(inAppChatNotificationsProvider.notifier).clear();
    await ChatCompletionNotifier.instance.clearSessionNotifications();
    await StreamingForegroundService.instance.clear();
    if (mounted) _popProjectPicker();
  }

  void _popProjectPicker([Object? result]) {
    if (!mounted) return;
    setState(() => _allowExitPop = true);
    Navigator.of(context).pop(result);
  }

  void _enterProject(Project project) {
    final agent =
        ref.read(projectDefaultAgentProvider.notifier).forProject(project.path);
    _showNewChatSheet(context, project, agent);
  }

  void _enterProjectWithAgent(Project project, AgentKind agent) {
    ref.read(selectedProjectProvider.notifier).state = project;
    final runtime = _defaultRuntimeForAgent(agent, project.path);
    ref.read(currentSessionProvider.notifier).state = CurrentSession(
      cwd: project.path,
      label: project.name,
      agent: agent,
      runtime: runtime,
    );
    Navigator.of(context).push(
      CupertinoPageRoute(builder: (_) => const MainShell()),
    );
  }

  Map<String, dynamic> _defaultRuntimeForAgent(AgentKind agent, String cwd) {
    final agents = ref.read(agentsProvider).valueOrNull ?? const <AgentInfo>[];
    for (final info in agents) {
      if (info.kind == agent && info.defaultRuntime.isNotEmpty) {
        return Map<String, dynamic>.from(info.defaultRuntime);
      }
    }
    return ref
        .read(projectAgentRuntimeProvider.notifier)
        .runtimeFor(cwd, agent);
  }

  void _showNewChatSheet(
      BuildContext context, Project project, AgentKind agent) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => _NewChatSheet(
        project: project,
        agent: agent,
        onStart: () {
          Navigator.of(sheetContext).pop();
          _enterProjectWithAgent(project, agent);
        },
        onChangeAgent: () {
          Navigator.of(sheetContext).pop();
          _showAgentPicker(context, project);
        },
      ),
    );
  }

  void _enterProjectWithSession(Project project, SessionSummary session) {
    ref.read(selectedProjectProvider.notifier).state = project;
    ref.read(currentSessionProvider.notifier).state = CurrentSession(
      cwd: project.path,
      label: '${project.name} · ${session.displayTitle}',
      resumeId: session.sessionId,
      agent: session.agent,
      runtime: session.runtime.isNotEmpty
          ? session.runtime
          : ref
              .read(projectAgentRuntimeProvider.notifier)
              .runtimeFor(project.path, session.agent),
    );
    Navigator.of(context).push(
      CupertinoPageRoute(builder: (_) => const MainShell()),
    );
  }

  void _showAddSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) =>
          AddProjectSheet(onAdded: () => ref.invalidate(projectsProvider)),
    );
  }

  void _showAgentPicker(BuildContext context, Project project) {
    final agentsAsync = ref.read(agentsProvider);
    if (agentsAsync.isLoading && !agentsAsync.hasValue) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Agent 列表加载中，稍后再试')),
      );
      return;
    }
    if (agentsAsync.hasError && !agentsAsync.hasValue) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Agent 列表加载失败：${agentsAsync.error}')),
      );
      return;
    }
    final agents = (agentsAsync.value ?? const <AgentInfo>[]);
    if (agents.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('服务端没有返回可用 Agent')),
      );
      return;
    }
    final selected =
        ref.read(projectDefaultAgentProvider.notifier).forProject(project.path);
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => AgentPickerSheet(
        agents: agents,
        selected: selected,
        onSelected: (agent) {
          Navigator.of(sheetContext).pop();
          ref
              .read(projectDefaultAgentProvider.notifier)
              .setDefault(project.path, agent);
          ref.invalidate(sessionsProvider(project.path));
        },
      ),
    );
  }

  Future<void> _confirmAndDelete(Project project) async {
    final t = AppTokens.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: t.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text('移除项目', style: TextStyle(fontSize: 16, color: t.text)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '将从项目列表中移除：',
              style: TextStyle(fontSize: 13, color: t.textMuted),
            ),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: t.surfaceHi,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: t.border),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(project.name,
                      style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: t.text)),
                  const SizedBox(height: 2),
                  Text(
                    project.path.replaceFirst(RegExp(r'^/Users/[^/]+'), '~'),
                    style: TextStyle(
                        fontSize: 11,
                        fontFamily: 'monospace',
                        color: t.textDim),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: t.accent.withValues(alpha: 0.06),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: t.accent.withValues(alpha: 0.18)),
              ),
              child: Row(
                children: [
                  Icon(Icons.shield_outlined, size: 14, color: t.accent),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      '会话历史不会删除，仍保存在服务端。',
                      style:
                          TextStyle(fontSize: 11, color: t.accent, height: 1.4),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text('取消', style: TextStyle(color: t.textMuted)),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: FilledButton.styleFrom(backgroundColor: t.error),
            child: const Text('移除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    final conn = ref.read(activeConnectionProvider);
    if (conn == null) return;
    try {
      await ProjectsApi(conn.apiBase, token: conn.token)
          .removeProject(project.path);
      ref.invalidate(projectsProvider);
      // 如果当前会话用的就是这个项目，清理一下
      final current = ref.read(currentSessionProvider);
      if (current?.cwd == project.path) {
        ref.read(currentSessionProvider.notifier).state = null;
        ref.read(selectedProjectProvider.notifier).state = null;
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('移除失败：$e')),
      );
    }
  }
}

// ── Connecting / failed view ──────────────────────────────────

class _ConnectingView extends StatefulWidget {
  final Connection conn;
  final _ConnectionAttempt? currentAttempt;
  final int totalAttempts;
  final List<_ConnectionAttemptResult> failedAttempts;
  final _ConnectionAttemptResult? successfulAttempt;
  final String? error;
  final bool needsRepair;
  final VoidCallback onBack;
  final VoidCallback onRetry;
  final VoidCallback onRepair;
  const _ConnectingView({
    super.key,
    required this.conn,
    required this.currentAttempt,
    required this.totalAttempts,
    required this.failedAttempts,
    required this.successfulAttempt,
    required this.error,
    this.needsRepair = false,
    required this.onBack,
    required this.onRetry,
    required this.onRepair,
  });

  @override
  State<_ConnectingView> createState() => _ConnectingViewState();
}

class _ConnectingViewState extends State<_ConnectingView>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    final isError = widget.error != null;
    final current = widget.currentAttempt;
    final cleanUrl = current?.displayUrl ??
        widget.conn.url.replaceFirst(RegExp(r'^https?://'), '');
    final currentName = current?.connection.name ?? widget.conn.name;
    final progressText = current != null && widget.totalAttempts > 1
        ? '第 ${current.index + 1}/${widget.totalAttempts} 个地址'
        : null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 顶部只保留一个返回按钮
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 6, 8, 4),
          child: Row(
            children: [
              IconButton(
                icon: Icon(Icons.arrow_back_ios_new,
                    size: 18, color: t.textMuted),
                onPressed: widget.onBack,
                tooltip: '返回',
              ),
            ],
          ),
        ),
        Expanded(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // 服务器图标 + 转圈光环
                  SizedBox(
                    width: 110,
                    height: 110,
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        if (!isError)
                          AnimatedBuilder(
                            animation: _ctrl,
                            builder: (_, __) => CustomPaint(
                              size: const Size(110, 110),
                              painter: _RingPainter(
                                progress: _ctrl.value,
                                color: t.accent,
                              ),
                            ),
                          ),
                        Container(
                          width: 72,
                          height: 72,
                          decoration: BoxDecoration(
                            color: isError
                                ? t.error.withValues(alpha: 0.08)
                                : t.accentSubt,
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(
                              color: isError
                                  ? t.error.withValues(alpha: 0.3)
                                  : t.accent.withValues(alpha: 0.25),
                            ),
                          ),
                          child: Center(
                            child: Text(widget.conn.emoji,
                                style: const TextStyle(fontSize: 36)),
                          ),
                        ),
                        if (isError)
                          Positioned(
                            right: 14,
                            bottom: 14,
                            child: Container(
                              width: 22,
                              height: 22,
                              decoration: BoxDecoration(
                                color: t.error,
                                shape: BoxShape.circle,
                                border: Border.all(color: t.bg, width: 2),
                              ),
                              child: const Icon(Icons.close,
                                  size: 13, color: Colors.white),
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 28),
                  Text(
                    isError ? '连接失败' : '正在连接',
                    style: TextStyle(
                      fontSize: 13,
                      color: t.textMuted,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 6),
                  // 名称单行；过长时允许横向滑动，短文本依旧居中显示。
                  LayoutBuilder(
                    builder: (ctx, constraints) => SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: ConstrainedBox(
                        constraints:
                            BoxConstraints(minWidth: constraints.maxWidth),
                        child: Center(
                          child: Text(
                            currentName,
                            maxLines: 1,
                            softWrap: false,
                            style: TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.w700,
                              color: t.text,
                              letterSpacing: -0.3,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    cleanUrl,
                    style: TextStyle(
                      fontSize: 12,
                      fontFamily: 'monospace',
                      color: t.textDim,
                    ),
                  ),
                  if (!isError && progressText != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      progressText,
                      style: TextStyle(fontSize: 11, color: t.textDim),
                    ),
                  ],
                  if (widget.failedAttempts.isNotEmpty ||
                      widget.successfulAttempt != null ||
                      current != null) ...[
                    const SizedBox(height: 18),
                    _ConnectionAttemptsList(
                      failedAttempts: widget.failedAttempts,
                      successfulAttempt: widget.successfulAttempt,
                      currentAttempt: isError ? null : current,
                    ),
                  ],
                  if (isError) ...[
                    const SizedBox(height: 14),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 8),
                      decoration: BoxDecoration(
                        color: t.error.withValues(alpha: 0.08),
                        border:
                            Border.all(color: t.error.withValues(alpha: 0.25)),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        widget.error!,
                        style: TextStyle(fontSize: 12, color: t.error),
                      ),
                    ),
                    const SizedBox(height: 20),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        OutlinedButton(
                          onPressed: widget.onBack,
                          style: OutlinedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 22, vertical: 12),
                            side: BorderSide(color: t.border),
                            foregroundColor: t.textMuted,
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(10)),
                          ),
                          child: const Text('返回'),
                        ),
                        const SizedBox(width: 12),
                        FilledButton.icon(
                          onPressed: widget.onRetry,
                          icon: const Icon(Icons.refresh, size: 16),
                          label: const Text('重试'),
                          style: FilledButton.styleFrom(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 22, vertical: 12),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(10)),
                          ),
                        ),
                      ],
                    ),
                    if (widget.needsRepair) ...[
                      const SizedBox(height: 8),
                      FilledButton.icon(
                        onPressed: widget.onRepair,
                        icon: const Icon(Icons.link_off_rounded, size: 16),
                        label: const Text('重新配对'),
                        style: FilledButton.styleFrom(
                          backgroundColor: const Color(0xFFF59E0B),
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(
                              horizontal: 20, vertical: 12),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10)),
                        ),
                      ),
                    ],
                  ],
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _ConnectionAttemptsList extends StatelessWidget {
  final List<_ConnectionAttemptResult> failedAttempts;
  final _ConnectionAttemptResult? successfulAttempt;
  final _ConnectionAttempt? currentAttempt;

  const _ConnectionAttemptsList({
    required this.failedAttempts,
    required this.successfulAttempt,
    required this.currentAttempt,
  });

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    final rows = <Widget>[
      ...failedAttempts.take(4).map((item) => _AttemptRow(result: item)),
      if (currentAttempt != null) _AttemptRow(current: currentAttempt),
      if (successfulAttempt != null) _AttemptRow(result: successfulAttempt),
    ];
    final hiddenFailures =
        failedAttempts.length > 4 ? failedAttempts.length - 4 : 0;
    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(maxWidth: 340),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: t.surfaceHi.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final row in rows) row,
          if (hiddenFailures > 0)
            Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Text(
                '还有 $hiddenFailures 个地址已失败',
                style: TextStyle(fontSize: 10.5, color: t.textDim),
              ),
            ),
        ],
      ),
    );
  }
}

class _AttemptRow extends StatelessWidget {
  final _ConnectionAttemptResult? result;
  final _ConnectionAttempt? current;

  const _AttemptRow({this.result, this.current});

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    final attempt = result?.attempt ?? current!;
    final isCurrent = current != null;
    final isOk = result?.ok == true;
    final color = isCurrent
        ? t.accent
        : isOk
            ? const Color(0xFF16A34A)
            : t.error;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3.5),
      child: Row(
        children: [
          SizedBox(
            width: 15,
            height: 15,
            child: isCurrent
                ? CircularProgressIndicator(strokeWidth: 1.8, color: color)
                : Icon(
                    isOk ? Icons.check_rounded : Icons.close_rounded,
                    size: 15,
                    color: color,
                  ),
          ),
          const SizedBox(width: 7),
          Expanded(
            child: Text(
              attempt.displayUrl,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: isCurrent ? 11.5 : 11,
                fontFamily: 'monospace',
                color: isCurrent ? t.text : t.textMuted,
                fontWeight: isCurrent ? FontWeight.w700 : FontWeight.w500,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            isCurrent ? '尝试中' : result!.message,
            style: TextStyle(
              fontSize: 10.5,
              color: color,
              fontWeight: isCurrent || isOk ? FontWeight.w700 : FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  final double progress;
  final Color color;
  _RingPainter({required this.progress, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2 - 2;

    // 背景环
    final bg = Paint()
      ..color = color.withValues(alpha: 0.12)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    canvas.drawCircle(center, radius, bg);

    // 旋转弧
    final fg = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round;
    final start = progress * 2 * 3.14159265;
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      start,
      1.4,
      false,
      fg,
    );
  }

  @override
  bool shouldRepaint(covariant _RingPainter old) => old.progress != progress;
}

// ── Top bar ──────────────────────────────────────────────────

class _TopBar extends StatelessWidget {
  final Connection conn;
  final VoidCallback onExitConnection;
  final VoidCallback onRefresh;
  final VoidCallback onAdd;
  const _TopBar({
    required this.conn,
    required this.onExitConnection,
    required this.onRefresh,
    required this.onAdd,
  });

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 6, 12, 6),
      child: Row(
        children: [
          // Back button: emoji + back arrow
          InkWell(
            onTap: onExitConnection,
            borderRadius: BorderRadius.circular(10),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.arrow_back_ios_new, size: 15, color: t.accent),
                  const SizedBox(width: 4),
                  Text(conn.emoji, style: const TextStyle(fontSize: 18)),
                ],
              ),
            ),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  conn.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: t.text,
                    letterSpacing: -0.2,
                  ),
                ),
                Text(
                  conn.url.replaceFirst(RegExp(r'^https?://'), ''),
                  style: TextStyle(
                      fontSize: 10, color: t.textDim, fontFamily: 'monospace'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          IconButton(
            icon: Icon(Icons.refresh, size: 20, color: t.textMuted),
            onPressed: onRefresh,
            tooltip: '刷新',
          ),
          GestureDetector(
            onTap: onAdd,
            child: Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: t.accentSubt,
                border: Border.all(color: t.accent.withValues(alpha: 0.3)),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(Icons.add, size: 18, color: t.accent),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Project list ─────────────────────────────────────────────

class _ProjectList extends ConsumerWidget {
  final List<Project> projects;
  final Set<String> expanded;
  final void Function(String path) onToggle;
  final void Function(Project) onNewSession;
  final void Function(Project, SessionSummary) onPickSession;
  final VoidCallback onAdd;
  final void Function(Project) onDelete;

  const _ProjectList({
    required this.projects,
    required this.expanded,
    required this.onToggle,
    required this.onNewSession,
    required this.onPickSession,
    required this.onAdd,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = AppTokens.of(context);
    if (projects.isEmpty) return _EmptyState(onAdd: onAdd);
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 40),
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 10, left: 2),
          child: Text(
            '项目',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: t.textDim,
            ),
          ),
        ),
        for (final p in projects)
          _SlidableProjectCard(
            key: ValueKey(p.path),
            project: p,
            isExpanded: expanded.contains(p.path),
            onToggle: () => onToggle(p.path),
            onNewSession: () => onNewSession(p),
            onPickSession: (s) => onPickSession(p, s),
            onDelete: () => onDelete(p),
          ),
        const SizedBox(height: 8),
        _AddCard(onTap: onAdd),
      ],
    );
  }
}

// ── Project card (expandable) ─────────────────────────────────

/// 折叠时支持左滑删除，展开时禁用滑动（改用展开内的删除图标按钮）。
class _SlidableProjectCard extends StatelessWidget {
  final Project project;
  final bool isExpanded;
  final VoidCallback onToggle;
  final VoidCallback onNewSession;
  final void Function(SessionSummary) onPickSession;
  final VoidCallback onDelete;

  const _SlidableProjectCard({
    super.key,
    required this.project,
    required this.isExpanded,
    required this.onToggle,
    required this.onNewSession,
    required this.onPickSession,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final card = _ProjectCard(
      project: project,
      isExpanded: isExpanded,
      onToggle: onToggle,
      onNewSession: onNewSession,
      onPickSession: onPickSession,
      onDelete: onDelete,
    );
    if (isExpanded) return card;
    return Slidable(
      groupTag: 'project-cards',
      endActionPane: ActionPane(
        motion: const DrawerMotion(),
        extentRatio: 0.22,
        children: [
          SlidableAction(
            onPressed: (_) => onDelete(),
            backgroundColor: const Color(0xFFEF4444),
            foregroundColor: Colors.white,
            icon: Icons.delete_outline,
            label: '移除',
            borderRadius: BorderRadius.circular(16),
            padding: const EdgeInsets.symmetric(vertical: 4),
          ),
        ],
      ),
      child: card,
    );
  }
}

enum _SessionFilter { all, claude, codex }

class _ProjectCard extends ConsumerStatefulWidget {
  final Project project;
  final bool isExpanded;
  final VoidCallback onToggle;
  final VoidCallback onNewSession;
  final void Function(SessionSummary) onPickSession;
  final VoidCallback onDelete;

  const _ProjectCard({
    required this.project,
    required this.isExpanded,
    required this.onToggle,
    required this.onNewSession,
    required this.onPickSession,
    required this.onDelete,
  });

  @override
  ConsumerState<_ProjectCard> createState() => _ProjectCardState();
}

class _ProjectCardState extends ConsumerState<_ProjectCard> {
  _SessionFilter _filter = _SessionFilter.all;

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    final project = widget.project;
    final isExpanded = widget.isExpanded;
    final defaultAgent = ref.watch(projectDefaultAgentProvider)[project.path] ??
        AgentKind.claude;
    final sessionsAsync =
        isExpanded ? ref.watch(sessionsProvider(project.path)) : null;

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: isExpanded ? Color.lerp(t.surface, t.accent, 0.035) : t.surface,
        border: Border.all(
          color: isExpanded ? t.accent.withValues(alpha: 0.28) : t.border,
        ),
        borderRadius: BorderRadius.circular(8),
      ),
      clipBehavior: Clip.hardEdge,
      child: Stack(
        children: [
          if (isExpanded)
            Positioned(
              left: 0,
              top: 10,
              bottom: 10,
              child: Container(
                width: 3,
                decoration: BoxDecoration(
                  color: t.accent,
                  borderRadius: const BorderRadius.horizontal(
                    right: Radius.circular(999),
                  ),
                ),
              ),
            ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              InkWell(
                onTap: widget.onToggle,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(14, 13, 13, 12),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        width: 38,
                        height: 38,
                        decoration: BoxDecoration(
                          color: isExpanded ? t.accentSubt : t.surfaceHi,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: isExpanded
                                ? t.accent.withValues(alpha: 0.18)
                                : t.borderSubt,
                            width: 0.5,
                          ),
                        ),
                        child: Center(
                          child: Icon(
                            isExpanded
                                ? Icons.folder_open
                                : Icons.folder_outlined,
                            size: 19,
                            color: isExpanded ? t.accent : t.textMuted,
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const SizedBox(height: 1),
                            Text(
                              project.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 13.5,
                                fontWeight: FontWeight.w700,
                                color: t.text,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              _humanPath(project.path),
                              style: TextStyle(
                                fontSize: 11,
                                fontFamily: 'monospace',
                                color: t.textDim,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      AgentBadge(agent: defaultAgent, compact: true),
                      const SizedBox(width: 4),
                      AnimatedRotation(
                        duration: const Duration(milliseconds: 180),
                        turns: isExpanded ? 0.5 : 0,
                        child:
                            Icon(Icons.expand_more, size: 20, color: t.textDim),
                      ),
                    ],
                  ),
                ),
              ),
              if (isExpanded) ...[
                Divider(
                    color: t.borderSubt,
                    height: 0.5,
                    indent: 14,
                    endIndent: 14),
                const Padding(
                  padding: EdgeInsets.fromLTRB(14, 12, 14, 0),
                  child: _SectionLabel('会话'),
                ),
                if (sessionsAsync != null)
                  sessionsAsync.when(
                    loading: () => const Padding(
                      padding: EdgeInsets.symmetric(vertical: 16),
                      child: Center(
                        child: SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      ),
                    ),
                    error: (e, _) => Padding(
                      padding: const EdgeInsets.all(12),
                      child: Text(
                        '载入失败：$e',
                        style: TextStyle(fontSize: 11, color: t.error),
                      ),
                    ),
                    data: (sessions) {
                      final filtered = sessions.where((s) {
                        return switch (_filter) {
                          _SessionFilter.all => true,
                          _SessionFilter.claude => s.agent == AgentKind.claude,
                          _SessionFilter.codex => s.agent == AgentKind.codex,
                        };
                      }).toList();
                      return sessions.isEmpty
                          ? Padding(
                              padding: const EdgeInsets.fromLTRB(14, 8, 14, 14),
                              child: Text(
                                '暂无历史会话',
                                style:
                                    TextStyle(fontSize: 12, color: t.textDim),
                              ),
                            )
                          : Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Padding(
                                  padding:
                                      const EdgeInsets.fromLTRB(14, 10, 14, 4),
                                  child: _SessionFilterBar(
                                    selected: _filter,
                                    onChanged: (next) =>
                                        setState(() => _filter = next),
                                  ),
                                ),
                                _SessionListViewport(
                                  sessions: filtered,
                                  emptyText: '这个 Agent 暂无历史会话',
                                  onPickSession: widget.onPickSession,
                                ),
                              ],
                            );
                    },
                  ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 6, 14, 14),
                  child: Row(
                    children: [
                      Expanded(
                        child: _ActionChip(
                          icon: Icons.add_comment_outlined,
                          label: '新会话',
                          primary: true,
                          onTap: widget.onNewSession,
                        ),
                      ),
                      const SizedBox(width: 8),
                      _IconAction(
                        icon: Icons.delete_outline,
                        color: t.error,
                        tooltip: '从列表移除',
                        onTap: widget.onDelete,
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  String _humanPath(String path) =>
      path.replaceFirst(RegExp(r'^/Users/[^/]+'), '~');
}

class _SessionRow extends ConsumerWidget {
  final SessionSummary session;
  final VoidCallback onTap;
  const _SessionRow({required this.session, required this.onTap});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = AppTokens.of(context);
    final hasPendingApproval = ref.watch(inAppChatNotificationsProvider).any(
        (item) =>
            item.kind == InAppChatNotificationKind.approval &&
            item.payload.resumeId == session.sessionId &&
            item.payload.agent == session.agent &&
            (session.cwd == null || item.payload.cwd == session.cwd));
    final ts = session.lastModified;
    final timeText = ts == null
        ? ''
        : DateFormat('MM-dd HH:mm')
            .format(DateTime.fromMillisecondsSinceEpoch(ts));

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 9, 14, 9),
        child: Row(
          children: [
            Container(
              width: 3,
              height: 24,
              margin: const EdgeInsets.only(right: 10),
              decoration: BoxDecoration(
                color: t.border,
                borderRadius: BorderRadius.circular(1.5),
              ),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          session.displayTitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 13,
                            color: session.holderDeviceId != null
                                ? t.textMuted
                                : t.text,
                          ),
                        ),
                      ),
                      if (hasPendingApproval) ...[
                        const SizedBox(width: 6),
                        SizedBox(
                          width: 18,
                          height: 18,
                          child: _PulsingStatusDot(color: t.warning),
                        ),
                        const SizedBox(width: 3),
                        Text('待审批',
                            style: TextStyle(fontSize: 10, color: t.warning)),
                      ] else if (session.holderDeviceId != null) ...[
                        const SizedBox(width: 6),
                        Container(
                          width: 6,
                          height: 6,
                          decoration: BoxDecoration(
                              color: t.warning, shape: BoxShape.circle),
                        ),
                        const SizedBox(width: 3),
                        Text('占用中',
                            style: TextStyle(fontSize: 10, color: t.warning)),
                      ],
                    ],
                  ),
                  if (timeText.isNotEmpty)
                    Text(
                      timeText,
                      style: TextStyle(
                        fontSize: 10,
                        color: t.textDim,
                        fontFamily: 'monospace',
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            AgentBadge(agent: session.agent, compact: true),
          ],
        ),
      ),
    );
  }
}

class _SessionListViewport extends StatelessWidget {
  final List<SessionSummary> sessions;
  final String emptyText;
  final void Function(SessionSummary) onPickSession;

  const _SessionListViewport({
    required this.sessions,
    required this.emptyText,
    required this.onPickSession,
  });

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    final maxHeight = (MediaQuery.sizeOf(context).height * 0.32)
        .clamp(148.0, 260.0)
        .toDouble();

    if (sessions.isEmpty) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(14, 8, 14, 12),
        child: Text(
          emptyText,
          style: TextStyle(fontSize: 12, color: t.textDim),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 2, 0, 6),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: Scrollbar(
          thumbVisibility: sessions.length > 4,
          thickness: 2.5,
          radius: const Radius.circular(2),
          child: ListView.builder(
            padding: EdgeInsets.zero,
            shrinkWrap: true,
            itemCount: sessions.length,
            itemBuilder: (context, index) {
              final session = sessions[index];
              return _SessionRow(
                session: session,
                onTap: () => onPickSession(session),
              );
            },
          ),
        ),
      ),
    );
  }
}

class _PulsingStatusDot extends StatefulWidget {
  final Color color;
  const _PulsingStatusDot({required this.color});

  @override
  State<_PulsingStatusDot> createState() => _PulsingStatusDotState();
}

class _PulsingStatusDotState extends State<_PulsingStatusDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (_, __) {
        final value = _controller.value;
        final pulseSize = 7.0 + value * 10.0;
        final opacity = (1.0 - value).clamp(0.0, 1.0) * 0.30;
        return Center(
          child: Stack(
            alignment: Alignment.center,
            children: [
              Container(
                width: pulseSize,
                height: pulseSize,
                decoration: BoxDecoration(
                  color: widget.color.withValues(alpha: opacity),
                  shape: BoxShape.circle,
                ),
              ),
              Container(
                width: 7,
                height: 7,
                decoration: BoxDecoration(
                  color: widget.color,
                  shape: BoxShape.circle,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return Text(
      text,
      style: TextStyle(
        fontSize: 12,
        color: t.textDim,
        fontWeight: FontWeight.w700,
      ),
    );
  }
}

class _SessionFilterBar extends StatelessWidget {
  final _SessionFilter selected;
  final ValueChanged<_SessionFilter> onChanged;
  const _SessionFilterBar({required this.selected, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return Container(
      height: 34,
      decoration: BoxDecoration(
        color: t.surfaceHi,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: t.borderSubt, width: 0.5),
      ),
      padding: const EdgeInsets.all(3),
      child: Row(
        children: [
          _FilterSegment(
            label: '全部',
            selected: selected == _SessionFilter.all,
            onTap: () => onChanged(_SessionFilter.all),
          ),
          _FilterSegment(
            label: 'Claude',
            selected: selected == _SessionFilter.claude,
            onTap: () => onChanged(_SessionFilter.claude),
          ),
          _FilterSegment(
            label: 'Codex',
            selected: selected == _SessionFilter.codex,
            onTap: () => onChanged(_SessionFilter.codex),
          ),
        ],
      ),
    );
  }
}

class _FilterSegment extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _FilterSegment({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return Expanded(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(7),
        child: Container(
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: selected ? t.surface : Colors.transparent,
            borderRadius: BorderRadius.circular(7),
            border:
                selected ? Border.all(color: t.borderSubt, width: 0.5) : null,
          ),
          child: Text(
            label,
            style: TextStyle(
              color: selected ? t.text : t.textMuted,
              fontSize: 12,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }
}

class _NewChatSheet extends StatelessWidget {
  final Project project;
  final AgentKind agent;
  final VoidCallback onStart;
  final VoidCallback onChangeAgent;

  const _NewChatSheet({
    required this.project,
    required this.agent,
    required this.onStart,
    required this.onChangeAgent,
  });

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 18),
        decoration: BoxDecoration(
          color: t.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(18)),
          border: Border(top: BorderSide(color: t.border, width: 0.5)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 42,
                height: 4,
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                  color: t.border,
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
            ),
            Text(
              '开始新会话',
              style: TextStyle(
                color: t.text,
                fontSize: 17,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: t.surfaceHi,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: t.borderSubt, width: 0.5),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    project.name,
                    style: TextStyle(
                      color: t.text,
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    project.path.replaceFirst(RegExp(r'^/Users/[^/]+'), '~'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: t.textDim,
                      fontSize: 11,
                      fontFamily: 'monospace',
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: t.surfaceHi,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: t.borderSubt, width: 0.5),
              ),
              child: Row(
                children: [
                  AgentBadge(agent: agent),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Text(
                              _agentLabel(agent),
                              style: TextStyle(
                                color: t.text,
                                fontSize: 14,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(width: 8),
                            const _MiniBadge('项目默认'),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text(
                          _runtimeText(agent),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: t.textMuted, fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            SizedBox(
              width: double.infinity,
              height: 46,
              child: FilledButton(
                onPressed: onStart,
                style: FilledButton.styleFrom(
                  backgroundColor: t.accent,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                child: const Text('用当前 Agent 开始'),
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              height: 44,
              child: OutlinedButton(
                onPressed: onChangeAgent,
                style: OutlinedButton.styleFrom(
                  foregroundColor: t.text,
                  side: BorderSide(color: t.border),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                child: const Text('换一个 Agent'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _agentLabel(AgentKind agent) => switch (agent) {
        AgentKind.claude => 'Claude Code',
        AgentKind.codex => 'Codex',
        AgentKind.gemini => 'Gemini CLI',
      };

  static String _runtimeText(AgentKind agent) => switch (agent) {
        AgentKind.claude => 'Sonnet · acceptEdits',
        AgentKind.codex => 'GPT · workspace-write · 按需审批',
        AgentKind.gemini => '默认运行时',
      };
}

class _MiniBadge extends StatelessWidget {
  final String text;
  const _MiniBadge(this.text);

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: t.accentSubt,
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: t.accent.withValues(alpha: 0.2)),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: t.accent,
          fontSize: 10,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

/// 一个只显示图标的次要操作按钮，与 _ActionChip 同高，用于"移除"这类
/// 不应当抢眼但需要可达的操作。
class _IconAction extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String tooltip;
  final VoidCallback onTap;
  const _IconAction({
    required this.icon,
    required this.color,
    required this.tooltip,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          width: 38,
          height: 38,
          decoration: BoxDecoration(
            border: Border.all(color: t.border),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(icon, size: 16, color: color.withValues(alpha: 0.8)),
        ),
      ),
    );
  }
}

class _ActionChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool primary;
  final VoidCallback onTap;
  const _ActionChip(
      {required this.icon,
      required this.label,
      required this.primary,
      required this.onTap});

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          color: primary ? t.accentSubt : null,
          border: Border.all(
            color: primary ? t.accent.withValues(alpha: 0.22) : t.border,
          ),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 15, color: primary ? t.accent : t.textMuted),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: primary ? t.accent : t.textMuted,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AddCard extends StatelessWidget {
  final VoidCallback onTap;
  const _AddCard({required this.onTap});

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: CustomPaint(
        painter: _DashedBorderPainter(color: t.textDim.withValues(alpha: 0.35)),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 18),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.create_new_folder_outlined,
                  size: 18, color: t.textDim),
              const SizedBox(width: 8),
              Text(
                '添加项目目录',
                style: TextStyle(
                  fontSize: 14,
                  color: t.textDim,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DashedBorderPainter extends CustomPainter {
  final Color color;
  const _DashedBorderPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;
    const r = 16.0;
    final rrect = RRect.fromRectAndRadius(
      Rect.fromLTWH(0.75, 0.75, size.width - 1.5, size.height - 1.5),
      const Radius.circular(r),
    );
    final path = Path()..addRRect(rrect);
    canvas.drawPath(_dashPath(path), paint);
  }

  Path _dashPath(Path source) {
    final dest = Path();
    for (final metric in source.computeMetrics()) {
      double dist = 0;
      bool draw = true;
      while (dist < metric.length) {
        final len = draw ? 6.0 : 4.0;
        if (draw) {
          dest.addPath(metric.extractPath(dist, dist + len), Offset.zero);
        }
        dist += len;
        draw = !draw;
      }
    }
    return dest;
  }

  @override
  bool shouldRepaint(covariant _DashedBorderPainter old) => old.color != color;
}

// ── Empty / error states ──────────────────────────────────────

class _EmptyState extends StatelessWidget {
  final VoidCallback onAdd;
  const _EmptyState({required this.onAdd});

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                color: t.surface,
                border: Border.all(color: t.border),
                borderRadius: BorderRadius.circular(20),
              ),
              child: const Center(
                  child: Text('📁', style: TextStyle(fontSize: 32))),
            ),
            const SizedBox(height: 20),
            Text(
              '还没有项目',
              style: TextStyle(
                  fontSize: 17, fontWeight: FontWeight.w600, color: t.text),
            ),
            const SizedBox(height: 8),
            Text(
              '添加一个工作目录，\n就能用 Claude 控制这台机器了。',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: t.textMuted, height: 1.7),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: onAdd,
              icon: const Icon(Icons.add, size: 16),
              label: const Text('添加项目目录'),
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  const _ErrorState({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, color: t.error, size: 32),
            const SizedBox(height: 12),
            Text(
              '获取项目列表失败',
              style: TextStyle(
                  color: t.text, fontSize: 15, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 6),
            Text(message,
                style: TextStyle(color: t.textMuted, fontSize: 12),
                textAlign: TextAlign.center),
            const SizedBox(height: 16),
            OutlinedButton(onPressed: onRetry, child: const Text('重试')),
          ],
        ),
      ),
    );
  }
}
