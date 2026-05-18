import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../../api/chat_api.dart';
import '../../api/protocol.dart';
import '../../api/sse_client.dart';
import '../../api/upload_api.dart';
import '../../i18n/locale_provider.dart';
import '../../i18n/strings.dart';
import '../../utils/time_format.dart';
import '../../state/prefs.dart';
import '../../state/projects_store.dart';
import '../../state/server_config.dart';
import '../../state/todo_list.dart';
import '../../theme.dart';
import '../../widgets/cc_spinner.dart';
import '../../widgets/message_view.dart';
import '../../widgets/todo_chip.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

class LocalUserInput extends IncomingMessage {
  final String text;
  final int timestamp;
  LocalUserInput(this.text, {int? timestamp})
      : timestamp = timestamp ?? DateTime.now().millisecondsSinceEpoch;
}

class _HistoryPage {
  final List<IncomingMessage> messages;
  final String? oldestUuid;
  final bool hasMore;
  const _HistoryPage({required this.messages, this.oldestUuid, required this.hasMore});
}

enum _ConflictChoice { observe, takeover, cancel }

enum _AttachmentStatus { uploading, ready, failed }

class _AttachmentState {
  final String localName;
  final String localPath;
  String? remotePath;
  String? errorMsg;
  _AttachmentStatus status;
  _AttachmentState({
    required this.localName,
    required this.localPath,
    required this.status,
  });
}

class ChatTab extends ConsumerStatefulWidget {
  const ChatTab({super.key});

  @override
  ConsumerState<ChatTab> createState() => _ChatTabState();
}

class _ChatTabState extends ConsumerState<ChatTab> with WidgetsBindingObserver {
  ChatApi? _chatApi;
  SseClient? _sseClient;
  StreamSubscription<SseEvent>? _sseSub;
  String? _serverToken;
  /// Claude session UUID. For new sessions: client-generated and persisted.
  /// For resumed sessions: equals currentSession.resumeId.
  String? _sessionId;
  final List<IncomingMessage> _messages = [];
  /// Debug only: 保存每条消息对应的原始 SSE event JSON，供长按查看。
  final Map<IncomingMessage, Map<String, dynamic>> _debugRaw = {};
  final TextEditingController _textController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  bool _connected = false;
  bool _observeMode = false;
  SessionHolder? _observeHolder;
  Timer? _observeTimer;
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

  // 键盘弹出跟随：记录上一帧键盘高度，用于判断键盘是否正在弹出。
  double _prevKeyboardHeight = 0;

  // 历史消息反向分页（首屏 50 条，滚到顶取上一页）。
  static const int _historyPageSize = 50;
  static const double _loadMoreThreshold = 200.0;
  String? _oldestUuid;
  bool _hasMoreHistory = false;
  bool _loadingOlder = false;
  /// 首屏历史加载中（resume 一个已有会话时为 true，直到第一页返回）。
  /// 用来区分"连接中"vs"加载历史中"，避免显示"开始对话"占位。
  bool _loadingHistory = false;

  /// 流式中用户继续提交的消息，按 FIFO 排队。
  /// busy 解除（result 到达）后自动出队、依次发送。
  /// 参考 claude-code messageQueueManager.ts 的单优先级简化版本。
  final List<String> _pending = [];

  /// 待发送的附件：用户从相册/文件选择后立即上传，发送时把 remotePath 拼到消息文本里。
  /// 上传中/失败的附件会阻塞发送（_attachmentsAllReady=false）。
  final List<_AttachmentState> _attachments = [];

  // ── Sub-agent (Task tool) streaming ──────────────────────────────────
  // keyed by the Task tool_use_id (= parent_tool_use_id on sub-agent msgs)
  final Map<String, List<IncomingMessage>> _subMsgs = {};
  /// Tracks the live StreamingAssistant per sub-agent so deltas can be appended.
  final Map<String, StreamingAssistant> _subStreaming = {};

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

  void _closeSse() {
    _sseSub?.cancel();
    _sseSub = null;
    unawaited(_sseClient?.close() ?? Future.value());
    _sseClient = null;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _thoughtForTimer?.cancel();
    _observeTimer?.cancel();
    _closeSse();
    _textController.dispose();
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      if (_observeMode) return; // observe mode handles its own polling
      // After app comes back to foreground, force reconnect if SSE stream died.
      if (!_connected && _boundKey != null) {
        _closeSse();
        setState(() {
          _sessionId = null;
          _boundKey = null;
          _error = null;
        });
      }
    }
  }

  /// 键盘弹出时，消息列表"追着"跟上去：延迟 80ms 再做动画，
  /// 产生轻微的"活力感"；只在用户已经贴底（_stickToBottom）时触发。
  @override
  void didChangeMetrics() {
    final keyboardHeight = WidgetsBinding
        .instance.platformDispatcher.views.first.viewInsets.bottom;
    final opening = keyboardHeight > _prevKeyboardHeight;
    _prevKeyboardHeight = keyboardHeight;

    if (opening && _stickToBottom) {
      Future.delayed(const Duration(milliseconds: 80), () {
        if (!mounted || !_scrollController.hasClients) return;
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOut,
        );
      });
    }
  }

  String _sessionKey(CurrentSession s) => '${s.cwd}|${s.resumeId ?? "new"}';

  // Throttle session-start attempts so a dead server doesn't trigger a tight loop.
  // Once api.start() failed, only the user-visible "reconnect" button will retry.
  // (SSE drops are handled by SseClient's own backoff loop; this debounce gates
  // only the initial REST handshake.)
  String? _attemptedKey;
  bool _attempting = false;

  void _ensureConnected(CurrentSession session) {
    final key = _sessionKey(session);
    if (_boundKey == key && (_sseClient != null || _connected || _observeMode)) return;
    if (_attempting) return;
    if (_attemptedKey == key) return;

    // Tear down prior SSE and observe timer before binding to a new session.
    _closeSse();
    _stopObserveTimer();

    _attempting = true;
    _attemptedKey = key;
    setState(() {
      _messages.clear();
      _debugRaw.clear();
      _subMsgs.clear();
      _subStreaming.clear();
      _sseClient = null;
      _sessionId = null;
      _chatApi = null;
      _connected = false;
      _observeMode = false;
      _observeHolder = null;
      _busy = false;
      _error = null;
      _boundKey = key;
      _oldestUuid = null;
      _hasMoreHistory = false;
      _loadingOlder = false;
      _loadingHistory = false;
    });
    ref.read(todoListProvider.notifier).clear();

    final config = ref.read(activeConnectionProvider);
    if (config == null) {
      _attempting = false;
      return;
    }
    _serverToken = config.token;

    unawaited(_connectToSession(config.httpBase, session));
  }

  /// 处理会话冲突（另一个 CLI 进程持有该会话）。
  /// 弹窗让用户选择：旁观、接管、或取消。
  ///
  /// 当通过 preloadedHolder 快速路径进入时，历史尚未开始加载；
  /// 用户确认继续（旁观/接管）后再触发，避免取消时的多余请求。
  Future<void> _handleConflict(
    String httpBase,
    CurrentSession session,
    String uuid,
    SessionHolder holder,
  ) async {
    final choice = await _showConflictDialog(holder);
    if (!mounted) return;
    switch (choice) {
      case _ConflictChoice.observe:
        // 旁观前先加载一次历史，确保消息列表有内容。
        if (session.resumeId != null && _messages.isEmpty) {
          _loadHistory(httpBase, session.cwd, session.resumeId!);
        }
        _startObserveMode(httpBase, session, uuid, holder);
      case _ConflictChoice.takeover:
        if (session.resumeId != null && _messages.isEmpty) {
          _loadHistory(httpBase, session.cwd, session.resumeId!);
        }
        unawaited(_doTakeover(httpBase, session, uuid));
      case null:
      case _ConflictChoice.cancel:
        setState(() => _attempting = false);
    }
  }

  Future<_ConflictChoice?> _showConflictDialog(SessionHolder holder) async {
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
    return showDialog<_ConflictChoice>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: t.surface,
        title: Text('会话正被另一个 Claude 进程使用',
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
              '旁观：静默跟随对话进展，可随时一键接管。\n接管：终止对端进程，本端取得控制权。',
              style: TextStyle(color: t.textMuted, fontSize: 12, height: 1.5),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(_ConflictChoice.cancel),
            child: Text('取消', style: TextStyle(color: t.textMuted)),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(_ConflictChoice.observe),
            child: Text('旁观', style: TextStyle(color: t.accent, fontWeight: FontWeight.w600)),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(_ConflictChoice.takeover),
            child: Text('接管', style: TextStyle(color: t.error)),
          ),
        ],
      ),
    );
  }

  void _startObserveMode(
    String httpBase,
    CurrentSession session,
    String uuid,
    SessionHolder holder,
  ) {
    setState(() {
      _observeMode = true;
      _observeHolder = holder;
    });
    _stopObserveTimer();
    _observeTimer = Timer.periodic(const Duration(seconds: 3), (_) async {
      if (!mounted) return;
      // Check if the holder is still running.
      try {
        final status = await _chatApi?.status(uuid);
        if (!mounted) return;
        if (status != null && status.state != TurnState.running) {
          _stopObserveTimer();
          if (!mounted) return;
          setState(() {
            _observeMode = false;
            _observeHolder = null;
          });
          unawaited(_connectToSession(httpBase, session));
          return;
        }
      } catch (_) {}
      // Silently refresh messages.
      try {
        final page = await _fetchHistoryPage(
          httpBase, session.cwd, uuid,
          limit: _historyPageSize,
        );
        if (!mounted || page == null) return;
        if (page.messages.length != _messages.length) {
          setState(() {
            _messages
              ..clear()
              ..addAll(page.messages);
            _oldestUuid = page.oldestUuid;
            _hasMoreHistory = page.hasMore;
          });
          _scrollToEnd();
        }
      } catch (_) {}
    });
  }

  void _stopObserveTimer() {
    _observeTimer?.cancel();
    _observeTimer = null;
  }

  Future<void> _doTakeover(String httpBase, CurrentSession session, String uuid) async {
    try {
      await _chatApi!.takeover(uuid);
    } catch (e) {
      if (mounted) setState(() => _error = '接管失败: $e');
      return;
    }
    if (!mounted) return;
    unawaited(_connectToSession(httpBase, session));
  }

  void _takeoverFromObserve() {
    final config = ref.read(activeConnectionProvider);
    final session = ref.read(currentSessionProvider);
    if (config == null || session == null || _sessionId == null || _chatApi == null) return;
    final uuid = _sessionId!;
    _stopObserveTimer();
    setState(() {
      _observeMode = false;
      _observeHolder = null;
    });
    unawaited(_doTakeover(config.httpBase, session, uuid));
  }

  /// 建立到会话的连接。为新建会话生成 UUID，为已有会话使用 resumeId。
  /// 根据 /chat/status 结果决定：直连 SSE（live）、等待发消息（idle）或进入冲突处理（running）。
  ///
  /// 快速路径：若 session.preloadedHolder 不为 null（会话列表已经告知存在 holder），
  /// 直接跳过 /chat/status 网络请求，立即弹出接管对话框。
  Future<void> _connectToSession(String httpBase, CurrentSession session) async {
    final uuid = session.resumeId ?? const Uuid().v4();
    _sessionId = uuid;
    unawaited(_persistUuid(uuid));

    final api = ChatApi(httpBase, token: _serverToken);
    _chatApi = api;

    // 快速路径：会话列表已提供 holder 信息，无需再发 /chat/status 请求。
    // 同时推迟 _loadHistory：若用户取消冲突弹窗，避免多余的历史加载。
    if (session.preloadedHolder != null) {
      setState(() => _attempting = false);
      unawaited(_handleConflict(httpBase, session, uuid, session.preloadedHolder!));
      return;
    }

    // 常规路径：先开始加载历史（与状态查询并行），再检测是否有冲突。
    if (session.resumeId != null) {
      _loadHistory(httpBase, session.cwd, session.resumeId!);
    }

    TurnStatus turnStatus;
    try {
      turnStatus = await api.status(uuid);
    } catch (_) {
      turnStatus = TurnStatus(TurnState.unknown);
    }

    if (!mounted) return;

    if (turnStatus.state == TurnState.running) {
      final holder = turnStatus.holder;
      setState(() => _attempting = false);
      if (holder != null) {
        unawaited(_handleConflict(httpBase, session, uuid, holder));
      } else {
        // No holder detail — treat as idle.
        setState(() { _connected = true; _error = null; });
      }
      return;
    }

    setState(() {
      _attempting = false;
      _connected = true;
      _error = null;
      if (turnStatus.state == TurnState.live) {
        _busy = true;
        _busyStartedAt ??= DateTime.now();
      }
    });

    if (turnStatus.state == TurnState.live) {
      _subscribeSse(httpBase, uuid);
    }
  }

  void _subscribeSse(String httpBase, String uuid) {
    final sseUrl = ChatApi(httpBase, token: _serverToken).eventsUrl(uuid);
    final sse = SseClient(
      url: sseUrl,
      headers: _serverToken != null ? {'Authorization': 'Bearer $_serverToken'} : const {},
    );
    _sseClient = sse;
    _sseSub = sse.events.listen(_onSseEvent);
    unawaited(sse.connect());
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
    if (_sessionId != null && _chatApi != null) {
      unawaited(_chatApi!.model(_sessionId!, m.id));
    }
  }

  void _switchPermissionMode(CcPermissionMode m) {
    ref.read(permissionModeProvider.notifier).set(m);
    if (_sessionId != null && _chatApi != null) {
      unawaited(_chatApi!.permission(_sessionId!, m.wire));
    }
  }

  /// 首屏加载：最后 [_historyPageSize] 条消息。
  Future<void> _loadHistory(String httpBase, String cwd, String sessionId) async {
    // 给骨架屏一个最少展示时长，避免 fetch 太快"闪一下"
    final minShowUntil = DateTime.now().add(const Duration(milliseconds: 280));
    setState(() => _loadingHistory = true);
    try {
      final page = await _fetchHistoryPage(
        httpBase, cwd, sessionId,
        limit: _historyPageSize,
      );
      if (!mounted) return;
      final remaining = minShowUntil.difference(DateTime.now());
      if (remaining > Duration.zero) await Future.delayed(remaining);
      if (!mounted) return;
      if (page != null) {
        setState(() {
          _messages
            ..clear()
            ..addAll(page.messages);
          _oldestUuid = page.oldestUuid;
          _hasMoreHistory = page.hasMore;
          _loadingHistory = false;
        });
        // ListView.builder 惰性布局：第一帧 maxScrollExtent 是基于可见条目的估算值，
        // 直接 animateTo 会停在中间。双帧 jumpTo 解决：
        //   第 1 帧：跳到估算底部，触发底部附近条目的布局；
        //   第 2 帧：再跳一次，此时所有底部条目已构建，extent 精确。
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || !_scrollController.hasClients) return;
          _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
          if (mounted) setState(() => _stickToBottom = true);
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted || !_scrollController.hasClients) return;
            _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
          });
        });
      } else {
        setState(() => _loadingHistory = false);
      }
    } catch (_) {
      if (mounted) setState(() => _loadingHistory = false);
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
      // 先插入消息，保持 spinner 可见（_loadingOlder 仍为 true），
      // 下一帧 layout 完成后先恢复视口位置再隐藏 spinner——
      // 这样 spinner 遮住了位置跳动的那一帧，过渡更平滑。
      setState(() {
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
        if (mounted) setState(() => _loadingOlder = false);
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
    final authHeaders = _serverToken != null ? {'Authorization': 'Bearer $_serverToken'} : const <String, String>{};
    final resp = await http.get(uri, headers: authHeaders).timeout(const Duration(seconds: 10));
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

  static const _kLastUuidKey = 'chat_last_uuid';

  Future<void> _persistUuid(String uuid) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kLastUuidKey, uuid);
  }

  Future<String?> _loadPersistedUuid() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_kLastUuidKey);
  }

  void _manualReconnect() {
    _stopObserveTimer();
    _closeSse();
    setState(() {
      _sessionId = null;
      _chatApi = null;
      _boundKey = null;
      _attemptedKey = null;
      _attempting = false;
      _error = null;
      _observeMode = false;
      _observeHolder = null;
    });
  }

  void _onSseEvent(SseEvent ev) {
    // Internal transport signals come through with a `__` prefix; surface them
    // as connection-level state changes rather than wire messages.
    if (ev.type.startsWith('__')) {
      if (ev.type == '__gap') {
        if (!mounted) return;
        setState(() {
          _error = 'event gap, reloading…';
          _connected = false;
        });
      } else if (ev.type == '__client_error') {
        // Transient — the SSE client will retry. Surface the latest error.
        if (!mounted) return;
        setState(() {
          _error = ev.data;
          _connected = false;
        });
      }
      return;
    }
    // Heartbeats etc. emit blank data; skip safely.
    if (ev.data.isEmpty) return;
    Map<String, dynamic> json;
    try {
      json = jsonDecode(ev.data) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    // First wire message after reconnect (re)confirms the live stream.
    if (!_connected && mounted) {
      setState(() {
        _connected = true;
        _error = null;
      });
    }
    _handleWireMessage(json);
  }

  void _debugTrack(IncomingMessage msg, Map<String, dynamic> json) {
    if (kDebugMode) _debugRaw[msg] = json;
  }

  /// Routes messages that belong to a sub-agent (Task tool) into [_subMsgs].
  /// Called inside setState so no extra setState needed.
  void _handleSubAgentMsg(IncomingMessage msg, String parentId) {
    _subMsgs.putIfAbsent(parentId, () => []);
    final list = _subMsgs[parentId]!;

    if (msg is AssistantMsg) {
      // Replace the live StreamingAssistant (if any) with the final message.
      if (list.isNotEmpty && list.last is StreamingAssistant) {
        list.removeLast();
      }
      list.add(msg);
    } else if (msg is UserMsg) {
      list.add(msg);
    } else if (msg is StreamBlockStart && msg.kind == 'text') {
      final streaming = StreamingAssistant();
      list.add(streaming);
      _subStreaming[parentId] = streaming;
    } else if (msg is StreamDelta && msg.kind == 'text') {
      final streaming = _subStreaming[parentId];
      if (streaming != null && !streaming.stopped) {
        streaming.text.write(msg.text);
      }
    } else if (msg is StreamBlockStop) {
      final streaming = _subStreaming[parentId];
      if (streaming != null) {
        streaming.stopped = true;
        _subStreaming.remove(parentId);
      }
    }
    // ResultMsg, ErrorMsg etc. from sub-agents are intentionally ignored.
  }

  void _handleWireMessage(Map<String, dynamic> json) {
    if (!mounted) return;
    final msg = IncomingMessage.fromJson(json);

    // Sub-agent messages carry parent_tool_use_id; route to nested map.
    final parentId = json['parent_tool_use_id'] as String?;
    if (parentId != null) {
      setState(() => _handleSubAgentMsg(msg, parentId));
      _scrollToEnd();
      return;
    }

    setState(() {
      if (msg is SessionReady) {
        _attempting = false;
        _connected = true;
        _error = null;
        // 服务端在 attach 一个 in-flight session：立刻恢复 streaming UI，
        // 不必等下一个 stream_block_start。后续的 outputBuffer replay 会
        // 把当前 turn 的所有事件补齐。
        if (msg.busy) {
          _busy = true;
          _busyStartedAt ??= DateTime.now();
          _mode = CcStreamMode.responding;
        }
      } else if (msg is ResultMsg) {
        _busy = false;
        _busyStartedAt = null;
        _mode = CcStreamMode.requesting;
        _thoughtForTimer?.cancel();
        _thoughtSeconds = null;
        _currentBlockKind = null;
        _messages.add(msg); _debugTrack(msg, json);
        // 当前轮结束 — 看看队列里有没有用户在 busy 期间堆的消息，
        // 有就出队继续发（递归触发下一轮）。
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _drainQueue();
        });
        // Turn finished — cancel subscription and close SSE proactively so the
        // SseClient's reconnect loop never fires after the server's grace period ends.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            _sseSub?.cancel();
            _sseSub = null;
            unawaited(_sseClient?.close() ?? Future.value());
            setState(() => _sseClient = null);
          }
        });
      } else if (msg is ErrorMsg) {
        _error = msg.message;
        _messages.add(msg); _debugTrack(msg, json);
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
          final removed = _messages.removeLast();
          _debugRaw.remove(removed);
        }
        _messages.add(msg); _debugTrack(msg, json);
        // 拦截 TodoWrite 工具调用 → 更新全局 todoListProvider，让顶部 chip 反映进度。
        // 注意：tool_use 块本身仍保留在 message 里（_buildToolResultIndex 还要用），
        // tool_call_card 会在渲染时识别 TodoWrite 并跳过卡片显示。
        for (final block in msg.content) {
          if (block is ToolUseBlock && block.name == 'TodoWrite') {
            final next = parseTodos(block.input['todos']);
            final changed = ref.read(todoListProvider.notifier).replace(next);
            if (changed) {
              ref.read(todoUpdatedAtProvider.notifier).state =
                  DateTime.now().millisecondsSinceEpoch;
            }
          }
        }
      } else if (msg is PongMsg || msg is SystemMsg) {
        // skip
      } else if (msg is CompactBoundaryMsg) {
        // 实时也可能收到（用户在会话中触发了 /compact）。
        _messages.add(msg); _debugTrack(msg, json);
      } else {
        _messages.add(msg); _debugTrack(msg, json);
      }
    });
    _scrollToEnd();
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
    if (!_connected) return;
    // 任何附件没就绪（uploading/failed）就不让发，UI 上 send 按钮已 disabled
    // —— 这里二次防御，避免极端情况下漏掉一条 ref。
    if (!_attachmentsAllReady) return;
    final raw = _textController.text.trim();
    final attachLines = _attachments
        .where((a) => a.status == _AttachmentStatus.ready && a.remotePath != null)
        .map((a) => '`${a.remotePath!}`')
        .toList();
    final text = attachLines.isEmpty
        ? raw
        : '$raw\n\n附件：\n${attachLines.join('\n')}';
    if (text.isEmpty) return;
    _textController.clear();
    setState(() => _attachments.clear());
    // busy 时排队，否则直接发。result 到达 → _drainQueue 出队继续。
    if (_busy) {
      setState(() => _pending.add(text));
      _scrollToEnd(force: true);
      return;
    }
    _sendNow(text);
  }

  /// 实际把一条 user_message 发到 server，并设置 busy / spinner 状态。
  /// 已经假设 !_busy。调用者应自己处理排队。
  void _sendNow(String text) {
    setState(() {
      _messages.add(LocalUserInput(text));
      _busy = true;
      _busyStartedAt = DateTime.now();
      _mode = CcStreamMode.requesting;
      _currentBlockKind = null;
      _thoughtSeconds = null;
      _thoughtForTimer?.cancel();
    });
    final uuid = _sessionId;
    final config = ref.read(activeConnectionProvider);
    final session = ref.read(currentSessionProvider);
    if (uuid != null && _chatApi != null && config != null && session != null) {
      final model = ref.read(currentModelProvider);
      final permMode = ref.read(permissionModeProvider);
      unawaited(_chatApi!.stream(
        uuid: uuid,
        cwd: session.cwd,
        text: text,
        model: model.id,
        permissionMode: permMode.wire,
      ).then((_) {
        // Turn started — connect SSE if not already connected.
        if (mounted && _sseClient == null) {
          _subscribeSse(config.httpBase, uuid);
        }
      }).catchError((e) {
        if (mounted) {
          setState(() {
            _busy = false;
            _error = '$e';
          });
        }
      }));
    }
    _scrollToEnd(force: true);
  }

  /// busy 解除后调用：从队列头取一条发出。递归调用直至队列空或下一条 result。
  void _drainQueue() {
    if (_busy || !_connected || _pending.isEmpty) return;
    final next = _pending.removeAt(0);
    _sendNow(next);
  }

  /// 删除队列中某条 pending 消息（用户撤回未发出的输入）。
  void _removePending(int index) {
    if (index < 0 || index >= _pending.length) return;
    setState(() => _pending.removeAt(index));
  }

  void _interrupt() {
    if (_busy && _sessionId != null && _chatApi != null) {
      unawaited(_chatApi!.interrupt(_sessionId!));
    }
  }

  /// 把用户对 AskUserQuestion 工具的回答通过 REST 发给 server。
  void _sendAnswerQuestion(
    String toolUseId,
    Map<String, String> answers,
    Map<String, Map<String, String>>? annotations,
  ) {
    if (_sessionId == null || _chatApi == null) return;
    unawaited(_chatApi!.answer(_sessionId!, toolUseId, answers, annotations));
  }

  /// 弹文件选择器，把每个选中的文件都登记为 uploading 状态并启动并发上传。
  Future<void> _pickAndUploadAttachments() async {
    final result = await FilePicker.platform.pickFiles(allowMultiple: true);
    if (result == null) return;
    final session = ref.read(currentSessionProvider);
    if (session == null) return;
    final config = ref.read(activeConnectionProvider);
    if (config == null) return;
    final api = UploadApi(config.httpBase, token: config.token);
    for (final pickedFile in result.files) {
      final path = pickedFile.path;
      if (path == null) continue;
      final state = _AttachmentState(
        localName: pickedFile.name,
        localPath: path,
        status: _AttachmentStatus.uploading,
      );
      setState(() => _attachments.add(state));
      unawaited(_uploadOne(api, state, session.cwd));
    }
  }

  Future<void> _uploadOne(UploadApi api, _AttachmentState state, String cwd) async {
    try {
      final result = await api.upload(File(state.localPath), cwd);
      if (!mounted) return;
      setState(() {
        state.remotePath = result.path;
        state.status = _AttachmentStatus.ready;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        state.errorMsg = e.toString();
        state.status = _AttachmentStatus.failed;
      });
    }
  }

  void _removeAttachment(_AttachmentState a) {
    setState(() => _attachments.remove(a));
  }

  Future<void> _retryAttachment(_AttachmentState a) async {
    final session = ref.read(currentSessionProvider);
    final config = ref.read(activeConnectionProvider);
    if (session == null || config == null) return;
    setState(() {
      a.status = _AttachmentStatus.uploading;
      a.errorMsg = null;
    });
    await _uploadOne(UploadApi(config.httpBase, token: config.token), a, session.cwd);
  }

  bool get _attachmentsAllReady =>
      _attachments.every((a) => a.status == _AttachmentStatus.ready);

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
        if (_observeMode && _observeHolder != null)
          _ObserveBanner(
            holder: _observeHolder!,
            onTakeover: _takeoverFromObserve,
          )
        else
          _StatusRow(
            connected: _connected,
            busy: _busy,
            error: _error,
            uuid: _sessionId,
            onReconnect: _manualReconnect,
          ),
        Divider(color: t.borderSubt, height: 0.5, thickness: 0.5),
        Expanded(
          child: Stack(
            children: [
              _messages.isEmpty
                  ? (_loadingHistory && !_observeMode
                      ? const _ChatSkeleton()
                      : _EmptyState(
                          icon: Icons.send_outlined,
                          title: _observeMode
                              ? '旁观中…'
                              : (_connected ? s.chatStartTalking : s.chatConnecting),
                        ))
                  : Scrollbar(
                      controller: _scrollController,
                      thumbVisibility: false,
                      thickness: 3,
                      radius: const Radius.circular(1.5),
                      child: ListView.builder(
                        controller: _scrollController,
                        padding: const EdgeInsets.fromLTRB(16, 12, 19, 8),
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
                          return MessageView(
                            message: m,
                            toolResults: toolResults,
                            subMsgsMap: _subMsgs,
                            onAnswerQuestion: _sendAnswerQuestion,
                            rawJson: kDebugMode ? _debugRaw[m] : null,
                          );
                        },
                      ),
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
            trailing: const TodoChip(),
          )
        else if (ref.watch(todoListProvider).isNotEmpty)
          // 非 streaming 也要看到任务进度条 —— 单独占一行
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 4, 12, 4),
            child: Row(
              children: [Spacer(), TodoChip()],
            ),
          ),
        if (_pending.isNotEmpty)
          _PendingQueueBar(
            messages: _pending,
            onRemove: _removePending,
          ),
        Divider(color: t.borderSubt, height: 0.5, thickness: 0.5),
        if (!_observeMode)
          _Composer(
            controller: _textController,
            connected: _connected,
            busy: _busy,
            attachments: _attachments,
            attachmentsAllReady: _attachmentsAllReady,
            onPickAttachment: _pickAndUploadAttachments,
            onRemoveAttachment: _removeAttachment,
            onRetryAttachment: _retryAttachment,
            onSubmit: _submit,
            onStop: _interrupt,
            onSwitchModel: _switchModel,
            onSwitchPermissionMode: _switchPermissionMode,
          ),
      ],
    );
  }
}

class _ObserveBanner extends StatelessWidget {
  final SessionHolder holder;
  final VoidCallback onTakeover;
  const _ObserveBanner({required this.holder, required this.onTakeover});

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    final ago = DateTime.now().difference(
        DateTime.fromMillisecondsSinceEpoch(holder.startedAt));
    final agoStr = ago.inMinutes < 1
        ? '刚刚'
        : ago.inHours < 1
            ? '${ago.inMinutes} 分钟前'
            : '${ago.inHours} 小时前';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: t.surfaceHi,
      child: Row(
        children: [
          Icon(Icons.visibility_outlined, size: 14, color: t.warning),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '旁观中 · PID ${holder.pid} · $agoStr',
              style: TextStyle(fontSize: 12, color: t.textMuted),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          GestureDetector(
            onTap: onTakeover,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: t.error.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(4),
                border: Border.all(
                    color: t.error.withValues(alpha: 0.3), width: 0.5),
              ),
              child: Text(
                '接管',
                style: TextStyle(
                    fontSize: 11,
                    color: t.error,
                    fontWeight: FontWeight.w600),
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
  final String? uuid;
  final VoidCallback onReconnect;
  const _StatusRow({
    required this.connected,
    required this.busy,
    required this.error,
    required this.onReconnect,
    this.uuid,
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
          if (uuid != null) ...[
            GestureDetector(
              onTap: () {
                Clipboard.setData(ClipboardData(text: uuid!));
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('UUID copied'), duration: Duration(seconds: 1)),
                );
              },
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                decoration: BoxDecoration(
                  color: AppTokens.of(context).surfaceHi,
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: AppTokens.of(context).border, width: 0.5),
                ),
                child: Text(
                  uuid!.length >= 8 ? uuid!.substring(0, 8) : uuid!,
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 10,
                    color: AppTokens.of(context).textDim,
                    letterSpacing: 0.5,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 6),
          ],
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
                color: t.accentSubt,
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(14),
                  topRight: Radius.circular(14),
                  bottomLeft: Radius.circular(14),
                  bottomRight: Radius.circular(4),
                ),
                border: Border.all(
                  color: t.accent.withValues(alpha: 0.18),
                  width: 0.5,
                ),
              ),
              child: SelectableText(
                text,
                style: TextStyle(fontSize: 14, color: t.text, height: 1.45),
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
  final List<_AttachmentState> attachments;
  final bool attachmentsAllReady;
  final VoidCallback onPickAttachment;
  final void Function(_AttachmentState) onRemoveAttachment;
  final void Function(_AttachmentState) onRetryAttachment;
  final VoidCallback onSubmit;
  final VoidCallback onStop;
  final void Function(ModelOption) onSwitchModel;
  final void Function(CcPermissionMode) onSwitchPermissionMode;
  const _Composer({
    required this.controller,
    required this.connected,
    required this.busy,
    required this.attachments,
    required this.attachmentsAllReady,
    required this.onPickAttachment,
    required this.onRemoveAttachment,
    required this.onRetryAttachment,
    required this.onSubmit,
    required this.onStop,
    required this.onSwitchModel,
    required this.onSwitchPermissionMode,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = AppTokens.of(context);
    final model = ref.watch(currentModelProvider);
    // 任意附件没就绪（上传中/失败）都禁止发送，避免发出去的引用不可达。
    final canSend = connected && !busy && attachmentsAllReady;
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
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 附件 chip 行：非空时显示在输入框上方。
              if (attachments.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8, right: 8),
                  child: Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final a in attachments)
                        _AttachmentChip(
                          state: a,
                          onRemove: () => onRemoveAttachment(a),
                          onRetry: () => onRetryAttachment(a),
                        ),
                    ],
                  ),
                ),
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
              // 工具栏在按钮下方，左对齐。最左边是 + 按钮（附件上传）。
              Row(
                children: [
                  GestureDetector(
                    onTap: connected ? onPickAttachment : null,
                    behavior: HitTestBehavior.opaque,
                    child: Container(
                      width: 32,
                      height: 32,
                      alignment: Alignment.center,
                      child: Icon(
                        Icons.add_rounded,
                        size: 20,
                        color: connected ? t.textMuted : t.textDim,
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
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

/// 输入框右侧的 40×40 圆形按钮（黑白主题，对照 cxclaw）。
/// - busy=false → 发送上箭头
/// - busy=true  → 停止方块（同一种背景，仅图标变）
/// - 不可用    → 浅灰
class _SendOrStopButton extends StatefulWidget {
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
  State<_SendOrStopButton> createState() => _SendOrStopButtonState();
}

class _SendOrStopButtonState extends State<_SendOrStopButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    final dark = Theme.of(context).brightness == Brightness.dark;

    // 主题色：亮模式黑底，暗模式近白底。按下时 / 不可用时颜色降级。
    final Color bg;
    final Color fg;
    if (!widget.canSend && !widget.busy) {
      bg = dark ? t.borderSubt : const Color(0xFFE4E7EC);
      fg = dark ? t.textDim : const Color(0xFF98A2B3);
    } else {
      bg = dark ? t.text : const Color(0xFF101828);
      fg = dark ? const Color(0xFF0B1210) : Colors.white;
    }

    return GestureDetector(
      onTapDown: (_) {
        HapticFeedback.lightImpact();
        setState(() => _pressed = true);
      },
      onTapUp: (_) => setState(() => _pressed = false),
      onTapCancel: () => setState(() => _pressed = false),
      onTap: widget.busy
          ? widget.onStop
          : (widget.canSend ? widget.onSubmit : null),
      child: AnimatedScale(
        scale: _pressed ? 0.96 : 1.0,
        duration: const Duration(milliseconds: 100),
        curve: Curves.easeOut,
        child: SizedBox(
          width: 44,
          height: 44,
          child: Center(
            child: Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: bg,
                shape: BoxShape.circle,
                boxShadow: dark
                    ? null
                    : [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.15),
                          blurRadius: 6,
                          offset: const Offset(0, 2),
                        ),
                      ],
              ),
              alignment: Alignment.center,
              child: widget.busy
                  ? Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                        color: fg,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    )
                  : Icon(Icons.arrow_upward_rounded, size: 18, color: fg),
            ),
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
    return GestureDetector(
      onTap: () => _openSheet(context),
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.auto_awesome, size: 11, color: t.textDim),
            const SizedBox(width: 4),
            Text(
              _shortLabel(current.label),
              style: TextStyle(fontSize: 11.5, color: t.textMuted, fontWeight: FontWeight.w500),
            ),
            const SizedBox(width: 2),
            Icon(Icons.expand_more, size: 13, color: t.textDim),
          ],
        ),
      ),
    );
  }

  String _shortLabel(String label) => label.split(' ').first;
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

  // 权限名称固定英文，不随语言设置变化
  String _label(CcPermissionMode m) {
    switch (m) {
      case CcPermissionMode.defaultMode: return 'Default';
      case CcPermissionMode.acceptEdits: return 'Accept Edits';
      case CcPermissionMode.plan: return 'Plan';
      case CcPermissionMode.bypass: return 'Bypass';
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
                  label: _label(m),
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
    final (icon, color) = _glyph(current, t);
    return Tooltip(
      message: _label(current),
      preferBelow: false,
      child: GestureDetector(
        onTap: () => _openSheet(context, ref),
        behavior: HitTestBehavior.opaque,
        child: Container(
          width: 32,
          height: 32,
          alignment: Alignment.center,
          child: Icon(icon, size: 17, color: color),
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

/// 附件 chip：固定 28pt 高，左侧显示文件类型图标 + 文件名（最多 200pt 截断），
/// 右侧根据上传状态显示菊花 / 错误 ! / 关闭 × 三种态。
/// - uploading：1.5pt 圆形 spinner
/// - failed：t.error 图标，点击触发重传
/// - ready：t.textMuted close 图标，点击从列表移除
class _AttachmentChip extends StatelessWidget {
  final _AttachmentState state;
  final VoidCallback onRemove;
  final VoidCallback onRetry;
  const _AttachmentChip({
    required this.state,
    required this.onRemove,
    required this.onRetry,
  });

  IconData _iconForName(String name) {
    final lower = name.toLowerCase();
    if (RegExp(r'\.(png|jpg|jpeg|webp|heic|heif|gif|bmp)$').hasMatch(lower)) {
      return Icons.image_outlined;
    }
    if (lower.endsWith('.pdf')) return Icons.picture_as_pdf_outlined;
    if (RegExp(r'\.(ts|tsx|js|jsx|py|dart|go|rs|java|c|cpp|h|hpp|json|yaml|yml|md|sh)$').hasMatch(lower)) {
      return Icons.code;
    }
    return Icons.insert_drive_file_outlined;
  }

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    final failed = state.status == _AttachmentStatus.failed;
    return Container(
      height: 28,
      padding: const EdgeInsets.only(left: 8, right: 4),
      decoration: BoxDecoration(
        color: t.surfaceHi,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: failed ? t.error.withValues(alpha: 0.5) : t.border,
          width: 0.5,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(_iconForName(state.localName), size: 14, color: t.textMuted),
          const SizedBox(width: 6),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 200),
            child: Text(
              state.localName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: t.text),
            ),
          ),
          const SizedBox(width: 6),
          if (state.status == _AttachmentStatus.uploading)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 2),
              child: SizedBox(
                width: 12,
                height: 12,
                child: CircularProgressIndicator(strokeWidth: 1.5),
              ),
            )
          else if (failed)
            GestureDetector(
              onTap: onRetry,
              behavior: HitTestBehavior.opaque,
              child: Padding(
                padding: const EdgeInsets.all(2),
                child: Icon(Icons.error_outline, size: 14, color: t.error),
              ),
            )
          else
            GestureDetector(
              onTap: onRemove,
              behavior: HitTestBehavior.opaque,
              child: Padding(
                padding: const EdgeInsets.all(2),
                child: Icon(Icons.close_rounded, size: 14, color: t.textMuted),
              ),
            ),
        ],
      ),
    );
  }
}

/// 流式 assistant 消息：每个 delta 都用 MarkdownBody 实时渲染。
/// 用同样的 ⏺ gutter，跟最终 AssistantMsg 保持连续——流式收到的 token
/// 看起来就像最终消息的同一条 block。
/// 流式期间用户连发的消息在 composer 上方堆叠显示，每条带 × 撤回按钮。
/// 复刻 claude-code 的 messageQueueManager：busy 时所有 user prompt 排队，
/// 当前 turn 结束后 FIFO 出队继续发。
class _PendingQueueBar extends ConsumerWidget {
  final List<String> messages;
  final void Function(int) onRemove;
  const _PendingQueueBar({required this.messages, required this.onRemove});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = AppTokens.of(context);
    return Container(
      color: t.surface,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 6),
            child: Row(
              children: [
                Icon(Icons.schedule, size: 12, color: t.textDim),
                const SizedBox(width: 6),
                Text(
                  '排队中 · ${messages.length} 条',
                  style: TextStyle(
                    fontSize: 11,
                    color: t.textDim,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
          for (int i = 0; i < messages.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Container(
                decoration: BoxDecoration(
                  color: t.accent.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: t.accent.withValues(alpha: 0.18)),
                ),
                padding: const EdgeInsets.fromLTRB(12, 8, 6, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        messages[i],
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 13, color: t.text, height: 1.3),
                      ),
                    ),
                    InkResponse(
                      onTap: () => onRemove(i),
                      radius: 18,
                      child: Padding(
                        padding: const EdgeInsets.all(6),
                        child: Icon(Icons.close, size: 14, color: t.textDim),
                      ),
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

class _StreamingMessage extends StatelessWidget {
  final StreamingAssistant buffer;
  const _StreamingMessage({required this.buffer});

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    final text = buffer.text.toString();
    final approxTokens = (text.length / 4).round();
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 18,
            child: Padding(
              padding: const EdgeInsets.only(top: 2),
              child: _PulsingDot(color: t.textMuted),
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                MarkdownBody(
                  data: text,
                  selectable: true,
                  styleSheet: streamingMarkdownStyle(t),
                ),
                if (approxTokens > 0)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      '~$approxTokens tokens',
                      style: TextStyle(fontSize: 10, color: t.textDim),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _PulsingDot extends StatefulWidget {
  final Color color;
  const _PulsingDot({required this.color});

  @override
  State<_PulsingDot> createState() => _PulsingDotState();
}

class _PulsingDotState extends State<_PulsingDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _anim;
  late final Animation<double> _opacity;

  @override
  void initState() {
    super.initState();
    _anim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);
    _opacity = Tween<double>(begin: 0.25, end: 1.0).animate(
      CurvedAnimation(parent: _anim, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _anim.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _opacity,
      builder: (_, __) => Opacity(
        opacity: _opacity.value,
        child: Text(
          '●',
          style: TextStyle(fontSize: 11, color: widget.color, height: 1.4),
        ),
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

/// 历史会话首屏加载骨架屏：3 段不同长度的灰色占位 + 一组工具卡占位。
/// 跟最终消息的 `●` gutter + bubble/卡片样式呼应，让加载完后视觉无突变。
class _ChatSkeleton extends StatefulWidget {
  const _ChatSkeleton();

  @override
  State<_ChatSkeleton> createState() => _ChatSkeletonState();
}

class _ChatSkeletonState extends State<_ChatSkeleton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1100),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (_, __) {
        final color = Color.lerp(t.surfaceHi, t.surface, _ctrl.value)!;
        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          children: [
            // user bubble 占位（右侧）
            _skelBubble(color, width: 180, isUser: true),
            const SizedBox(height: 18),
            // assistant ⏺ 几段
            _skelAssistant(t, color, lines: const [.9, .65]),
            const SizedBox(height: 14),
            _skelToolCard(t, color),
            const SizedBox(height: 14),
            _skelAssistant(t, color, lines: const [.95, .7, .5]),
          ],
        );
      },
    );
  }

  Widget _skelBubble(Color c, {required double width, bool isUser = false}) {
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        width: width,
        height: 36,
        decoration: BoxDecoration(
          color: c,
          borderRadius: BorderRadius.circular(14),
        ),
      ),
    );
  }

  Widget _skelLine(Color c, double widthFactor, {double height = 16}) {
    return FractionallySizedBox(
      alignment: Alignment.centerLeft,
      widthFactor: widthFactor,
      child: Container(
        height: height,
        margin: const EdgeInsets.symmetric(vertical: 3),
        decoration: BoxDecoration(
          color: c,
          borderRadius: BorderRadius.circular(4),
        ),
      ),
    );
  }

  Widget _skelAssistant(AppTokens t, Color c, {required List<double> lines}) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 18,
          child: Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Container(
              width: 8, height: 8,
              decoration: BoxDecoration(color: c, shape: BoxShape.circle),
            ),
          ),
        ),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [for (final w in lines) _skelLine(c, w)],
          ),
        ),
      ],
    );
  }

  Widget _skelToolCard(AppTokens t, Color c) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 18,
          child: Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Container(
              width: 8, height: 8,
              decoration: BoxDecoration(color: c, shape: BoxShape.circle),
            ),
          ),
        ),
        Expanded(
          child: Container(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
            decoration: BoxDecoration(
              color: t.surface,
              border: Border(
                top: BorderSide(color: c, width: 0.5),
                right: BorderSide(color: c, width: 0.5),
                bottom: BorderSide(color: c, width: 0.5),
                left: BorderSide(color: c, width: 3),
              ),
              borderRadius: const BorderRadius.only(
                topRight: Radius.circular(6),
                bottomRight: Radius.circular(6),
              ),
            ),
            child: Row(
              children: [
                Container(width: 14, height: 14, decoration: BoxDecoration(color: c, borderRadius: BorderRadius.circular(3))),
                const SizedBox(width: 8),
                Container(width: 60, height: 10, decoration: BoxDecoration(color: c, borderRadius: BorderRadius.circular(3))),
                const SizedBox(width: 8),
                Expanded(child: Container(height: 10, decoration: BoxDecoration(color: c, borderRadius: BorderRadius.circular(3)))),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

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
