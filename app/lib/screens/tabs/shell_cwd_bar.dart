import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../i18n/locale_provider.dart';
import '../../theme.dart';
import '../../widgets/top_toast.dart';

/// 终端上方的 cwd 状态条。
///
/// 设计目标：让用户随时知道当前工作目录，**不依赖 shell prompt**——这样
/// 任何 starship/p10k/默认 PS1 都不必改，又能避免长路径占满终端首行。
///
/// 显示策略：
/// - 把 `/Users/<me>` 折叠成 `~`
/// - 总是保留**最后两段**（项目名/子目录），中间段塞不下用 `…/` 替代
/// - 整条点击展开成多行；右侧"复制"按钮把完整路径放剪贴板
class ShellCwdBar extends ConsumerStatefulWidget {
  final String cwd;
  const ShellCwdBar({super.key, required this.cwd});

  @override
  ConsumerState<ShellCwdBar> createState() => _ShellCwdBarState();
}

class _ShellCwdBarState extends ConsumerState<ShellCwdBar> {
  bool _expanded = false;

  String _homeFold(String p) => p.replaceFirst(RegExp(r'^/Users/[^/]+'), '~');

  /// 智能折叠：始终保留最后两段，其余压成 `…/`。
  /// 例：`~/workspace/shulex/claude-companion/server` → `~/…/claude-companion/server`
  String _compact(String p) {
    final folded = _homeFold(p);
    final segs = folded.split('/').where((e) => e.isNotEmpty).toList();
    final startsWithHome = folded.startsWith('~');
    final headPrefix =
        startsWithHome ? '~' : (folded.startsWith('/') ? '' : '');

    if (segs.length <= 2) return folded;
    if (startsWithHome && segs.length <= 3) return folded;

    final tail = segs.takeLast(2).join('/');
    return startsWithHome
        ? '$headPrefix/…/$tail'
        : '${folded.startsWith('/') ? '/' : ''}…/$tail';
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.cwd));
    if (!mounted) return;
    final s = ref.read(stringsProvider);
    showTopToast(
      context,
      s.shellCwdCopied,
      duration: const Duration(seconds: 1),
      icon: Icons.copy_rounded,
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    final s = ref.watch(stringsProvider);
    final folded = _homeFold(widget.cwd);
    final shown = _expanded ? folded : _compact(widget.cwd);

    return InkWell(
      onTap: () => setState(() => _expanded = !_expanded),
      child: Container(
        width: double.infinity,
        decoration: BoxDecoration(
          color: t.surface,
          border: Border(bottom: BorderSide(color: t.borderSubt, width: 0.5)),
        ),
        padding: const EdgeInsets.fromLTRB(12, 6, 6, 6),
        child: Row(
          children: [
            Icon(Icons.folder_outlined, size: 13, color: t.accent),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                shown,
                maxLines: _expanded ? 3 : 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11,
                  fontFamily: 'monospace',
                  color: t.textMuted,
                  height: 1.4,
                  letterSpacing: 0.1,
                ),
              ),
            ),
            const SizedBox(width: 4),
            Tooltip(
              message: s.shellCwdCopyTooltip,
              child: InkResponse(
                onTap: _copy,
                radius: 16,
                child: Padding(
                  padding: const EdgeInsets.all(6),
                  child: Icon(Icons.content_copy, size: 13, color: t.textDim),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

extension<E> on List<E> {
  Iterable<E> takeLast(int n) => skip(length - n);
}
