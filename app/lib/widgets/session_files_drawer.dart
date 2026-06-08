import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api/files_api.dart';
import '../api/session_files_api.dart';
import '../theme.dart';

Future<void> showSessionFilesDrawer(
  BuildContext context, {
  required SessionFilesApi api,
  required FilesApi filesApi,
  required String sessionId,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _SessionFilesDrawer(
      api: api,
      filesApi: filesApi,
      sessionId: sessionId,
    ),
  );
}

class _SessionFilesDrawer extends StatefulWidget {
  final SessionFilesApi api;
  final FilesApi filesApi;
  final String sessionId;

  const _SessionFilesDrawer({
    required this.api,
    required this.filesApi,
    required this.sessionId,
  });

  @override
  State<_SessionFilesDrawer> createState() => _SessionFilesDrawerState();
}

class _SessionFilesDrawerState extends State<_SessionFilesDrawer> {
  late Future<List<SessionFileRef>> _future;

  @override
  void initState() {
    super.initState();
    _future = widget.api.list(widget.sessionId);
  }

  void _reload() {
    setState(() {
      _future = widget.api.list(widget.sessionId);
    });
  }

  Future<void> _open(String path) async {
    final uri = widget.filesApi.previewUri(path);
    final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!opened && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('无法打开预览')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
      child: Container(
        constraints: const BoxConstraints(maxHeight: 560),
        decoration: BoxDecoration(
          color: t.surface,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: t.border, width: 0.5),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.18),
              blurRadius: 24,
              offset: const Offset(0, 10),
            ),
          ],
        ),
        child: DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.66,
          minChildSize: 0.38,
          maxChildSize: 0.9,
          builder: (_, scrollController) => Column(
            children: [
              const SizedBox(height: 10),
              Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: t.border,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 10, 10),
                child: Row(
                  children: [
                    Icon(Icons.folder_special_outlined,
                        size: 18, color: t.accent),
                    const SizedBox(width: 8),
                    Text(
                      '会话文件',
                      style: TextStyle(
                        color: t.text,
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const Spacer(),
                    IconButton(
                      tooltip: '刷新',
                      onPressed: _reload,
                      icon: Icon(Icons.refresh, size: 18, color: t.textDim),
                    ),
                    IconButton(
                      tooltip: '关闭',
                      onPressed: () => Navigator.of(context).pop(),
                      icon: Icon(Icons.close, size: 18, color: t.textDim),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: FutureBuilder<List<SessionFileRef>>(
                  future: _future,
                  builder: (_, snapshot) {
                    if (snapshot.connectionState != ConnectionState.done) {
                      return Center(
                        child: SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 1.8,
                            color: t.accent,
                          ),
                        ),
                      );
                    }
                    if (snapshot.hasError) {
                      return Center(
                        child: Padding(
                          padding: const EdgeInsets.all(20),
                          child: Text(
                            '${snapshot.error}',
                            style: TextStyle(color: t.error, fontSize: 12),
                          ),
                        ),
                      );
                    }
                    final files = snapshot.data ?? const [];
                    if (files.isEmpty) {
                      return Center(
                        child: Text(
                          '还没有收藏文件',
                          style: TextStyle(color: t.textDim, fontSize: 13),
                        ),
                      );
                    }
                    return ListView.separated(
                      controller: scrollController,
                      padding: const EdgeInsets.fromLTRB(12, 0, 12, 14),
                      itemCount: files.length,
                      separatorBuilder: (_, __) =>
                          Divider(color: t.borderSubt, height: 0.5),
                      itemBuilder: (_, i) {
                        final file = files[i];
                        return _SessionFileRow(
                          file: file,
                          onOpen: () => _open(file.path),
                          onRemove: () async {
                            await widget.api.remove(
                              sessionId: widget.sessionId,
                              id: file.id,
                            );
                            _reload();
                          },
                        );
                      },
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

class _SessionFileRow extends StatelessWidget {
  final SessionFileRef file;
  final VoidCallback onOpen;
  final VoidCallback onRemove;

  const _SessionFileRow({
    required this.file,
    required this.onOpen,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return InkWell(
      onTap: onOpen,
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 10),
        child: Row(
          children: [
            Icon(Icons.insert_drive_file_outlined, size: 17, color: t.accent),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    file.name.isEmpty ? file.path.split('/').last : file.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: t.text,
                      fontSize: 13.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    file.path,
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
            PopupMenuButton<String>(
              tooltip: '更多',
              icon: Icon(Icons.more_horiz, size: 18, color: t.textDim),
              onSelected: (value) {
                if (value == 'open') onOpen();
                if (value == 'remove') onRemove();
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'open', child: Text('打开预览')),
                PopupMenuItem(value: 'remove', child: Text('移除收藏')),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
