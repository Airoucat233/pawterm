import 'package:flutter/material.dart';

import '../api/ideas_api.dart';
import '../theme.dart';

Future<void> showInspirationDrawer(
  BuildContext context, {
  required IdeasApi api,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _InspirationDrawer(api: api),
  );
}

class _InspirationDrawer extends StatefulWidget {
  final IdeasApi api;

  const _InspirationDrawer({required this.api});

  @override
  State<_InspirationDrawer> createState() => _InspirationDrawerState();
}

class _InspirationDrawerState extends State<_InspirationDrawer> {
  final _controller = TextEditingController();
  late Future<List<Idea>> _future;
  bool _saving = false;
  bool _showArchived = false;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<List<Idea>> _load() {
    return widget.api.list(status: _showArchived ? 'archived' : 'active');
  }

  void _reload() {
    setState(() {
      _future = _load();
    });
  }

  Future<void> _create() async {
    final text = _controller.text.trim();
    if (text.isEmpty || _saving) return;
    setState(() => _saving = true);
    try {
      await widget.api.create(text);
      _controller.clear();
      _reload();
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _edit(Idea idea) async {
    final next = await _showEditSheet(context, initial: idea.text);
    if (next == null || next.trim() == idea.text) return;
    await widget.api.update(idea.id, next.trim());
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(8, 0, 8, bottom + 8),
      child: Container(
        constraints: const BoxConstraints(maxHeight: 620),
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
          initialChildSize: 0.72,
          minChildSize: 0.42,
          maxChildSize: 0.94,
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
                    Icon(Icons.lightbulb_outline, size: 18, color: t.accent),
                    const SizedBox(width: 8),
                    Text(
                      '灵感抽屉',
                      style: TextStyle(
                        color: t.text,
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const Spacer(),
                    _SegmentButton(
                      label: _showArchived ? '已归档' : '活跃',
                      selected: true,
                      onTap: () {
                        setState(() {
                          _showArchived = !_showArchived;
                          _future = _load();
                        });
                      },
                    ),
                    IconButton(
                      tooltip: '关闭',
                      icon: Icon(Icons.close, size: 18, color: t.textDim),
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ],
                ),
              ),
              if (!_showArchived)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                  child: Container(
                    decoration: BoxDecoration(
                      color: t.bg,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: t.border, width: 0.5),
                    ),
                    padding: const EdgeInsets.fromLTRB(12, 4, 6, 4),
                    child: Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _controller,
                            autofocus: true,
                            minLines: 1,
                            maxLines: 4,
                            textInputAction: TextInputAction.newline,
                            style: TextStyle(color: t.text, fontSize: 14),
                            decoration: InputDecoration(
                              border: InputBorder.none,
                              hintText: '先记下来，稍后再处理…',
                              hintStyle:
                                  TextStyle(color: t.textDim, fontSize: 13),
                            ),
                          ),
                        ),
                        IconButton(
                          tooltip: '保存灵感',
                          onPressed: _saving ? null : _create,
                          icon: _saving
                              ? SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 1.8,
                                    color: t.accent,
                                  ),
                                )
                              : Icon(Icons.arrow_upward_rounded,
                                  size: 18, color: t.accent),
                        ),
                      ],
                    ),
                  ),
                ),
              Expanded(
                child: FutureBuilder<List<Idea>>(
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
                    final ideas = snapshot.data ?? const [];
                    if (ideas.isEmpty) {
                      return Center(
                        child: Text(
                          _showArchived ? '没有归档灵感' : '抽屉还是空的',
                          style: TextStyle(color: t.textDim, fontSize: 13),
                        ),
                      );
                    }
                    return ListView.separated(
                      controller: scrollController,
                      padding: const EdgeInsets.fromLTRB(12, 0, 12, 14),
                      itemCount: ideas.length,
                      separatorBuilder: (_, __) =>
                          Divider(color: t.borderSubt, height: 0.5),
                      itemBuilder: (_, i) => _IdeaRow(
                        idea: ideas[i],
                        archived: _showArchived,
                        onEdit: () => _edit(ideas[i]),
                        onArchive: () async {
                          await widget.api.archive(ideas[i].id);
                          _reload();
                        },
                        onUnarchive: () async {
                          await widget.api.unarchive(ideas[i].id);
                          _reload();
                        },
                        onDelete: () async {
                          await widget.api.delete(ideas[i].id);
                          _reload();
                        },
                      ),
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

class _IdeaRow extends StatelessWidget {
  final Idea idea;
  final bool archived;
  final VoidCallback onEdit;
  final VoidCallback onArchive;
  final VoidCallback onUnarchive;
  final VoidCallback onDelete;

  const _IdeaRow({
    required this.idea,
    required this.archived,
    required this.onEdit,
    required this.onArchive,
    required this.onUnarchive,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return InkWell(
      onTap: onEdit,
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Icon(
                archived ? Icons.inventory_2_outlined : Icons.circle_outlined,
                size: 16,
                color: archived ? t.textDim : t.accent,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                idea.text,
                style: TextStyle(color: t.text, fontSize: 13.5, height: 1.45),
              ),
            ),
            PopupMenuButton<String>(
              tooltip: '更多',
              icon: Icon(Icons.more_horiz, size: 18, color: t.textDim),
              onSelected: (value) {
                switch (value) {
                  case 'edit':
                    onEdit();
                    break;
                  case 'archive':
                    onArchive();
                    break;
                  case 'unarchive':
                    onUnarchive();
                    break;
                  case 'delete':
                    onDelete();
                    break;
                }
              },
              itemBuilder: (_) => [
                const PopupMenuItem(value: 'edit', child: Text('编辑')),
                PopupMenuItem(
                  value: archived ? 'unarchive' : 'archive',
                  child: Text(archived ? '移回活跃' : '归档'),
                ),
                const PopupMenuItem(value: 'delete', child: Text('删除')),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _SegmentButton extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _SegmentButton({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: selected ? t.accent.withValues(alpha: 0.11) : t.surfaceHi,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: selected ? t.accent.withValues(alpha: 0.24) : t.border,
            width: 0.5,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? t.accent : t.textMuted,
            fontSize: 11.5,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

Future<String?> _showEditSheet(
  BuildContext context, {
  required String initial,
}) async {
  final controller = TextEditingController(text: initial);
  final result = await showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) {
      final t = AppTokens.of(ctx);
      return Padding(
        padding: EdgeInsets.fromLTRB(
          16,
          16,
          16,
          MediaQuery.of(ctx).viewInsets.bottom + 16,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '编辑灵感',
              style: TextStyle(
                color: t.text,
                fontSize: 15,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              autofocus: true,
              minLines: 3,
              maxLines: 8,
              style: TextStyle(color: t.text, fontSize: 14),
              decoration: InputDecoration(
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: t.border),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: t.accent),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                const Spacer(),
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const Text('取消'),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: () => Navigator.of(ctx).pop(controller.text),
                  child: const Text('保存'),
                ),
              ],
            ),
          ],
        ),
      );
    },
  );
  controller.dispose();
  return result;
}
