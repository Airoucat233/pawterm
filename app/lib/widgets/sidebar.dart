import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../api/sessions_api.dart';
import '../i18n/locale_provider.dart';
import '../screens/connections_screen.dart';
import '../screens/git_page.dart';
import '../screens/settings_screen.dart';
import '../state/projects_store.dart';
import '../theme.dart';

class Sidebar extends ConsumerStatefulWidget {
  const Sidebar({super.key});

  @override
  ConsumerState<Sidebar> createState() => _SidebarState();
}

class _SidebarState extends ConsumerState<Sidebar> {
  final Set<String> _expanded = {};

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    final s = ref.watch(stringsProvider);
    final projectsAsync = ref.watch(projectsProvider);
    final session = ref.watch(currentSessionProvider);

    return Drawer(
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 16, 4),
              child: Text(
                s.sidebarProjectsTitle,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: t.text,
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 16, 12),
              child: Text(
                s.sidebarProjectsSubtitle,
                style: TextStyle(
                  fontSize: 11,
                  color: t.textDim,
                ),
              ),
            ),
            Divider(color: t.borderSubt, height: 0.5),
            Expanded(
              child: projectsAsync.when(
                loading: () => const Center(child: CircularProgressIndicator(strokeWidth: 2)),
                error: (e, _) => Center(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(
                      '${s.sidebarLoadFailed}: $e',
                      style: TextStyle(color: t.error, fontSize: 12),
                    ),
                  ),
                ),
                data: (projects) {
                  if (projects.isEmpty) {
                    return Center(
                      child: Text(
                        s.sidebarNoProjects,
                        style: TextStyle(color: t.textMuted, fontSize: 13),
                      ),
                    );
                  }
                  return ListView.builder(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    itemCount: projects.length,
                    itemBuilder: (_, i) {
                      final p = projects[i];
                      final isExpanded = _expanded.contains(p.path);
                      return _ProjectNode(
                        project: p,
                        expanded: isExpanded,
                        currentSessionId: session?.resumeId,
                        isCurrent: session?.cwd == p.path,
                        onToggle: () => setState(() {
                          if (isExpanded) {
                            _expanded.remove(p.path);
                          } else {
                            _expanded.add(p.path);
                          }
                        }),
                        onNewSession: () {
                          ref.read(selectedProjectProvider.notifier).state = p;
                          ref.read(currentSessionProvider.notifier).state =
                              CurrentSession(cwd: p.path, label: p.name);
                          Navigator.of(context).pop();
                        },
                        onPickSession: (s) {
                          ref.read(selectedProjectProvider.notifier).state = p;
                          ref.read(currentSessionProvider.notifier).state = CurrentSession(
                            cwd: p.path,
                            resumeId: s.sessionId,
                            label: '${p.name} · ${s.displayTitle}',
                            agent: s.agent,
                          );
                          Navigator.of(context).pop();
                        },
                        onOpenGit: () {
                          Navigator.of(context).pop();
                          Navigator.of(context).push(
                            MaterialPageRoute(builder: (_) => GitPage(cwd: p.path, name: p.name)),
                          );
                        },
                      );
                    },
                  );
                },
              ),
            ),
            Divider(color: t.borderSubt, height: 0.5),
            _FooterItem(
              icon: Icons.refresh,
              label: s.sidebarRefresh,
              onTap: () {
                ref.invalidate(projectsProvider);
                for (final p in _expanded) {
                  ref.invalidate(sessionsProvider(p));
                }
              },
            ),
            _FooterItem(
              icon: Icons.tune,
              label: s.sidebarSettings,
              onTap: () {
                Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const SettingsScreen()),
                );
              },
            ),
            _FooterItem(
              icon: Icons.dns_outlined,
              label: s.sidebarManageConnections,
              onTap: () {
                Navigator.of(context).pushAndRemoveUntil(
                  MaterialPageRoute(builder: (_) => const ConnectionsScreen()),
                  (_) => false,
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _ProjectNode extends ConsumerWidget {
  final Project project;
  final bool expanded;
  final bool isCurrent;
  final String? currentSessionId;
  final VoidCallback onToggle;
  final VoidCallback onNewSession;
  final VoidCallback onOpenGit;
  final void Function(SessionSummary) onPickSession;

  const _ProjectNode({
    required this.project,
    required this.expanded,
    required this.isCurrent,
    required this.currentSessionId,
    required this.onToggle,
    required this.onNewSession,
    required this.onOpenGit,
    required this.onPickSession,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = AppTokens.of(context);

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
                    expanded ? Icons.folder_open : Icons.folder_outlined,
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
                          fontSize: 13,
                          fontWeight: isCurrent ? FontWeight.w600 : FontWeight.w500,
                          color: isCurrent ? t.accent : t.text,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        _humanPath(project.path),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 10,
                          color: t.textDim,
                          fontFamily: 'monospace',
                          height: 1.4,
                        ),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Icon(
                    expanded ? Icons.expand_more : Icons.chevron_right,
                    size: 16,
                    color: t.textMuted,
                  ),
                ),
              ],
            ),
          ),
        ),
        if (expanded)
          _SessionsList(
            project: project,
            currentSessionId: currentSessionId,
            onNewSession: onNewSession,
            onOpenGit: onOpenGit,
            onPickSession: onPickSession,
          ),
      ],
    );
  }

  /// Replace /Users/<name> with ~ but keep the full remainder for clarity.
  String _humanPath(String path) {
    return path.replaceFirst(RegExp(r'^/Users/[^/]+'), '~');
  }
}

class _SessionsList extends ConsumerWidget {
  final Project project;
  final String? currentSessionId;
  final VoidCallback onNewSession;
  final VoidCallback onOpenGit;
  final void Function(SessionSummary) onPickSession;
  const _SessionsList({
    required this.project,
    required this.currentSessionId,
    required this.onNewSession,
    required this.onOpenGit,
    required this.onPickSession,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = AppTokens.of(context);
    final async = ref.watch(sessionsProvider(project.path));

    return Padding(
      padding: const EdgeInsets.only(left: 28, right: 12, bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(
              children: [
                Expanded(
                  child: _ChipButton(
                    icon: Icons.add,
                    label: '新对话',
                    primary: true,
                    onTap: onNewSession,
                  ),
                ),
                const SizedBox(width: 6),
                _ChipButton(
                  icon: Icons.alt_route,
                  label: 'Git',
                  primary: false,
                  onTap: onOpenGit,
                ),
              ],
            ),
          ),
          async.when(
            loading: () => Padding(
              padding: const EdgeInsets.all(8),
              child: SizedBox(
                height: 14,
                width: 14,
                child: CircularProgressIndicator(strokeWidth: 1.5, color: t.textMuted),
              ),
            ),
            error: (e, _) => Padding(
              padding: const EdgeInsets.all(8),
              child: Text('载入失败：$e', style: TextStyle(fontSize: 10, color: t.error)),
            ),
            data: (sessions) => Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (sessions.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(8),
                    child: Text(
                      '暂无历史 session',
                      style: TextStyle(fontSize: 11, color: t.textDim),
                    ),
                  ),
                for (final s in sessions)
                  _SessionTile(
                    session: s,
                    isCurrent: s.sessionId == currentSessionId,
                    onTap: () => onPickSession(s),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SessionTile extends StatelessWidget {
  final SessionSummary session;
  final bool isCurrent;
  final VoidCallback onTap;
  const _SessionTile({required this.session, required this.isCurrent, required this.onTap});

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
          crossAxisAlignment: CrossAxisAlignment.center,
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
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      if (isCurrent) ...[
                        Container(
                          width: 5,
                          height: 5,
                          margin: const EdgeInsets.only(right: 6),
                          decoration: BoxDecoration(color: t.accent, shape: BoxShape.circle),
                        ),
                      ],
                      Flexible(
                        child: Text(
                          session.displayTitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: isCurrent ? FontWeight.w600 : FontWeight.w400,
                            color: isCurrent ? t.accent : t.text,
                          ),
                        ),
                      ),
                    ],
                  ),
                  if (timeText.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        timeText,
                        style: TextStyle(fontSize: 10, color: t.textDim, fontFamily: 'monospace'),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ChipButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool primary;
  final VoidCallback onTap;
  const _ChipButton({required this.icon, required this.label, required this.primary, required this.onTap});

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

class _FooterItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  const _FooterItem({required this.icon, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        child: Row(
          children: [
            Icon(icon, size: 16, color: t.textMuted),
            const SizedBox(width: 12),
            Text(label, style: TextStyle(fontSize: 13, color: t.textMuted)),
          ],
        ),
      ),
    );
  }
}
