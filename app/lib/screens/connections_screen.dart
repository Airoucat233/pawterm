import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../i18n/locale_provider.dart' show stringsProvider;
import '../i18n/strings.dart';
import '../state/server_config.dart';
import '../theme.dart';
import '../widgets/top_toast.dart';
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
                        : _ConnectionList(
                            connections: connections, active: active),
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
  const _NavItem(
      {required this.icon,
      required this.label,
      required this.selected,
      required this.onTap});

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
              child: const Center(
                  child: Text('🖥️', style: TextStyle(fontSize: 36))),
            ),
            const SizedBox(height: 20),
            Text(
              s.connectionsEmpty,
              style: TextStyle(
                  fontSize: 17, fontWeight: FontWeight.w600, color: t.text),
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
    final recent = connections.where((e) => e.lastConnected != null).toList()
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
          _SectionLabel(recent.isEmpty
              ? s.connectionsSectionAll
              : s.connectionsSectionOther),
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
        margin: const EdgeInsets.only(bottom: 10),
        decoration: BoxDecoration(
          color: isActive ? Color.lerp(t.surface, t.accent, 0.04) : t.surface,
          border: Border.all(
            color: isActive ? t.accent.withValues(alpha: 0.3) : t.border,
          ),
          borderRadius: BorderRadius.circular(8),
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          children: [
            if (isActive)
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
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 13, 13, 12),
              child: Column(
                children: [
                  Row(
                    children: [
                      _Avatar(emoji: entry.emoji, isActive: isActive),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              entry.name,
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
                              entry.url.replaceFirst(RegExp(r'^https?://'), ''),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 11.5,
                                fontFamily: 'monospace',
                                color: t.textMuted,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      if (isActive)
                        _Tag(label: s.connectionsTagConnected, accent: true)
                      else if (entry.lastConnected != null)
                        _Tag(
                            label: s.connectionsTagLastUsedTpl.replaceAll(
                                '{ago}', _ago(entry.lastConnected!, s)))
                      else
                        const _Tag(label: 'idle'),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      const _Tag(label: 'LAN'),
                      if (entry.token != null && entry.token!.isNotEmpty) ...[
                        const SizedBox(width: 6),
                        const _Tag(label: 'paired'),
                      ],
                      if (entry.pinnedUrls.isNotEmpty) ...[
                        const SizedBox(width: 6),
                        _Tag(label: '钉住 ${entry.pinnedUrls.length}'),
                      ],
                      const Spacer(),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      // 次要操作放左边，主操作「连接/打开」(绿色)推到右下角。
                      _MiniConnAction(
                        label: '编辑',
                        icon: Icons.edit_outlined,
                        onTap: () => _edit(context),
                      ),
                      const SizedBox(width: 8),
                      _MiniConnAction.icon(
                        icon: Icons.more_horiz_rounded,
                        onTap: () => _showActions(context, ref),
                      ),
                      const Spacer(),
                      _MiniConnAction(
                        label: isActive ? '打开' : '连接',
                        icon: isActive
                            ? Icons.open_in_new_rounded
                            : Icons.power_settings_new_rounded,
                        primary: true,
                        onTap: () => _connect(context, ref),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
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

  void _edit(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => AddConnectionSheet(editing: entry),
    );
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
            Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                    color: t.border, borderRadius: BorderRadius.circular(2))),
            const SizedBox(height: 8),
            ListTile(
              leading: Icon(Icons.edit_outlined, color: t.textMuted),
              title: Text(s.connectionsEdit,
                  style: TextStyle(color: t.text, fontSize: 15)),
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
            Divider(color: t.borderSubt, height: 1),
            ListTile(
              leading: Icon(Icons.push_pin_outlined, color: t.textMuted),
              title:
                  Text('地址管理', style: TextStyle(color: t.text, fontSize: 15)),
              subtitle: Text('钉住固定地址，清理 Wi-Fi 临时地址',
                  style: TextStyle(color: t.textMuted, fontSize: 12)),
              onTap: () {
                Navigator.pop(ctx);
                showModalBottomSheet(
                  context: context,
                  isScrollControlled: true,
                  backgroundColor: Colors.transparent,
                  builder: (_) =>
                      _AddressManagementSheet(connectionId: entry.id),
                );
              },
            ),
            if (entry.token != null && entry.token!.isNotEmpty) ...[
              Divider(color: t.borderSubt, height: 1),
              ListTile(
                leading: Icon(Icons.copy_outlined, color: t.textMuted),
                title: Text(s.connectionsCopyToken,
                    style: TextStyle(color: t.text, fontSize: 15)),
                onTap: () {
                  Navigator.pop(ctx);
                  Clipboard.setData(ClipboardData(text: entry.token!));
                  showTopToast(
                    context,
                    s.connectionsTokenCopied,
                    duration: const Duration(seconds: 1),
                    icon: Icons.copy_rounded,
                  );
                },
              ),
            ],
            Divider(color: t.borderSubt, height: 1),
            ListTile(
              leading: Icon(Icons.delete_outline, color: t.error),
              title: Text(s.connectionsRemove,
                  style: TextStyle(color: t.error, fontSize: 15)),
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
    if (diff.inHours < 1) {
      return s.timeMinutesAgoTpl.replaceAll('{n}', '${diff.inMinutes}');
    }
    if (diff.inDays < 1) {
      return s.timeHoursAgoTpl.replaceAll('{n}', '${diff.inHours}');
    }
    if (diff.inDays < 7) {
      return s.timeDaysAgoTpl.replaceAll('{n}', '${diff.inDays}');
    }
    return s.timeWeeksAgoTpl.replaceAll('{n}', '${(diff.inDays / 7).floor()}');
  }
}

class _AddressManagementSheet extends ConsumerWidget {
  final String connectionId;

  const _AddressManagementSheet({required this.connectionId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = AppTokens.of(context);
    final conn = ref
        .watch(connectionsProvider)
        .where((c) => c.id == connectionId)
        .firstOrNull;
    if (conn == null) {
      return const SizedBox.shrink();
    }
    final current = _normalizeUrl(conn.url);
    final pinned = _normalizedUnique(conn.pinnedUrls);
    final recent = _normalizedUnique(conn.recentUrls)
        .where((url) => url != current && !pinned.contains(url))
        .toList();

    return Container(
      constraints:
          BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.78),
      margin: const EdgeInsets.all(8),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: t.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: t.border),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              margin: const EdgeInsets.only(top: 10, bottom: 10),
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: t.border,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 0, 12, 12),
              child: Row(
                children: [
                  Container(
                    width: 34,
                    height: 34,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: t.accentSubt,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(Icons.push_pin_outlined,
                        size: 18, color: t.accent),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '地址管理',
                          style: TextStyle(
                            color: t.text,
                            fontSize: 16,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          conn.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: t.textMuted, fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon:
                        Icon(Icons.close_rounded, size: 20, color: t.textMuted),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            Divider(color: t.borderSubt, height: 0.5),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 18),
                children: [
                  const _AddressSectionLabel('当前地址'),
                  _AddressRow(
                    url: current,
                    label: '正在使用',
                    icon: Icons.radio_button_checked_rounded,
                    iconColor: const Color(0xFF16A34A),
                    trailing: IconButton(
                      tooltip: pinned.contains(current) ? '取消钉住' : '钉住',
                      icon: Icon(
                        pinned.contains(current)
                            ? Icons.push_pin_rounded
                            : Icons.push_pin_outlined,
                        size: 18,
                        color: pinned.contains(current) ? t.accent : t.textDim,
                      ),
                      onPressed: () => pinned.contains(current)
                          ? _unpin(context, ref, conn, current)
                          : _pin(context, ref, conn, current),
                    ),
                  ),
                  const SizedBox(height: 14),
                  const _AddressSectionLabel('钉住地址'),
                  if (pinned.isEmpty)
                    const _AddressEmptyHint('把 Tailscale IP 或固定域名钉住，自动重连会优先尝试。')
                  else
                    for (final url in pinned)
                      _AddressRow(
                        url: url,
                        label: url == current ? '当前使用中' : '固定保留',
                        icon: Icons.push_pin_rounded,
                        iconColor: t.accent,
                        trailing: _AddressActions(
                          canSetCurrent: url != current,
                          onSetCurrent: () =>
                              _setCurrent(context, ref, conn, url),
                          onDelete: () => _unpin(context, ref, conn, url),
                          deleteTooltip: '取消钉住',
                        ),
                      ),
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      const Expanded(child: _AddressSectionLabel('最近地址')),
                      if (recent.isNotEmpty)
                        TextButton(
                          onPressed: () async {
                            await ref
                                .read(connectionsProvider.notifier)
                                .clearRecentUrls(conn.id);
                            _syncActive(ref, conn.id);
                          },
                          child:
                              Text('清空', style: TextStyle(color: t.textMuted)),
                        ),
                    ],
                  ),
                  if (recent.isEmpty)
                    const _AddressEmptyHint('Wi-Fi 变化产生的临时地址会自动限制为最近 3 条。')
                  else
                    for (final url in recent)
                      _AddressRow(
                        url: url,
                        label: '临时地址',
                        icon: Icons.history_rounded,
                        iconColor: t.textDim,
                        trailing: _AddressActions(
                          canSetCurrent: true,
                          onSetCurrent: () =>
                              _setCurrent(context, ref, conn, url),
                          onPin: () => _pin(context, ref, conn, url),
                          onDelete: () =>
                              _removeRecent(context, ref, conn, url),
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

  Future<void> _setCurrent(
      BuildContext context, WidgetRef ref, Connection conn, String url) async {
    final updated =
        await ref.read(connectionsProvider.notifier).updateUrl(conn.id, url);
    if (updated != null && ref.read(activeConnectionProvider)?.id == conn.id) {
      ref.read(activeConnectionProvider.notifier).state = updated;
    }
  }

  Future<void> _pin(
      BuildContext context, WidgetRef ref, Connection conn, String url) async {
    await ref.read(connectionsProvider.notifier).pinUrl(conn.id, url);
    _syncActive(ref, conn.id);
  }

  Future<void> _unpin(
      BuildContext context, WidgetRef ref, Connection conn, String url) async {
    await ref.read(connectionsProvider.notifier).unpinUrl(conn.id, url);
    _syncActive(ref, conn.id);
  }

  Future<void> _removeRecent(
      BuildContext context, WidgetRef ref, Connection conn, String url) async {
    await ref.read(connectionsProvider.notifier).removeRecentUrl(conn.id, url);
    _syncActive(ref, conn.id);
  }

  static void _syncActive(WidgetRef ref, String id) {
    if (ref.read(activeConnectionProvider)?.id != id) return;
    final fresh =
        ref.read(connectionsProvider).where((c) => c.id == id).firstOrNull;
    if (fresh != null) {
      ref.read(activeConnectionProvider.notifier).state = fresh;
    }
  }

  static List<String> _normalizedUnique(Iterable<String> urls) {
    final seen = <String>{};
    return [
      for (final url in urls)
        if (_normalizeUrl(url).isNotEmpty && seen.add(_normalizeUrl(url)))
          _normalizeUrl(url),
    ];
  }

  static String _normalizeUrl(String url) =>
      url.trim().replaceFirst(RegExp(r'/$'), '');
}

class _AddressSectionLabel extends StatelessWidget {
  final String label;

  const _AddressSectionLabel(this.label);

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return Padding(
      padding: const EdgeInsets.only(left: 2, bottom: 8),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w800,
          color: t.textDim,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

class _AddressEmptyHint extends StatelessWidget {
  final String text;

  const _AddressEmptyHint(this.text);

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
      decoration: BoxDecoration(
        color: t.surfaceHi,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: t.borderSubt),
      ),
      child: Text(text, style: TextStyle(color: t.textMuted, fontSize: 12)),
    );
  }
}

class _AddressRow extends StatelessWidget {
  final String url;
  final String label;
  final IconData icon;
  final Color iconColor;
  final Widget trailing;

  const _AddressRow({
    required this.url,
    required this.label,
    required this.icon,
    required this.iconColor,
    required this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(12, 10, 6, 10),
      decoration: BoxDecoration(
        color: t.surfaceHi.withValues(alpha: 0.74),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: t.borderSubt),
      ),
      child: Row(
        children: [
          Icon(icon, size: 17, color: iconColor),
          const SizedBox(width: 9),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  url.replaceFirst(RegExp(r'^https?://'), ''),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: t.text,
                    fontSize: 12,
                    fontFamily: 'monospace',
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(label, style: TextStyle(color: t.textDim, fontSize: 11)),
              ],
            ),
          ),
          trailing,
        ],
      ),
    );
  }
}

class _AddressActions extends StatelessWidget {
  final bool canSetCurrent;
  final VoidCallback onSetCurrent;
  final VoidCallback? onPin;
  final VoidCallback onDelete;
  final String deleteTooltip;

  const _AddressActions({
    required this.canSetCurrent,
    required this.onSetCurrent,
    this.onPin,
    required this.onDelete,
    this.deleteTooltip = '删除',
  });

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (canSetCurrent)
          IconButton(
            tooltip: '设为当前',
            icon: Icon(Icons.check_circle_outline_rounded,
                size: 18, color: t.accent),
            onPressed: onSetCurrent,
          ),
        if (onPin != null)
          IconButton(
            tooltip: '钉住',
            icon: Icon(Icons.push_pin_outlined, size: 18, color: t.textMuted),
            onPressed: onPin,
          ),
        IconButton(
          tooltip: deleteTooltip,
          icon: Icon(Icons.delete_outline_rounded, size: 18, color: t.error),
          onPressed: onDelete,
        ),
      ],
    );
  }
}

class _MiniConnAction extends StatelessWidget {
  final String? label;
  final IconData icon;
  final bool primary;
  final VoidCallback onTap;

  const _MiniConnAction({
    required this.label,
    required this.icon,
    required this.onTap,
    this.primary = false,
  });

  const _MiniConnAction.icon({
    required this.icon,
    required this.onTap,
  })  : label = null,
        primary = false;

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    final foreground = primary ? Colors.white : t.textMuted;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        height: 28,
        constraints: BoxConstraints(minWidth: label == null ? 28 : 0),
        padding: EdgeInsets.symmetric(horizontal: label == null ? 0 : 9),
        decoration: BoxDecoration(
          color: primary ? t.accent : t.surfaceHi.withValues(alpha: 0.72),
          borderRadius: BorderRadius.circular(7),
          border: primary ? null : Border.all(color: t.borderSubt, width: 0.5),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 14, color: foreground),
            if (label != null) ...[
              const SizedBox(width: 5),
              Text(
                label!,
                style: TextStyle(
                  color: foreground,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ],
        ),
      ),
    );
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
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: t.accent.withValues(alpha: 0.16)),
          ),
          child:
              Center(child: Text(emoji, style: const TextStyle(fontSize: 20))),
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
