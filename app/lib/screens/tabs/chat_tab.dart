import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';

import '../../api/protocol.dart';
import '../../api/sessions_api.dart';
import '../../i18n/locale_provider.dart';
import '../../i18n/strings.dart';
import '../../utils/time_format.dart';
import '../../state/prefs.dart';
import '../../state/projects_store.dart';
import '../../state/server_config.dart';
import '../../theme.dart';
import '../../widgets/cc_spinner.dart';
import '../../widgets/message_view.dart';

class LocalUserInput extends IncomingMessage {
  final String text;
  final int timestamp;
  LocalUserInput(this.text, {int? timestamp})
      : timestamp = timestamp ?? DateTime.now().millisecondsSinceEpoch;
}

/// In-progress assistant message being built char-by-char from stream deltas.
class StreamingAssistant extends IncomingMessage {
  final StringBuffer text = StringBuffer();
  bool stopped = false;
}

class _HistoryPage {
  final List<IncomingMessage> messages;
  final String? oldestUuid;
  final bool hasMore;
  const _HistoryPage({required this.messages, this.oldestUuid, required this.hasMore});
}

enum _HolderChoice { takeover, readOnly, cancel }

class ChatTab extends ConsumerStatefulWidget {
  const ChatTab({super.key});

  @override
  ConsumerState<ChatTab> createState() => _ChatTabState();
}

class _ChatTabState extends ConsumerState<ChatTab> with WidgetsBindingObserver {
  WebSocketChannel? _channel;
  final List<IncomingMessage> _messages = [];
  final TextEditingController _textController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  bool _connected = false;
  bool _busy = false;
  DateTime? _busyStartedAt;
  String? _error;
  String? _boundKey;

  // Stream-mode 状态机（复刻 claude-code Spinner.tsx 的 thinkingStatus 逻辑）
  CcStreamMode _mode = CcStreamMode.requesting;
  String? _currentBlockKind;
  DateTime? _thinkingStartedAt;
  int? _thoughtSeconds;
  Timer? _thoughtForTimer;

  // 跟随末尾滚动：默认开启。当用户手动向上划离开底部 → 关闭，并在右下角显示
  // 浮动按钮；用户按按钮或自己滑回底部 → 重新开启。
  bool _stickToBottom = true;
  static const double _stickToBottomThreshold = 80.0;

  // 历史消息反向分页（首屏 50 条，滚到顶取上一页）。
  static const int _historyPageSize = 50;
  static const double _loadMoreThreshold = 200.0;
  String? _oldestUuid;
  bool _hasMoreHistory = false;
  bool _loadingOlder = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _scrollController.addListener(_onScroll);
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final pos = _scrollController.position;
    final atBottom = pos.maxScrollExtent - pos.pixels <= _stickToBottomThreshold;
    if (atBottom != _stickToBottom) {
      setState(() => _stickToBottom = atBottom);
    }
    // 滚到接近顶部 → 拉更早一页
    if (pos.pixels <= _loadMoreThreshold &&
        _hasMoreHistory &&
        !_loadingOlder &&
        _oldestUuid != null) {
      _loadOlderPage();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _thoughtForTimer?.cancel();
    _channel?.sink.close();
    _textController.dispose();
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // After app comes back to foreground, force reconnect if socket died.
      if (!_connected && _boundKey != null) {
        setState(() {
          _channel?.sink.close();
          _channel = null;
          _boundKey = null;
          _error = null;
        });
      }
    }
  }

  String _sessionKey(CurrentSession s) =>
      '${s.cwd}|${s.resumeId ?? "new"}|${s.readOnly ? "ro" : "rw"}';

  // Throttle reconnect attempts so a dead server doesn't trigger a tight loop.
  // Once attempted, only the user-visible "reconnect" button will retry.
  String? _attemptedKey;
  bool _attempting = false;

  void _ensureConnected(CurrentSession session) {
    final key = _sessionKey(session);
    if (_boundKey == key && (_channel != null || session.readOnly)) return;
    if (_attemptedKey == key) return; // already tried, don't auto-retry

    _channel?.sink.close();
    _attempting = true;
    _attemptedKey = key;
    setState(() {
      _messages.clear();
      _channel = null;
      _connected = false;
      _busy = false;
      _error = null;
      _boundKey = key;
      _oldestUuid = null;
      _hasMoreHistory = false;
      _loadingOlder = false;
    });

    final config = ref.read(activeConnectionProvider);
    if (config == null) {
      _attempting = false;
      return;
    }

    // 只读模式：完全不开 ws，仅通过 HTTP 翻历史。
    if (session.readOnly && session.resumeId != null) {
      _attempting = false;
      _loadHistory(config.httpBase, session.cwd, session.resumeId!);
      return;
    }

    // 普通 resume：先看是否被其他 CLI 进程持有；命中则把决定权交给用户。
    if (session.resumeId != null) {
      _resumeWithHolderCheck(config.httpBase, config.wsBase, session);
    } else {
      _openSessionWebSocket(config.wsBase, session);
    }
  }

  /// Resume 前先 GET /sessions/:id/holder。
  /// - 没人持有：直接打开 ws。
  /// - 有持有者：弹窗让用户选「接管」或「只读」。
  ///   - 接管：照常打开 ws（jsonl 会出现两条分叉，但服务端目前没办法 kill 远端 CLI；
  ///     这一步主要是把"明知有冲突"这个状态显式化）。
  ///   - 只读：把 currentSession 切到 readOnly=true 重新走一遍 _ensureConnected。
  Future<void> _resumeWithHolderCheck(
    String httpBase,
    String wsBase,
    CurrentSession session,
  ) async {
    SessionHolder? holder;
    try {
      holder = await SessionsApi(httpBase).holder(session.resumeId!);
    } catch (_) {
      // 检测失败不阻塞使用，按"没人持有"继续。
      holder = null;
    }
    if (!mounted) return;
    if (holder == null) {
      _openSessionWebSocket(wsBase, session);
      return;
    }
    // 弹窗
    final choice = await _showHolderDialog(holder);
    if (!mounted) return;
    if (choice == _HolderChoice.readOnly) {
      // 切到只读再走一遍：_attemptedKey 也要跟着更新避免被去重。
      _attemptedKey = null;
      ref.read(currentSessionProvider.notifier).state =
          session.copyWith(readOnly: true);
      return;
    }
    if (choice == _HolderChoice.takeover) {
      _openSessionWebSocket(wsBase, session);
      return;
    }
    // 取消 / 关闭对话框：什么都不做，停留在空白态。
    _attempting = false;
  }

  void _openSessionWebSocket(String wsBase, CurrentSession session) {
    // History first — 让用户在 ws 建立期间就能看到历史消息。
    final conn = ref.read(activeConnectionProvider);
    if (conn != null && session.resumeId != null) {
      _loadHistory(conn.httpBase, session.cwd, session.resumeId!);
    }

    final uri = Uri.parse('$wsBase/ws/session');
    try {
      _channel = WebSocketChannel.connect(uri);
    } catch (e) {
      _attempting = false;
      setState(() => _error = '$e');
      return;
    }
    _channel!.stream.listen(_onData, onError: _onError, onDone: _onDone);

    final model = ref.read(currentModelProvider);
    final permMode = ref.read(permissionModeProvider);
    final initMsg = {
      'type': 'init',
      'cwd': session.cwd,
      'permission_mode': permMode.wire,
      'model': model.id,
      if (session.resumeId != null) 'resume': session.resumeId,
    };
    _channel!.sink.add(jsonEncode(initMsg));
  }

  Future<_HolderChoice?> _showHolderDialog(SessionHolder holder) async {
    final t = AppTokens.of(context);
    final fmt = DateTime.fromMillisecondsSinceEpoch(holder.startedAt);
    final ago = DateTime.now().difference(fmt);
    final agoStr = ago.inMinutes < 1
        ? '刚刚'
        : ago.inHours < 1
            ? '${ago.inMinutes} 分钟前'
            : ago.inDays < 1
                ? '${ago.inHours} 小时前'
                : '${ago.inDays} 天前';
    return showDialog<_HolderChoice>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: t.surface,
        title: Text('该会话正被另一个 Claude 进程使用',
            style: TextStyle(color: t.text, fontSize: 15, fontWeight: FontWeight.w600)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _kv('PID', '${holder.pid}', t),
            _kv('启动于', agoStr, t),
            if (holder.cwd.isNotEmpty) _kv('cwd', holder.cwd, t),
            const SizedBox(height: 10),
            Text(
              '继续写入可能导致历史分叉、消息互相不可见。建议先关闭那个终端再回来；'
              '或选择「只读」翻阅历史。',
              style: TextStyle(color: t.textMuted, fontSize: 12, height: 1.5),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(_HolderChoice.cancel),
            child: Text('取消', style: TextStyle(color: t.textMuted)),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(_HolderChoice.takeover),
            child: Text('仍然接管', style: TextStyle(color: t.error)),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(_HolderChoice.readOnly),
            child: Text('只读查看', style: TextStyle(color: t.accent, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }

  Widget _kv(String k, String v, AppTokens t) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 56,
              child: Text(k, style: TextStyle(color: t.textDim, fontSize: 12, fontFamily: 'monospace')),
            ),
            Expanded(
              child: Text(v, style: TextStyle(color: t.text, fontSize: 12, fontFamily: 'monospace')),
            ),
          ],
        ),
      );

  void _switchModel(ModelOption m) {
    ref.read(currentModelProvider.notifier).state = m;
    if (_channel != null && _connected) {
      _channel!.sink.add(jsonEncode({'type': 'set_model', 'model': m.id}));
    }
  }

  void _switchPermissionMode(CcPermissionMode m) {
    ref.read(permissionModeProvider.notifier).set(m);
    if (_channel != null && _connected) {
      _channel!.sink.add(jsonEncode({'type': 'set_permission_mode', 'mode': m.wire}));
    }
  }

  /// 首屏加载：最后 [_historyPageSize] 条消息。
  Future<void> _loadHistory(String httpBase, String cwd, String sessionId) async {
    try {
      final page = await _fetchHistoryPage(
        httpBase, cwd, sessionId,
        limit: _historyPageSize,
      );
      if (page == null || !mounted) return;
      setState(() {
        _messages
          ..clear()
          ..addAll(page.messages);
        _oldestUuid = page.oldestUuid;
        _hasMoreHistory = page.hasMore;
      });
      _scrollToEnd(force: true);
    } catch (_) {
      // History fetch failure is non-fatal — just skip.
    }
  }

  /// 上滑到顶时调用：取 [_oldestUuid] 前面的一页，prepend 到列表前。
  /// prepend 后用 maxScrollExtent 差值保持视口位置（避免视觉跳动）。
  Future<void> _loadOlderPage() async {
    if (_loadingOlder || !_hasMoreHistory || _oldestUuid == null) return;
    final conn = ref.read(activeConnectionProvider);
    final session = ref.read(currentSessionProvider);
    if (conn == null || session?.resumeId == null) return;

    setState(() => _loadingOlder = true);
    final preMax = _scrollController.hasClients
        ? _scrollController.position.maxScrollExtent
        : 0.0;
    final preOffset = _scrollController.hasClients
        ? _scrollController.offset
        : 0.0;

    try {
      final page = await _fetchHistoryPage(
        conn.httpBase, session!.cwd, session.resumeId!,
        limit: _historyPageSize,
        beforeUuid: _oldestUuid,
      );
      if (page == null || !mounted) {
        setState(() => _loadingOlder = false);
        return;
      }
      setState(() {
        _messages.insertAll(0, page.messages);
        _oldestUuid = page.oldestUuid ?? _oldestUuid;
        _hasMoreHistory = page.hasMore;
        _loadingOlder = false;
      });
      // 等下一帧 layout 完，根据高度增量保持视口
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_scrollController.hasClients) return;
        final postMax = _scrollController.position.maxScrollExtent;
        final delta = postMax - preMax;
        if (delta > 0) {
          _scrollController.jumpTo(preOffset + delta);
        }
      });
    } catch (_) {
      if (mounted) setState(() => _loadingOlder = false);
    }
  }

  Future<_HistoryPage?> _fetchHistoryPage(
    String httpBase,
    String cwd,
    String sessionId, {
    required int limit,
    String? beforeUuid,
  }) async {
    final uri = Uri.parse('$httpBase/sessions/$sessionId/messages').replace(
      queryParameters: {
        'cwd': cwd,
        'limit': '$limit',
        if (beforeUuid != null) 'before_uuid': beforeUuid,
      },
    );
    final resp = await http.get(uri).timeout(const Duration(seconds: 10));
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

  void _manualReconnect() {
    setState(() {
      _channel?.sink.close();
      _channel = null;
      _boundKey = null;
      _attemptedKey = null;
      _attempting = false;
      _error = null;
    });
  }

  void _onData(dynamic raw) {
    if (raw is! String) return;
    final json = jsonDecode(raw) as Map<String, dynamic>;
    final msg = IncomingMessage.fromJson(json);
    setState(() {
      if (msg is SessionReady) {
        _attempting = false;
        _connected = true;
        _error = null;
      } else if (msg is ResultMsg) {
        _busy = false;
        _busyStartedAt = null;
        _mode = CcStreamMode.requesting;
        _thoughtForTimer?.cancel();
        _thoughtSeconds = null;
        _currentBlockKind = null;
        _messages.add(msg);
      } else if (msg is ErrorMsg) {
        _error = msg.message;
        _messages.add(msg);
      } else if (msg is StreamBlockStart) {
        _currentBlockKind = msg.kind;
        switch (msg.kind) {
          case 'text':
            _mode = CcStreamMode.responding;
            _thoughtForTimer?.cancel();
            _thoughtSeconds = null;
            _messages.add(StreamingAssistant());
            break;
          case 'thinking':
            _mode = CcStreamMode.thinking;
            _thinkingStartedAt = DateTime.now();
            _thoughtForTimer?.cancel();
            break;
          case 'tool_use':
            _mode = CcStreamMode.toolInput;
            break;
        }
      } else if (msg is StreamDelta) {
        if (msg.kind == 'text') {
          // 追加流式文本；thinking_delta 丢弃（参见 docs/streaming-response.md）。
          final last = _messages.isNotEmpty ? _messages.last : null;
          if (last is StreamingAssistant && !last.stopped) {
            last.text.write(msg.text);
          } else {
            final s = StreamingAssistant()..text.write(msg.text);
            _messages.add(s);
          }
        }
      } else if (msg is StreamBlockStop) {
        // thinking 块结束时进入 "已思考 Xs" 过渡态，至少显示 2 秒。
        if (_currentBlockKind == 'thinking' && _thinkingStartedAt != null) {
          final dur = DateTime.now().difference(_thinkingStartedAt!);
          _thinkingStartedAt = null;
          _thoughtSeconds = dur.inSeconds.clamp(1, 99999);
          _mode = CcStreamMode.thoughtFor;
          _thoughtForTimer?.cancel();
          _thoughtForTimer = Timer(const Duration(seconds: 2), () {
            if (!mounted) return;
            setState(() {
              // 2 秒后回落到 responding 提示（除非新的 block 已经来）。
              if (_mode == CcStreamMode.thoughtFor) {
                _mode = CcStreamMode.responding;
                _thoughtSeconds = null;
              }
            });
          });
        }
        _currentBlockKind = null;
        final last = _messages.isNotEmpty ? _messages.last : null;
        if (last is StreamingAssistant) last.stopped = true;
      } else if (msg is AssistantMsg) {
        // Final non-streaming assistant message arrives after streaming completes.
        // If we already streamed its text, replace the in-progress block.
        if (_messages.isNotEmpty && _messages.last is StreamingAssistant) {
          _messages.removeLast();
        }
        _messages.add(msg);
      } else if (msg is PongMsg || msg is SystemMsg) {
        // skip
      } else if (msg is CompactBoundaryMsg) {
        // 实时也可能收到（用户在会话中触发了 /compact）。
        _messages.add(msg);
      } else {
        _messages.add(msg);
      }
    });
    _scrollToEnd();
  }

  void _onError(Object e) {
    _attempting = false;
    setState(() {
      _error = e.toString();
      _connected = false;
      _channel = null;
    });
  }

  void _onDone() {
    _attempting = false;
    setState(() {
      _connected = false;
      _busy = false;
      _busyStartedAt = null;
      _channel = null;
    });
  }

  /// 滚动到底部。
  /// - [force] = true：无论 _stickToBottom 是什么都强制滚（用于浮动按钮 / 提交消息后）
  /// - [force] = false（默认）：仅在当前已经"贴底"时滚（用于流式 delta 自动跟随）
  void _scrollToEnd({bool force = false}) {
    if (!force && !_stickToBottom) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 150),
        curve: Curves.easeOut,
      );
      if (force) setState(() => _stickToBottom = true);
    });
  }

  void _submit() {
    final text = _textController.text.trim();
    if (text.isEmpty || !_connected || _busy) return;
    setState(() {
      _messages.add(LocalUserInput(text));
      _busy = true;
      _busyStartedAt = DateTime.now();
      _mode = CcStreamMode.requesting;
      _currentBlockKind = null;
      _thoughtSeconds = null;
      _thoughtForTimer?.cancel();
      _textController.clear();
    });
    _channel?.sink.add(jsonEncode({'type': 'user_message', 'text': text}));
    _scrollToEnd(force: true);
  }

  void _interrupt() {
    if (_busy) _channel?.sink.add(jsonEncode({'type': 'interrupt'}));
  }

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    final s = ref.watch(stringsProvider);
    final session = ref.watch(currentSessionProvider);

    if (session == null) {
      return _EmptyState(
        icon: Icons.chat_bubble_outline,
        title: s.chatEmptyTitle,
        subtitle: s.chatEmptyPickProject,
      );
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _ensureConnected(session);
    });

    // 扫一遍消息流，按 tool_use_id 索引所有 ToolResultBlock。
    // 这样渲染 ToolUseBlock 时能找到匹配 result 一起折叠显示（参考 cxClaw 的 upsertToolMessage）。
    final toolResults = <String, ToolResultBlock>{};
    for (final m in _messages) {
      if (m is UserMsg) {
        for (final b in m.content) {
          if (b is ToolResultBlock && b.toolUseId.isNotEmpty) {
            toolResults[b.toolUseId] = b;
          }
        }
      }
    }

    return Column(
      children: [
        if (session.readOnly)
          _ReadOnlyBanner(
            onExit: () {
              _attemptedKey = null;
              ref.read(currentSessionProvider.notifier).state =
                  session.copyWith(readOnly: false);
            },
          )
        else
          _StatusRow(
            connected: _connected,
            busy: _busy,
            error: _error,
            onReconnect: _manualReconnect,
          ),
        Divider(color: t.borderSubt, height: 0.5, thickness: 0.5),
        Expanded(
          child: Stack(
            children: [
              _messages.isEmpty
                  ? _EmptyState(
                      icon: Icons.send_outlined,
                      title: _connected ? s.chatStartTalking : s.chatConnecting,
                    )
                  : ListView.builder(
                      controller: _scrollController,
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                      // +1 用于在顶部插入"加载更早消息"指示
                      itemCount: _messages.length + 1,
                      itemBuilder: (_, i) {
                        if (i == 0) {
                          if (_loadingOlder) {
                            return const Padding(
                              padding: EdgeInsets.symmetric(vertical: 14),
                              child: Center(
                                child: SizedBox(
                                  width: 16, height: 16,
                                  child: CircularProgressIndicator(strokeWidth: 1.5),
                                ),
                              ),
                            );
                          }
                          // 没在加载也要占位（哪怕高度 0），保证 itemCount 一致
                          return const SizedBox.shrink();
                        }
                        final m = _messages[i - 1];
                        if (m is LocalUserInput) {
                          return _UserMessage(text: m.text, timestamp: m.timestamp);
                        }
                        if (m is StreamingAssistant) return _StreamingMessage(buffer: m);
                        return MessageView(message: m, toolResults: toolResults);
                      },
                    ),
              // Right-bottom "jump to bottom" button — only shown when the user
              // scrolled away from the latest message.
              if (!_stickToBottom)
                Positioned(
                  right: 12,
                  bottom: 12,
                  child: _JumpToBottomButton(
                    onTap: () => _scrollToEnd(force: true),
                  ),
                ),
            ],
          ),
        ),
        if (_busy && _busyStartedAt != null)
          CcSpinnerLine(
            startedAt: _busyStartedAt!,
            mode: _mode,
            thoughtSeconds: _thoughtSeconds,
            color: t.accent,
            dimColor: t.textDim,
          ),
        Divider(color: t.borderSubt, height: 0.5, thickness: 0.5),
        if (!session.readOnly)
          _Composer(
            controller: _textController,
            connected: _connected,
            busy: _busy,
            onSubmit: _submit,
            onStop: _interrupt,
            onSwitchModel: _switchModel,
            onSwitchPermissionMode: _switchPermissionMode,
          ),
      ],
    );
  }
}

class _ReadOnlyBanner extends StatelessWidget {
  final VoidCallback onExit;
  const _ReadOnlyBanner({required this.onExit});

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: t.surfaceHi,
      child: Row(
        children: [
          Icon(Icons.visibility_outlined, size: 14, color: t.textMuted),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '只读模式：会话被另一个 Claude 进程持有，仅展示历史',
              style: TextStyle(fontSize: 12, color: t.textMuted),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          InkWell(
            onTap: onExit,
            borderRadius: BorderRadius.circular(4),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              child: Text(
                '重新连接',
                style: TextStyle(
                  fontSize: 11,
                  color: t.accent,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _JumpToBottomButton extends StatelessWidget {
  final VoidCallback onTap;
  const _JumpToBottomButton({required this.onTap});

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return Material(
      elevation: 3,
      shadowColor: Colors.black.withValues(alpha: 0.18),
      color: t.surface,
      shape: CircleBorder(side: BorderSide(color: t.border, width: 0.5)),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: SizedBox(
          width: 40, height: 40,
          child: Icon(Icons.arrow_downward_rounded, size: 18, color: t.text),
        ),
      ),
    );
  }
}

class _StatusRow extends StatelessWidget {
  final bool connected;
  final bool busy;
  final String? error;
  final VoidCallback onReconnect;
  const _StatusRow({
    required this.connected,
    required this.busy,
    required this.error,
    required this.onReconnect,
  });

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    final dotColor = error != null
        ? t.error
        : (connected ? (busy ? t.warning : t.success) : t.textDim);
    final statusText = error != null
        ? 'error'
        : (connected ? (busy ? 'streaming' : 'ready') : 'connecting…');

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      color: t.surface,
      child: Row(
        children: [
          Container(
            width: 6, height: 6,
            decoration: BoxDecoration(color: dotColor, shape: BoxShape.circle),
          ),
          const SizedBox(width: 8),
          Text(statusText, style: TextStyle(fontSize: 11, color: t.textMuted)),
          const Spacer(),
          if (error != null || (!connected && !busy))
            InkWell(
              onTap: onReconnect,
              borderRadius: BorderRadius.circular(4),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                child: Row(
                  children: [
                    Icon(Icons.refresh, size: 14, color: t.accent),
                    const SizedBox(width: 4),
                    Text(
                      'reconnect',
                      style: TextStyle(fontSize: 11, color: t.accent, fontWeight: FontWeight.w500),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _UserMessage extends ConsumerWidget {
  final String text;
  final int? timestamp;
  const _UserMessage({required this.text, this.timestamp});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = AppTokens.of(context);
    final s = ref.watch(stringsProvider);
    final ts = tsFromMillis(timestamp);
    final maxW = MediaQuery.of(context).size.width * 0.78;
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          ConstrainedBox(
            constraints: BoxConstraints(maxWidth: maxW),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: t.accent,
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(14),
                  topRight: Radius.circular(14),
                  bottomLeft: Radius.circular(14),
                  bottomRight: Radius.circular(4),
                ),
              ),
              child: SelectableText(
                text,
                style: const TextStyle(fontSize: 14, color: Colors.white, height: 1.45),
              ),
            ),
          ),
          if (ts != null)
            Padding(
              padding: const EdgeInsets.only(top: 4, right: 2),
              child: Text(
                formatMessageTime(ts, yesterdayLabel: s.timeYesterday),
                style: TextStyle(fontFamily: 'monospace', fontSize: 10, color: t.textDim),
              ),
            ),
        ],
      ),
    );
  }
}

class _Composer extends ConsumerWidget {
  final TextEditingController controller;
  final bool connected;
  final bool busy;
  final VoidCallback onSubmit;
  final VoidCallback onStop;
  final void Function(ModelOption) onSwitchModel;
  final void Function(CcPermissionMode) onSwitchPermissionMode;
  const _Composer({
    required this.controller,
    required this.connected,
    required this.busy,
    required this.onSubmit,
    required this.onStop,
    required this.onSwitchModel,
    required this.onSwitchPermissionMode,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = AppTokens.of(context);
    final model = ref.watch(currentModelProvider);
    final canSend = connected && !busy;
    final editable = connected; // 文本框 busy 时仍可编辑（用户能预写下一条），但发送被 stop 按钮替代。
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
        child: Container(
          decoration: BoxDecoration(
            color: t.surface,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: t.border, width: 0.5),
          ),
          padding: const EdgeInsets.fromLTRB(12, 8, 8, 6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 输入框 + 发送/停止按钮：纵向居中。
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(
                    child: TextField(
                      controller: controller,
                      minLines: 2,
                      maxLines: 6,
                      enabled: editable,
                      cursorColor: t.accent,
                      style: TextStyle(fontSize: 14, color: t.text, height: 1.4),
                      decoration: InputDecoration(
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        disabledBorder: InputBorder.none,
                        isDense: true,
                        filled: false,
                        contentPadding: const EdgeInsets.symmetric(vertical: 4),
                        hintText: editable ? 'Ask Claude…' : 'Connecting…',
                        hintStyle: TextStyle(color: t.textDim, fontSize: 14),
                      ),
                      textInputAction: TextInputAction.newline,
                      keyboardType: TextInputType.multiline,
                    ),
                  ),
                  const SizedBox(width: 8),
                  _SendOrStopButton(
                    busy: busy,
                    canSend: canSend,
                    onSubmit: onSubmit,
                    onStop: onStop,
                  ),
                ],
              ),
              const SizedBox(height: 4),
              // 工具栏在按钮下方，左对齐。
              Row(
                children: [
                  _PermissionModePicker(
                    current: ref.watch(permissionModeProvider),
                    onPick: onSwitchPermissionMode,
                  ),
                  _ModelPicker(current: model, onPick: onSwitchModel),
                  const Spacer(),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 输入框右侧的 44×44 圆角方块按钮。
/// - busy=false → 发送箭头，accent 色
/// - busy=true  → 停止方块，红色
/// - 不可用    → 灰
class _SendOrStopButton extends StatelessWidget {
  final bool busy;
  final bool canSend;
  final VoidCallback onSubmit;
  final VoidCallback onStop;
  const _SendOrStopButton({
    required this.busy,
    required this.canSend,
    required this.onSubmit,
    required this.onStop,
  });

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    final bg = busy
        ? t.error
        : (canSend ? t.accent : t.surfaceHi);
    final fg = (busy || canSend) ? Colors.white : t.textDim;
    final radius = BorderRadius.circular(12);
    return Material(
      color: bg,
      borderRadius: radius,
      child: InkWell(
        borderRadius: radius,
        onTap: busy ? onStop : (canSend ? onSubmit : null),
        child: SizedBox(
          width: 44,
          height: 44,
          child: Icon(
            busy ? Icons.stop_rounded : Icons.arrow_upward_rounded,
            size: 22,
            color: fg,
          ),
        ),
      ),
    );
  }
}

class _ModelPicker extends StatelessWidget {
  final ModelOption current;
  final void Function(ModelOption) onPick;
  const _ModelPicker({required this.current, required this.onPick});

  Future<void> _openSheet(BuildContext context) async {
    final t = AppTokens.of(context);
    final picked = await showModalBottomSheet<ModelOption>(
      context: context,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withValues(alpha: 0.35),
      builder: (ctx) => Container(
        margin: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: t.surface,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: t.border),
        ),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 10, bottom: 4),
                child: Center(
                  child: Container(
                    width: 36, height: 4,
                    decoration: BoxDecoration(color: t.border, borderRadius: BorderRadius.circular(2)),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
                child: Row(
                  children: [
                    Icon(Icons.auto_awesome_outlined, size: 16, color: t.textMuted),
                    const SizedBox(width: 8),
                    Text(
                      '选择模型',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: t.text,
                        letterSpacing: -0.1,
                      ),
                    ),
                  ],
                ),
              ),
              for (final m in knownModels) ...[
                Divider(color: t.borderSubt, height: 0.5, indent: 16, endIndent: 16),
                _ModelRow(
                  model: m,
                  selected: m.id == current.id,
                  onTap: () => Navigator.of(ctx).pop(m),
                ),
              ],
              const SizedBox(height: 6),
            ],
          ),
        ),
      ),
    );
    if (picked != null) onPick(picked);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return InkWell(
      onTap: () => _openSheet(context),
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        margin: const EdgeInsets.symmetric(horizontal: 4),
        decoration: BoxDecoration(
          color: t.surfaceHi,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: t.border, width: 0.5),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.auto_awesome, size: 12, color: t.textMuted),
            const SizedBox(width: 6),
            Text(
              current.label,
              style: TextStyle(fontSize: 12, color: t.textMuted, fontWeight: FontWeight.w500),
            ),
            const SizedBox(width: 4),
            Icon(Icons.expand_more, size: 14, color: t.textMuted),
          ],
        ),
      ),
    );
  }
}

class _ModelRow extends StatelessWidget {
  final ModelOption model;
  final bool selected;
  final VoidCallback onTap;
  const _ModelRow({required this.model, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        child: Row(
          children: [
            Container(
              width: 18, height: 18,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: selected ? t.accent : Colors.transparent,
                border: Border.all(
                  color: selected ? t.accent : t.border,
                  width: 1.5,
                ),
              ),
              child: selected
                  ? const Icon(Icons.check, size: 11, color: Colors.white)
                  : null,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    model.label,
                    style: TextStyle(
                      color: t.text,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      letterSpacing: -0.1,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    model.description,
                    style: TextStyle(
                      color: t.textDim,
                      fontSize: 11.5,
                      letterSpacing: 0.1,
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

/// 权限模式 chip + bottom sheet selector，跟 ModelPicker 同款 UI 语言。
class _PermissionModePicker extends ConsumerWidget {
  final CcPermissionMode current;
  final void Function(CcPermissionMode) onPick;
  const _PermissionModePicker({required this.current, required this.onPick});

  String _label(CcPermissionMode m, Strings s) {
    switch (m) {
      case CcPermissionMode.defaultMode: return s.permModeDefaultLabel;
      case CcPermissionMode.acceptEdits: return s.permModeAcceptEditsLabel;
      case CcPermissionMode.plan: return s.permModePlanLabel;
      case CcPermissionMode.bypass: return s.permModeBypassLabel;
    }
  }

  String _desc(CcPermissionMode m, Strings s) {
    switch (m) {
      case CcPermissionMode.defaultMode: return s.permModeDefaultDesc;
      case CcPermissionMode.acceptEdits: return s.permModeAcceptEditsDesc;
      case CcPermissionMode.plan: return s.permModePlanDesc;
      case CcPermissionMode.bypass: return s.permModeBypassDesc;
    }
  }

  (IconData, Color) _glyph(CcPermissionMode m, AppTokens t) {
    switch (m) {
      case CcPermissionMode.defaultMode: return (Icons.front_hand_outlined, t.warning);
      case CcPermissionMode.acceptEdits: return (Icons.edit_note_outlined, t.accent);
      case CcPermissionMode.plan: return (Icons.checklist_outlined, t.toolRead);
      case CcPermissionMode.bypass: return (Icons.rocket_launch_outlined, t.toolBash);
    }
  }

  Future<void> _openSheet(BuildContext context, WidgetRef ref) async {
    final t = AppTokens.of(context);
    final s = ref.read(stringsProvider);
    final picked = await showModalBottomSheet<CcPermissionMode>(
      context: context,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withValues(alpha: 0.35),
      builder: (ctx) => Container(
        margin: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: t.surface,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: t.border),
        ),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 10, bottom: 4),
                child: Center(
                  child: Container(
                    width: 36, height: 4,
                    decoration: BoxDecoration(color: t.border, borderRadius: BorderRadius.circular(2)),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
                child: Row(
                  children: [
                    Icon(Icons.shield_outlined, size: 16, color: t.textMuted),
                    const SizedBox(width: 8),
                    Text(
                      s.permModeTitle,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: t.text,
                        letterSpacing: -0.1,
                      ),
                    ),
                  ],
                ),
              ),
              for (final m in CcPermissionMode.values) ...[
                Divider(color: t.borderSubt, height: 0.5, indent: 16, endIndent: 16),
                _PermissionModeRow(
                  mode: m,
                  label: _label(m, s),
                  description: _desc(m, s),
                  glyph: _glyph(m, t),
                  selected: m == current,
                  onTap: () => Navigator.of(ctx).pop(m),
                ),
              ],
              const SizedBox(height: 6),
            ],
          ),
        ),
      ),
    );
    if (picked != null) onPick(picked);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = AppTokens.of(context);
    final s = ref.watch(stringsProvider);
    final (icon, color) = _glyph(current, t);
    return InkWell(
      onTap: () => _openSheet(context, ref),
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        margin: const EdgeInsets.symmetric(horizontal: 4),
        decoration: BoxDecoration(
          color: t.surfaceHi,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: t.border, width: 0.5),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 12, color: color),
            const SizedBox(width: 6),
            Text(
              _label(current, s),
              style: TextStyle(fontSize: 12, color: t.textMuted, fontWeight: FontWeight.w500),
            ),
            const SizedBox(width: 4),
            Icon(Icons.expand_more, size: 14, color: t.textMuted),
          ],
        ),
      ),
    );
  }
}

class _PermissionModeRow extends StatelessWidget {
  final CcPermissionMode mode;
  final String label;
  final String description;
  final (IconData, Color) glyph;
  final bool selected;
  final VoidCallback onTap;
  const _PermissionModeRow({
    required this.mode,
    required this.label,
    required this.description,
    required this.glyph,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    final (icon, color) = glyph;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        child: Row(
          children: [
            Container(
              width: 18, height: 18,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: selected ? t.accent : Colors.transparent,
                border: Border.all(
                  color: selected ? t.accent : t.border,
                  width: 1.5,
                ),
              ),
              child: selected
                  ? const Icon(Icons.check, size: 11, color: Colors.white)
                  : null,
            ),
            const SizedBox(width: 12),
            Icon(icon, size: 16, color: color),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    label,
                    style: TextStyle(
                      color: t.text,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      letterSpacing: -0.1,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    description,
                    style: TextStyle(
                      color: t.textDim,
                      fontSize: 11.5,
                      letterSpacing: 0.1,
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

/// 流式 assistant 消息：每个 delta 都用 MarkdownBody 实时渲染，
/// 跟最终 AssistantMsg 的样式保持一致——代码块/列表/链接在打字过程中就成型。
class _StreamingMessage extends StatelessWidget {
  final StreamingAssistant buffer;
  const _StreamingMessage({required this.buffer});

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                'CLAUDE',
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 1.2,
                  color: t.accent,
                ),
              ),
              const SizedBox(width: 8),
              Container(
                width: 4,
                height: 4,
                decoration: BoxDecoration(color: t.accent, shape: BoxShape.circle),
              ),
            ],
          ),
          const SizedBox(height: 6),
          MarkdownBody(
            data: buffer.text.toString(),
            selectable: true,
            styleSheet: streamingMarkdownStyle(t),
          ),
        ],
      ),
    );
  }
}

/// 流式 / 最终消息共用的 markdown 样式表。
MarkdownStyleSheet streamingMarkdownStyle(AppTokens t) => MarkdownStyleSheet(
      p: TextStyle(color: t.text, fontSize: 13, height: 1.6),
      code: TextStyle(
        fontFamily: 'monospace',
        fontSize: 12,
        color: t.accent,
        backgroundColor: t.surfaceHi,
      ),
      codeblockDecoration: BoxDecoration(
        color: t.surfaceHi,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: t.border, width: 0.5),
      ),
      codeblockPadding: const EdgeInsets.all(10),
      blockquoteDecoration: BoxDecoration(
        color: t.surfaceHi,
        border: Border(left: BorderSide(color: t.accent, width: 3)),
      ),
      h1: TextStyle(color: t.text, fontSize: 16, fontWeight: FontWeight.w600),
      h2: TextStyle(color: t.text, fontSize: 14, fontWeight: FontWeight.w600),
      h3: TextStyle(color: t.text, fontSize: 13, fontWeight: FontWeight.w600),
      listBullet: TextStyle(color: t.textMuted, fontSize: 13),
    );

class _EmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  const _EmptyState({required this.icon, required this.title, this.subtitle});

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 40, color: t.textDim),
          const SizedBox(height: 16),
          Text(title, style: TextStyle(fontSize: 14, color: t.textMuted, fontWeight: FontWeight.w500)),
          if (subtitle != null) ...[
            const SizedBox(height: 4),
            Text(subtitle!, style: TextStyle(fontSize: 12, color: t.textDim)),
          ],
        ],
      ),
    );
  }
}
