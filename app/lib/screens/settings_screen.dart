import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../i18n/locale_provider.dart';
import '../state/app_info.dart';
import '../state/prefs.dart';
import '../state/streaming_foreground_service.dart';
import '../theme.dart';
import '../utils/update_checker.dart';

const _apkInstallerChannel = MethodChannel('pawterm/apk_installer');

// ── Public standalone screen (used from MainShell top-bar gear button) ────────

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  bool _showConversationSettings = false;

  void _setConversationSettings(bool value) {
    setState(() => _showConversationSettings = value);
  }

  void _handleBack() {
    if (_showConversationSettings) {
      _setConversationSettings(false);
    } else {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    final s = ref.watch(stringsProvider);

    return PopScope(
      canPop: !_showConversationSettings,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _showConversationSettings) {
          _setConversationSettings(false);
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(_showConversationSettings ? '对话设置' : s.settingsTitle),
          leading: IconButton(
            icon: Icon(Icons.arrow_back, color: t.text),
            onPressed: _handleBack,
            tooltip: s.settingsBack,
          ),
        ),
        body: SettingsBody(
          showConversationSettings: _showConversationSettings,
          onConversationSettingsChanged: _setConversationSettings,
        ),
      ),
    );
  }
}

// ── Shared body — used both in SettingsScreen and in ConnectionsScreen tab ─────

class SettingsBody extends ConsumerStatefulWidget {
  final bool? showConversationSettings;
  final ValueChanged<bool>? onConversationSettingsChanged;

  const SettingsBody({
    super.key,
    this.showConversationSettings,
    this.onConversationSettingsChanged,
  });

  @override
  ConsumerState<SettingsBody> createState() => _SettingsBodyState();
}

class _SettingsBodyState extends ConsumerState<SettingsBody> {
  bool _showConversationSettings = false;

  bool get _effectiveShowConversationSettings =>
      widget.showConversationSettings ?? _showConversationSettings;

  void _setConversationSettings(bool value) {
    final external = widget.onConversationSettingsChanged;
    if (external != null) {
      external(value);
    } else {
      setState(() => _showConversationSettings = value);
    }
  }

  @override
  Widget build(BuildContext context) {
    final showConversationSettings = _effectiveShowConversationSettings;
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 240),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      transitionBuilder: (child, animation) {
        final enteringConversation =
            child.key == const ValueKey('conversation-settings');
        final beginOffset =
            enteringConversation ? const Offset(1, 0) : const Offset(-1, 0);
        return SlideTransition(
          position: Tween<Offset>(
            begin: beginOffset,
            end: Offset.zero,
          ).animate(animation),
          child: FadeTransition(opacity: animation, child: child),
        );
      },
      child: showConversationSettings
          ? _ConversationSettingsPage(
              key: const ValueKey('conversation-settings'),
              showInlineBack: widget.showConversationSettings == null,
              onBack: () => _setConversationSettings(false),
            )
          : _SettingsRootPage(
              key: const ValueKey('settings-root'),
              onOpenConversationSettings: () => _setConversationSettings(true),
            ),
    );
  }
}

class _SettingsRootPage extends ConsumerWidget {
  final VoidCallback onOpenConversationSettings;

  const _SettingsRootPage({
    super.key,
    required this.onOpenConversationSettings,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(stringsProvider);
    final themeMode = ref.watch(prefsProvider);
    final langPref = ref.watch(langPrefProvider);

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      children: [
        // ── 外观 ──────────────────────────────────────
        _SettingSection(s.settingsAppearance),
        _SettingCard(children: [
          _SegmentRow(
            label: s.settingsTheme,
            icon: Icons.brightness_6_outlined,
            options: [
              s.settingsThemeSystem,
              s.settingsThemeLight,
              s.settingsThemeDark
            ],
            selected: switch (themeMode) {
              ThemeMode.light => 1,
              ThemeMode.dark => 2,
              _ => 0,
            },
            onChanged: (i) => ref.read(prefsProvider.notifier).setTheme(
                  [ThemeMode.system, ThemeMode.light, ThemeMode.dark][i],
                ),
          ),
          _Divider(),
          _SegmentRow(
            label: s.settingsLanguage,
            icon: Icons.translate_outlined,
            options: [s.settingsLanguageSystem, 'English', '中文'],
            selected: switch (langPref) {
              LangPref.en => 1,
              LangPref.zh => 2,
              _ => 0,
            },
            onChanged: (i) => ref.read(langPrefProvider.notifier).set(
                  [LangPref.system, LangPref.en, LangPref.zh][i],
                ),
          ),
        ]),

        // ── 导航 ──────────────────────────────────────
        const _SettingSection('导航'),
        const _SettingCard(children: [
          _BottomTabOrderTile(),
        ]),

        // ── 对话 ──────────────────────────────────────
        const _SettingSection('对话'),
        _SettingCard(children: [
          _TappableRow(
            icon: Icons.chat_bubble_outline,
            label: '对话设置',
            subtitle: '滚动行为、工具卡片展示',
            trailing: const Icon(Icons.chevron_right, size: 18),
            onTap: onOpenConversationSettings,
          ),
        ]),

        // ── 关于 ──────────────────────────────────────
        _SettingSection(s.settingsAbout),
        _SettingCard(children: [
          _InfoRow(
            icon: Icons.info_outline,
            label: s.settingsVersion,
            valueWidget: ref.watch(packageInfoProvider).when(
                  data: (info) => Text(
                    formatPackageVersion(info),
                    style: TextStyle(
                      fontSize: 13,
                      color: AppTokens.of(context).textMuted,
                      fontFamily: 'monospace',
                    ),
                  ),
                  loading: () => Text('…',
                      style: TextStyle(
                          fontSize: 13, color: AppTokens.of(context).textDim)),
                  error: (_, __) => Text('—',
                      style: TextStyle(
                          fontSize: 13, color: AppTokens.of(context).textDim)),
                ),
          ),
          _Divider(),
          _InfoRow(
            icon: Icons.person_outline,
            label: s.settingsAuthor,
            value: 'airoucat',
          ),
          _Divider(),
          _TappableRow(
            icon: Icons.code_outlined,
            label: s.settingsProjectPage,
            trailing: const Icon(Icons.open_in_new, size: 14),
            onTap: () => launchUrl(
              Uri.parse('https://github.com/Airoucat233/pawterm'),
              mode: LaunchMode.externalApplication,
            ),
          ),
          _Divider(),
          const _PrereleaseChannelTile(),
          _Divider(),
          const _CheckUpdateTile(),
        ]),
      ],
    );
  }
}

class _ConversationSettingsPage extends ConsumerWidget {
  final bool showInlineBack;
  final VoidCallback onBack;

  const _ConversationSettingsPage({
    super.key,
    required this.showInlineBack,
    required this.onBack,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scrollToBottom = ref.watch(scrollToBottomOnSessionSwitchProvider);
    final fileToolExpanded = ref.watch(fileToolCardsExpandedProvider);
    final showContextBar = ref.watch(showContextBarProvider);

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      children: [
        if (showInlineBack) ...[
          _InlineBackHeader(label: '对话设置', onBack: onBack),
          const SizedBox(height: 8),
        ],
        const _SettingSection('对话'),
        _SettingCard(children: [
          _SwitchRow(
            label: '切换会话后滚到底部',
            subtitle: '进入另一个会话时直接查看最新内容',
            icon: Icons.vertical_align_bottom_outlined,
            value: scrollToBottom,
            onChanged: (v) =>
                ref.read(scrollToBottomOnSessionSwitchProvider.notifier).set(v),
          ),
          _Divider(),
          _SwitchRow(
            label: '文件工具默认展开',
            subtitle: '控制文件修改、补丁等工具卡片进入对话时是否自动展开',
            icon: Icons.description_outlined,
            value: fileToolExpanded,
            onChanged: (v) =>
                ref.read(fileToolCardsExpandedProvider.notifier).set(v),
          ),
          _Divider(),
          _SwitchRow(
            label: '上下文占用条',
            subtitle: '输入框上方显示上下文窗口实时占用进度条（绿/黄/红），仅 Claude',
            icon: Icons.data_usage_outlined,
            value: showContextBar,
            onChanged: (v) => ref.read(showContextBarProvider.notifier).set(v),
          ),
          _Divider(),
          const _BatteryExemptionRow(),
        ]),
      ],
    );
  }
}

// ── Shared UI building blocks ──────────────────────────────────────────────────

class _InlineBackHeader extends StatelessWidget {
  final String label;
  final VoidCallback onBack;

  const _InlineBackHeader({required this.label, required this.onBack});

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return SizedBox(
      height: 44,
      child: Row(
        children: [
          IconButton(
            icon: Icon(Icons.arrow_back, color: t.text),
            onPressed: onBack,
            tooltip: '返回',
          ),
          Text(
            label,
            style: TextStyle(
              color: t.text,
              fontSize: 18,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _SettingSection extends StatelessWidget {
  final String label;
  const _SettingSection(this.label);

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 16, 2, 8),
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

class _SettingCard extends StatelessWidget {
  final List<Widget> children;
  const _SettingCard({required this.children});

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return Container(
      decoration: BoxDecoration(
        color: t.surface,
        border: Border.all(color: t.border),
        borderRadius: BorderRadius.circular(14),
      ),
      clipBehavior: Clip.hardEdge,
      child: Column(children: children),
    );
  }
}

class _Divider extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return Divider(color: t.borderSubt, height: 1, indent: 44);
  }
}

class _BottomTabOrderTile extends ConsumerWidget {
  const _BottomTabOrderTile();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final order = ref.watch(bottomTabOrderProvider);
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.dock_outlined,
                  size: 18, color: AppTokens.of(context).textMuted),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '底部栏顺序',
                      style: TextStyle(
                          fontSize: 14, color: AppTokens.of(context).text),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '拖动右侧把手调整对话、终端、文件的显示位置',
                      style: TextStyle(
                          fontSize: 11, color: AppTokens.of(context).textMuted),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          ReorderableListView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            buildDefaultDragHandles: false,
            proxyDecorator: (child, _, animation) => AnimatedBuilder(
              animation: animation,
              builder: (context, child) {
                final t = AppTokens.of(context);
                return Material(
                  color: Colors.transparent,
                  child: Transform.scale(
                    scale: 1 + animation.value * 0.02,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: t.surface,
                        borderRadius: BorderRadius.circular(10),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.16),
                            blurRadius: 18,
                            offset: const Offset(0, 8),
                          ),
                        ],
                      ),
                      child: child,
                    ),
                  ),
                );
              },
              child: child,
            ),
            itemCount: order.length,
            onReorder: (oldIndex, newIndex) {
              final next = List<BottomTabId>.from(order);
              if (newIndex > oldIndex) newIndex -= 1;
              final item = next.removeAt(oldIndex);
              next.insert(newIndex, item);
              ref.read(bottomTabOrderProvider.notifier).set(next);
            },
            itemBuilder: (context, index) {
              final tab = order[index];
              return _BottomTabOrderRow(
                key: ValueKey(tab),
                tab: tab,
                index: index,
              );
            },
          ),
        ],
      ),
    );
  }
}

class _BottomTabOrderRow extends StatelessWidget {
  final BottomTabId tab;
  final int index;

  const _BottomTabOrderRow({
    super.key,
    required this.tab,
    required this.index,
  });

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return Container(
      height: 46,
      margin: const EdgeInsets.only(bottom: 6),
      decoration: BoxDecoration(
        color: t.surfaceHi,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: t.border, width: 0.5),
      ),
      child: Row(
        children: [
          const SizedBox(width: 12),
          Icon(_bottomTabIcon(tab), size: 18, color: t.textMuted),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              _bottomTabLabel(tab),
              style: TextStyle(
                color: t.text,
                fontSize: 13.5,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          ReorderableDragStartListener(
            index: index,
            child: SizedBox(
              width: 44,
              height: 44,
              child:
                  Icon(Icons.drag_handle_rounded, size: 20, color: t.textDim),
            ),
          ),
        ],
      ),
    );
  }
}

String _bottomTabLabel(BottomTabId tab) => switch (tab) {
      BottomTabId.chat => '对话',
      BottomTabId.shell => '终端',
      BottomTabId.files => '文件',
    };

IconData _bottomTabIcon(BottomTabId tab) => switch (tab) {
      BottomTabId.chat => Icons.chat_bubble_outline,
      BottomTabId.shell => Icons.terminal,
      BottomTabId.files => Icons.folder_outlined,
    };

class _SegmentRow extends StatelessWidget {
  final String label;
  final IconData icon;
  final List<String> options;
  final int selected;
  final ValueChanged<int> onChanged;
  const _SegmentRow({
    required this.label,
    required this.icon,
    required this.options,
    required this.selected,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        children: [
          Icon(icon, size: 18, color: t.textMuted),
          const SizedBox(width: 10),
          Text(label, style: TextStyle(fontSize: 14, color: t.text)),
          const Spacer(),
          Container(
            decoration: BoxDecoration(
              color: t.surfaceHi,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: t.border),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: List.generate(options.length, (i) {
                final active = i == selected;
                return GestureDetector(
                  onTap: () => onChanged(i),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 150),
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: active ? t.accent : Colors.transparent,
                      borderRadius: BorderRadius.circular(7),
                    ),
                    child: Text(
                      options[i],
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: active ? FontWeight.w600 : FontWeight.w400,
                        color: active ? Colors.white : t.textMuted,
                      ),
                    ),
                  ),
                );
              }),
            ),
          ),
        ],
      ),
    );
  }
}

class _SwitchRow extends StatelessWidget {
  final String label;
  final String subtitle;
  final IconData icon;
  final bool value;
  final ValueChanged<bool> onChanged;

  const _SwitchRow({
    required this.label,
    required this.subtitle,
    required this.icon,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return InkWell(
      onTap: () => onChanged(!value),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Row(
          children: [
            Icon(icon, size: 18, color: t.textMuted),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label, style: TextStyle(fontSize: 14, color: t.text)),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: TextStyle(fontSize: 11, color: t.textMuted),
                  ),
                ],
              ),
            ),
            Switch(
              value: value,
              onChanged: onChanged,
              activeColor: t.accent,
            ),
          ],
        ),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String? value;
  final Widget? valueWidget;
  const _InfoRow({
    required this.icon,
    required this.label,
    this.value,
    this.valueWidget,
  });

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        children: [
          Icon(icon, size: 18, color: t.textMuted),
          const SizedBox(width: 10),
          Text(label, style: TextStyle(fontSize: 14, color: t.text)),
          const Spacer(),
          if (valueWidget != null)
            valueWidget!
          else
            Text(value ?? '',
                style: TextStyle(fontSize: 13, color: t.textMuted)),
        ],
      ),
    );
  }
}

class _TappableRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback onTap;
  const _TappableRow(
      {required this.icon,
      required this.label,
      required this.onTap,
      this.subtitle,
      this.trailing});

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          children: [
            Icon(icon, size: 18, color: t.textMuted),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label, style: TextStyle(fontSize: 14, color: t.text)),
                  if (subtitle != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      subtitle!,
                      style: TextStyle(fontSize: 11, color: t.textMuted),
                    ),
                  ],
                ],
              ),
            ),
            if (trailing != null)
              IconTheme(
                  data: IconThemeData(color: t.textDim), child: trailing!),
          ],
        ),
      ),
    );
  }
}

// ── 后台保活：电池优化豁免（仅 Android，点击主动申请，不自动弹）──────────────

class _BatteryExemptionRow extends StatefulWidget {
  const _BatteryExemptionRow();

  @override
  State<_BatteryExemptionRow> createState() => _BatteryExemptionRowState();
}

class _BatteryExemptionRowState extends State<_BatteryExemptionRow> {
  bool? _exempt;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final v = await StreamingForegroundService.instance.isBatteryExempt();
    if (mounted) setState(() => _exempt = v);
  }

  @override
  Widget build(BuildContext context) {
    if (!Platform.isAndroid) return const SizedBox.shrink();
    final t = AppTokens.of(context);
    final exempt = _exempt ?? false;
    return _TappableRow(
      icon: Icons.battery_saver_outlined,
      label: '后台保活（电池优化豁免）',
      subtitle: exempt
          ? '已豁免 — 熄屏/后台流式更稳'
          : '默认仅前台服务保活；部分 ROM 熄屏会断流，点此申请豁免',
      trailing: exempt
          ? Icon(Icons.check_circle, size: 18, color: t.success)
          : const Icon(Icons.chevron_right, size: 18),
      onTap: () async {
        await StreamingForegroundService.instance.requestBatteryExemption();
        await _refresh();
      },
    );
  }
}

// ── Prerelease channel toggle ──────────────────────────────────────────────────

class _PrereleaseChannelTile extends ConsumerWidget {
  const _PrereleaseChannelTile();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = AppTokens.of(context);
    final s = ref.watch(stringsProvider);
    final enabled = ref.watch(prereleaseChannelProvider);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Row(
        children: [
          Icon(Icons.science_outlined, size: 18, color: t.textMuted),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(s.settingsPrereleaseChannel,
                    style: TextStyle(fontSize: 14, color: t.text)),
                Text(s.settingsPrereleaseChannelSub,
                    style: TextStyle(fontSize: 11, color: t.textMuted)),
              ],
            ),
          ),
          Switch(
            value: enabled,
            onChanged: (v) =>
                ref.read(prereleaseChannelProvider.notifier).set(v),
            activeColor: t.accent,
          ),
        ],
      ),
    );
  }
}

// ── Check for updates ──────────────────────────────────────────────────────────

enum _UpdateStatus { idle, checking, upToDate, hasUpdate, checkFailed }

class _CheckUpdateTile extends ConsumerStatefulWidget {
  const _CheckUpdateTile();

  @override
  ConsumerState<_CheckUpdateTile> createState() => _CheckUpdateTileState();
}

class _CheckUpdateTileState extends ConsumerState<_CheckUpdateTile> {
  _UpdateStatus _status = _UpdateStatus.idle;
  GithubRelease? _release;

  Future<void> _check() async {
    if (_status == _UpdateStatus.checking) return;
    setState(() => _status = _UpdateStatus.checking);

    String current = '0.0.0';
    try {
      final pkgInfo = await ref.read(packageInfoProvider.future);
      current = pkgInfo.version;
    } catch (_) {}

    final prereleaseChannel = ref.read(prereleaseChannelProvider);
    final release =
        await fetchLatestRelease(prereleaseChannel: prereleaseChannel);

    if (!mounted) return;

    if (release == null) {
      setState(() => _status = _UpdateStatus.checkFailed);
      Future.delayed(const Duration(seconds: 3), () {
        if (mounted) setState(() => _status = _UpdateStatus.idle);
      });
      return;
    }
    final hasUpdate = isNewerVersion(release.tagName, current);
    if (hasUpdate) {
      setState(() {
        _status = _UpdateStatus.hasUpdate;
        _release = release;
      });
      await _showUpdateDialog(release);
    } else {
      setState(() => _status = _UpdateStatus.upToDate);
      Future.delayed(const Duration(seconds: 3), () {
        if (mounted) setState(() => _status = _UpdateStatus.idle);
      });
    }
  }

  Future<void> _showUpdateDialog(GithubRelease release) async {
    final s = ref.read(stringsProvider);
    final asset = findApkAsset(release);
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(s.updateDialogTitle),
        content: Text(
          s.updateDialogMessageTpl.replaceAll('{version}', release.tagName),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(s.genericCancel),
          ),
          TextButton.icon(
            onPressed: () {
              Navigator.of(context).pop();
              _openDownloadInBrowser(release);
            },
            icon: const Icon(Icons.open_in_browser_rounded, size: 18),
            label: Text(s.updateOpenInBrowser),
          ),
          if (asset != null)
            FilledButton.icon(
              onPressed: () {
                Navigator.of(context).pop();
                _downloadAndInstall(asset);
              },
              icon: const Icon(Icons.system_update_alt_rounded, size: 18),
              label: Text(s.updateInstallInApp),
            ),
        ],
      ),
    );
  }

  Future<void> _openDownloadInBrowser(GithubRelease release) async {
    final asset = findApkAsset(release);
    final url = Uri.parse(asset?.downloadUrl ??
        'https://github.com/Airoucat233/pawterm/releases/tag/${release.tagName}');
    if (await canLaunchUrl(url)) {
      final opened = await launchUrl(url, mode: LaunchMode.inAppBrowserView);
      if (!opened) {
        await launchUrl(url, mode: LaunchMode.externalApplication);
      }
    }
  }

  Future<void> _downloadAndInstall(GithubAsset asset) async {
    final s = ref.read(stringsProvider);
    try {
      await _apkInstallerChannel.invokeMethod<void>('downloadAndInstallApk', {
        'url': asset.downloadUrl,
        'fileName': asset.name,
        'headers': const <String, String>{},
      });
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content:
              Text(s.updateInstallStartedTpl.replaceAll('{name}', asset.name)),
        ),
      );
    } on PlatformException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.message ?? e.code)),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    final s = ref.watch(stringsProvider);

    Widget trailing;
    String subtitle = '';
    Color titleColor = t.text;

    switch (_status) {
      case _UpdateStatus.idle:
        trailing =
            Icon(Icons.system_update_outlined, size: 16, color: t.textMuted);
      case _UpdateStatus.checking:
        trailing = SizedBox(
          width: 14,
          height: 14,
          child: CircularProgressIndicator(strokeWidth: 1.5, color: t.accent),
        );
        subtitle = s.updateChecking;
      case _UpdateStatus.upToDate:
        trailing = const Icon(Icons.check_circle_outline,
            size: 16, color: Colors.green);
        subtitle = s.updateUpToDate;
      case _UpdateStatus.checkFailed:
        trailing = Icon(Icons.warning_amber_outlined, size: 16, color: t.error);
        subtitle = s.updateCheckFailed;
      case _UpdateStatus.hasUpdate:
        trailing = Icon(Icons.download_outlined, size: 16, color: t.accent);
        subtitle =
            s.updateAvailableTpl.replaceAll('{version}', _release!.tagName);
        titleColor = t.accent;
    }

    return InkWell(
      onTap: _status == _UpdateStatus.hasUpdate && _release != null
          ? () => _showUpdateDialog(_release!)
          : _check,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          children: [
            Icon(Icons.system_update_outlined, size: 18, color: t.textMuted),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    s.settingsCheckUpdate,
                    style: TextStyle(fontSize: 14, color: titleColor),
                  ),
                  if (subtitle.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        subtitle,
                        style: TextStyle(fontSize: 11, color: t.textMuted),
                      ),
                    ),
                ],
              ),
            ),
            trailing,
          ],
        ),
      ),
    );
  }
}
