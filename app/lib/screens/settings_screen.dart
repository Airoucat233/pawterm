import 'dart:io';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:open_file/open_file.dart';
import 'package:permission_handler/permission_handler.dart';

import '../i18n/locale_provider.dart';
import '../state/app_info.dart';
import '../state/prefs.dart';
import '../state/projects_store.dart';
import '../theme.dart';
import '../utils/update_checker.dart';

// ── Public standalone screen (used from MainShell top-bar gear button) ────────

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = AppTokens.of(context);
    final s = ref.watch(stringsProvider);

    return Scaffold(
      appBar: AppBar(
        title: Text(s.settingsTitle),
        leading: IconButton(
          icon: Icon(Icons.arrow_back, color: t.text),
          onPressed: () => Navigator.of(context).pop(),
          tooltip: s.settingsBack,
        ),
      ),
      body: const SettingsBody(),
    );
  }
}

// ── Shared body — used both in SettingsScreen and in ConnectionsScreen tab ─────

class SettingsBody extends ConsumerWidget {
  const SettingsBody({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(stringsProvider);
    final themeMode = ref.watch(prefsProvider);
    final langPref = ref.watch(langPrefProvider);
    final model = ref.watch(currentModelProvider);

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      children: [
        // ── 外观 ──────────────────────────────────────
        _SettingSection(s.settingsAppearance),
        _SettingCard(children: [
          _SegmentRow(
            label: s.settingsTheme,
            icon: Icons.brightness_6_outlined,
            options: [s.settingsThemeSystem, s.settingsThemeLight, s.settingsThemeDark],
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

        // ── Claude 模型 ───────────────────────────────
        _SettingSection(s.settingsClaudeModel),
        _SettingCard(children: [
          for (final m in knownModels) ...[
            _RadioRow(
              label: m.label,
              icon: Icons.auto_awesome_outlined,
              subtitle: m.description,
              selected: model.id == m.id,
              onTap: () => ref.read(currentModelProvider.notifier).state = m,
            ),
            if (m != knownModels.last) _Divider(),
          ],
        ]),

        // ── 关于 ──────────────────────────────────────
        _SettingSection(s.settingsAbout),
        _SettingCard(children: [
          _InfoRow(
            icon: Icons.info_outline,
            label: s.settingsVersion,
            valueWidget: ref.watch(packageInfoProvider).when(
              data: (info) => Text(
                'v${info.version}',
                style: TextStyle(
                  fontSize: 13,
                  color: AppTokens.of(context).textMuted,
                  fontFamily: 'monospace',
                ),
              ),
              loading: () => Text('…',
                  style: TextStyle(fontSize: 13, color: AppTokens.of(context).textDim)),
              error: (_, __) => Text('—',
                  style: TextStyle(fontSize: 13, color: AppTokens.of(context).textDim)),
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
          const _DevChannelTile(),
          _Divider(),
          const _CheckUpdateTile(),
        ]),
      ],
    );
  }
}

// ── Shared UI building blocks ──────────────────────────────────────────────────

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
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
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

class _RadioRow extends StatelessWidget {
  final String label;
  final IconData icon;
  final String subtitle;
  final bool selected;
  final VoidCallback onTap;
  const _RadioRow({
    required this.label,
    required this.icon,
    required this.subtitle,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          children: [
            Icon(icon, size: 18, color: selected ? t.accent : t.textMuted),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 13.5,
                      color: t.text,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: TextStyle(
                      fontSize: 10.5,
                      color: t.textDim.withValues(alpha: 0.85),
                      letterSpacing: 0.1,
                    ),
                  ),
                ],
              ),
            ),
            if (selected) Icon(Icons.check_rounded, size: 18, color: t.accent),
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
            Text(value ?? '', style: TextStyle(fontSize: 13, color: t.textMuted)),
        ],
      ),
    );
  }
}

class _TappableRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final Widget? trailing;
  final VoidCallback onTap;
  const _TappableRow({required this.icon, required this.label, required this.onTap, this.trailing});

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
            Text(label, style: TextStyle(fontSize: 14, color: t.text)),
            const Spacer(),
            if (trailing != null)
              IconTheme(data: IconThemeData(color: t.textDim), child: trailing!),
          ],
        ),
      ),
    );
  }
}

// ── Dev channel toggle ─────────────────────────────────────────────────────────

class _DevChannelTile extends ConsumerWidget {
  const _DevChannelTile();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = AppTokens.of(context);
    final s = ref.watch(stringsProvider);
    final enabled = ref.watch(devChannelProvider);

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
                Text(s.settingsDevChannel, style: TextStyle(fontSize: 14, color: t.text)),
                Text(s.settingsDevChannelSub,
                    style: TextStyle(fontSize: 11, color: t.textMuted)),
              ],
            ),
          ),
          Switch(
            value: enabled,
            onChanged: (v) => ref.read(devChannelProvider.notifier).set(v),
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

    final devChannel = ref.read(devChannelProvider);
    final release = await fetchLatestRelease(devChannel: devChannel);

    if (!mounted) return;

    if (release == null) {
      setState(() => _status = _UpdateStatus.checkFailed);
      Future.delayed(const Duration(seconds: 3), () {
        if (mounted) setState(() => _status = _UpdateStatus.idle);
      });
      return;
    }
    // Dev channel: always offer the dev release if it exists.
    final hasUpdate = devChannel ? true : isNewerVersion(release.tagName, current);
    if (hasUpdate) {
      setState(() {
        _status = _UpdateStatus.hasUpdate;
        _release = release;
      });
    } else {
      setState(() => _status = _UpdateStatus.upToDate);
      Future.delayed(const Duration(seconds: 3), () {
        if (mounted) setState(() => _status = _UpdateStatus.idle);
      });
    }
  }

  void _showDialog() {
    if (_release == null) return;
    showDialog<void>(
      context: context,
      builder: (_) => _UpdateDialog(release: _release!),
    );
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
        trailing = Icon(Icons.system_update_outlined, size: 16, color: t.textMuted);
      case _UpdateStatus.checking:
        trailing = SizedBox(
          width: 14,
          height: 14,
          child: CircularProgressIndicator(strokeWidth: 1.5, color: t.accent),
        );
        subtitle = s.updateChecking;
      case _UpdateStatus.upToDate:
        trailing = const Icon(Icons.check_circle_outline, size: 16, color: Colors.green);
        subtitle = s.updateUpToDate;
      case _UpdateStatus.checkFailed:
        trailing = Icon(Icons.warning_amber_outlined, size: 16, color: t.error);
        subtitle = s.updateCheckFailed;
      case _UpdateStatus.hasUpdate:
        trailing = Icon(Icons.download_outlined, size: 16, color: t.accent);
        subtitle = s.updateAvailableTpl.replaceAll('{version}', _release!.tagName);
        titleColor = t.accent;
    }

    return InkWell(
      onTap: _status == _UpdateStatus.hasUpdate ? _showDialog : _check,
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

// ── Update download dialog ─────────────────────────────────────────────────────

enum _DlStatus { idle, downloading, done, failed, noApk }

class _UpdateDialog extends ConsumerStatefulWidget {
  final GithubRelease release;
  const _UpdateDialog({required this.release});

  @override
  ConsumerState<_UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends ConsumerState<_UpdateDialog> {
  _DlStatus _dlStatus = _DlStatus.idle;
  double _progress = 0;
  File? _file;

  Future<void> _download() async {
    final asset = findApkAsset(widget.release);
    if (asset == null) {
      setState(() => _dlStatus = _DlStatus.noApk);
      return;
    }

    setState(() {
      _dlStatus = _DlStatus.downloading;
      _progress = 0;
    });

    final dlDir = await getDownloadsDir();
    final file = await downloadAsset(asset, dlDir, onProgress: (p) {
      if (mounted) setState(() => _progress = p);
    });

    if (!mounted) return;
    if (file != null) {
      setState(() {
        _dlStatus = _DlStatus.done;
        _file = file;
      });
    } else {
      setState(() => _dlStatus = _DlStatus.failed);
    }
  }

  Future<void> _install() async {
    final f = _file;
    if (f == null) return;
    if (Platform.isAndroid) {
      final status = await Permission.requestInstallPackages.status;
      if (!status.isGranted) {
        await Permission.requestInstallPackages.request();
        if (!mounted) return;
        final after = await Permission.requestInstallPackages.status;
        if (!after.isGranted) return;
      }
    }
    final result = await OpenFile.open(f.path);
    if (!mounted) return;
    if (result.type != ResultType.done && result.type != ResultType.noAppToOpen) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(result.message)),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    final s = ref.watch(stringsProvider);

    final notes = widget.release.body.trim();
    final preview = notes.length > 280 ? '${notes.substring(0, 280)}…' : notes;

    Widget content;
    List<Widget> actions;

    switch (_dlStatus) {
      case _DlStatus.idle:
        content = Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.release.tagName,
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: t.accent),
            ),
            if (preview.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(preview, style: TextStyle(fontSize: 12, color: t.textMuted, height: 1.5)),
            ],
          ],
        );
        actions = [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(s.genericCancel, style: TextStyle(color: t.textMuted)),
          ),
          FilledButton(
            onPressed: _download,
            style: FilledButton.styleFrom(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            child: Text(s.updateDownloadInstall),
          ),
        ];

      case _DlStatus.downloading:
        final pct = (_progress * 100).toInt();
        content = Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            LinearProgressIndicator(
              value: _progress > 0 ? _progress : null,
              color: t.accent,
              backgroundColor: t.border,
            ),
            const SizedBox(height: 8),
            Text(
              _progress > 0 ? '$pct%' : s.filesDownloading,
              style: TextStyle(fontSize: 12, color: t.textMuted),
            ),
          ],
        );
        actions = [];

      case _DlStatus.done:
        content = Row(
          children: [
            const Icon(Icons.check_circle_outline, color: Colors.green, size: 20),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                _file?.path.split('/').last ?? '',
                style: TextStyle(fontSize: 13, color: t.text),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        );
        actions = [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(s.genericClose, style: TextStyle(color: t.textMuted)),
          ),
          FilledButton(
            onPressed: _install,
            style: FilledButton.styleFrom(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            child: Text(s.updateInstall),
          ),
        ];

      case _DlStatus.failed:
      case _DlStatus.noApk:
        final msg = _dlStatus == _DlStatus.noApk ? s.updateNoApk : s.updateDownloadFailed;
        content = Row(
          children: [
            Icon(Icons.error_outline, color: t.error, size: 20),
            const SizedBox(width: 10),
            Text(msg, style: TextStyle(fontSize: 13, color: t.error)),
          ],
        );
        actions = [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(s.genericClose, style: TextStyle(color: t.textMuted)),
          ),
          if (_dlStatus == _DlStatus.failed)
            FilledButton(
              onPressed: _download,
              style: FilledButton.styleFrom(
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
              child: Text(s.genericRetry),
            ),
        ];
    }

    return AlertDialog(
      backgroundColor: t.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Text(
        s.updateDialogTitle,
        style: TextStyle(color: t.text, fontSize: 16, fontWeight: FontWeight.w600),
      ),
      content: content,
      actions: actions,
    );
  }
}
