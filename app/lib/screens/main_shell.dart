import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../api/sessions_api.dart';
import '../i18n/locale_provider.dart';
import '../state/projects_store.dart';
import '../state/server_config.dart';
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

class _MainShellState extends ConsumerState<MainShell> {
  int _index = 0;
  // 保留弹出栏的展开状态，关闭再打开时保持上次展开的项目。
  final Set<String> _sheetExpanded = {};

  @override
  Widget build(BuildContext context) {
    final conn = ref.watch(activeConnectionProvider);
    final session = ref.watch(currentSessionProvider);
    final s = ref.watch(stringsProvider);
    final t = AppTokens.of(context);

    final tabs = <_TabSpec>[
      _TabSpec(s.tabChat, Icons.chat_bubble_outline),
      _TabSpec(s.tabShell, Icons.terminal),
      _TabSpec(s.tabFiles, Icons.folder_outlined),
    ];

    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            _TopBar(
              conn: conn,
              session: session,
              onSessionTap: () => _showSessionSwitcher(context),
            ),
            Divider(color: t.borderSubt, height: 0.5, thickness: 0.5),
            Expanded(
              child: _LazyTabSwitcher(
                index: _index,
                builders: const [
                  _LazyBuilder(builder: _buildChat),
                  _LazyBuilder(builder: _buildShell),
                  _LazyBuilder(builder: _buildFiles),
                ],
              ),
            ),
            _BottomNav(
              tabs: tabs,
              index: _index,
              onChanged: (i) => setState(() => _index = i),
            ),
          ],
        ),
      ),
    );
  }

  void _showSessionSwitcher(BuildContext context) {
    showModalBottomSheet(
      context: context,
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
}

// ── Tab helpers ───────────────────────────────────────────────

class _TabSpec {
  final String label;
  final IconData icon;
  const _TabSpec(this.label, this.icon);
}

Widget _buildChat() => const ChatTab();
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
  final VoidCallback onSessionTap;
  const _TopBar({
    required this.conn,
    required this.session,
    required this.onSessionTap,
  });

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    final connEmoji = conn?.emoji ?? '🖥️';

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
                    Icon(Icons.arrow_back_ios_new, size: 14, color: t.textMuted),
                    const SizedBox(width: 3),
                    Text(connEmoji, style: const TextStyle(fontSize: 16)),
                  ],
                ),
              ),
            ),

            // Center: context pill (project + session)
            Expanded(
              child: GestureDetector(
                onTap: onSessionTap,
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
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.folder_outlined, size: 13, color: t.textMuted),
                      const SizedBox(width: 5),
                      Flexible(
                        child: Text(
                          session?.label ?? '选择工作目录',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                            color: session != null ? t.text : t.textDim,
                          ),
                        ),
                      ),
                      const SizedBox(width: 4),
                      Icon(Icons.expand_more, size: 15, color: t.textMuted),
                    ],
                  ),
                ),
              ),
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
  ConsumerState<_SessionSwitcherSheet> createState() => _SessionSwitcherSheetState();
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
      constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.8),
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
                width: 36, height: 4,
                decoration: BoxDecoration(color: t.border, borderRadius: BorderRadius.circular(2)),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 16, 10),
            child: Row(
              children: [
                Text(
                  '切换工作目录',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: t.text),
                ),
                const Spacer(),
                IconButton(
                  icon: Icon(Icons.refresh, size: 18, color: t.textMuted),
                  onPressed: () {
                    ref.invalidate(projectsProvider);
                    for (final p in _expanded) { ref.invalidate(sessionsProvider(p)); }
                  },
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
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
                child: Text('载入失败：$e', style: TextStyle(color: t.error, fontSize: 13)),
              ),
              data: (projects) => projects.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text('没有可用项目', style: TextStyle(color: t.textDim, fontSize: 14)),
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
                              ref.read(selectedProjectProvider.notifier).state = p;
                              ref.read(currentSessionProvider.notifier).state =
                                  CurrentSession(cwd: p.path, label: p.name);
                              widget.onPop();
                            },
                            onPickSession: (s) {
                              ref.read(selectedProjectProvider.notifier).state = p;
                              ref.read(currentSessionProvider.notifier).state = CurrentSession(
                                cwd: p.path,
                                resumeId: s.sessionId,
                                label: '${p.name} · ${s.displayTitle}',
                                agent: s.agent,
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
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                child: Row(
                  children: [
                    Icon(Icons.swap_horiz, size: 16, color: t.textMuted),
                    const SizedBox(width: 12),
                    Text('切换连接', style: TextStyle(fontSize: 14, color: t.textMuted)),
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
                          fontWeight: isCurrent ? FontWeight.w600 : FontWeight.w500,
                          color: isCurrent ? t.accent : t.text,
                        ),
                      ),
                      Text(
                        project.path.replaceFirst(RegExp(r'^/Users/[^/]+'), '~'),
                        style: TextStyle(fontSize: 10, color: t.textDim, fontFamily: 'monospace'),
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
                          width: 14, height: 14,
                          child: CircularProgressIndicator(strokeWidth: 1.5),
                        ),
                      ),
                      error: (e, _) => Text('$e', style: TextStyle(fontSize: 10, color: t.error)),
                      data: (sessions) => Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (sessions.isEmpty)
                            Padding(
                              padding: const EdgeInsets.all(8),
                              child: Text('暂无历史 session',
                                  style: TextStyle(fontSize: 11, color: t.textDim)),
                            ),
                          for (final s in sessions)
                            _SheetSessionTile(
                              session: s,
                              isCurrent: s.sessionId == currentSessionId,
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
}

class _SheetSessionTile extends StatelessWidget {
  final SessionSummary session;
  final bool isCurrent;
  final VoidCallback onTap;
  final String myDeviceId;
  const _SheetSessionTile({required this.session, required this.isCurrent, required this.onTap, required this.myDeviceId});

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    final ts = session.lastModified;
    final timeText = ts == null
        ? ''
        : DateFormat('MM-dd HH:mm').format(DateTime.fromMillisecondsSinceEpoch(ts));

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
              width: 3, height: 28,
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
                      if (isCurrent)
                        Container(
                          width: 5, height: 5,
                          margin: const EdgeInsets.only(right: 6),
                          decoration: BoxDecoration(color: t.accent, shape: BoxShape.circle),
                        ),
                      Flexible(
                        child: Text(
                          session.displayTitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: isCurrent ? FontWeight.w600 : FontWeight.w400,
                            color: isCurrent ? t.accent : (session.holderDeviceId != null ? t.textMuted : t.text),
                          ),
                        ),
                      ),
                      if (session.holderDeviceId != null) ...[
                        const SizedBox(width: 6),
                        if (session.holderDeviceId == myDeviceId) ...[
                          Container(
                            width: 6, height: 6,
                            decoration: BoxDecoration(color: t.success, shape: BoxShape.circle),
                          ),
                          const SizedBox(width: 3),
                          Text('进行中', style: TextStyle(fontSize: 10, color: t.success)),
                        ] else ...[
                          Container(
                            width: 6, height: 6,
                            decoration: BoxDecoration(color: t.warning, shape: BoxShape.circle),
                          ),
                          const SizedBox(width: 3),
                          Text('占用中', style: TextStyle(fontSize: 10, color: t.warning)),
                        ],
                      ],
                    ],
                  ),
                  if (timeText.isNotEmpty)
                    Text(timeText, style: TextStyle(fontSize: 10, color: t.textDim, fontFamily: 'monospace')),
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
  const _SheetChip({required this.icon, required this.label, required this.primary, required this.onTap});

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
  final int index;
  final ValueChanged<int> onChanged;
  const _BottomNav({required this.tabs, required this.index, required this.onChanged});

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
              final selected = i == index;
              return Expanded(
                child: _NavItem(
                  label: tabs[i].label,
                  icon: tabs[i].icon,
                  selected: selected,
                  onTap: () => onChanged(i),
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
  final VoidCallback onTap;
  const _NavItem(
      {required this.label, required this.icon, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    final color = selected ? t.accent : t.textMuted;
    return InkWell(
      onTap: onTap,
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 22, color: color),
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
