part of 'chat_tab.dart';

/// 附件选择与上传 —— 从 god-class 拆出到这个 part 文件（agent 中立关注点）。
/// extension on _ChatTabState，同库、私有可达、调用语义不变；纯位移、零行为
/// 改动。setState 经 _ChatTabState.rebuild() 转发。
extension _AttachmentLogic on _ChatTabState {
  Future<void> _pickAndUploadAttachments() async {
    FocusManager.instance.primaryFocus?.unfocus();
    final result = await FilePicker.platform.pickFiles(allowMultiple: true);
    if (result == null) return;
    final session = ref.read(currentSessionProvider);
    if (session == null) return;
    final config = ref.read(activeConnectionProvider);
    if (config == null) return;
    final api = UploadApi(config.apiBase, token: config.token);
    for (final pickedFile in result.files) {
      final path = pickedFile.path;
      if (path == null) continue;
      final state = _AttachmentState(
        localName: pickedFile.name,
        localPath: path,
        status: _AttachmentStatus.uploading,
      );
      rebuild(() => _attachments.add(state));
      unawaited(_uploadOne(api, state, session.cwd));
    }
  }

  Future<void> _uploadOne(
      UploadApi api, _AttachmentState state, String cwd) async {
    try {
      final result = await api.upload(File(state.localPath), cwd);
      if (!mounted) return;
      rebuild(() {
        state.remotePath = result.path;
        state.status = _AttachmentStatus.ready;
      });
    } catch (e) {
      if (!mounted) return;
      rebuild(() {
        state.errorMsg = e.toString();
        state.status = _AttachmentStatus.failed;
      });
    }
  }

  void _removeAttachment(_AttachmentState a) {
    rebuild(() => _attachments.remove(a));
  }

  Future<void> _retryAttachment(_AttachmentState a) async {
    final session = ref.read(currentSessionProvider);
    final config = ref.read(activeConnectionProvider);
    if (session == null || config == null) return;
    rebuild(() {
      a.status = _AttachmentStatus.uploading;
      a.errorMsg = null;
    });
    await _uploadOne(
        UploadApi(config.apiBase, token: config.token), a, session.cwd);
  }

  bool get _attachmentsAllReady =>
      _attachments.every((a) => a.status == _AttachmentStatus.ready);
}
