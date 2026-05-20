import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../i18n/locale_provider.dart' show stringsProvider;
import '../i18n/strings.dart';
import '../state/server_config.dart';
import '../theme.dart';
import 'add_connection_sheet.dart';
import 'project_picker_screen.dart';
import 'settings_screen.dart';

class ConnectionsScreen extends ConsumerStatefulWidget {
  const ConnectionsScreen({super.key});

  @override
  ConsumerState<ConnectionsScreen> createState() => _ConnectionsScreenState();
}

class _ConnectionsScreenState extends ConsumerState<ConnectionsScreen> {
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    final connections = ref.watch(connectionsProvider);
    final active = ref.watch(activeConnectionProvider);
    final s = ref.watch(stringsProvider);
    final t = AppTokens.of(context);

    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: _tab == 0
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _Header(onAdd: () => _showAddSheet(context)),
                  Expanded(
                    child: connections.isEmpty
                        ? _EmptyState(onAdd: () => _showAddSheet(context))
                        : _ConnectionList(connections: connections, active: active),
                  ),
                ],
              )
            : const SettingsBody(),
      ),
      bottomNavigationBar: Container(
        decoration: BoxDecoration(
          color: t.bg,
          border: Border(top: BorderSide(color: t.borderSubt, width: 0.5)),
        ),
        child: SafeArea(
          top: false,
          child: SizedBox(
            height: 58,
            child: Row(
              children: [
                _NavItem(
                  icon: Icons.monitor_outlined,
                  label: s.settingsTabConnections,
                  selected: _tab == 0,
                  onTap: () => setState(() => _tab = 0),
                ),
                _NavItem(
                  icon: Icons.settings_outlined,
                  label: s.settingsTabSettings,
                  selected: _tab == 1,
                  onTap: () => setState(() => _tab = 1),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _showAddSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const AddConnectionSheet(),
    );
  }
}

class _NavItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _NavItem({required this.icon, required this.label, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    final color = selected ? t.accent : t.textMuted;
    return Expanded(
      child: InkWell(
        onTap: onTap,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 22, color: color),
            const SizedBox(height: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 10,
                color: color,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  final VoidCallback onAdd;
  const _Header({required this.onAdd});

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 16, 12),
      child: Row(
        children: [
          Expanded(
            child: Text(
              'Connections',
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w700,
                color: t.text,
                letterSpacing: -0.4,
              ),
            ),
          ),
          GestureDetector(
            onTap: onAdd,
            child: Container(
              width: 36,
              height: 36,
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

class _EmptyState extends ConsumerWidget {
  final VoidCallback onAdd;
  const _EmptyState({required this.onAdd});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = AppTokens.of(context);
    final s = ref.watch(stringsProvider);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 80,
              height: 80,
              decoration: BoxDecoration(
                color: t.surface,
                border: Border.all(color: t.border),
                borderRadius: BorderRadius.circular(24),
              ),
              child: const Center(child: Text('🖥️', style: TextStyle(fontSize: 36))),
            ),
            const SizedBox(height: 20),
            Text(
              s.connectionsEmpty,
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: t.text),
            ),
            const SizedBox(height: 8),
            Text(
              s.connectionsEmptyHintLong,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: t.textMuted, height: 1.7),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: onAdd,
              icon: const Icon(Icons.add, size: 16),
              label: Text(s.connectionsAddFirst),
            ),
          ],
        ),
      ),
    );
  }
}

class _ConnectionList extends ConsumerWidget {
  final List<Connection> connections;
  final Connection? active;
  const _ConnectionList({required this.connections, required this.active});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(stringsProvider);
    final recent = connections
        .where((e) => e.lastConnected != null)
        .toList()
      ..sort((a, b) => b.lastConnected!.compareTo(a.lastConnected!));
    final others = connections.where((e) => e.lastConnected == null).toList();

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
      children: [
        if (recent.isNotEmpty) ...[
          _SectionLabel(s.connectionsSectionRecent),
          for (final e in recent)
            _ConnCard(entry: e, isActive: e.id == active?.id),
        ],
        if (others.isNotEmpty) ...[
          _SectionLabel(recent.isEmpty ? s.connectionsSectionAll : s.connectionsSectionOther),
          for (final e in others)
            _ConnCard(entry: e, isActive: e.id == active?.id),
        ],
      ],
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String label;
  const _SectionLabel(this.label);

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 4, 2, 10),
      child: Text(
        label.toUpperCase(),
        style: TextStyle(
          fontSize: 10.5,
          fontWeight: FontWeight.w600,
          color: t.textDim,
          letterSpacing: 0.7,
        ),
      ),
    );
  }
}

class _ConnCard extends ConsumerWidget {
  final Connection entry;
  final bool isActive;
  const _ConnCard({required this.entry, required this.isActive});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = AppTokens.of(context);
    final s = ref.watch(stringsProvider);

    return GestureDetector(
      onTap: () => _connect(context, ref),
      onLongPress: () => _showActions(context, ref),
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        decoration: BoxDecoration(
          color: isActive
              ? Color.lerp(t.surface, t.accent, 0.04)
              : t.surface,
          border: Border.all(
            color: isActive ? t.accent.withValues(alpha: 0.3) : t.border,
          ),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              _Avatar(emoji: entry.emoji, isActive: isActive),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      entry.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: t.text,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      entry.url.replaceFirst(RegExp(r'^https?://'), ''),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11.5,
                        fontFamily: 'monospace',
                        color: t.textMuted,
                      ),
                    ),
                    const SizedBox(height: 5),
                    Row(
                      children: [
                        if (isActive)
                          _Tag(label: s.connectionsTagConnected, accent: true)
                        else if (entry.lastConnected != null)
                          _Tag(label: s.connectionsTagLastUsedTpl
                              .replaceAll('{ago}', _ago(entry.lastConnected!, s))),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Icon(Icons.chevron_right, size: 18, color: t.textDim),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _connect(BuildContext context, WidgetRef ref) async {
    ref.read(activeConnectionProvider.notifier).state = entry;
    ref.read(connectionsProvider.notifier).touch(entry.id);
    final result = await Navigator.of(context).push<String>(
      CupertinoPageRoute(builder: (_) => const ProjectPickerScreen()),
    );
    if (result == 'repair' && context.mounted) {
      showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        builder: (_) => AddConnectionSheet(editing: entry),
      );
    }
  }

  void _showActions(BuildContext context, WidgetRef ref) {
    final t = AppTokens.of(context);
    final s = ref.read(stringsProvider);
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        margin: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: t.surface,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: t.border),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            Container(width: 36, height: 4, decoration: BoxDecoration(color: t.border, borderRadius: BorderRadius.circular(2))),
            const SizedBox(height: 8),
            ListTile(
              leading: Icon(Icons.edit_outlined, color: t.textMuted),
              title: Text(s.connectionsEdit, style: TextStyle(color: t.text, fontSize: 15)),
              onTap: () {
                Navigator.pop(ctx);
                showModalBottomSheet(
                  context: context,
                  isScrollControlled: true,
                  backgroundColor: Colors.transparent,
                  builder: (_) => AddConnectionSheet(editing: entry),
                );
              },
            ),
            if (entry.token != null && entry.token!.isNotEmpty) ...[
              Divider(color: t.borderSubt, height: 1),
              ListTile(
                leading: Icon(Icons.copy_outlined, color: t.textMuted),
                title: Text(s.connectionsCopyToken, style: TextStyle(color: t.text, fontSize: 15)),
                onTap: () {
                  Navigator.pop(ctx);
                  Clipboard.setData(ClipboardData(text: entry.token!));
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(s.connectionsTokenCopied), duration: const Duration(seconds: 1)),
                  );
                },
              ),
            ],
            Divider(color: t.borderSubt, height: 1),
            ListTile(
              leading: Icon(Icons.delete_outline, color: t.error),
              title: Text(s.connectionsRemove, style: TextStyle(color: t.error, fontSize: 15)),
              onTap: () {
                Navigator.pop(ctx);
                ref.read(connectionsProvider.notifier).remove(entry.id);
                if (ref.read(activeConnectionProvider)?.id == entry.id) {
                  ref.read(activeConnectionProvider.notifier).state = null;
                }
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  String _ago(DateTime dt, Strings s) {
    final diff = DateTime.now().difference(dt);
    if (diff.inMinutes < 1) return s.timeJustNow;
    if (diff.inHours < 1) return s.timeMinutesAgoTpl.replaceAll('{n}', '${diff.inMinutes}');
    if (diff.inDays < 1) return s.timeHoursAgoTpl.replaceAll('{n}', '${diff.inHours}');
    if (diff.inDays < 7) return s.timeDaysAgoTpl.replaceAll('{n}', '${diff.inDays}');
    return s.timeWeeksAgoTpl.replaceAll('{n}', '${(diff.inDays / 7).floor()}');
  }
}

class _Avatar extends StatelessWidget {
  final String emoji;
  final bool isActive;
  const _Avatar({required this.emoji, required this.isActive});

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return Stack(
      children: [
        Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: t.accentSubt,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Center(child: Text(emoji, style: const TextStyle(fontSize: 20))),
        ),
        Positioned(
          bottom: -1,
          right: -1,
          child: Container(
            width: 11,
            height: 11,
            decoration: BoxDecoration(
              color: isActive ? const Color(0xFF22C55E) : t.textDim,
              shape: BoxShape.circle,
              border: Border.all(color: t.surface, width: 2),
            ),
          ),
        ),
      ],
    );
  }
}

class _Tag extends StatelessWidget {
  final String label;
  final bool accent;
  const _Tag({required this.label, this.accent = false});

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
      decoration: BoxDecoration(
        color: accent ? t.accentSubt : t.surfaceHi,
        border: Border.all(
          color: accent ? t.accent.withValues(alpha: 0.22) : t.border,
        ),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w600,
          color: accent ? t.accent : t.textDim,
        ),
      ),
    );
  }
}
