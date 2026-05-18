import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:open_file/open_file.dart';
import 'package:permission_handler/permission_handler.dart';

import '../i18n/locale_provider.dart';
import '../state/app_info.dart';
import '../theme.dart';
import '../utils/update_checker.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = AppTokens.of(context);
    final s = ref.watch(stringsProvider);
    final pref = ref.watch(langPrefProvider);

    return Scaffold(
      appBar: AppBar(
        title: Text(s.settingsTitle),
        leading: IconButton(
          icon: Icon(Icons.arrow_back, color: t.text),
          onPressed: () => Navigator.of(context).pop(),
          tooltip: s.settingsBack,
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          _SectionHeader(label: s.settingsLanguage),
          for (final option in LangPref.values)
            _LangTile(
              option: option,
              selected: pref == option,
              label: option.label(s),
              onTap: () => ref.read(langPrefProvider.notifier).set(option),
            ),
          const SizedBox(height: 24),
          _SectionHeader(label: s.settingsAbout),
          ListTile(
            leading: Icon(Icons.info_outline, size: 18, color: t.textMuted),
            title: Text(s.appTitle, style: TextStyle(color: t.text, fontSize: 13)),
            subtitle: Text(s.appTagline, style: TextStyle(color: t.textMuted, fontSize: 11)),
            dense: true,
          ),
          ListTile(
            leading: Icon(Icons.bookmark_outline, size: 18, color: t.textMuted),
            title: Text(s.settingsVersion, style: TextStyle(color: t.text, fontSize: 13)),
            trailing: ref.watch(packageInfoProvider).when(
              data: (info) => Text(
                'v${info.version}',
                style: TextStyle(color: t.textDim, fontSize: 11, fontFamily: 'monospace'),
              ),
              loading: () => Text('…', style: TextStyle(color: t.textDim, fontSize: 11)),
              error: (_, __) => Text('—', style: TextStyle(color: t.textDim, fontSize: 11)),
            ),
            dense: true,
          ),
          const _CheckUpdateTile(),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String label;
  const _SectionHeader({required this.label});

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: t.textMuted,
          letterSpacing: 0.6,
        ),
      ),
    );
  }
}

class _LangTile extends StatelessWidget {
  final LangPref option;
  final bool selected;
  final String label;
  final VoidCallback onTap;
  const _LangTile({
    required this.option,
    required this.selected,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        child: Row(
          children: [
            Icon(
              selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
              size: 18,
              color: selected ? t.accent : t.textMuted,
            ),
            const SizedBox(width: 12),
            Text(
              label,
              style: TextStyle(
                fontSize: 14,
                color: selected ? t.accent : t.text,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Check for updates tile ────────────────────────────────────────────────

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

    final release = await fetchLatestRelease();

    if (!mounted) return;

    if (release == null) {
      setState(() => _status = _UpdateStatus.checkFailed);
      Future.delayed(const Duration(seconds: 3), () {
        if (mounted) setState(() => _status = _UpdateStatus.idle);
      });
      return;
    }
    if (isNewerVersion(release.tagName, current)) {
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

    return ListTile(
      leading: Icon(Icons.system_update_outlined, size: 18, color: t.textMuted),
      title: Text(s.settingsCheckUpdate, style: TextStyle(color: titleColor, fontSize: 13)),
      subtitle: subtitle.isNotEmpty
          ? Text(subtitle, style: TextStyle(color: t.textMuted, fontSize: 11))
          : null,
      trailing: trailing,
      dense: true,
      onTap: _status == _UpdateStatus.hasUpdate ? _showDialog : _check,
    );
  }
}

// ── Update download dialog ────────────────────────────────────────────────

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
