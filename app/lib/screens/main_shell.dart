import 'dart:async';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../api/agents_api.dart';
import '../api/git_api.dart';
import '../api/sessions_api.dart';
import '../i18n/locale_provider.dart';
import '../state/agents_store.dart';
import '../state/chat_completion_notifier.dart';
import '../state/open_chat_windows.dart';
import '../state/prefs.dart';
import '../state/projects_store.dart';
import '../state/server_config.dart';
import '../state/streaming_foreground_service.dart';
import '../theme.dart';
import 'settings_screen.dart';
import 'tabs/chat_tab.dart';
import 'tabs/files_tab.dart';
import 'tabs/shell_tab.dart';

class MainShell extends ConsumerStatefulWidget {
  const MainShell({super.key});

  @override
  ConsumerState<MainShell> createState() => _MainShellState();
}

class _MainShellState extends ConsumerState<MainShell>
    with WidgetsBindingObserver {
  BottomTabId _tab = BottomTabId.chat;
  // 保留弹出栏的展开状态，关闭再打开时保持上次展开的项目。
  final Set<String> _sheetExpanded = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        ref.read(mainShellMountedProvider.notifier).state = true;
        unawaited(_syncAppForegroundNotifications());
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    ref.read(mainShellMountedProvider.notifier).state = false;
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_syncAppForegroundNotifications());
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      unawaited(StreamingForegroundService.instance.setAppInForeground(false));
    }
  }

  Future<void> _syncAppForegroundNotifications() async {
    await StreamingForegroundService.instance.setAppInForeground(true);
    await ChatCompletionNotifier.instance.clearSessionNotifications();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<int>(chatNotificationNavigationProvider, (previous, next) {
      if (previous == null || previous == next) return;
      if (_tab != BottomTabId.chat) {
        setState(() => _tab = BottomTabId.chat);
      }
    });
    final conn = ref.watch(activeConnectionProvider);
    final session = ref.watch(currentSessionProvider);
    final openWindows = ref.watch(openChatWindowsProvider);
    final bottomTabOrder = ref.watch(bottomTabOrderProvider);
    final s = ref.watch(stringsProvider);
    final t = AppTokens.of(context);
    if (session != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ref.read(openChatWindowsProvider.notifier).open(session);
      });
    }

    final tabs = <_TabSpec>[
      _TabSpec(BottomTabId.chat, s.tabChat, Icons.chat_bubble_outline),
      _TabSpec(BottomTabId.shell, s.tabShell, Icons.terminal),
      _TabSpec(BottomTabId.files, s.tabFiles, Icons.folder_outlined),
    ];
    final tabsById = {for (final tab in tabs) tab.id: tab};

    return Scaffold(
      body: Stack(
        children: [
          SafeArea(
            bottom: false,
            child: Column(
              children: [
                _TopBar(
                  conn: conn,
                  session: session,
                  tabIndex: _tab.index,
                  onSessionTap: () => _showSessionSwitcher(context),
                ),
                Divider(color: t.borderSubt, height: 0.5, thickness: 0.5),
                Expanded(
                  child: _LazyTabSwitcher(
                    index: _tab.index,
                    builders: [
                      _LazyBuilder(
                          builder: () => ChatTab(
                                onGitTap: () {
                                  final currentConn =
                                      ref.read(activeConnectionProvider);
                                  final currentSession =
                                      ref.read(currentSessionProvider);
                                  if (currentConn == null ||
                                      currentSession == null) {
                                    return;
                                  }
                                  _showGitPanel(
                                      context, currentConn, currentSession);
                                },
                              )),
                      const _LazyBuilder(builder: _buildShell),
                      const _LazyBuilder(builder: _buildFiles),
                    ],
                  ),
                ),
                _BottomNav(
                  tabs: [
                    for (final id in bottomTabOrder) tabsById[id]!,
                  ],
                  selectedId: _tab,
                  hasRunningChat: openWindows.windows.any(
                    (window) => window.status == OpenChatWindowStatus.running,
                  ),
                  onChanged: (id) {
                    if (id == BottomTabId.chat && _tab == BottomTabId.chat) {
                      _showOpenChatWindows(context);
                      return;
                    }
                    setState(() => _tab = id);
                  },
                  onChatSwipeUp: () => _showOpenChatWindows(context),
                ),
              ],
            ),
          ),
          const _InAppChatNotificationHost(),
        ],
      ),
    );
  }

  void _showOpenChatWindows(BuildContext context) {
    FocusManager.instance.primaryFocus?.unfocus();
    showGeneralDialog<void>(
      context: context,
      requestFocus: false,
      barrierDismissible: true,
      barrierLabel: '打开的会话',
      barrierColor: Colors.transparent,
      transitionDuration: const Duration(milliseconds: 140),
      pageBuilder: (ctx, _, __) => _OpenChatWindowsPopup(
        onSelect: (session) {
          ref.read(currentSessionProvider.notifier).state = session;
          ref
              .read(openChatWindowsProvider.notifier)
              .select(sessionKey(session));
          setState(() => _tab = BottomTabId.chat);
          Navigator.of(ctx).pop();
        },
        onClose: (key) {
          final notifier = ref.read(openChatWindowsProvider.notifier);
          final before = ref.read(openChatWindowsProvider);
          notifier.close(key);
          final after = ref.read(openChatWindowsProvider);
          if (before.currentKey == key) {
            ref.read(currentSessionProvider.notifier).state =
                after.current?.session;
          }
        },
      ),
      transitionBuilder: (_, animation, __, child) {
        final curved =
            CurvedAnimation(parent: animation, curve: Curves.easeOut);
        return FadeTransition(
          opacity: curved,
          child: SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0, 0.04),
              end: Offset.zero,
            ).animate(curved),
            child: child,
          ),
        );
      },
    );
  }

  void _showSessionSwitcher(BuildContext context) {
    FocusManager.instance.primaryFocus?.unfocus();
    showModalBottomSheet(
      context: context,
      requestFocus: false,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _SessionSwitcherSheet(
        initialExpanded: _sheetExpanded,
        onExpandedChanged: (updated) => _sheetExpanded
          ..clear()
          ..addAll(updated),
        onPop: () => Navigator.of(ctx).pop(),
      ),
    );
  }

  void _showGitPanel(
    BuildContext context,
    Connection conn,
    CurrentSession session,
  ) {
    FocusManager.instance.primaryFocus?.unfocus();
    showGeneralDialog(
      context: context,
      requestFocus: false,
      barrierDismissible: true,
      barrierLabel: 'Git',
      barrierColor: Colors.black.withValues(alpha: 0.28),
      transitionDuration: const Duration(milliseconds: 180),
      pageBuilder: (ctx, _, __) => Align(
        alignment: Alignment.centerRight,
        child: _GitSidePanel(
          api: GitApi(conn.apiBase, token: conn.token),
          cwd: session.cwd,
          title: session.label,
        ),
      ),
      transitionBuilder: (_, animation, __, child) {
        return SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(1, 0),
            end: Offset.zero,
          ).animate(CurvedAnimation(parent: animation, curve: Curves.easeOut)),
          child: child,
        );
      },
    );
  }
}

class _InAppChatNotificationHost extends ConsumerWidget {
  const _InAppChatNotificationHost();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final items = ref.watch(inAppChatNotificationsProvider);
    final current = ref.watch(currentSessionProvider);
    final currentKey =
        current == null ? null : ChatCompletionPayload.fromSession(current).key;
    final visibleItems = currentKey == null
        ? items
        : items
            .where((item) => item.payload.key != currentKey)
            .toList(growable: false);
    if (currentKey != null && visibleItems.length != items.length) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!context.mounted) return;
        ref
            .read(inAppChatNotificationsProvider.notifier)
            .dismissForPayloadKey(currentKey);
      });
    }
    if (visibleItems.isEmpty) return const SizedBox.shrink();
    final item = visibleItems.first;
    return Positioned(
      top: MediaQuery.of(context).padding.top + 64,
      right: 12,
      child: _InAppChatNotificationCard(
        key: ValueKey(item.id),
        item: item,
        onTap: () {
          ref.read(currentSessionProvider.notifier).state = CurrentSession(
            cwd: item.payload.cwd,
            label: item.payload.label,
            resumeId: item.payload.resumeId,
            agent: item.payload.agent,
            runtime: item.payload.runtime.isEmpty ? null : item.payload.runtime,
          );
          ref.read(chatNotificationNavigationProvider.notifier).state++;
          if (!item.persistent) {
            ref.read(inAppChatNotificationsProvider.notifier).dismiss(item.id);
          }
        },
        onDismiss: () =>
            ref.read(inAppChatNotificationsProvider.notifier).dismiss(item.id),
      ),
    );
  }
}

class _InAppChatNotificationCard extends StatefulWidget {
  final InAppChatNotification item;
  final VoidCallback onTap;
  final VoidCallback? onDismiss;

  const _InAppChatNotificationCard({
    super.key,
    required this.item,
    required this.onTap,
    this.onDismiss,
  });

  @override
  State<_InAppChatNotificationCard> createState() =>
      _InAppChatNotificationCardState();
}

class _InAppChatNotificationCardState extends State<_InAppChatNotificationCard>
    with TickerProviderStateMixin {
  static const _completionDuration = Duration(seconds: 10);

  late final AnimationController _controller;
  late final AnimationController _progressController;
  late final Animation<Offset> _slide;
  late final Animation<double> _fade;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 220),
      reverseDuration: const Duration(milliseconds: 150),
    );
    _progressController = AnimationController(
      vsync: this,
      duration: _completionDuration,
    );
    final curved =
        CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic);
    _slide = Tween<Offset>(
      begin: const Offset(1.05, 0),
      end: Offset.zero,
    ).animate(curved);
    _fade = CurvedAnimation(parent: _controller, curve: Curves.easeOut);
    _controller.forward();
    if (!widget.item.persistent) {
      _progressController.forward();
      _timer = Timer(_completionDuration, _dismiss);
    }
  }

  Future<void> _dismiss() async {
    _timer?.cancel();
    if (!mounted) return;
    await _controller.reverse();
    if (mounted) widget.onDismiss?.call();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _progressController.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    final isApproval = widget.item.kind == InAppChatNotificationKind.approval;
    final accent = isApproval ? t.warning : t.success;
    final screenWidth = MediaQuery.sizeOf(context).width;
    final width = max(158.0, min(screenWidth * 0.5, 190.0));
    return SlideTransition(
      position: _slide,
      child: FadeTransition(
        opacity: _fade,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: widget.onTap,
            borderRadius: BorderRadius.circular(13),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(13),
              child: BackdropFilter(
                filter: ui.ImageFilter.blur(sigmaX: 11, sigmaY: 11),
                child: Container(
                  width: width,
                  padding: const EdgeInsets.fromLTRB(8, 7, 8, 0),
                  foregroundDecoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(13),
                    gradient: LinearGradient(
                      colors: [
                        accent.withValues(alpha: 0.11),
                        Colors.white.withValues(alpha: 0.035),
                        Colors.transparent,
                      ],
                      stops: const [0, 0.55, 1],
                    ),
                  ),
                  decoration: BoxDecoration(
                    color: t.surface.withValues(alpha: 0.68),
                    borderRadius: BorderRadius.circular(13),
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.025),
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.18),
                        blurRadius: 18,
                        offset: const Offset(0, 10),
                      ),
                    ],
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          Container(
                            width: 21,
                            height: 21,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: accent.withValues(alpha: 0.12),
                              boxShadow: [
                                BoxShadow(
                                  color: accent.withValues(alpha: 0.14),
                                  blurRadius: 14,
                                ),
                              ],
                            ),
                            alignment: Alignment.center,
                            child: Icon(
                              isApproval
                                  ? Icons.priority_high_rounded
                                  : Icons.done_rounded,
                              size: 13,
                              color: accent,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              isApproval ? widget.item.title : widget.item.body,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: t.text,
                                fontSize: 12.5,
                                fontWeight: FontWeight.w700,
                                height: 1.22,
                                shadows: [
                                  Shadow(
                                    color: Colors.black.withValues(alpha: 0.28),
                                    blurRadius: 10,
                                  ),
                                ],
                              ),
                            ),
                          ),
                          if (widget.item.persistent) ...[
                            const SizedBox(width: 3),
                            GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onTap: _dismiss,
                              child: SizedBox(
                                width: 24,
                                height: 24,
                                child: Icon(Icons.close_rounded,
                                    color: t.textDim, size: 15),
                              ),
                            ),
                          ],
                        ],
                      ),
                      if (!widget.item.persistent) ...[
                        const SizedBox(height: 7),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: AnimatedBuilder(
                            animation: _progressController,
                            builder: (_, __) => FractionallySizedBox(
                              widthFactor:
                                  1 - _progressController.value.clamp(0, 1),
                              child: Container(
                                height: 2,
                                decoration: BoxDecoration(
                                  color: t.success.withValues(alpha: 0.72),
                                  borderRadius: BorderRadius.circular(999),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ── Tab helpers ───────────────────────────────────────────────

class _TabSpec {
  final BottomTabId id;
  final String label;
  final IconData icon;
  const _TabSpec(this.id, this.label, this.icon);
}

Widget _buildShell() => const ShellTab();
Widget _buildFiles() => const FilesTab();

class _LazyBuilder {
  final Widget Function() builder;
  const _LazyBuilder({required this.builder});
}

class _LazyTabSwitcher extends StatefulWidget {
  final int index;
  final List<_LazyBuilder> builders;
  const _LazyTabSwitcher({required this.index, required this.builders});

  @override
  State<_LazyTabSwitcher> createState() => _LazyTabSwitcherState();
}

class _LazyTabSwitcherState extends State<_LazyTabSwitcher> {
  late final List<Widget?> _children;
  late final Set<int> _visited;

  @override
  void initState() {
    super.initState();
    _children = List<Widget?>.filled(widget.builders.length, null);
    _visited = <int>{};
    _ensureMounted(widget.index);
  }

  @override
  void didUpdateWidget(covariant _LazyTabSwitcher oldWidget) {
    super.didUpdateWidget(oldWidget);
    _ensureMounted(widget.index);
  }

  void _ensureMounted(int i) {
    if (!_visited.contains(i)) {
      _visited.add(i);
      _children[i] = widget.builders[i].builder();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: List.generate(widget.builders.length, (i) {
        if (!_visited.contains(i)) return const SizedBox.shrink();
        return Offstage(
          offstage: i != widget.index,
          child: TickerMode(enabled: i == widget.index, child: _children[i]!),
        );
      }),
    );
  }
}

// ── Top bar ───────────────────────────────────────────────────

class _TopBar extends StatelessWidget {
  final Connection? conn;
  final CurrentSession? session;
  final int tabIndex;
  final VoidCallback onSessionTap;
  const _TopBar({
    required this.conn,
    required this.session,
    required this.tabIndex,
    required this.onSessionTap,
  });

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    final connEmoji = conn?.emoji ?? '🖥️';
    final isChat = tabIndex == 0 && session != null;
    final title = session?.label ?? '选择工作目录';
    final chatPrefix = isChat ? _agentLabel(session!.agent) : null;
    return SizedBox(
      height: 52,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6),
        child: Row(
          children: [
            // Left: back to project picker
            InkWell(
              onTap: () => Navigator.of(context).pop(),
              borderRadius: BorderRadius.circular(10),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.arrow_back_ios_new,
                        size: 14, color: t.textMuted),
                    const SizedBox(width: 3),
                    Text(connEmoji, style: const TextStyle(fontSize: 16)),
                  ],
                ),
              ),
            ),

            // Center: fixed runtime prefix + scrollable session title.
            Expanded(
              child: Container(
                height: 34,
                margin: const EdgeInsets.symmetric(horizontal: 4),
                decoration: BoxDecoration(
                  color: t.surfaceHi,
                  border: Border.all(color: t.border),
                  borderRadius: BorderRadius.circular(10),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: Row(
                  children: [
                    Icon(
                      isChat ? Icons.smart_toy_outlined : Icons.folder_outlined,
                      size: 13,
                      color: t.textMuted,
                    ),
                    const SizedBox(width: 5),
                    if (chatPrefix != null) ...[
                      Text(
                        chatPrefix,
                        maxLines: 1,
                        softWrap: false,
                        style: TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w700,
                          color: t.text,
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                        child: Text(
                          '·',
                          style: TextStyle(
                            fontSize: 13.5,
                            fontWeight: FontWeight.w600,
                            color: t.textDim,
                          ),
                        ),
                      ),
                    ],
                    Expanded(
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        physics: const BouncingScrollPhysics(),
                        child: Text(
                          title,
                          maxLines: 1,
                          softWrap: false,
                          style: TextStyle(
                            fontSize: isChat ? 13.5 : 13,
                            fontWeight:
                                isChat ? FontWeight.w500 : FontWeight.w600,
                            color: session != null ? t.text : t.textDim,
                          ),
                        ),
                      ),
                    ),
                    if (!isChat) ...[
                      const SizedBox(width: 4),
                      Icon(Icons.expand_more, size: 15, color: t.textMuted),
                    ],
                  ],
                ),
              ),
            ),

            IconButton(
              icon: Icon(Icons.more_horiz, size: 20, color: t.textMuted),
              onPressed: onSessionTap,
              padding: const EdgeInsets.all(6),
              constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
              tooltip: '切换会话',
            ),

            // Right: settings button
            IconButton(
              icon: Icon(Icons.settings_outlined, size: 19, color: t.textMuted),
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const SettingsScreen()),
              ),
              padding: const EdgeInsets.all(6),
              constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
            ),
          ],
        ),
      ),
    );
  }

  String _agentLabel(AgentKind agent) {
    return switch (agent) {
      AgentKind.claude => 'Claude',
      AgentKind.codex => 'Codex',
      AgentKind.gemini => 'Gemini',
    };
  }
}

class _GitSidePanel extends StatefulWidget {
  final GitApi api;
  final String cwd;
  final String title;
  const _GitSidePanel({
    required this.api,
    required this.cwd,
    required this.title,
  });

  @override
  State<_GitSidePanel> createState() => _GitSidePanelState();
}

class _GitSidePanelState extends State<_GitSidePanel> {
  late Future<GitStatus> _statusFuture;
  GitChangedFile? _selected;
  Future<String>? _diffFuture;

  @override
  void initState() {
    super.initState();
    _statusFuture = widget.api.status(widget.cwd);
  }

  void _refresh() {
    setState(() {
      _selected = null;
      _diffFuture = null;
      _statusFuture = widget.api.status(widget.cwd);
    });
  }

  void _select(GitChangedFile file) {
    setState(() {
      _selected = file;
      _diffFuture = widget.api.diff(cwd: widget.cwd, path: file.path);
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    final width = min(MediaQuery.of(context).size.width * 0.92, 420.0);
    return Material(
      color: t.surface,
      child: SafeArea(
        child: SizedBox(
          width: width,
          height: double.infinity,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
                child: Row(
                  children: [
                    Icon(Icons.account_tree_outlined,
                        size: 18, color: t.accent),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Git',
                            style: TextStyle(
                              color: t.text,
                              fontWeight: FontWeight.w700,
                              fontSize: 15,
                            ),
                          ),
                          Text(
                            widget.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(color: t.textDim, fontSize: 11),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      onPressed: _refresh,
                      icon: Icon(Icons.refresh, size: 18, color: t.textMuted),
                    ),
                    IconButton(
                      onPressed: () => Navigator.of(context).pop(),
                      icon: Icon(Icons.close, size: 18, color: t.textMuted),
                    ),
                  ],
                ),
              ),
              Divider(color: t.borderSubt, height: 0.5),
              Expanded(
                child: FutureBuilder<GitStatus>(
                  future: _statusFuture,
                  builder: (context, snap) {
                    if (snap.connectionState != ConnectionState.done) {
                      return const Center(
                        child: CircularProgressIndicator(strokeWidth: 2),
                      );
                    }
                    if (snap.hasError) {
                      return Center(
                        child: Padding(
                          padding: const EdgeInsets.all(20),
                          child: Text(
                            '${snap.error}',
                            style: TextStyle(color: t.error, fontSize: 12),
                          ),
                        ),
                      );
                    }
                    final status = snap.data!;
                    return Column(
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(14, 10, 14, 8),
                          child: Row(
                            children: [
                              Text(
                                status.branch,
                                style: TextStyle(
                                  color: t.text,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              const Spacer(),
                              Text(
                                '${status.files.length} files',
                                style:
                                    TextStyle(color: t.textDim, fontSize: 11),
                              ),
                            ],
                          ),
                        ),
                        SizedBox(
                          height: 180,
                          child: status.files.isEmpty
                              ? Center(
                                  child: Text(
                                    '工作区干净',
                                    style: TextStyle(
                                        color: t.textDim, fontSize: 13),
                                  ),
                                )
                              : ListView.builder(
                                  itemCount: status.files.length,
                                  itemBuilder: (context, i) {
                                    final file = status.files[i];
                                    final active = _selected?.path == file.path;
                                    return _GitFileRow(
                                      file: file,
                                      active: active,
                                      onTap: () => _select(file),
                                    );
                                  },
                                ),
                        ),
                        Divider(color: t.borderSubt, height: 0.5),
                        Expanded(
                          child: _selected == null
                              ? Center(
                                  child: Text(
                                    '选择文件查看 diff',
                                    style: TextStyle(
                                        color: t.textDim, fontSize: 13),
                                  ),
                                )
                              : FutureBuilder<String>(
                                  future: _diffFuture,
                                  builder: (context, diffSnap) {
                                    if (diffSnap.connectionState !=
                                        ConnectionState.done) {
                                      return const Center(
                                        child: CircularProgressIndicator(
                                            strokeWidth: 2),
                                      );
                                    }
                                    if (diffSnap.hasError) {
                                      return Center(
                                        child: Padding(
                                          padding: const EdgeInsets.all(16),
                                          child: Text(
                                            '${diffSnap.error}',
                                            style: TextStyle(
                                                color: t.error, fontSize: 12),
                                          ),
                                        ),
                                      );
                                    }
                                    final diff = diffSnap.data ?? '';
                                    if (diff.trim().isEmpty) {
                                      return Center(
                                        child: Text(
                                          '没有可显示的 diff',
                                          style: TextStyle(
                                              color: t.textDim, fontSize: 13),
                                        ),
                                      );
                                    }
                                    return _UnifiedDiffView(diff: diff);
                                  },
                                ),
                        ),
                      ],
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _GitFileRow extends StatelessWidget {
  final GitChangedFile file;
  final bool active;
  final VoidCallback onTap;
  const _GitFileRow({
    required this.file,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return InkWell(
      onTap: onTap,
      child: Container(
        color: active ? t.accent.withValues(alpha: 0.08) : Colors.transparent,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        child: Row(
          children: [
            SizedBox(
              width: 28,
              child: Text(
                file.label,
                style: TextStyle(
                  color: _statusColor(t, file.label),
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                  fontFamily: 'monospace',
                ),
              ),
            ),
            Expanded(
              child: Text(
                file.path,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: t.text, fontSize: 12.5),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Color _statusColor(AppTokens t, String label) {
    if (label.contains('?') || label.contains('A')) return t.success;
    if (label.contains('D')) return t.error;
    if (label.contains('M')) return t.warning;
    return t.textMuted;
  }
}

class _UnifiedDiffView extends StatelessWidget {
  final String diff;
  const _UnifiedDiffView({required this.diff});

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [
        for (final line in diff.split('\n')) _DiffLine(line: line, tokens: t),
      ],
    );
  }
}

class _DiffLine extends StatelessWidget {
  final String line;
  final AppTokens tokens;
  const _DiffLine({required this.line, required this.tokens});

  @override
  Widget build(BuildContext context) {
    final isAdd = line.startsWith('+') && !line.startsWith('+++');
    final isDel = line.startsWith('-') && !line.startsWith('---');
    final isMeta = line.startsWith('diff ') ||
        line.startsWith('@@') ||
        line.startsWith('+++') ||
        line.startsWith('---') ||
        line.startsWith('index ');
    final bg = isAdd
        ? tokens.success.withValues(alpha: 0.10)
        : isDel
            ? tokens.error.withValues(alpha: 0.09)
            : Colors.transparent;
    final fg = isAdd
        ? tokens.success
        : isDel
            ? tokens.error
            : isMeta
                ? tokens.textDim
                : tokens.text;
    return Container(
      color: bg,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      child: SelectableText(
        line,
        style: TextStyle(
          color: fg,
          fontSize: 11,
          height: 1.35,
          fontFamily: 'monospace',
          fontWeight: isMeta ? FontWeight.w700 : FontWeight.w400,
        ),
      ),
    );
  }
}

// ── Session switcher sheet ────────────────────────────────────

class _SessionSwitcherSheet extends ConsumerStatefulWidget {
  final Set<String> initialExpanded;
  final void Function(Set<String>) onExpandedChanged;
  final VoidCallback onPop;
  const _SessionSwitcherSheet({
    required this.initialExpanded,
    required this.onExpandedChanged,
    required this.onPop,
  });

  @override
  ConsumerState<_SessionSwitcherSheet> createState() =>
      _SessionSwitcherSheetState();
}

class _SessionSwitcherSheetState extends ConsumerState<_SessionSwitcherSheet> {
  late final Set<String> _expanded;
  Timer? _pollTimer;

  @override
  void initState() {
    super.initState();
    _expanded = Set.of(widget.initialExpanded);
    // 每 5s 刷新一次已展开项目的 session 列表，实时感知 holderDeviceId 变化。
    _pollTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!mounted) return;
      for (final p in _expanded) {
        ref.invalidate(sessionsProvider(p));
      }
    });
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    final session = ref.watch(currentSessionProvider);
    final projectsAsync = ref.watch(projectsProvider);

    return Container(
      constraints:
          BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.8),
      decoration: BoxDecoration(
        color: t.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        border: Border.all(color: t.border),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Handle + header
          Padding(
            padding: const EdgeInsets.only(top: 12, bottom: 6),
            child: Center(
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                    color: t.border, borderRadius: BorderRadius.circular(2)),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 16, 10),
            child: Row(
              children: [
                Text(
                  '切换工作目录',
                  style: TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w700, color: t.text),
                ),
                const Spacer(),
                IconButton(
                  icon: Icon(Icons.refresh, size: 18, color: t.textMuted),
                  onPressed: () {
                    ref.invalidate(projectsProvider);
                    for (final p in _expanded) {
                      ref.invalidate(sessionsProvider(p));
                    }
                  },
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints(minWidth: 32, minHeight: 32),
                ),
              ],
            ),
          ),
          Divider(color: t.borderSubt, height: 0.5),

          // Project list
          Flexible(
            child: projectsAsync.when(
              loading: () => const Padding(
                padding: EdgeInsets.all(32),
                child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
              ),
              error: (e, _) => Padding(
                padding: const EdgeInsets.all(20),
                child: Text('载入失败：$e',
                    style: TextStyle(color: t.error, fontSize: 13)),
              ),
              data: (projects) => projects.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text('没有可用项目',
                          style: TextStyle(color: t.textDim, fontSize: 14)),
                    )
                  : ListView(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      shrinkWrap: true,
                      children: [
                        for (final p in projects)
                          _SheetProjectNode(
                            project: p,
                            isExpanded: _expanded.contains(p.path),
                            currentCwd: session?.cwd,
                            currentSessionId: session?.resumeId,
                            onToggle: () => setState(() {
                              if (_expanded.contains(p.path)) {
                                _expanded.remove(p.path);
                              } else {
                                _expanded.add(p.path);
                              }
                              widget.onExpandedChanged(_expanded);
                            }),
                            onNewSession: () {
                              final agent = ref
                                  .read(projectDefaultAgentProvider.notifier)
                                  .forProject(p.path);
                              ref.read(selectedProjectProvider.notifier).state =
                                  p;
                              ref.read(currentSessionProvider.notifier).state =
                                  CurrentSession(
                                cwd: p.path,
                                label: p.name,
                                agent: agent,
                                runtime: ref
                                    .read(projectAgentRuntimeProvider.notifier)
                                    .runtimeFor(p.path, agent),
                              );
                              widget.onPop();
                            },
                            onPickSession: (s) {
                              ref.read(selectedProjectProvider.notifier).state =
                                  p;
                              ref.read(currentSessionProvider.notifier).state =
                                  CurrentSession(
                                cwd: p.path,
                                resumeId: s.sessionId,
                                label: '${p.name} · ${s.displayTitle}',
                                agent: s.agent,
                                runtime: ref
                                    .read(projectAgentRuntimeProvider.notifier)
                                    .runtimeFor(p.path, s.agent),
                              );
                              widget.onPop();
                            },
                          ),
                      ],
                    ),
            ),
          ),

          Divider(color: t.borderSubt, height: 0.5),
          SafeArea(
            top: false,
            child: InkWell(
              onTap: () {
                widget.onPop();
                // Navigate back to project picker
                Navigator.of(context).pop();
              },
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                child: Row(
                  children: [
                    Icon(Icons.swap_horiz, size: 16, color: t.textMuted),
                    const SizedBox(width: 12),
                    Text('切换连接',
                        style: TextStyle(fontSize: 14, color: t.textMuted)),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SheetProjectNode extends ConsumerWidget {
  final Project project;
  final bool isExpanded;
  final String? currentCwd;
  final String? currentSessionId;
  final VoidCallback onToggle;
  final VoidCallback onNewSession;
  final void Function(SessionSummary) onPickSession;

  const _SheetProjectNode({
    required this.project,
    required this.isExpanded,
    required this.currentCwd,
    required this.currentSessionId,
    required this.onToggle,
    required this.onNewSession,
    required this.onPickSession,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = AppTokens.of(context);
    final isCurrent = currentCwd == project.path;
    final myDeviceId = ref.watch(deviceIdProvider).valueOrNull ?? '';
    final inAppNotifications = ref.watch(inAppChatNotificationsProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          onTap: onToggle,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 12, 10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Icon(
                    isExpanded ? Icons.folder_open : Icons.folder_outlined,
                    size: 16,
                    color: isCurrent ? t.accent : t.textMuted,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        project.name,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight:
                              isCurrent ? FontWeight.w600 : FontWeight.w500,
                          color: isCurrent ? t.accent : t.text,
                        ),
                      ),
                      Text(
                        project.path
                            .replaceFirst(RegExp(r'^/Users/[^/]+'), '~'),
                        style: TextStyle(
                            fontSize: 10,
                            color: t.textDim,
                            fontFamily: 'monospace'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                Icon(
                  isExpanded ? Icons.expand_more : Icons.chevron_right,
                  size: 16,
                  color: t.textMuted,
                ),
              ],
            ),
          ),
        ),
        if (isExpanded)
          Padding(
            padding: const EdgeInsets.only(left: 28, right: 12, bottom: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _SheetChip(
                  icon: Icons.add,
                  label: '新对话',
                  primary: true,
                  onTap: onNewSession,
                ),
                const SizedBox(height: 6),
                Consumer(
                  builder: (_, ref, __) {
                    final async = ref.watch(sessionsProvider(project.path));
                    return async.when(
                      loading: () => const Padding(
                        padding: EdgeInsets.all(8),
                        child: SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 1.5),
                        ),
                      ),
                      error: (e, _) => Text('$e',
                          style: TextStyle(fontSize: 10, color: t.error)),
                      data: (sessions) => Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (sessions.isEmpty)
                            Padding(
                              padding: const EdgeInsets.all(8),
                              child: Text('暂无历史 session',
                                  style: TextStyle(
                                      fontSize: 11, color: t.textDim)),
                            ),
                          for (final s in sessions)
                            _SheetSessionTile(
                              session: s,
                              isCurrent: s.sessionId == currentSessionId,
                              hasPendingApproval:
                                  _hasPendingApproval(inAppNotifications, s),
                              onTap: () => onPickSession(s),
                              myDeviceId: myDeviceId,
                            ),
                        ],
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
      ],
    );
  }

  bool _hasPendingApproval(
    List<InAppChatNotification> notifications,
    SessionSummary session,
  ) {
    return notifications.any((item) =>
        item.kind == InAppChatNotificationKind.approval &&
        item.payload.resumeId == session.sessionId &&
        item.payload.agent == session.agent &&
        (session.cwd == null || item.payload.cwd == session.cwd));
  }
}

class _SheetSessionTile extends StatelessWidget {
  final SessionSummary session;
  final bool isCurrent;
  final bool hasPendingApproval;
  final VoidCallback onTap;
  final String myDeviceId;
  const _SheetSessionTile(
      {required this.session,
      required this.isCurrent,
      required this.hasPendingApproval,
      required this.onTap,
      required this.myDeviceId});

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    final ts = session.lastModified;
    final timeText = ts == null
        ? ''
        : DateFormat('MM-dd HH:mm')
            .format(DateTime.fromMillisecondsSinceEpoch(ts));

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: const EdgeInsets.fromLTRB(10, 8, 8, 8),
        margin: const EdgeInsets.only(bottom: 2),
        decoration: BoxDecoration(
          color: isCurrent ? t.accentSubt : null,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          children: [
            Container(
              width: 3,
              height: 28,
              margin: const EdgeInsets.only(right: 10),
              decoration: BoxDecoration(
                color: isCurrent ? t.accent : t.border,
                borderRadius: BorderRadius.circular(1.5),
              ),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      if (hasPendingApproval) ...[
                        SizedBox(
                          width: 18,
                          height: 18,
                          child: _PulsingStatusDot(color: t.warning),
                        ),
                        const SizedBox(width: 4),
                      ] else if (isCurrent)
                        Container(
                          width: 5,
                          height: 5,
                          margin: const EdgeInsets.only(right: 6),
                          decoration: BoxDecoration(
                              color: t.accent, shape: BoxShape.circle),
                        ),
                      Flexible(
                        child: Text(
                          session.displayTitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight:
                                isCurrent ? FontWeight.w600 : FontWeight.w400,
                            color: isCurrent
                                ? t.accent
                                : (session.holderDeviceId != null
                                    ? t.textMuted
                                    : t.text),
                          ),
                        ),
                      ),
                      if (hasPendingApproval) ...[
                        const SizedBox(width: 6),
                        Text('待审批',
                            style: TextStyle(fontSize: 10, color: t.warning)),
                      ] else if (session.holderDeviceId != null) ...[
                        const SizedBox(width: 6),
                        if (session.holderDeviceId == myDeviceId) ...[
                          Container(
                            width: 6,
                            height: 6,
                            decoration: BoxDecoration(
                                color: t.success, shape: BoxShape.circle),
                          ),
                          const SizedBox(width: 3),
                          Text('进行中',
                              style: TextStyle(fontSize: 10, color: t.success)),
                        ] else ...[
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
                    ],
                  ),
                  if (timeText.isNotEmpty)
                    Text(timeText,
                        style: TextStyle(
                            fontSize: 10,
                            color: t.textDim,
                            fontFamily: 'monospace')),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SheetChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool primary;
  final VoidCallback onTap;
  const _SheetChip(
      {required this.icon,
      required this.label,
      required this.primary,
      required this.onTap});

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: primary ? t.accentSubt : null,
          border: primary ? null : Border.all(color: t.border, width: 0.6),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 13, color: primary ? t.accent : t.textMuted),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                fontSize: 13,
                color: primary ? t.accent : t.textMuted,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Bottom nav ────────────────────────────────────────────────

class _BottomNav extends StatelessWidget {
  final List<_TabSpec> tabs;
  final BottomTabId selectedId;
  final bool hasRunningChat;
  final ValueChanged<BottomTabId> onChanged;
  final VoidCallback onChatSwipeUp;
  const _BottomNav({
    required this.tabs,
    required this.selectedId,
    this.hasRunningChat = false,
    required this.onChanged,
    required this.onChatSwipeUp,
  });

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return Container(
      decoration: BoxDecoration(
        color: t.bg,
        border: Border(top: BorderSide(color: t.borderSubt, width: 0.5)),
      ),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 58,
          child: Row(
            children: List.generate(tabs.length, (i) {
              final tab = tabs[i];
              final selected = tab.id == selectedId;
              return Expanded(
                child: _NavItem(
                  label: tab.label,
                  icon: tab.icon,
                  selected: selected,
                  showRunningDot: tab.id == BottomTabId.chat && hasRunningChat,
                  onTap: () => onChanged(tab.id),
                  onSwipeUp: tab.id == BottomTabId.chat ? onChatSwipeUp : null,
                ),
              );
            }),
          ),
        ),
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool selected;
  final bool showRunningDot;
  final VoidCallback onTap;
  final VoidCallback? onSwipeUp;
  const _NavItem({
    required this.label,
    required this.icon,
    required this.selected,
    this.showRunningDot = false,
    required this.onTap,
    this.onSwipeUp,
  });

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    final color = selected ? t.accent : t.textMuted;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      onVerticalDragEnd: onSwipeUp == null
          ? null
          : (details) {
              final velocity = details.primaryVelocity ?? 0;
              if (velocity < -220) onSwipeUp!();
            },
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            Stack(
              clipBehavior: Clip.none,
              children: [
                Icon(icon, size: 22, color: color),
                if (showRunningDot)
                  Positioned(
                    right: -2,
                    top: -2,
                    child: _StatusDot(color: t.success, size: 7),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 10,
                color: color,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                letterSpacing: 0.2,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _OpenChatWindowsPopup extends ConsumerWidget {
  final ValueChanged<CurrentSession> onSelect;
  final ValueChanged<String> onClose;

  const _OpenChatWindowsPopup({
    required this.onSelect,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = AppTokens.of(context);
    final state = ref.watch(openChatWindowsProvider);
    final windows = state.windows;
    final media = MediaQuery.of(context);
    final width = min(media.size.width - 20, 390.0);
    return Material(
      color: Colors.transparent,
      child: Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => Navigator.of(context).pop(),
            ),
          ),
          Positioned(
            left: 10,
            bottom: media.padding.bottom + 62,
            width: width,
            child: Container(
              decoration: BoxDecoration(
                color: t.surface,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: t.border, width: 0.5),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.16),
                    blurRadius: 18,
                    offset: const Offset(0, 8),
                  ),
                ],
              ),
              constraints: BoxConstraints(
                maxHeight: min(media.size.height * 0.54, 420.0),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(14, 12, 10, 8),
                      child: Row(
                        children: [
                          Icon(Icons.chat_bubble_outline,
                              size: 16, color: t.accent),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              '打开的会话',
                              style: TextStyle(
                                color: t.text,
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          Icon(Icons.keyboard_arrow_down_rounded,
                              size: 18, color: t.textDim),
                        ],
                      ),
                    ),
                    Divider(color: t.borderSubt, height: 0.5, thickness: 0.5),
                    if (windows.isEmpty)
                      Padding(
                        padding: const EdgeInsets.all(22),
                        child: Text(
                          '暂无打开会话',
                          style: TextStyle(color: t.textDim, fontSize: 12),
                        ),
                      )
                    else
                      Flexible(
                        child: ListView.separated(
                          shrinkWrap: true,
                          padding: const EdgeInsets.symmetric(vertical: 6),
                          itemCount: windows.length,
                          separatorBuilder: (_, __) => Divider(
                              color: t.borderSubt, height: 0.5, thickness: 0.5),
                          itemBuilder: (_, i) {
                            final window = windows[i];
                            final selected = window.key == state.currentKey;
                            return _OpenChatWindowRow(
                              window: window,
                              selected: selected,
                              onSelect: () => onSelect(window.session),
                              onClose: () => onClose(window.key),
                            );
                          },
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _OpenChatWindowRow extends StatelessWidget {
  final OpenChatWindow window;
  final bool selected;
  final VoidCallback onSelect;
  final VoidCallback onClose;

  const _OpenChatWindowRow({
    required this.window,
    required this.selected,
    required this.onSelect,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    final session = window.session;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color:
              selected ? t.accent.withValues(alpha: 0.08) : Colors.transparent,
          borderRadius: BorderRadius.circular(7),
          border: Border.all(
            color: selected
                ? t.accent.withValues(alpha: 0.24)
                : Colors.transparent,
            width: 0.5,
          ),
        ),
        child: InkWell(
          onTap: onSelect,
          borderRadius: BorderRadius.circular(7),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 8, 4, 8),
            child: Row(
              children: [
                _WindowStatusDot(status: window.status),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(
                            _agentLabel(session.agent),
                            style: TextStyle(
                              color: selected ? t.accent : t.textMuted,
                              fontSize: 10.5,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              session.label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: t.text,
                                fontSize: 13,
                                fontWeight: selected
                                    ? FontWeight.w700
                                    : FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 3),
                      Text(
                        _compactPath(session.cwd),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: t.textDim,
                          fontSize: 10.5,
                          fontFamily: 'monospace',
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  onPressed: onClose,
                  icon: Icon(Icons.close_rounded, size: 16, color: t.textDim),
                  padding: const EdgeInsets.all(8),
                  constraints:
                      const BoxConstraints(minWidth: 36, minHeight: 36),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _agentLabel(AgentKind agent) {
    return switch (agent) {
      AgentKind.claude => 'Claude',
      AgentKind.codex => 'Codex',
      AgentKind.gemini => 'Gemini',
    };
  }

  String _compactPath(String path) {
    final folded = path.replaceFirst(RegExp(r'^/Users/[^/]+'), '~');
    if (folded.length <= 48) return folded;
    final parts = folded.split('/');
    if (parts.length <= 2) return folded;
    return '${parts.first}/…/${parts.last}';
  }
}

class _WindowStatusDot extends StatelessWidget {
  final OpenChatWindowStatus status;

  const _WindowStatusDot({required this.status});

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    final color = _statusColor(t, status);
    final animated = status == OpenChatWindowStatus.running ||
        status == OpenChatWindowStatus.waiting;
    if (!animated) {
      return _StatusDot(color: color, size: 9);
    }
    return SizedBox(
      width: 20,
      height: 20,
      child: _PulsingStatusDot(color: color),
    );
  }

  Color _statusColor(AppTokens t, OpenChatWindowStatus status) {
    return switch (status) {
      OpenChatWindowStatus.running => t.success,
      OpenChatWindowStatus.waiting => t.warning,
      OpenChatWindowStatus.error => t.error,
      OpenChatWindowStatus.idle => t.textDim,
    };
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
        final pulseSize = 9.0 + value * 11.0;
        final opacity = (1.0 - value).clamp(0.0, 1.0) * 0.28;
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
              _StatusDot(color: widget.color, size: 9),
            ],
          ),
        );
      },
    );
  }
}

class _StatusDot extends StatelessWidget {
  final Color color;
  final double size;

  const _StatusDot({required this.color, this.size = 8});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
      ),
    );
  }
}
