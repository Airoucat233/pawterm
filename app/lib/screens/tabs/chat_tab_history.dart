part of 'chat_tab.dart';

/// 历史消息加载与分页 —— 从 god-class 拆出到这个 part 文件（agent 中立的
/// 关注点拆分）。extension on _ChatTabState，同库、私有可达、调用语义不变；
/// 纯位移、零行为改动。setState 经 _ChatTabState.rebuild() 转发。
extension _HistoryLogic on _ChatTabState {
  Future<void> _loadHistory(
    String httpBase,
    String cwd,
    String sessionId,
    AgentKind agent, {
    _ChatSessionRuntime? runtime,
  }) async {
    final target = runtime ?? _runtime;
    // 给骨架屏一个最少展示时长，避免 fetch 太快"闪一下"
    final minShowUntil = DateTime.now().add(const Duration(milliseconds: 280));
    if (_isActiveRuntime(target)) {
      rebuild(() => _withRuntime(target, () => _loadingHistory = true));
    } else {
      _withRuntime(target, () => _loadingHistory = true);
    }
    try {
      final page = await _fetchHistoryPage(
        httpBase,
        cwd,
        sessionId,
        agent,
        limit: _ChatTabState._historyPageSize,
      );
      if (!mounted) return;
      final remaining = minShowUntil.difference(DateTime.now());
      if (remaining > Duration.zero) await Future.delayed(remaining);
      if (!mounted) return;
      final targetSession = target.session;
      final targetSessionId = target.sessionId ?? targetSession?.resumeId;
      if (targetSession?.cwd != cwd ||
          targetSession?.agent != agent ||
          targetSessionId != sessionId) {
        return;
      }
      if (page != null) {
        if (_isActiveRuntime(target)) {
          rebuild(() => _withRuntime(target, () {
                _messages
                  ..clear()
                  ..addAll(page.messages);
                _localUserEchoes.clear();
                _seenRealtimeUuids.clear();
                _codexRealtimeSnapshots.clear();
                _oldestUuid = page.oldestUuid;
                _hasMoreHistory = page.hasMore;
                _loadingHistory = false;
              }));
        } else {
          _withRuntime(target, () {
            _messages
              ..clear()
              ..addAll(page.messages);
            _localUserEchoes.clear();
            _seenRealtimeUuids.clear();
            _codexRealtimeSnapshots.clear();
            _oldestUuid = page.oldestUuid;
            _hasMoreHistory = page.hasMore;
            _loadingHistory = false;
          });
        }
        if (_isActiveRuntime(target)) {
          _settleScrollToEnd(target);
        }
      } else if (_isActiveRuntime(target)) {
        rebuild(() => _loadingHistory = false);
      } else {
        _withRuntime(target, () => _loadingHistory = false);
      }
    } catch (_) {
      if (mounted && _isActiveRuntime(target)) {
        rebuild(() => _loadingHistory = false);
      } else {
        _withRuntime(target, () => _loadingHistory = false);
      }
    }
  }

  Future<void> _reloadCurrentHistory() async {
    final conn = ref.read(activeConnectionProvider);
    final session = ref.read(currentSessionProvider);
    final uuid = _sessionId ?? session?.resumeId;
    if (conn == null || session == null || uuid == null) return;
    final page = await _fetchHistoryPage(
      conn.apiBase,
      session.cwd,
      uuid,
      session.agent,
      limit: _ChatTabState._historyPageSize,
    );
    if (!mounted || page == null) return;
    rebuild(() {
      _messages
        ..clear()
        ..addAll(page.messages);
      _oldestUuid = page.oldestUuid;
      _hasMoreHistory = page.hasMore;
      _loadingHistory = false;
    });
    _scrollToEnd(force: true);
  }

  /// 上滑到顶时调用：取 [_oldestUuid] 前面的一页，prepend 到列表前。
  /// prepend 后用 maxScrollExtent 差值保持视口位置（避免视觉跳动）。
  Future<void> _loadOlderPage() async {
    if (_loadingOlder || !_hasMoreHistory || _oldestUuid == null) return;
    final conn = ref.read(activeConnectionProvider);
    final session = ref.read(currentSessionProvider);
    if (conn == null || session?.resumeId == null) return;

    rebuild(() => _loadingOlder = true);
    final preMax = _scrollController.hasClients
        ? _scrollController.position.maxScrollExtent
        : 0.0;
    final preOffset =
        _scrollController.hasClients ? _scrollController.offset : 0.0;

    try {
      final page = await _fetchHistoryPage(
        conn.apiBase,
        session!.cwd,
        session.resumeId!,
        session.agent,
        limit: _ChatTabState._historyPageSize,
        beforeUuid: _oldestUuid,
      );
      if (page == null || !mounted) {
        rebuild(() => _loadingOlder = false);
        return;
      }
      // 先插入消息，保持固定 loading 浮层可见（_loadingOlder 仍为 true），
      // 下一帧 layout 完成后先恢复视口位置再隐藏浮层，避免列表高度突变。
      rebuild(() {
        _messages.insertAll(0, page.messages);
        _oldestUuid = page.oldestUuid ?? _oldestUuid;
        _hasMoreHistory = page.hasMore;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scrollController.hasClients) {
          final postMax = _scrollController.position.maxScrollExtent;
          final delta = postMax - preMax;
          if (delta > 0) _scrollController.jumpTo(preOffset + delta);
        }
        if (mounted) rebuild(() => _loadingOlder = false);
      });
    } catch (_) {
      if (mounted) rebuild(() => _loadingOlder = false);
    }
  }

  Future<_HistoryPage?> _fetchHistoryPage(
    String httpBase,
    String cwd,
    String sessionId,
    AgentKind agent, {
    required int limit,
    String? beforeUuid,
  }) async {
    final apiBase = httpBase.endsWith('/api') ? httpBase : '$httpBase/api';
    final uri = Uri.parse('$apiBase/sessions/$sessionId/messages').replace(
      queryParameters: {
        'cwd': cwd,
        'limit': '$limit',
        'agent': agent.wire,
        if (beforeUuid != null) 'before_uuid': beforeUuid,
      },
    );
    final authHeaders = _serverToken != null
        ? {'Authorization': 'Bearer $_serverToken'}
        : const <String, String>{};
    final resp = await http
        .get(uri, headers: authHeaders)
        .timeout(const Duration(seconds: 10));
    if (resp.statusCode != 200) return null;
    final data = jsonDecode(resp.body) as Map<String, dynamic>;
    final raw = (data['messages'] as List?) ?? const [];
    final loaded = <IncomingMessage>[];
    String? oldestUuid;
    for (final item in raw) {
      final env = item as Map<String, dynamic>;
      oldestUuid ??= env['uuid'] as String?;
      final inner = env['message'];
      if (inner is Map<String, dynamic>) {
        final m = IncomingMessage.fromJson(inner);
        if (m is AssistantMsg ||
            m is UserMsg ||
            m is ResultMsg ||
            m is CompactBoundaryMsg) {
          loaded.add(m);
        }
      }
    }
    return _HistoryPage(
      messages: loaded,
      oldestUuid: oldestUuid,
      hasMore: (data['has_more'] as bool?) ?? false,
    );
  }
}
