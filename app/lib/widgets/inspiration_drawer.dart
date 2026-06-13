import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';

import '../api/ideas_api.dart';
import '../theme.dart';

Future<void> showInspirationDrawer(
  BuildContext context, {
  required IdeasApi api,
  ValueChanged<String>? onUseIdea,
  ValueChanged<String>? onSendIdea,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _InspirationDrawer(
      api: api,
      onUseIdea: onUseIdea,
      onSendIdea: onSendIdea,
    ),
  );
}

class _InspirationDrawer extends StatefulWidget {
  final IdeasApi api;
  final ValueChanged<String>? onUseIdea;
  final ValueChanged<String>? onSendIdea;

  const _InspirationDrawer({
    required this.api,
    this.onUseIdea,
    this.onSendIdea,
  });

  @override
  State<_InspirationDrawer> createState() => _InspirationDrawerState();
}

class _InspirationDrawerState extends State<_InspirationDrawer> {
  final _controller = TextEditingController();
  late Future<List<Idea>> _future;
  bool _draftHasText = false;
  bool _saving = false;
  bool _showArchived = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onDraftChanged);
    _future = _load();
  }

  @override
  void dispose() {
    _controller.removeListener(_onDraftChanged);
    _controller.dispose();
    super.dispose();
  }

  void _onDraftChanged() {
    final next = _controller.text.trim().isNotEmpty;
    if (next != _draftHasText) setState(() => _draftHasText = next);
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

  Future<void> _delete(Idea idea) async {
    await widget.api.delete(idea.id);
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    final media = MediaQuery.of(context);
    final height = media.size.height - media.padding.top;
    return AnimatedPadding(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
      padding: EdgeInsets.only(bottom: media.viewInsets.bottom),
      child: Align(
        alignment: Alignment.bottomCenter,
        child: Container(
          height: height,
          decoration: BoxDecoration(
            color: t.bg,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
            border: Border(top: BorderSide(color: t.border, width: 0.5)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.2),
                blurRadius: 28,
                offset: const Offset(0, -8),
              ),
            ],
          ),
          child: Column(
            children: [
              const SizedBox(height: 10),
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: t.border,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              _Header(
                archived: _showArchived,
                onToggleArchived: () {
                  setState(() {
                    _showArchived = !_showArchived;
                    _future = _load();
                  });
                },
                onClose: () => Navigator.of(context).pop(),
              ),
              if (!_showArchived)
                _IdeaComposerCard(
                  controller: _controller,
                  saving: _saving,
                  canSave: _draftHasText,
                  onSave: _create,
                ),
              Expanded(
                child: FutureBuilder<List<Idea>>(
                  future: _future,
                  builder: (_, snapshot) {
                    if (snapshot.connectionState != ConnectionState.done) {
                      return Center(
                        child: SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 1.8,
                            color: t.accent,
                          ),
                        ),
                      );
                    }
                    final ideas = snapshot.data ?? const [];
                    if (ideas.isEmpty) {
                      return _EmptyIdeas(archived: _showArchived);
                    }
                    return ListView.builder(
                      padding: const EdgeInsets.fromLTRB(16, 6, 16, 24),
                      itemCount: ideas.length,
                      itemBuilder: (_, i) {
                        final idea = ideas[i];
                        return _SwipeableIdeaCard(
                          key: ValueKey('idea-${idea.id}'),
                          idea: idea,
                          archived: _showArchived,
                          onEdit: () => _edit(idea),
                          onArchive: () async {
                            await widget.api.archive(idea.id);
                            _reload();
                          },
                          onUnarchive: () async {
                            await widget.api.unarchive(idea.id);
                            _reload();
                          },
                          onDelete: () => _delete(idea),
                          child: Padding(
                            padding: const EdgeInsets.only(bottom: 10),
                            child: _IdeaCard(
                              idea: idea,
                              archived: _showArchived,
                              onSend: widget.onSendIdea == null
                                  ? null
                                  : () {
                                      widget.onSendIdea!(idea.text);
                                      Navigator.of(context).pop();
                                    },
                              onUse: widget.onUseIdea == null
                                  ? null
                                  : () {
                                      widget.onUseIdea!(idea.text);
                                      Navigator.of(context).pop();
                                    },
                              onEdit: () => _edit(idea),
                              onArchive: () async {
                                await widget.api.archive(idea.id);
                                _reload();
                              },
                              onUnarchive: () async {
                                await widget.api.unarchive(idea.id);
                                _reload();
                              },
                            ),
                          ),
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

class _Header extends StatelessWidget {
  final bool archived;
  final VoidCallback onToggleArchived;
  final VoidCallback onClose;

  const _Header({
    required this.archived,
    required this.onToggleArchived,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 18, 12, 14),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: t.accent.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: t.accent.withValues(alpha: 0.18)),
            ),
            child: Icon(Icons.lightbulb_outline, size: 20, color: t.accent),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '灵感抽屉',
                  style: TextStyle(
                    color: t.text,
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  archived ? '归档的想法' : '随手捕捉，随时发送',
                  style: TextStyle(color: t.textDim, fontSize: 12),
                ),
              ],
            ),
          ),
          _SegmentButton(
            label: archived ? '归档' : '活跃',
            selected: true,
            onTap: onToggleArchived,
          ),
          const SizedBox(width: 2),
          IconButton(
            tooltip: '关闭',
            icon: Icon(Icons.close_rounded, size: 20, color: t.textMuted),
            onPressed: onClose,
          ),
        ],
      ),
    );
  }
}

class _IdeaComposerCard extends StatelessWidget {
  final TextEditingController controller;
  final bool saving;
  final bool canSave;
  final VoidCallback onSave;

  const _IdeaComposerCard({
    required this.controller,
    required this.saving,
    required this.canSave,
    required this.onSave,
  });

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
      child: Container(
        decoration: BoxDecoration(
          color: t.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: t.border, width: 0.5),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.06),
              blurRadius: 18,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        padding: const EdgeInsets.fromLTRB(14, 12, 10, 10),
        child: Column(
          children: [
            Row(
              children: [
                Icon(Icons.add_comment_outlined, size: 16, color: t.accent),
                const SizedBox(width: 8),
                Text(
                  '捕捉新灵感',
                  style: TextStyle(
                    color: t.textMuted,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const Spacer(),
                AnimatedOpacity(
                  opacity: canSave ? 1 : 0.45,
                  duration: const Duration(milliseconds: 160),
                  child: IconButton.filledTonal(
                    tooltip: '保存',
                    onPressed: saving || !canSave ? null : onSave,
                    style: IconButton.styleFrom(
                      minimumSize: const Size(40, 40),
                      backgroundColor: t.accent.withValues(alpha: 0.12),
                      foregroundColor: t.accent,
                    ),
                    icon: saving
                        ? SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 1.8,
                              color: t.accent,
                            ),
                          )
                        : const Icon(Icons.check_rounded, size: 19),
                  ),
                ),
              ],
            ),
            TextField(
              controller: controller,
              autofocus: false,
              minLines: 2,
              maxLines: 5,
              textInputAction: TextInputAction.newline,
              cursorColor: t.accent,
              style: TextStyle(color: t.text, fontSize: 14, height: 1.45),
              decoration: InputDecoration(
                border: InputBorder.none,
                isDense: true,
                contentPadding: const EdgeInsets.fromLTRB(0, 4, 6, 4),
                hintText: '写下一个待会儿要问的问题、命令或线索…',
                hintStyle: TextStyle(color: t.textDim, fontSize: 13.5),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SwipeableIdeaCard extends StatefulWidget {
  final Idea idea;
  final bool archived;
  final VoidCallback onEdit;
  final VoidCallback onArchive;
  final VoidCallback onUnarchive;
  final VoidCallback onDelete;
  final Widget child;

  const _SwipeableIdeaCard({
    super.key,
    required this.idea,
    required this.archived,
    required this.onEdit,
    required this.onArchive,
    required this.onUnarchive,
    required this.onDelete,
    required this.child,
  });

  @override
  State<_SwipeableIdeaCard> createState() => _SwipeableIdeaCardState();
}

class _SwipeableIdeaCardState extends State<_SwipeableIdeaCard> {
  static const double _maxOffset = 164;
  static const double _openThreshold = 0.42;
  double _offset = 0;
  bool _dragging = false;

  double get _progress => (_offset / _maxOffset).clamp(0.0, 1.0);

  void _close() {
    if (_offset == 0) return;
    setState(() {
      _dragging = false;
      _offset = 0;
    });
  }

  void _runAction(VoidCallback action) {
    _close();
    action();
  }

  void _onDragStart(DragStartDetails details) {
    setState(() => _dragging = true);
  }

  void _onDragUpdate(DragUpdateDetails details) {
    final next = (_offset - details.delta.dx).clamp(0.0, _maxOffset);
    if (next == _offset) return;
    setState(() => _offset = next);
  }

  void _onDragEnd(DragEndDetails details) {
    final velocity = -(details.primaryVelocity ?? 0);
    final shouldOpen =
        velocity > 360 || (velocity > -360 && _progress >= _openThreshold);
    setState(() {
      _dragging = false;
      _offset = shouldOpen ? _maxOffset : 0;
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    final progress = Curves.easeOutCubic.transform(_progress);
    final cardScale = lerpDouble(1, 0.972, progress)!;
    final duration =
        _dragging ? Duration.zero : const Duration(milliseconds: 190);
    final archiveLabel = widget.archived ? '移回' : '归档';
    final archiveIcon =
        widget.archived ? Icons.unarchive_outlined : Icons.inventory_2_outlined;
    final archiveColor = widget.archived ? t.success : t.warning;

    return Stack(
      clipBehavior: Clip.none,
      alignment: Alignment.centerRight,
      children: [
        Positioned.fill(
          bottom: 10,
          child: Align(
            alignment: Alignment.centerRight,
            child: SizedBox(
              width: _maxOffset,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  _SwipeActionButton(
                    progress: progress,
                    delay: 0.0,
                    color: t.accent,
                    icon: Icons.edit_outlined,
                    label: '编辑',
                    onTap: () => _runAction(widget.onEdit),
                  ),
                  const SizedBox(width: 6),
                  _SwipeActionButton(
                    progress: progress,
                    delay: 0.08,
                    color: archiveColor,
                    icon: archiveIcon,
                    label: archiveLabel,
                    onTap: () => _runAction(
                      widget.archived ? widget.onUnarchive : widget.onArchive,
                    ),
                  ),
                  const SizedBox(width: 6),
                  _SwipeActionButton(
                    progress: progress,
                    delay: 0.16,
                    color: t.error,
                    icon: Icons.delete_outline_rounded,
                    label: '删除',
                    onTap: () => _runAction(widget.onDelete),
                  ),
                ],
              ),
            ),
          ),
        ),
        GestureDetector(
          behavior: HitTestBehavior.translucent,
          onHorizontalDragStart: _onDragStart,
          onHorizontalDragUpdate: _onDragUpdate,
          onHorizontalDragEnd: _onDragEnd,
          onHorizontalDragCancel: () {
            setState(() {
              _dragging = false;
              _offset = _progress >= _openThreshold ? _maxOffset : 0;
            });
          },
          child: AnimatedContainer(
            duration: duration,
            curve: Curves.easeOutCubic,
            transform: Matrix4.identity()
              ..translate(-_offset)
              ..scale(cardScale, cardScale),
            transformAlignment: Alignment.center,
            child: widget.child,
          ),
        ),
      ],
    );
  }
}

class _SwipeActionButton extends StatelessWidget {
  final double progress;
  final double delay;
  final Color color;
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _SwipeActionButton({
    required this.progress,
    required this.delay,
    required this.color,
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final local = ((progress - delay) / (1 - delay)).clamp(0.0, 1.0);
    final eased = Curves.easeOutBack.transform(local);
    final opacity = Curves.easeOutCubic.transform(local);
    final scale = lerpDouble(0.72, 1, eased.clamp(0.0, 1.0))!;
    final shift = lerpDouble(14, 0, opacity)!;
    return Opacity(
      opacity: opacity,
      child: Transform.translate(
        offset: Offset(shift, 0),
        child: Transform.scale(
          scale: scale,
          child: Semantics(
            button: true,
            label: label,
            child: InkWell(
              onTap: local > 0.55 ? onTap : null,
              borderRadius: BorderRadius.circular(999),
              child: SizedBox(
                width: 48,
                height: 58,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: color.withValues(alpha: 0.14),
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: color.withValues(alpha: 0.22),
                          width: 0.5,
                        ),
                      ),
                      child: Icon(icon, color: color, size: 20),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      label,
                      maxLines: 1,
                      style: TextStyle(
                        color: color,
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _IdeaCard extends StatefulWidget {
  final Idea idea;
  final bool archived;
  final VoidCallback? onSend;
  final VoidCallback? onUse;
  final VoidCallback onEdit;
  final VoidCallback onArchive;
  final VoidCallback onUnarchive;

  const _IdeaCard({
    required this.idea,
    required this.archived,
    required this.onSend,
    required this.onUse,
    required this.onEdit,
    required this.onArchive,
    required this.onUnarchive,
  });

  @override
  State<_IdeaCard> createState() => _IdeaCardState();
}

class _IdeaCardState extends State<_IdeaCard>
    with SingleTickerProviderStateMixin {
  late final AnimationController _shakeController;
  double _scale = 1;
  bool _longPressing = false;

  @override
  void initState() {
    super.initState();
    _shakeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 220),
    );
  }

  @override
  void dispose() {
    _shakeController.dispose();
    super.dispose();
  }

  void _pressDown() {
    if (_longPressing) return;
    setState(() => _scale = 0.975);
  }

  void _pressCancel() {
    if (!mounted) return;
    setState(() {
      _longPressing = false;
      _scale = 1;
    });
  }

  Future<void> _sendWithBounce() async {
    if (_longPressing) return;
    setState(() => _scale = 1.018);
    await Future<void>.delayed(const Duration(milliseconds: 85));
    if (!mounted) return;
    setState(() => _scale = 1);
    await Future<void>.delayed(const Duration(milliseconds: 55));
    if (!mounted) return;
    widget.onSend?.call();
  }

  Future<void> _useWithShake() async {
    if (widget.onUse == null) return;
    _longPressing = true;
    setState(() => _scale = 0.965);
    await _shakeController.forward(from: 0);
    if (!mounted) return;
    setState(() => _scale = 1);
    widget.onUse!.call();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    final canSend = widget.onSend != null;
    return AnimatedBuilder(
      animation: _shakeController,
      builder: (context, child) {
        final shake = math.sin(_shakeController.value * math.pi * 7) * 2.6;
        return Transform.translate(
          offset: Offset(shake, 0),
          child: AnimatedScale(
            scale: _scale,
            duration: const Duration(milliseconds: 130),
            curve: _scale > 1 ? Curves.easeOutBack : Curves.easeOutCubic,
            child: child,
          ),
        );
      },
      child: Material(
        color: Colors.transparent,
        child: Container(
          decoration: BoxDecoration(
            color: t.surface,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: t.border, width: 0.5),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.07),
                blurRadius: 16,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapDown: canSend ? (_) => _pressDown() : null,
                  onTapCancel: canSend ? _pressCancel : null,
                  onTapUp: canSend ? (_) => _sendWithBounce() : null,
                  onLongPressStart: (_) => _useWithShake(),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(14, 14, 10, 14),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          width: 8,
                          height: 8,
                          margin: const EdgeInsets.only(top: 7),
                          decoration: BoxDecoration(
                            color: widget.archived ? t.textDim : t.accent,
                            shape: BoxShape.circle,
                            boxShadow: widget.archived
                                ? null
                                : [
                                    BoxShadow(
                                      color: t.accent.withValues(alpha: 0.28),
                                      blurRadius: 8,
                                    ),
                                  ],
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            widget.idea.text,
                            style: TextStyle(
                              color: t.text,
                              fontSize: 14,
                              height: 1.46,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(0, 8, 8, 8),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (canSend)
                      IconButton(
                        tooltip: '发送',
                        visualDensity: VisualDensity.compact,
                        onPressed: widget.onSend,
                        style: IconButton.styleFrom(
                          minimumSize: const Size(40, 40),
                          backgroundColor: t.accent.withValues(alpha: 0.1),
                          foregroundColor: t.accent,
                        ),
                        icon: const Icon(Icons.north_east_rounded, size: 18),
                      ),
                    PopupMenuButton<String>(
                      tooltip: '更多',
                      icon: Icon(
                        Icons.more_horiz_rounded,
                        size: 20,
                        color: t.textDim,
                      ),
                      onSelected: (value) {
                        switch (value) {
                          case 'edit':
                            widget.onEdit();
                            break;
                          case 'archive':
                            widget.onArchive();
                            break;
                          case 'unarchive':
                            widget.onUnarchive();
                            break;
                        }
                      },
                      itemBuilder: (_) => [
                        const PopupMenuItem(value: 'edit', child: Text('编辑')),
                        PopupMenuItem(
                          value: widget.archived ? 'unarchive' : 'archive',
                          child: Text(widget.archived ? '移回活跃' : '归档'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EmptyIdeas extends StatelessWidget {
  final bool archived;
  const _EmptyIdeas({required this.archived});

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                color: t.surfaceHi,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: t.border, width: 0.5),
              ),
              child: Icon(
                archived ? Icons.inventory_2_outlined : Icons.lightbulb_outline,
                color: t.textDim,
                size: 23,
              ),
            ),
            const SizedBox(height: 14),
            Text(
              archived ? '没有归档灵感' : '抽屉还是空的',
              style: TextStyle(
                color: t.textMuted,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
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
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
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
            fontSize: 12,
            fontWeight: FontWeight.w700,
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
