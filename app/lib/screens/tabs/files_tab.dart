import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:open_file_plus/open_file_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdfx/pdfx.dart';
import 'package:share_plus/share_plus.dart';

import '../../api/files_api.dart';
import '../../i18n/locale_provider.dart';
import '../../i18n/strings.dart';
import '../../state/projects_store.dart';
import '../../state/server_config.dart';
import '../../theme.dart';

// ── preview type ────────────────────────────────────────────────────

enum _PreviewType { text, markdown, image, pdf, none }

_PreviewType _previewTypeFor(String name) {
  final lower = name.toLowerCase();
  if (lower.endsWith('.md')) { return _PreviewType.markdown; }
  if (lower.endsWith('.png') || lower.endsWith('.jpg') || lower.endsWith('.jpeg') ||
      lower.endsWith('.gif') || lower.endsWith('.webp')) { return _PreviewType.image; }
  if (lower.endsWith('.pdf')) { return _PreviewType.pdf; }
  if (lower.endsWith('.txt') || lower.endsWith('.log') || lower.endsWith('.json') ||
      lower.endsWith('.yaml') || lower.endsWith('.yml') || lower.endsWith('.toml') ||
      lower.endsWith('.ini') || lower.endsWith('.env') || lower.endsWith('.ts') ||
      lower.endsWith('.tsx') || lower.endsWith('.js') || lower.endsWith('.jsx') ||
      lower.endsWith('.dart') || lower.endsWith('.py') || lower.endsWith('.rs') ||
      lower.endsWith('.go') || lower.endsWith('.java') || lower.endsWith('.kt') ||
      lower.endsWith('.swift') || lower.endsWith('.c') || lower.endsWith('.cpp') ||
      lower.endsWith('.h') || lower.endsWith('.sh') || lower.endsWith('.bash') ||
      lower.endsWith('.css') || lower.endsWith('.html') || lower.endsWith('.xml') ||
      lower.endsWith('.svg')) {
    return _PreviewType.text;
  }
  return _PreviewType.none;
}

// ── file action enum ────────────────────────────────────────────────

enum _FileAction { preview, open, save }

// ── main tab ────────────────────────────────────────────────────────

class FilesTab extends ConsumerStatefulWidget {
  const FilesTab({super.key});

  @override
  ConsumerState<FilesTab> createState() => _FilesTabState();
}

class _FilesTabState extends ConsumerState<FilesTab> {
  String? _path;
  String? _rootPath;
  List<FsEntry> _entries = const [];
  bool _loading = false;
  String? _error;

  final Map<String, FsListing> _cache = {};

  String _sessionKey(CurrentSession s) => s.cwd;

  void _initIfNeeded(CurrentSession session) {
    if (_path != null && _rootPath == _sessionKey(session)) return;
    _rootPath = _sessionKey(session);
    _path = session.cwd;
    _ls(session.cwd);
  }

  Future<void> _ls(String path, {bool force = false}) async {
    final conn = ref.read(activeConnectionProvider);
    if (conn == null) return;

    final cached = !force ? _cache[path] : null;
    setState(() {
      if (cached != null) {
        _path = cached.path;
        _entries = cached.entries;
        _loading = false;
      } else {
        _path = path;
        _entries = const [];
        _loading = true;
      }
      _error = null;
    });

    try {
      final api = FilesApi(conn.httpBase);
      final listing = await api.ls(path);
      if (!mounted) return;
      _cache[listing.path] = listing;
      if (_path != listing.path && _path != path) return;
      setState(() {
        _path = listing.path;
        _entries = listing.entries;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      if (cached == null) {
        setState(() {
          _loading = false;
          _error = e.toString();
        });
      }
    }
  }

  String _humanPath(String path) =>
      path.replaceFirst(RegExp(r'^/Users/[^/]+'), '~');

  // ── file tap → action sheet ──────────────────────────────────────

  Future<void> _onTapFile(FsEntry entry) async {
    final action = await showModalBottomSheet<_FileAction>(
      context: context,
      builder: (ctx) => _FileActionSheet(
        entry: entry,
        previewEnabled: _previewTypeFor(entry.name) != _PreviewType.none,
      ),
    );
    if (action == null || !mounted) return;
    switch (action) {
      case _FileAction.preview:
        await _doPreview(entry);
      case _FileAction.open:
        await _doOpen(entry);
      case _FileAction.save:
        await _doSave(entry);
    }
  }

  // ── generic download helper ──────────────────────────────────────

  Future<File?> _downloadTo(FsEntry entry, Directory destDir) async {
    final conn = ref.read(activeConnectionProvider);
    if (conn == null) return null;

    final progressNotifier = ValueNotifier<_DownloadState>(
      const _DownloadState(received: 0, total: null, done: false),
    );
    final cancelToken = Completer<void>();
    bool dialogOpen = true;

    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => _DownloadProgressDialog(
        filename: entry.name,
        progress: progressNotifier,
        onCancel: () {
          if (!cancelToken.isCompleted) cancelToken.complete();
        },
      ),
    ).then((_) => dialogOpen = false);

    try {
      await destDir.create(recursive: true);
      final dest = File('${destDir.path}/${entry.name}');
      final api = FilesApi(conn.httpBase);
      final file = await api.download(
        remotePath: entry.path,
        destFile: dest,
        cancelToken: cancelToken,
        onProgress: (recv, total) {
          progressNotifier.value = _DownloadState(received: recv, total: total, done: false);
        },
      );
      progressNotifier.value = _DownloadState(
        received: file.lengthSync(),
        total: file.lengthSync(),
        done: true,
      );
      if (dialogOpen && mounted) Navigator.of(context).pop();
      return file;
    } on FsCancelledException {
      if (dialogOpen && mounted) Navigator.of(context).pop();
      return null;
    } catch (e) {
      if (dialogOpen && mounted) Navigator.of(context).pop();
      if (mounted) {
        final s = ref.read(stringsProvider);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(s.filesDownloadFailedTpl.replaceAll('{err}', '$e')),
        ));
      }
      return null;
    } finally {
      progressNotifier.dispose();
    }
  }

  // ── action handlers ──────────────────────────────────────────────

  Future<void> _doPreview(FsEntry entry) async {
    final tmpDir = await getTemporaryDirectory();
    final file = await _downloadTo(entry, Directory('${tmpDir.path}/cc-previews'));
    if (file == null || !mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => _PreviewSheet(
        file: file,
        name: entry.name,
        type: _previewTypeFor(entry.name),
      ),
    );
  }

  Future<void> _doOpen(FsEntry entry) async {
    final tmpDir = await getTemporaryDirectory();
    final file = await _downloadTo(entry, Directory('${tmpDir.path}/cc-open'));
    if (file == null || !mounted) return;
    final result = await OpenFile.open(file.path);
    if (result.type != ResultType.done && mounted) {
      final s = ref.read(stringsProvider);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('${s.filesOpenFailed}: ${result.message}'),
      ));
    }
  }

  Future<void> _doSave(FsEntry entry) async {
    final docsDir = await getApplicationDocumentsDirectory();
    final file = await _downloadTo(entry, Directory('${docsDir.path}/downloads'));
    if (file == null || !mounted) return;
    final s = ref.read(stringsProvider);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(s.filesDownloadDoneTpl.replaceAll('{name}', entry.name)),
      action: SnackBarAction(
        label: s.filesShare,
        onPressed: () async {
          // ignore: deprecated_member_use
          await Share.shareXFiles([XFile(file.path, name: entry.name)]);
        },
      ),
    ));
  }

  // ── build ────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    final s = ref.watch(stringsProvider);
    final session = ref.watch(currentSessionProvider);

    if (session == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.folder_open, size: 40, color: t.textDim),
              const SizedBox(height: 12),
              Text(s.chatEmptyPickProject,
                  style: TextStyle(fontSize: 14, color: t.textMuted, fontWeight: FontWeight.w500),
                  textAlign: TextAlign.center),
            ],
          ),
        ),
      );
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _initIfNeeded(session);
    });

    return Column(
      children: [
        _PathBar(
          path: _path == null ? '~' : _humanPath(_path!),
          rawPath: _path,
          rootPath: _rootPath,
          onJump: (abs) => _ls(abs),
          onRefresh: _path == null ? null : () => _ls(_path!, force: true),
        ),
        Divider(color: t.borderSubt, height: 0.5, thickness: 0.5),
        Expanded(child: _body(t, s)),
      ],
    );
  }

  Widget _body(AppTokens t, Strings s) {
    if (_loading && _entries.isEmpty) {
      return Center(child: CircularProgressIndicator(strokeWidth: 2, color: t.accent));
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline, color: t.error, size: 28),
              const SizedBox(height: 10),
              Text(
                s.filesLoadFailedTpl.replaceAll('{err}', _error!),
                style: TextStyle(color: t.error, fontSize: 12),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }
    if (_entries.isEmpty) {
      return Center(
        child: Text(s.filesEmpty, style: TextStyle(color: t.textDim, fontSize: 13)),
      );
    }
    return RefreshIndicator(
      onRefresh: () async {
        if (_path != null) await _ls(_path!, force: true);
      },
      child: ListView.builder(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: EdgeInsets.zero,
        itemCount: _entries.length,
        itemBuilder: (_, i) {
          final e = _entries[i];
          return _FsRow(
            entry: e,
            onTap: () => e.isDir ? _ls(e.path) : _onTapFile(e),
          );
        },
      ),
    );
  }
}

// ── path bar (compact breadcrumb) ────────────────────────────────────

class _PathBar extends StatelessWidget {
  final String path;
  final String? rawPath;
  final String? rootPath;
  final void Function(String absolutePath) onJump;
  final VoidCallback? onRefresh;

  const _PathBar({
    required this.path,
    required this.rawPath,
    required this.rootPath,
    required this.onJump,
    required this.onRefresh,
  });

  List<(String, String?)> _segments() {
    if (rawPath == null || rawPath!.isEmpty) return [('~', null)];
    final raw = rawPath!;
    final segs = raw.split('/').where((s) => s.isNotEmpty).toList();
    final result = <(String, String?)>[];
    var cum = '';
    final isHome = path.startsWith('~');
    if (isHome) {
      if (segs.length >= 2) {
        cum = '/${segs[0]}/${segs[1]}';
        result.add(('~', _isUnderRoot(cum) ? cum : null));
        for (var i = 2; i < segs.length; i++) {
          cum = '$cum/${segs[i]}';
          result.add((segs[i], _isUnderRoot(cum) ? cum : null));
        }
      } else {
        result.add(('~', null));
      }
    } else {
      result.add(('/', null));
      for (final s in segs) {
        cum = '$cum/$s';
        result.add((s, _isUnderRoot(cum) ? cum : null));
      }
    }
    return result;
  }

  bool _isUnderRoot(String abs) {
    if (rootPath == null) return true;
    return abs == rootPath ||
        abs.startsWith('$rootPath/') ||
        rootPath!.startsWith('$abs/') ||
        rootPath == abs;
  }

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    final segs = _segments();
    return Container(
      color: t.surface,
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              reverse: true,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (int i = 0; i < segs.length; i++) ...[
                    _Crumb(
                      label: segs[i].$1,
                      target: segs[i].$2,
                      isLast: i == segs.length - 1,
                      onJump: onJump,
                    ),
                    if (i < segs.length - 1)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 2),
                        child: Icon(Icons.chevron_right, size: 12, color: t.textDim),
                      ),
                  ],
                ],
              ),
            ),
          ),
          IconButton(
            icon: Icon(Icons.refresh, size: 16, color: onRefresh == null ? t.textDim : t.textMuted),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            onPressed: onRefresh,
          ),
        ],
      ),
    );
  }
}

class _Crumb extends StatelessWidget {
  final String label;
  final String? target;
  final bool isLast;
  final void Function(String) onJump;

  const _Crumb({
    required this.label,
    required this.target,
    required this.isLast,
    required this.onJump,
  });

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    final color = isLast ? t.text : (target == null ? t.textDim : t.accent);
    final weight = isLast ? FontWeight.w600 : FontWeight.w500;
    final tappable = !isLast && target != null;
    return InkWell(
      onTap: tappable ? () => onJump(target!) : null,
      borderRadius: BorderRadius.circular(4),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 10.5,
            color: color,
            fontWeight: weight,
            fontFamily: 'monospace',
          ),
        ),
      ),
    );
  }
}

// ── file row ────────────────────────────────────────────────────────

class _FsRow extends StatelessWidget {
  final FsEntry entry;
  final VoidCallback onTap;
  const _FsRow({required this.entry, required this.onTap});

  IconData _iconFor(String name) {
    final lower = name.toLowerCase();
    if (lower.endsWith('.png') || lower.endsWith('.jpg') || lower.endsWith('.jpeg') ||
        lower.endsWith('.gif') || lower.endsWith('.webp')) { return Icons.image_outlined; }
    if (lower.endsWith('.mp4') || lower.endsWith('.mov') ||
        lower.endsWith('.webm')) { return Icons.movie_outlined; }
    if (lower.endsWith('.mp3') || lower.endsWith('.wav') || lower.endsWith('.m4a') ||
        lower.endsWith('.flac')) { return Icons.audiotrack_outlined; }
    if (lower.endsWith('.pdf')) { return Icons.picture_as_pdf_outlined; }
    if (lower.endsWith('.zip') || lower.endsWith('.tar') || lower.endsWith('.gz') ||
        lower.endsWith('.tgz')) { return Icons.folder_zip_outlined; }
    if (lower.endsWith('.md') || lower.endsWith('.txt') ||
        lower.endsWith('.log')) { return Icons.description_outlined; }
    if (lower.endsWith('.ts') || lower.endsWith('.tsx') || lower.endsWith('.js') ||
        lower.endsWith('.jsx') || lower.endsWith('.dart') || lower.endsWith('.py') ||
        lower.endsWith('.rs') || lower.endsWith('.go') || lower.endsWith('.java') ||
        lower.endsWith('.kt') || lower.endsWith('.swift') || lower.endsWith('.c') ||
        lower.endsWith('.cpp') || lower.endsWith('.h') ||
        lower.endsWith('.json')) { return Icons.code_outlined; }
    return Icons.insert_drive_file_outlined;
  }

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    final icon = entry.isDir ? Icons.folder : _iconFor(entry.name);
    final iconColor = entry.isDir ? t.accent : t.textMuted;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 11, 12, 11),
        child: Row(
          children: [
            Icon(icon, size: 18, color: iconColor),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    entry.name,
                    style: TextStyle(fontSize: 14, color: t.text),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (!entry.isDir) ...[
                    const SizedBox(height: 2),
                    Text(
                      '${formatBytes(entry.sizeBytes)} · ${_relativeTime(entry.modifiedMs)}',
                      style: TextStyle(fontSize: 10.5, color: t.textDim, fontFamily: 'monospace'),
                    ),
                  ],
                ],
              ),
            ),
            Icon(
              entry.isDir ? Icons.chevron_right : Icons.more_horiz,
              size: 16,
              color: t.textDim,
            ),
          ],
        ),
      ),
    );
  }
}

// ── file action sheet ────────────────────────────────────────────────

class _FileActionSheet extends ConsumerWidget {
  final FsEntry entry;
  final bool previewEnabled;

  const _FileActionSheet({
    required this.entry,
    required this.previewEnabled,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = AppTokens.of(context);
    final s = ref.watch(stringsProvider);

    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // drag handle
          Container(
            margin: const EdgeInsets.only(top: 10, bottom: 4),
            width: 36,
            height: 4,
            decoration: BoxDecoration(
              color: t.border,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          // file info
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                Icon(Icons.insert_drive_file_outlined, size: 18, color: t.textMuted),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    entry.name,
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: t.text),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Text(
                  formatBytes(entry.sizeBytes),
                  style: TextStyle(fontSize: 11, color: t.textDim, fontFamily: 'monospace'),
                ),
              ],
            ),
          ),
          Divider(color: t.borderSubt, height: 0.5, thickness: 0.5),
          // actions
          ListTile(
            enabled: previewEnabled,
            leading: Icon(
              Icons.visibility_outlined,
              color: previewEnabled ? t.accent : t.textDim,
            ),
            title: Text(
              s.filesPreview,
              style: TextStyle(color: previewEnabled ? t.text : t.textDim),
            ),
            onTap: previewEnabled ? () => Navigator.of(context).pop(_FileAction.preview) : null,
          ),
          ListTile(
            leading: Icon(Icons.open_in_new, color: t.text),
            title: Text(s.filesOpenWith, style: TextStyle(color: t.text)),
            onTap: () => Navigator.of(context).pop(_FileAction.open),
          ),
          ListTile(
            leading: Icon(Icons.save_outlined, color: t.text),
            title: Text(s.filesSaveLocal, style: TextStyle(color: t.text)),
            onTap: () => Navigator.of(context).pop(_FileAction.save),
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}

// ── preview sheet ─────────────────────────────────────────────────────

class _PreviewSheet extends StatelessWidget {
  final File file;
  final String name;
  final _PreviewType type;

  const _PreviewSheet({
    required this.file,
    required this.name,
    required this.type,
  });

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    final screenHeight = MediaQuery.of(context).size.height;
    return SizedBox(
      height: screenHeight * 0.92,
      child: Column(
        children: [
          // drag handle
          Center(
            child: Container(
              margin: const EdgeInsets.only(top: 10, bottom: 4),
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: t.border,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          // title bar
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 4, 6),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    name,
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: t.text),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                IconButton(
                  icon: Icon(Icons.close, size: 20, color: t.textMuted),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
          ),
          Divider(color: t.borderSubt, height: 0.5, thickness: 0.5),
          Expanded(child: _buildContent()),
        ],
      ),
    );
  }

  Widget _buildContent() {
    switch (type) {
      case _PreviewType.image:
        return _ImagePreview(file: file);
      case _PreviewType.markdown:
        return _MarkdownPreview(file: file);
      case _PreviewType.pdf:
        return _PdfPreview(file: file);
      case _PreviewType.text:
        return _TextPreview(file: file);
      case _PreviewType.none:
        return const Center(child: Text('Preview not available'));
    }
  }
}

// ── preview content widgets ──────────────────────────────────────────

class _ImagePreview extends StatelessWidget {
  final File file;
  const _ImagePreview({required this.file});

  @override
  Widget build(BuildContext context) {
    return InteractiveViewer(
      minScale: 0.5,
      maxScale: 6.0,
      child: Center(child: Image.file(file)),
    );
  }
}

class _TextPreview extends StatefulWidget {
  final File file;
  const _TextPreview({required this.file});

  @override
  State<_TextPreview> createState() => _TextPreviewState();
}

class _TextPreviewState extends State<_TextPreview> {
  String? _content;
  Object? _error;

  @override
  void initState() {
    super.initState();
    widget.file.readAsString().then((v) {
      if (mounted) setState(() => _content = v);
    }).catchError((Object e) {
      if (mounted) setState(() => _error = e);
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    if (_error != null) {
      return Center(child: Text('$_error', style: TextStyle(color: t.error, fontSize: 12)));
    }
    if (_content == null) {
      return Center(child: CircularProgressIndicator(strokeWidth: 2, color: t.accent));
    }
    return SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: SelectableText(
        _content!,
        style: TextStyle(
          fontSize: 11.5,
          color: t.text,
          fontFamily: 'monospace',
          height: 1.55,
        ),
      ),
    );
  }
}

class _MarkdownPreview extends StatefulWidget {
  final File file;
  const _MarkdownPreview({required this.file});

  @override
  State<_MarkdownPreview> createState() => _MarkdownPreviewState();
}

class _MarkdownPreviewState extends State<_MarkdownPreview> {
  String? _content;
  Object? _error;

  @override
  void initState() {
    super.initState();
    widget.file.readAsString().then((v) {
      if (mounted) setState(() => _content = v);
    }).catchError((Object e) {
      if (mounted) setState(() => _error = e);
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    if (_error != null) {
      return Center(child: Text('$_error', style: TextStyle(color: t.error, fontSize: 12)));
    }
    if (_content == null) {
      return Center(child: CircularProgressIndicator(strokeWidth: 2, color: t.accent));
    }
    return Markdown(data: _content!, padding: const EdgeInsets.all(16));
  }
}

class _PdfPreview extends StatefulWidget {
  final File file;
  const _PdfPreview({required this.file});

  @override
  State<_PdfPreview> createState() => _PdfPreviewState();
}

class _PdfPreviewState extends State<_PdfPreview> {
  late PdfController _controller;

  @override
  void initState() {
    super.initState();
    _controller = PdfController(document: PdfDocument.openFile(widget.file.path));
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PdfView(controller: _controller);
  }
}

// ── progress dialog ──────────────────────────────────────────────────

class _DownloadState {
  final int received;
  final int? total;
  final bool done;
  const _DownloadState({required this.received, required this.total, required this.done});
}

class _DownloadProgressDialog extends StatelessWidget {
  final String filename;
  final ValueListenable<_DownloadState> progress;
  final VoidCallback onCancel;

  const _DownloadProgressDialog({
    required this.filename,
    required this.progress,
    required this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    final s = ProviderScope.containerOf(context).read(stringsProvider);
    return AlertDialog(
      backgroundColor: t.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Text(s.filesDownloading, style: TextStyle(fontSize: 16, color: t.text)),
      content: ValueListenableBuilder<_DownloadState>(
        valueListenable: progress,
        builder: (_, state, __) {
          final pct = state.total == null || state.total == 0
              ? null
              : state.received / state.total!;
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                filename,
                style: TextStyle(fontSize: 13, color: t.text, fontFamily: 'monospace'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 12),
              LinearProgressIndicator(
                value: pct,
                minHeight: 6,
                backgroundColor: t.borderSubt,
                color: t.accent,
              ),
              const SizedBox(height: 8),
              Text(
                '${formatBytes(state.received)}${state.total != null ? ' / ${formatBytes(state.total!)}' : ''}',
                style: TextStyle(fontSize: 11, color: t.textDim, fontFamily: 'monospace'),
              ),
            ],
          );
        },
      ),
      actions: [
        TextButton(
          onPressed: onCancel,
          child: Text(s.filesCancel, style: TextStyle(color: t.textMuted)),
        ),
      ],
    );
  }
}

// ── formatting helpers ───────────────────────────────────────────────

String formatBytes(int n) {
  if (n < 1024) return '${n}B';
  if (n < 1024 * 1024) return '${(n / 1024).toStringAsFixed(1)}KB';
  if (n < 1024 * 1024 * 1024) return '${(n / 1024 / 1024).toStringAsFixed(1)}MB';
  return '${(n / 1024 / 1024 / 1024).toStringAsFixed(2)}GB';
}

String _relativeTime(int ms) {
  if (ms <= 0) return '';
  final dt = DateTime.fromMillisecondsSinceEpoch(ms);
  final now = DateTime.now();
  final diff = now.difference(dt);
  if (diff.inDays >= 365) return DateFormat('yyyy-MM-dd').format(dt);
  if (diff.inDays >= 1) return DateFormat('MM-dd').format(dt);
  return DateFormat('HH:mm').format(dt);
}
