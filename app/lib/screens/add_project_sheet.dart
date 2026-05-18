import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/projects_api.dart';
import '../i18n/locale_provider.dart';
import '../state/server_config.dart';
import '../theme.dart';

class AddProjectSheet extends ConsumerStatefulWidget {
  final VoidCallback onAdded;
  const AddProjectSheet({super.key, required this.onAdded});

  @override
  ConsumerState<AddProjectSheet> createState() => _AddProjectSheetState();
}

class _AddProjectSheetState extends ConsumerState<AddProjectSheet> {
  late TextEditingController _nameCtrl;

  /// 正在浏览的目录。
  String _currentPath = '';

  /// 用户选中的目录（要添加为项目的目标）。
  /// null 表示没有显式选中——此时项目名/保存按钮都退化到 _currentPath。
  String? _selectedPath;

  List<String> _dirs = [];
  bool _loadingDirs = false;
  bool _saving = false;
  String? _error;
  bool _nameTouched = false;

  @override
  void initState() {
    super.initState();
    _nameCtrl = TextEditingController();
    _nameCtrl.addListener(() {
      final effective = _effectivePath();
      if (!_nameTouched && _nameCtrl.text != _basename(effective)) {
        _nameTouched = true;
      }
    });
    _browse('~');
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  // ── helpers ────────────────────────────────────────────────

  String _basename(String path) {
    if (path.isEmpty) return '';
    return path.split('/').last;
  }

  String _parentOf(String path) {
    final idx = path.lastIndexOf('/');
    if (idx <= 0) return '';
    return path.substring(0, idx);
  }

  String _humanPath(String path) =>
      path.replaceFirst(RegExp(r'^/Users/[^/]+'), '~');

  /// 用户保存时实际生效的路径：选中过子目录就用它，否则用当前浏览路径。
  String _effectivePath() => _selectedPath ?? _currentPath;

  void _setNameFromPath(String path) {
    if (_nameTouched) return;
    _nameCtrl.text = _basename(path);
  }

  // ── browsing ───────────────────────────────────────────────

  Future<void> _browse(String path) async {
    final conn = ref.read(activeConnectionProvider);
    if (conn == null) return;
    setState(() => _loadingDirs = true);
    try {
      final api = ProjectsApi(conn.httpBase, token: conn.token);
      final dirs = await api.browse(path);
      if (!mounted) return;
      setState(() {
        _currentPath = path == '~' ? '' : path;
        _dirs = dirs;
        _loadingDirs = false;
        _selectedPath = null; // 进入新一层后清空之前的选中
      });
      if (path == '~' && dirs.isNotEmpty) {
        final parent = _parentOf(dirs.first);
        setState(() => _currentPath = parent);
      }
      _setNameFromPath(_currentPath);
    } catch (_) {
      if (mounted) setState(() => _loadingDirs = false);
    }
  }

  /// 点击行 = 选中。重复点已选项可取消选中。
  void _selectDir(String path) {
    setState(() {
      if (_selectedPath == path) {
        _selectedPath = null;
        _setNameFromPath(_currentPath);
      } else {
        _selectedPath = path;
        _setNameFromPath(path);
      }
    });
  }

  /// 点击行右侧 chevron = 进入下一级。
  void _enterDir(String path) => _browse(path);

  void _goUp() {
    if (_currentPath.isEmpty) return;
    final parent = _parentOf(_currentPath);
    _browse(parent.isEmpty ? '~' : parent);
  }

  Future<void> _newFolder() async {
    if (_currentPath.isEmpty) return;
    final name = await _promptNewFolderName(context);
    if (name == null || name.trim().isEmpty) return;
    final conn = ref.read(activeConnectionProvider)!;
    final api = ProjectsApi(conn.httpBase, token: conn.token);
    try {
      final created = await api.mkdir(parent: _currentPath, name: name.trim());
      await _browse(_currentPath);
      // 新建后自动选中（而不是进入），用户大概率就是想加这个目录为项目
      _selectDir(created);
    } on DirectoryExistsException {
      if (!mounted) return;
      final s = ref.read(stringsProvider);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(s.addProjectDirExists)),
      );
    } catch (e) {
      if (!mounted) return;
      final s = ref.read(stringsProvider);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(s.addProjectCreateFailedTpl.replaceAll('{err}', '$e'))),
      );
    }
  }

  Future<void> _save() async {
    final path = _effectivePath();
    if (path.isEmpty) return;
    final name = _nameCtrl.text.trim().isNotEmpty
        ? _nameCtrl.text.trim()
        : _basename(path);

    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final conn = ref.read(activeConnectionProvider)!;
      final api = ProjectsApi(conn.httpBase, token: conn.token);
      await api.addProject(name: name, path: path);
      widget.onAdded();
      if (mounted) Navigator.of(context).pop();
    } on DuplicateProjectException {
      if (!mounted) return;
      final s = ref.read(stringsProvider);
      setState(() {
        _saving = false;
        _error = s.addProjectAlreadyAdded;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = e.toString();
      });
    }
  }

  // ── build ──────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    final s = ref.watch(stringsProvider);
    final canGoUp = _currentPath.isNotEmpty && _currentPath.contains('/');
    final effective = _effectivePath();
    final effectiveLabel = effective.isEmpty
        ? s.addProjectNoDirSelected
        : (_selectedPath != null
            ? s.addProjectAddNamedTpl.replaceAll('{name}', _basename(_selectedPath!))
            : s.addProjectAddThisDir);

    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Container(
        decoration: BoxDecoration(
          color: t.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          border: Border.all(color: t.border),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 14, bottom: 4),
              child: Center(
                child: Container(
                  width: 36, height: 4,
                  decoration: BoxDecoration(color: t.border, borderRadius: BorderRadius.circular(2)),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
              child: Row(
                children: [
                  if (canGoUp)
                    InkWell(
                      onTap: _goUp,
                      borderRadius: BorderRadius.circular(8),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.arrow_back_ios_new, size: 13, color: t.accent),
                            const SizedBox(width: 2),
                            Text(s.addProjectGoParent, style: TextStyle(fontSize: 13, color: t.accent, fontWeight: FontWeight.w500)),
                          ],
                        ),
                      ),
                    ),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      child: Text(
                        _currentPath.isEmpty ? '~' : _humanPath(_currentPath),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 12, color: t.textMuted, fontFamily: 'monospace'),
                      ),
                    ),
                  ),
                  InkWell(
                    onTap: _currentPath.isEmpty ? null : _newFolder,
                    borderRadius: BorderRadius.circular(8),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.create_new_folder_outlined, size: 14,
                              color: _currentPath.isEmpty ? t.textDim : t.accent),
                          const SizedBox(width: 4),
                          Text(s.addProjectNewFolder,
                              style: TextStyle(
                                fontSize: 13,
                                color: _currentPath.isEmpty ? t.textDim : t.accent,
                                fontWeight: FontWeight.w500,
                              )),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 6),
            Divider(color: t.borderSubt, height: 0.5),
            SizedBox(
              height: 220,
              child: _loadingDirs
                  ? Center(child: CircularProgressIndicator(strokeWidth: 2, color: t.accent))
                  : _dirs.isEmpty
                      ? Center(child: Text(s.addProjectEmptyDir, style: TextStyle(color: t.textDim, fontSize: 13)))
                      : ListView.builder(
                          padding: EdgeInsets.zero,
                          itemCount: _dirs.length,
                          itemBuilder: (_, i) {
                            final dir = _dirs[i];
                            final selected = _selectedPath == dir;
                            return _DirRow(
                              name: _basename(dir),
                              selected: selected,
                              onSelect: () => _selectDir(dir),
                              onEnter: () => _enterDir(dir),
                            );
                          },
                        ),
            ),
            Divider(color: t.borderSubt, height: 0.5),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (_error != null) ...[
                    Container(
                      margin: const EdgeInsets.only(bottom: 12),
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                      decoration: BoxDecoration(
                        color: t.error.withValues(alpha: 0.08),
                        border: Border.all(color: t.error.withValues(alpha: 0.25)),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(_error!, style: TextStyle(fontSize: 12, color: t.error)),
                    ),
                  ],
                  Row(
                    children: [
                      Text(s.addProjectName, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: t.textMuted)),
                      const SizedBox(width: 6),
                      Text(s.addProjectNameOptional, style: TextStyle(fontSize: 10, color: t.textDim)),
                    ],
                  ),
                  const SizedBox(height: 6),
                  TextField(
                    controller: _nameCtrl,
                    style: TextStyle(fontSize: 14, color: t.text),
                    decoration: InputDecoration(
                      hintText: _basename(effective).isNotEmpty
                          ? _basename(effective)
                          : s.addProjectAutoFillHint,
                      hintStyle: TextStyle(color: t.textDim, fontSize: 14),
                    ),
                  ),
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: (_saving || effective.isEmpty) ? null : _save,
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                      child: _saving
                          ? const SizedBox(
                              width: 18, height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                            )
                          : Text(effectiveLabel,
                              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
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
}

/// 目录列表中的一行：
/// - 整行点击 → 选中（onSelect）
/// - 右侧 chevron 圆形按钮 → 进入下一级（onEnter）
class _DirRow extends StatelessWidget {
  final String name;
  final bool selected;
  final VoidCallback onSelect;
  final VoidCallback onEnter;
  const _DirRow({
    required this.name,
    required this.selected,
    required this.onSelect,
    required this.onEnter,
  });

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return InkWell(
      onTap: onSelect,
      child: Container(
        color: selected ? t.accentSubt : null,
        padding: const EdgeInsets.fromLTRB(20, 10, 8, 10),
        child: Row(
          children: [
            Icon(
              selected ? Icons.check_circle : Icons.folder_outlined,
              size: 18,
              color: selected ? t.accent : t.textMuted,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                name,
                style: TextStyle(
                  fontSize: 14,
                  color: selected ? t.accent : t.text,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            InkResponse(
              onTap: onEnter,
              radius: 22,
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Icon(
                  Icons.chevron_right,
                  size: 18,
                  color: t.textMuted,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

Future<String?> _promptNewFolderName(BuildContext context) async {
  final ctrl = TextEditingController();
  final t = AppTokens.of(context);
  final s = context.l10n;
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: t.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Text(s.addProjectNewFolderDialogTitle, style: TextStyle(fontSize: 16, color: t.text)),
      content: TextField(
        controller: ctrl,
        autofocus: true,
        inputFormatters: [FilteringTextInputFormatter.deny(RegExp(r'[\/]'))],
        decoration: InputDecoration(
          hintText: s.addProjectFolderNameHint,
          hintStyle: TextStyle(color: t.textDim),
        ),
        onSubmitted: (v) => Navigator.of(ctx).pop(v),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(ctx).pop(), child: Text(s.genericCancel)),
        FilledButton(
          onPressed: () => Navigator.of(ctx).pop(ctrl.text),
          child: Text(s.addProjectCreateBtn),
        ),
      ],
    ),
  );
}
