import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

import '../../api/agents_api.dart';
import '../../api/chat_api.dart';
import '../../api/files_api.dart';
import '../../api/git_api.dart';
import '../../api/ideas_api.dart';
import '../../api/protocol.dart';
import '../../api/session_files_api.dart';
import '../../api/sessions_api.dart';
import '../../api/sse_client.dart';
import '../../api/upload_api.dart';
import '../../i18n/locale_provider.dart';
import '../../state/chat_completion_notifier.dart';
import '../../state/open_chat_windows.dart';
import '../../state/prefs.dart';
import '../../state/connection_resolver.dart';
import '../../state/projects_store.dart';
import '../../state/rate_limit_state.dart';
import '../../state/server_config.dart';
import '../../state/session_status_state.dart';
import '../../state/streaming_foreground_service.dart';
import '../../state/context_usage_state.dart';
import '../../state/tasks_state.dart';
import '../../state/thinking_tokens_state.dart';
import '../../state/todo_list.dart';
import '../../state/tool_progress_state.dart';
import '../../theme.dart';
import '../../utils/time_format.dart';
import '../../widgets/ai_spinner.dart';
import '../../widgets/codex_approval_card.dart';
import '../../widgets/context_usage_bar.dart';
import '../../widgets/inspiration_drawer.dart';
import '../../widgets/message_view.dart';
import '../../widgets/session_files_drawer.dart';
import '../../widgets/tasks_chip.dart';
import '../../widgets/todo_chip.dart';
import '../../widgets/top_toast.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

// 各 agent 专属逻辑拆到对称的 part 文件（_ChatTabState 的 extension）。part 与
// 本文件同库，privacy 与调用语义完全一致，纯结构位移、零行为改动。
// _handleWireMessage 做中央分发，agent 专属处理委托到各自文件——骨架对称，
// 未来某个 agent 扩展就往它自己的文件塞（P3 绞杀式拆分）。
part 'chat_tab_codex.dart';
part 'chat_tab_claude.dart';
part 'chat_tab_history.dart';
part 'chat_tab_attachments.dart';

class LocalUserInput extends IncomingMessage {
  final String text;
  final int timestamp;
  bool serverAcked;
  LocalUserInput(this.text, {int? timestamp})
      : timestamp = timestamp ?? DateTime.now().millisecondsSinceEpoch,
        serverAcked = false;
}

class _HistoryPage {
  final List<IncomingMessage> messages;
  final String? oldestUuid;
  final bool hasMore;
  const _HistoryPage(
      {required this.messages, this.oldestUuid, required this.hasMore});
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

/// Codex 专属的 per-session 运行时状态，从 god-runtime 抽出集中到这里
/// （P3 plugin 架构第一步：runtime 瘦身）。包含 realtime item 快照与审批
/// 生命周期的全部本地状态——这些只有 Codex 会话用得到。
class _CodexRuntimeExt {
  /// realtime SSE 快照：item UUID → 最新消息（upsert in place）。
  final Map<String, IncomingMessage> codexRealtimeSnapshots = {};

  /// 已决策的 Codex approval ID → 用户决定。
  final Map<String, String> codexApprovalDecisions = {};

  /// 已通知过的 approval ID，防止重复通知。
  final Set<String> notifiedApprovalIds = {};

  /// 已弹出过 approval bottom sheet 的 ID。
  final Set<String> presentedApprovalSheetIds = {};

  /// 因多个 approval 同时到达而被抑制显示的 ID。
  final Set<String> suppressedApprovalSheetIds = {};

  /// 最后被用户忽略的 approval ID（单一最新值）。
  String? dismissedApprovalPopoverId;
}

class _ChatSessionRuntime {
  CurrentSession? session;
  ChatApi? chatApi;
  SseClient? sseClient;
  StreamSubscription<SseEvent>? sseSub;
  String? serverToken;
  String deviceId = '';
  String? sessionId;
  final List<IncomingMessage> messages = [];
  final Map<IncomingMessage, Map<String, dynamic>> debugRaw = {};
  bool connected = false;
  bool authFailed = false;
  bool observeMode = false;
  String? observeHolderDeviceId;
  Timer? observeTimer;
  bool busy = false;
  DateTime? busyStartedAt;
  bool interrupting = false;
  String? error;
  String? boundKey;
  AiStreamMode mode = AiStreamMode.requesting;
  String? currentBlockKind;
  DateTime? thinkingStartedAt;
  int? thoughtSeconds;
  Timer? thoughtForTimer;
  String? oldestUuid;
  bool hasMoreHistory = false;
  bool loadingOlder = false;
  bool loadingHistory = false;
  bool reconnecting = false;
  final List<String> pending = [];
  String? pendingKey;
  bool queuePausedOnUnknown = false;
  bool aiRespondedThisTurn = false;
  final List<LocalUserInput> localUserEchoes = [];
  final Set<String> seenRealtimeUuids = {};
  String? unrespondedUserText;
  // Codex 专属运行时状态（realtime 快照 + 审批生命周期）集中在这里。
  final _CodexRuntimeExt codex = _CodexRuntimeExt();
  final List<_AttachmentState> attachments = [];
  final Map<String, List<IncomingMessage>> subMsgs = {};
  final Map<String, StreamingAssistant> subStreaming = {};
  String? attemptedKey;
  bool attempting = false;

  Future<void> closeSse() async {
    await sseSub?.cancel();
    sseSub = null;
    final client = sseClient;
    sseClient = null;
    await client?.close();
  }

  void dispose() {
    unawaited(closeSse());
    observeTimer?.cancel();
    thoughtForTimer?.cancel();
  }
}

class ChatTab extends ConsumerStatefulWidget {
  final VoidCallback? onGitTap;
  const ChatTab({super.key, this.onGitTap});

  @override
  ConsumerState<ChatTab> createState() => _ChatTabState();
}

class _ChatTabState extends ConsumerState<ChatTab> with WidgetsBindingObserver {
  final Map<String, _ChatSessionRuntime> _runtimes = {};
  _ChatSessionRuntime _runtime = _ChatSessionRuntime();
  _ChatSessionRuntime? _selectedRuntime;
  final TextEditingController _textController = TextEditingController();
  final FocusNode _textFocusNode = FocusNode();
  final ScrollController _scrollController = ScrollController();
  final Map<IncomingMessage, GlobalKey> _messageKeys = {};
  bool _appInForeground = true;

  ChatApi? get _chatApi => _runtime.chatApi;
  set _chatApi(ChatApi? value) => _runtime.chatApi = value;
  SseClient? get _sseClient => _runtime.sseClient;
  set _sseClient(SseClient? value) => _runtime.sseClient = value;
  StreamSubscription<SseEvent>? get _sseSub => _runtime.sseSub;
  set _sseSub(StreamSubscription<SseEvent>? value) => _runtime.sseSub = value;
  String? get _serverToken => _runtime.serverToken;
  set _serverToken(String? value) => _runtime.serverToken = value;
  String get _deviceId => _runtime.deviceId;
  String? get _sessionId => _runtime.sessionId;
  set _sessionId(String? value) => _runtime.sessionId = value;
  List<IncomingMessage> get _messages => _runtime.messages;
  Map<IncomingMessage, Map<String, dynamic>> get _debugRaw => _runtime.debugRaw;
  bool get _connected => _runtime.connected;
  set _connected(bool value) => _runtime.connected = value;
  bool get _authFailed => _runtime.authFailed;
  set _authFailed(bool value) => _runtime.authFailed = value;
  bool get _observeMode => _runtime.observeMode;
  set _observeMode(bool value) => _runtime.observeMode = value;
  String? get _observeHolderDeviceId => _runtime.observeHolderDeviceId;
  set _observeHolderDeviceId(String? value) =>
      _runtime.observeHolderDeviceId = value;
  Timer? get _observeTimer => _runtime.observeTimer;
  set _observeTimer(Timer? value) => _runtime.observeTimer = value;
  bool get _busy => _runtime.busy;
  set _busy(bool value) => _runtime.busy = value;
  DateTime? get _busyStartedAt => _runtime.busyStartedAt;
  set _busyStartedAt(DateTime? value) => _runtime.busyStartedAt = value;
  bool get _interrupting => _runtime.interrupting;
  set _interrupting(bool value) => _runtime.interrupting = value;
  String? get _error => _runtime.error;
  set _error(String? value) => _runtime.error = value;
  String? get _boundKey => _runtime.boundKey;
  set _boundKey(String? value) => _runtime.boundKey = value;
  AiStreamMode get _mode => _runtime.mode;
  set _mode(AiStreamMode value) => _runtime.mode = value;
  String? get _currentBlockKind => _runtime.currentBlockKind;
  set _currentBlockKind(String? value) => _runtime.currentBlockKind = value;
  DateTime? get _thinkingStartedAt => _runtime.thinkingStartedAt;
  set _thinkingStartedAt(DateTime? value) => _runtime.thinkingStartedAt = value;
  int? get _thoughtSeconds => _runtime.thoughtSeconds;
  set _thoughtSeconds(int? value) => _runtime.thoughtSeconds = value;
  Timer? get _thoughtForTimer => _runtime.thoughtForTimer;
  set _thoughtForTimer(Timer? value) => _runtime.thoughtForTimer = value;

  // 跟随末尾滚动：默认开启。当用户手动向上划离开底部 → 关闭，并在右下角显示
  // 浮动按钮；用户按按钮或自己滑回底部 → 重新开启。
  bool _stickToBottom = true;
  static const double _stickToBottomThreshold = 80.0;
  DateTime? _suppressAutoScrollUntil;
  DateTime? _lastAutoScrollAt;
  int _settleScrollRequestId = 0;
  bool _scrollingToUserMessage = false;

  // 键盘弹出跟随：记录上一帧键盘高度，用于判断键盘是否正在弹出。
  double _prevKeyboardHeight = 0;

  // 历史消息反向分页（首屏 50 条，滚到顶取上一页）。
  static const int _historyPageSize = 50;
  static const double _loadMoreThreshold = 200.0;
  String? get _oldestUuid => _runtime.oldestUuid;
  set _oldestUuid(String? value) => _runtime.oldestUuid = value;
  bool get _hasMoreHistory => _runtime.hasMoreHistory;
  set _hasMoreHistory(bool value) => _runtime.hasMoreHistory = value;
  bool get _loadingOlder => _runtime.loadingOlder;
  set _loadingOlder(bool value) => _runtime.loadingOlder = value;

  /// 首屏历史加载中（resume 一个已有会话时为 true，直到第一页返回）。
  /// 用来区分"连接中"vs"加载历史中"，避免显示"开始对话"占位。
  bool get _loadingHistory => _runtime.loadingHistory;
  set _loadingHistory(bool value) => _runtime.loadingHistory = value;
  bool get _reconnecting => _runtime.reconnecting;
  set _reconnecting(bool value) => _runtime.reconnecting = value;

  /// 流式中用户继续提交的消息，按 FIFO 排队。
  /// busy 解除（result 到达）后自动出队、依次发送。
  /// 参考 claude-code messageQueueManager.ts 的单优先级简化版本。
  List<String> get _pending => _runtime.pending;
  String? get _pendingKey => _runtime.pendingKey;
  set _pendingKey(String? value) => _runtime.pendingKey = value;
  bool get _queuePausedOnUnknown => _runtime.queuePausedOnUnknown;
  set _queuePausedOnUnknown(bool value) =>
      _runtime.queuePausedOnUnknown = value;

  /// 输入框是否有内容（实时跟踪），用于切换发送/停止/排队按钮。
  bool _hasText = false;

  /// 当前轮次是否已收到 AI 文本响应（流式或最终消息）。
  /// 在 _sendNow 时重置；AI text block 开始时置 true。
  bool get _aiRespondedThisTurn => _runtime.aiRespondedThisTurn;
  set _aiRespondedThisTurn(bool value) => _runtime.aiRespondedThisTurn = value;

  /// 本机 optimistic 展示过的用户输入。
  /// 服务端 user 事件回来时标记对应气泡为已确认，并吞掉服务端回声，避免重复渲染。
  List<LocalUserInput> get _localUserEchoes => _runtime.localUserEchoes;

  /// Realtime SSE can replay or resend the same provider item snapshot.
  /// Claude items are final enough to dedupe by UUID. Codex sends progressive
  /// snapshots (`item/started` -> `item/completed`) with the same item UUID, so
  /// those must upsert in place to reveal final text/tool results.
  Set<String> get _seenRealtimeUuids => _runtime.seenRealtimeUuids;
  Map<String, IncomingMessage> get _codexRealtimeSnapshots =>
      _runtime.codex.codexRealtimeSnapshots;

  /// 上一轮用户消息的原文，仅在 AI 未响应就中断时保留。
  /// 非 null 时在输入框上方显示"重新编辑"快捷条。
  String? get _unrespondedUserText => _runtime.unrespondedUserText;
  set _unrespondedUserText(String? value) =>
      _runtime.unrespondedUserText = value;

  Map<String, String> get _codexApprovalDecisions =>
      _runtime.codex.codexApprovalDecisions;

  /// 待发送的附件：用户从相册/文件选择后立即上传，发送时把 remotePath 拼到消息文本里。
  /// 上传中/失败的附件会阻塞发送（_attachmentsAllReady=false）。
  List<_AttachmentState> get _attachments => _runtime.attachments;

  // ── Sub-agent (Task tool) streaming ──────────────────────────────────
  // keyed by the Task tool_use_id (= parent_tool_use_id on sub-agent msgs)
  Map<String, List<IncomingMessage>> get _subMsgs => _runtime.subMsgs;

  /// Tracks the live StreamingAssistant per sub-agent so deltas can be appended.
  Map<String, StreamingAssistant> get _subStreaming => _runtime.subStreaming;

  String? get _attemptedKey => _runtime.attemptedKey;
  set _attemptedKey(String? value) => _runtime.attemptedKey = value;
  bool get _attempting => _runtime.attempting;
  set _attempting(bool value) => _runtime.attempting = value;

  bool _isActiveRuntime(_ChatSessionRuntime runtime) =>
      identical(_selectedRuntime ?? _runtime, runtime);

  /// 这条 wire 事件所属的 runtime 是否就是当前前台显示的 Claude session。
  /// 现在只用于"只该对当前显示 session 弹"的副作用（如 InformationalMsg 的
  /// SnackBar）；per-session live-status provider 已改为 family-by-sessionKey
  /// 隔离，写入不再需要这个守卫（见 _liveStatusKey）。
  bool _isActiveClaudeRuntime(_ChatSessionRuntime runtime) =>
      _isActiveRuntime(runtime) &&
      runtime.session?.agent == AgentKind.claude;

  /// 这条事件所属 runtime 的 live-status family key（null 表示 runtime 还没
  /// 绑定 session）。per-session live-status provider（session status /
  /// thinking tokens / tool progress / tasks）用它做 family 隔离：写入侧用
  /// 事件 runtime 的 key，渲染侧用 currentSessionKeyProvider。后台 session 的
  /// 状态写进自己的 key，结构上不可能串到当前显示页面——无需再切换时手动清空。
  String? _liveStatusKey(_ChatSessionRuntime runtime) {
    final session = runtime.session;
    return session == null ? null : _sessionKey(session);
  }

  /// setState 的对外包装：State.setState 是 @protected，part 文件里的 extension
  /// （CodexChatLogic 等）不能直接调，统一经这里转发。纯转发，行为与 setState
  /// 完全一致。
  void rebuild(VoidCallback fn) => setState(fn);

  bool _isCurrentSessionRuntime(_ChatSessionRuntime runtime) {
    if (!_isActiveRuntime(runtime)) return false;
    final current = ref.read(currentSessionProvider);
    final session = runtime.session;
    if (current == null || session == null) return false;
    final runtimeKey = _sessionKeyFor(
      session.agent,
      session.cwd,
      runtime.sessionId ?? session.resumeId,
    );
    return _sessionKey(current) == runtimeKey;
  }

  T _withRuntime<T>(_ChatSessionRuntime runtime, T Function() body) {
    final previous = _runtime;
    _runtime = runtime;
    try {
      return body();
    } finally {
      _runtime = previous;
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _scrollController.addListener(_onScroll);
    _textController.addListener(_onTextChanged);
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final pos = _scrollController.position;
    final atBottom =
        pos.maxScrollExtent - pos.pixels <= _stickToBottomThreshold;
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

  bool _onUserScroll(UserScrollNotification notification) {
    if (notification.direction != ScrollDirection.idle) {
      _suppressAutoScrollUntil =
          DateTime.now().add(const Duration(milliseconds: 900));
    }
    return false;
  }

  GlobalKey _messageKeyFor(IncomingMessage message) {
    return _messageKeys.putIfAbsent(message, GlobalKey.new);
  }

  void _pruneMessageKeys() {
    final live = _messages.toSet();
    _messageKeys.removeWhere((message, _) => !live.contains(message));
  }

  bool _isMainUserMessage(IncomingMessage message) {
    if (message is LocalUserInput) return true;
    if (message is! UserMsg || message.parentToolUseId != null) return false;
    return message.content
        .any((block) => block is TextBlock && block.text.trim().isNotEmpty);
  }

  int _firstVisibleMessageIndex() {
    if (!_scrollController.hasClients) return _messages.length;
    final viewport = _scrollController.position.context.storageContext;
    final viewportObject = viewport.findRenderObject();
    if (viewportObject is! RenderBox) return _messages.length;
    final viewportTop = viewportObject.localToGlobal(Offset.zero).dy;
    final viewportBottom = viewportTop + viewportObject.size.height;

    for (var i = 0; i < _messages.length; i++) {
      final context = _messageKeys[_messages[i]]?.currentContext;
      final object = context?.findRenderObject();
      if (object is! RenderBox || !object.attached) continue;
      final top = object.localToGlobal(Offset.zero).dy;
      final bottom = top + object.size.height;
      if (bottom > viewportTop + 8 && top < viewportBottom) return i;
    }
    return _messages.length;
  }

  Future<void> _scrollToPreviousUserMessage() async {
    if (_scrollingToUserMessage ||
        !_scrollController.hasClients ||
        _messages.isEmpty) {
      return;
    }
    _settleScrollRequestId++;
    _suppressAutoScrollUntil =
        DateTime.now().add(const Duration(milliseconds: 1500));
    if (_stickToBottom && mounted) {
      setState(() => _stickToBottom = false);
    }

    _scrollingToUserMessage = true;
    try {
      final firstVisible = _firstVisibleMessageIndex();
      final start = min(firstVisible - 1, _messages.length - 1);
      int? targetIndex;
      for (var i = start; i >= 0; i--) {
        final message = _messages[i];
        if (!_isMainUserMessage(message)) continue;
        targetIndex = i;
        break;
      }
      if (targetIndex == null) return;
      await _scrollToMessageIndex(targetIndex);
    } finally {
      _scrollingToUserMessage = false;
      _suppressAutoScrollUntil =
          DateTime.now().add(const Duration(milliseconds: 700));
    }
  }

  Future<void> _scrollToMessageIndex(int targetIndex) async {
    for (var attempt = 0; attempt < 6; attempt++) {
      if (!_scrollController.hasClients) return;
      if (await _alignMessageIndexNearTop(targetIndex)) {
        return;
      }

      final position = _scrollController.position;
      final max = position.maxScrollExtent;
      final estimate = _messages.length <= 1
          ? 0.0
          : max * (targetIndex / (_messages.length - 1));
      final nextOffset = estimate.clamp(
        position.minScrollExtent,
        position.maxScrollExtent,
      );
      await position.animateTo(
        nextOffset.toDouble(),
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
      );
      await Future<void>.delayed(const Duration(milliseconds: 16));
    }
  }

  RenderBox? _messageRenderBox(BuildContext context) {
    final object = context.findRenderObject();
    if (object is RenderBox && object.attached) return object;
    return null;
  }

  Future<bool> _alignMessageIndexNearTop(int index) async {
    if (!_scrollController.hasClients) return false;
    final message = _messages[index];
    final context = _messageKeys[message]?.currentContext;
    if (context == null) return false;
    final messageBox = _messageRenderBox(context);
    final viewportContext = _scrollController.position.context.storageContext;
    final viewportObject = viewportContext.findRenderObject();
    if (messageBox == null || viewportObject is! RenderBox) return false;

    final messageTop = messageBox.localToGlobal(Offset.zero).dy;
    final viewportTop = viewportObject.localToGlobal(Offset.zero).dy;
    final desired = _scrollController.position.pixels +
        messageTop -
        viewportTop -
        (_scrollController.position.viewportDimension * 0.08);
    final target = desired.clamp(
      _scrollController.position.minScrollExtent,
      _scrollController.position.maxScrollExtent,
    );
    await _scrollController.animateTo(
      target.toDouble(),
      duration: const Duration(milliseconds: 240),
      curve: Curves.easeOutCubic,
    );
    return true;
  }

  void _closeSse() {
    final client = _sseClient;
    _sseSub?.cancel();
    _sseSub = null;
    unawaited(client?.close() ?? Future.value());
    _sseClient = null;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _syncForegroundStreamService(busy: false);
    for (final runtime in _runtimes.values) {
      runtime.dispose();
    }
    if (!_runtimes.values.any((runtime) => identical(runtime, _runtime))) {
      _runtime.dispose();
    }
    _textController.removeListener(_onTextChanged);
    _textController.dispose();
    _textFocusNode.dispose();
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final appVisible = state == AppLifecycleState.resumed ||
        state == AppLifecycleState.inactive;
    _appInForeground = appVisible;
    unawaited(StreamingForegroundService.instance
        .setAppInForeground(_appInForeground));
    if (!appVisible) {
      _syncForegroundStreamService();
    }
    if (state == AppLifecycleState.resumed) {
      unawaited(ChatCompletionNotifier.instance.refreshForegroundPermission());
      unawaited(ChatCompletionNotifier.instance.clearSessionNotifications());
      _syncForegroundStreamService();
      if (_observeMode) return; // observe mode handles its own polling
      unawaited(_refreshActiveRunState());
    }
  }

  Future<void> _refreshActiveRunState({bool forceResubscribe = false}) async {
    final session = ref.read(currentSessionProvider);
    final config = ref.read(activeConnectionProvider);
    final uuid = _sessionId ?? session?.resumeId;
    if (session == null || config == null || uuid == null || _chatApi == null) {
      return;
    }
    TurnStatus status;
    try {
      status = await _chatApi!.status(uuid, agent: session.agent);
    } catch (_) {
      if (!mounted) return;
      setState(() => _connected = false);
      return;
    }
    if (!mounted) return;
    if (_isOwnActiveRun(status)) {
      final shouldResubscribe =
          forceResubscribe || !_connected || _sseClient == null;
      setState(() {
        _connected = true;
        _busy = true;
        _queuePausedOnUnknown = false;
        _busyStartedAt ??= DateTime.now();
        _mode = AiStreamMode.responding;
        _error = null;
      });
      _syncForegroundStreamService(session: session, busy: true);
      if (shouldResubscribe) {
        _closeSse();
        _subscribeSse(config.apiBase, uuid, session.agent, runtime: _runtime);
      }
      return;
    }
    if (status.state == TurnState.done || status.state == TurnState.unknown) {
      _closeSse();
      setState(() {
        _connected = true;
        _busy = false;
        _busyStartedAt = null;
        _interrupting = false;
        _error = null;
      });
      _syncForegroundStreamService();
      if (status.state == TurnState.done) {
        _queuePausedOnUnknown = false;
        unawaited(_reloadCurrentHistory());
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _drainQueue();
        });
      } else if (_pending.isNotEmpty) {
        setState(() {
          _queuePausedOnUnknown = true;
          _error = 'stream state unknown; queue paused';
        });
      }
    }
  }

  bool _isOwnActiveRun(TurnStatus status, {_ChatSessionRuntime? runtime}) {
    final target = runtime ?? _runtime;
    if (status.state == TurnState.live) return true;
    if (status.state != TurnState.running) return false;
    final holder = status.holderDeviceId;
    return holder == null || holder == target.deviceId;
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

  String _sessionKey(CurrentSession s) =>
      _sessionKeyFor(s.agent, s.cwd, s.resumeId);

  String _sessionKeyFor(AgentKind agent, String cwd, String? resumeId) =>
      '${agent.wire}|$cwd|${resumeId ?? "new"}';

  String _pendingPrefsKey(String sessionKey) =>
      'chat_pending_queue_v1|$sessionKey';

  Future<void> _loadPendingQueue(
    String sessionKey, {
    _ChatSessionRuntime? runtime,
  }) async {
    final target = runtime ?? _runtime;
    final prefs = await SharedPreferences.getInstance();
    final items = prefs.getStringList(_pendingPrefsKey(sessionKey)) ?? const [];
    if (!mounted || target.pendingKey != sessionKey) return;
    void apply() {
      target.pending
        ..clear()
        ..addAll(items.where((item) => item.trim().isNotEmpty));
    }

    if (_isActiveRuntime(target)) {
      setState(apply);
    } else {
      apply();
    }
  }

  Future<void> _persistPendingQueue() async {
    final key = _pendingKey;
    if (key == null) return;
    final prefs = await SharedPreferences.getInstance();
    final prefsKey = _pendingPrefsKey(key);
    if (_pending.isEmpty) {
      await prefs.remove(prefsKey);
    } else {
      await prefs.setStringList(prefsKey, List<String>.from(_pending));
    }
  }

  void _ensureConnected(CurrentSession session) {
    final key = _sessionKey(session);
    final nextRuntime = _runtimes.putIfAbsent(key, _ChatSessionRuntime.new);
    nextRuntime.session = session;
    if (!identical(_runtime, nextRuntime)) {
      final shouldScrollToBottom =
          ref.read(scrollToBottomOnSessionSwitchProvider);
      setState(() {
        _runtime = nextRuntime;
        _selectedRuntime = nextRuntime;
        _stickToBottom = true;
        _suppressAutoScrollUntil = null;
      });
      // live-status provider 现在按 sessionKey family 隔离，切 session 自然
      // 读到新 key 的状态，无需手动清空上一个 session。
      if (shouldScrollToBottom) {
        _scrollToEnd(force: true);
      }
    } else {
      _selectedRuntime = nextRuntime;
    }
    if (_boundKey == key &&
        (_sseClient != null || _connected || _observeMode)) {
      _scheduleDrainQueue(nextRuntime);
      return;
    }
    if (_attempting) return;
    if (_attemptedKey == key) return;

    // Tear down this runtime's previous SSE/observe timer before rebinding it.
    _closeSse();
    _stopObserveTimer();

    _attempting = true;
    _attemptedKey = key;
    setState(() {
      _messages.clear();
      _debugRaw.clear();
      _localUserEchoes.clear();
      _seenRealtimeUuids.clear();
      _codexRealtimeSnapshots.clear();
      _subMsgs.clear();
      _subStreaming.clear();
      _sseClient = null;
      _sessionId = null;
      _chatApi = null;
      _connected = false;
      _authFailed = false;
      _observeMode = false;
      _observeHolderDeviceId = null;
      _busy = false;
      _interrupting = false;
      _error = null;
      _boundKey = key;
      _pendingKey = null;
      _pending.clear();
      _queuePausedOnUnknown = false;
      _oldestUuid = null;
      _hasMoreHistory = false;
      _loadingOlder = false;
      _loadingHistory = false;
      _reconnecting = false;
    });
    ref.read(todoListProvider.notifier).clear();

    final config = ref.read(activeConnectionProvider);
    if (config == null) {
      _attempting = false;
      return;
    }
    _serverToken = config.token;

    unawaited(_connectWithServerRuntime(config.apiBase, session, _runtime));
  }

  Future<void> _connectWithServerRuntime(
    String httpBase,
    CurrentSession session,
    _ChatSessionRuntime runtime,
  ) async {
    var nextSession = session;
    if (session.resumeId != null) {
      try {
        final serverRuntime = await SessionsApi(httpBase, token: _serverToken)
            .runtime(session.resumeId!, session.cwd, agent: session.agent);
        if (serverRuntime.isNotEmpty) {
          nextSession = session.copyWith(runtime: serverRuntime);
          runtime.session = nextSession;
          if (mounted && _isActiveRuntime(runtime)) {
            ref.read(currentSessionProvider.notifier).state = nextSession;
          }
        }
      } catch (_) {}
    }
    if (!mounted) return;
    await _connectToSession(httpBase, nextSession, runtime: runtime);
  }

  /// 处理会话冲突（另一个设备持有该会话）。
  /// 弹窗让用户选择：旁观、接管、或取消。
  Future<void> _handleConflict(
    String httpBase,
    CurrentSession session,
    String uuid,
    String holderDeviceId,
    _ChatSessionRuntime runtime,
  ) async {
    final choice = await _showConflictDialog(holderDeviceId);
    if (!mounted) return;
    switch (choice) {
      case _ConflictChoice.observe:
        if (session.resumeId != null && runtime.messages.isEmpty) {
          _loadHistory(httpBase, session.cwd, session.resumeId!, session.agent,
              runtime: runtime);
        }
        _startObserveMode(httpBase, session, uuid, holderDeviceId, runtime);
      case _ConflictChoice.takeover:
        if (session.resumeId != null && runtime.messages.isEmpty) {
          _loadHistory(httpBase, session.cwd, session.resumeId!, session.agent,
              runtime: runtime);
        }
        unawaited(_doTakeover(httpBase, session, uuid, runtime));
      case null:
      case _ConflictChoice.cancel:
        if (_isActiveRuntime(runtime)) {
          setState(() => _withRuntime(runtime, () => _attempting = false));
        } else {
          _withRuntime(runtime, () => _attempting = false);
        }
    }
  }

  Future<_ConflictChoice?> _showConflictDialog(String holderDeviceId) async {
    final t = AppTokens.of(context);
    final isServer = holderDeviceId == 'server';
    final holderLabel = isServer
        ? 'PC 端 Claude CLI'
        : '另一台设备 (${holderDeviceId.substring(0, 8)}…)';
    return showDialog<_ConflictChoice>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: t.surface,
        title: Text('会话正被占用',
            style: TextStyle(
                color: t.text, fontSize: 15, fontWeight: FontWeight.w600)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _kv('占用方', holderLabel, t),
            const SizedBox(height: 10),
            Text(
              '旁观：静默跟随对话进展，可随时一键接管。\n接管：中断对端，本端取得控制权。',
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
            child: Text('旁观',
                style: TextStyle(color: t.accent, fontWeight: FontWeight.w600)),
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
    String holderDeviceId,
    _ChatSessionRuntime runtime,
  ) {
    void markObserving() {
      _observeMode = true;
      _observeHolderDeviceId = holderDeviceId;
    }

    if (_isActiveRuntime(runtime)) {
      setState(() => _withRuntime(runtime, markObserving));
    } else {
      _withRuntime(runtime, markObserving);
    }
    _withRuntime(runtime, _stopObserveTimer);
    runtime.observeTimer =
        Timer.periodic(const Duration(seconds: 3), (_) async {
      if (!mounted) return;
      // Check if the holder is still running.
      try {
        final api = runtime.chatApi;
        final status = await api?.status(uuid, agent: session.agent);
        if (!mounted) return;
        if (status != null &&
            (status.state != TurnState.running ||
                status.holderDeviceId == runtime.deviceId)) {
          _withRuntime(runtime, _stopObserveTimer);
          if (!mounted) return;
          void clearObserve() {
            _observeMode = false;
            _observeHolderDeviceId = null;
          }

          if (_isActiveRuntime(runtime)) {
            setState(() => _withRuntime(runtime, clearObserve));
          } else {
            _withRuntime(runtime, clearObserve);
          }
          // 等 400ms 让 claude 子进程完成 pid.json 清理，再重连避免
          // status 短暂窗口内仍返回 running 导致再次弹框。
          await Future.delayed(const Duration(milliseconds: 400));
          if (!mounted) return;
          unawaited(_connectToSession(httpBase, session, runtime: runtime));
          return;
        }
      } catch (_) {}
      // Silently refresh messages.
      try {
        final page = await _fetchHistoryPage(
          httpBase,
          session.cwd,
          uuid,
          session.agent,
          limit: _historyPageSize,
        );
        if (!mounted || page == null) return;
        if (page.messages.length != runtime.messages.length) {
          void applyPage() {
            _messages
              ..clear()
              ..addAll(page.messages);
            _oldestUuid = page.oldestUuid;
            _hasMoreHistory = page.hasMore;
          }

          if (_isActiveRuntime(runtime)) {
            setState(() => _withRuntime(runtime, applyPage));
            _scrollToEnd();
          } else {
            _withRuntime(runtime, applyPage);
          }
        }
      } catch (_) {}
    });
  }

  void _stopObserveTimer() {
    _observeTimer?.cancel();
    _observeTimer = null;
  }

  Future<void> _doTakeover(
    String httpBase,
    CurrentSession session,
    String uuid, [
    _ChatSessionRuntime? runtime,
  ]) async {
    final target = runtime ?? _runtime;
    try {
      await target.chatApi!.takeover(uuid, deviceId: target.deviceId);
    } catch (e) {
      if (mounted) {
        if (_isActiveRuntime(target)) {
          setState(() => _withRuntime(target, () => _error = '接管失败: $e'));
        } else {
          _withRuntime(target, () => _error = '接管失败: $e');
        }
      }
      return;
    }
    if (!mounted) return;
    // 接管成功：直接置 idle 连接态，不再走 _connectToSession 重新查 status。
    // 重查 status 存在竞态（holder 文件未及时清除），会导致弹框再次弹出。
    void applyTakeover() {
      _attempting = false;
      _connected = true;
      _error = null;
    }

    if (_isActiveRuntime(target)) {
      setState(() => _withRuntime(target, applyTakeover));
    } else {
      _withRuntime(target, applyTakeover);
    }
  }

  void _takeoverFromObserve() {
    final config = ref.read(activeConnectionProvider);
    final session = ref.read(currentSessionProvider);
    if (config == null ||
        session == null ||
        _sessionId == null ||
        _chatApi == null) {
      return;
    }
    final uuid = _sessionId!;
    _stopObserveTimer();
    setState(() {
      _observeMode = false;
      _observeHolderDeviceId = null;
    });
    unawaited(_doTakeover(config.apiBase, session, uuid));
  }

  /// 建立到会话的连接。为新建会话生成 UUID，为已有会话使用 resumeId。
  /// 根据 /chat/status 结果决定：直连 SSE（live）、等待发消息（idle）或进入冲突处理（running）。
  Future<void> _connectToSession(
    String httpBase,
    CurrentSession session, {
    required _ChatSessionRuntime runtime,
  }) async {
    final uuid = session.resumeId ?? const Uuid().v4();
    final pendingKey = _sessionKeyFor(session.agent, session.cwd, uuid);
    runtime.sessionId = uuid;
    runtime.pendingKey = pendingKey;
    unawaited(_persistUuid(uuid));

    await _loadPendingQueue(pendingKey, runtime: runtime);
    final deviceId = await ConnectionsNotifier.getOrCreateDeviceId();
    if (!mounted || !identical(runtime.session, session)) return;

    runtime.deviceId = deviceId;
    final api = ChatApi(httpBase, token: runtime.serverToken);
    runtime.chatApi = api;

    // 先加载历史（与状态查询并行）。已缓存过消息的 runtime 切回来时不重复拉取，
    // 避免 idle 会话切换时列表闪烁和卡顿。
    if (session.resumeId != null && runtime.messages.isEmpty) {
      _loadHistory(httpBase, session.cwd, session.resumeId!, session.agent,
          runtime: runtime);
    }

    TurnStatus turnStatus;
    var statusFailed = false;
    try {
      turnStatus = await api.status(uuid, agent: session.agent);
    } catch (_) {
      turnStatus = TurnStatus(TurnState.unknown);
      statusFailed = true;
    }

    if (!mounted || !identical(runtime.session, session)) return;

    // status() 抛错 = server 不可达：这是真·建连失败。之前会被吞成 unknown，
    // 然后 applyConnected() 乐观置 connected=true（"假装连上"）。这里改成明确
    // 置错 + 弹提示，让用户看到失败并能点重试。
    if (statusFailed) {
      void applyFailed() {
        runtime.attempting = false;
        runtime.connected = false;
        runtime.error = '连接失败：服务器无法访问';
      }

      if (_isActiveRuntime(runtime)) {
        setState(applyFailed);
        _showConnError('连接失败，服务器无法访问');
      } else {
        applyFailed();
      }
      return;
    }

    if (turnStatus.state == TurnState.running &&
        !_isOwnActiveRun(turnStatus, runtime: runtime)) {
      final holderDeviceId = turnStatus.holderDeviceId;
      if (_isActiveRuntime(runtime)) {
        setState(() => _withRuntime(runtime, () => _attempting = false));
      } else {
        runtime.attempting = false;
      }
      if (holderDeviceId != null) {
        unawaited(
            _handleConflict(httpBase, session, uuid, holderDeviceId, runtime));
      } else {
        // Defensive fallback for malformed status responses.
        void applyFallback() {
          runtime.connected = true;
          runtime.error = null;
        }

        if (_isActiveRuntime(runtime)) {
          setState(applyFallback);
        } else {
          applyFallback();
        }
      }
      return;
    }

    void applyConnected() {
      runtime.attempting = false;
      runtime.connected = true;
      runtime.error = null;
      if (_isOwnActiveRun(turnStatus, runtime: runtime)) {
        runtime.busy = true;
        runtime.queuePausedOnUnknown = false;
        runtime.busyStartedAt ??= DateTime.now();
        runtime.mode = AiStreamMode.responding;
      }
    }

    if (_isActiveRuntime(runtime)) {
      setState(applyConnected);
    } else {
      applyConnected();
    }

    if (_isOwnActiveRun(turnStatus, runtime: runtime)) {
      _subscribeSse(httpBase, uuid, session.agent, runtime: runtime);
    } else if (turnStatus.state == TurnState.done) {
      runtime.queuePausedOnUnknown = false;
      _scheduleDrainQueue(runtime);
    } else if (turnStatus.state == TurnState.unknown &&
        runtime.pending.isNotEmpty) {
      void applyUnknown() {
        runtime.queuePausedOnUnknown = true;
        runtime.error = 'stream state unknown; queue paused';
      }

      if (_isActiveRuntime(runtime)) {
        setState(applyUnknown);
      } else {
        applyUnknown();
      }
    }
  }

  void _subscribeSse(
    String httpBase,
    String uuid,
    AgentKind agent, {
    _ChatSessionRuntime? runtime,
  }) {
    final target = runtime ?? _runtime;
    _withRuntime(target, () {
      final sseUrl =
          ChatApi(httpBase, token: _serverToken).eventsUrl(uuid, agent: agent);
      final sse = SseClient(
        url: sseUrl,
        headers: _serverToken != null
            ? {'Authorization': 'Bearer $_serverToken'}
            : const {},
      );
      _sseClient = sse;
      _sseSub = sse.events.listen((ev) {
        _onSseEvent(ev, runtime: target);
      });
      unawaited(sse.connect());
    });
  }

  void _publishRuntimeStatus(_ChatSessionRuntime runtime) {
    final session = runtime.session;
    if (session == null) return;
    ref.read(openChatWindowsProvider.notifier).setStatus(
          sessionKey(session),
          _statusForRuntime(runtime),
        );
  }

  OpenChatWindowStatus _statusForRuntime(_ChatSessionRuntime runtime) {
    return runtime.error != null
        ? OpenChatWindowStatus.error
        : runtime.busy
            ? OpenChatWindowStatus.running
            : OpenChatWindowStatus.idle;
  }

  OpenChatWindowStatus _statusForSession(CurrentSession session) {
    final key = _sessionKey(session);
    final target = _runtimes[key];
    if (target != null) return _statusForRuntime(target);

    final currentSession = _runtime.session;
    if (currentSession != null && _sessionKey(currentSession) == key) {
      return _statusForRuntime(_runtime);
    }

    return OpenChatWindowStatus.idle;
  }

  void _disposeClosedRuntimes(Set<String> openKeys) {
    final closedKeys =
        _runtimes.keys.where((key) => !openKeys.contains(key)).toList();
    for (final key in closedKeys) {
      final runtime = _runtimes.remove(key);
      if (runtime == null) continue;
      runtime.dispose();
      // 释放该 session 的 live-status family 条目，避免 family 随会话开关无界增长。
      ref.invalidate(claudeSessionStatusProvider(key));
      ref.invalidate(thinkingTokensProvider(key));
      ref.invalidate(toolProgressProvider(key));
      ref.invalidate(tasksProvider(key));
      if (identical(_selectedRuntime, runtime)) _selectedRuntime = null;
      if (identical(_runtime, runtime)) {
        _runtime = _selectedRuntime ?? _ChatSessionRuntime();
      }
    }
  }

  Widget _kv(String k, String v, AppTokens t) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 56,
              child: Text(k,
                  style: TextStyle(
                      color: t.textDim, fontSize: 12, fontFamily: 'monospace')),
            ),
            Expanded(
              child: Text(v,
                  style: TextStyle(
                      color: t.text, fontSize: 12, fontFamily: 'monospace')),
            ),
          ],
        ),
      );

  void _switchModel(ModelOption m) {
    final session = ref.read(currentSessionProvider);
    if (session == null) return;
    ref.read(currentModelProvider.notifier).state = m;
    if (session.agent == AgentKind.claude) {
      final nextRuntime = {...session.runtime, 'model': m.id};
      ref.read(currentSessionProvider.notifier).state =
          session.copyWith(runtime: nextRuntime);
    } else if (session.agent == AgentKind.codex) {
      _patchRuntime({'model': m.id});
      return;
    }
    if (session.agent == AgentKind.claude &&
        _sessionId != null &&
        _chatApi != null) {
      unawaited(_chatApi!.model(_sessionId!, m.id));
    }
  }

  // _switchPermissionMode 已移到 chat_tab_claude.dart（_ClaudeChatLogic），
  // 行为不变。

  void _patchRuntime(Map<String, dynamic> patch) {
    final session = ref.read(currentSessionProvider);
    if (session == null) return;
    final nextRuntime = {...session.runtime, ...patch};
    final next = session.copyWith(runtime: nextRuntime);
    ref.read(currentSessionProvider.notifier).state = next;
    _runtime.session = next;
    // 写入 agent-level overrides，跨 cwd 共享用户偏好——下次新建同 agent
    // 的 session 时这些字段会自动 merge 到 default runtime 上。agent 这个
    // 字段是 wire 标识不能 override，剔掉。
    final overridePatch = Map<String, dynamic>.from(patch)..remove('agent');
    if (overridePatch.isNotEmpty) {
      ref
          .read(agentRuntimeOverridesProvider.notifier)
          .patch(session.agent, overridePatch);
    }
    if (_sessionId != null && _chatApi != null) {
      unawaited(_chatApi!
          .runtime(_sessionId!, next.cwd, next.agent, next.runtime)
          .then((serverRuntime) {
        if (!mounted || serverRuntime == null) return;
        final current = ref.read(currentSessionProvider);
        if (current == null ||
            current.cwd != next.cwd ||
            current.agent != next.agent) {
          return;
        }
        final updated = current.copyWith(runtime: serverRuntime);
        ref.read(currentSessionProvider.notifier).state = updated;
        if (_runtime.session?.cwd == updated.cwd &&
            _runtime.session?.agent == updated.agent) {
          _runtime.session = updated;
        }
      }).catchError((_) {}));
    }
  }

  /// 首屏加载：最后 [_historyPageSize] 条消息。
  // _loadHistory / _reloadCurrentHistory / _loadOlderPage / _fetchHistoryPage
  // 已移到 chat_tab_history.dart（_HistoryLogic extension），行为不变。

  static const _kLastUuidKey = 'chat_last_uuid';

  Future<void> _persistUuid(String uuid) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kLastUuidKey, uuid);
  }

  /// 建连/重连失败时弹一条醒目的错误提示，带「重试」按钮（再走一次完整重连）。
  void _showConnError(String msg) {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.clearSnackBars();
    messenger.showSnackBar(
      SnackBar(
        content: Text(msg, style: const TextStyle(fontSize: 13)),
        backgroundColor: AppTokens.of(context).error,
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 6),
        action: SnackBarAction(
          label: '重试',
          textColor: Colors.white,
          onPressed: _manualReconnect,
        ),
      ),
    );
  }

  void _manualReconnect() {
    if (_reconnecting) return;
    unawaited(_manualReconnectAsync());
  }

  Future<void> _manualReconnectAsync() async {
    final runtime = _runtime;
    if (runtime.reconnecting) return;
    setState(() {
      runtime.reconnecting = true;
      runtime.error = null;
    });
    try {
      final resolved = await _resolveActiveConnection();
      if (!mounted || !_isActiveRuntime(runtime)) return;
      final session = ref.read(currentSessionProvider);
      final canRefresh =
          _chatApi != null && (_sessionId != null || session?.resumeId != null);
      if (canRefresh) {
        setState(() {
          _error = null;
          _attempting = false;
        });
        if (resolved != null) {
          _serverToken = resolved.token;
          _chatApi = ChatApi(resolved.apiBase, token: resolved.token);
        }
        await _refreshActiveRunState(forceResubscribe: true);
        // 重订阅后仍没连上 = server 不可达，弹提示让用户能再重试。
        if (mounted && _isActiveRuntime(runtime) && !_connected) {
          _showConnError('重连失败，服务器无法访问');
        }
        return;
      }
      // 没有可重订阅的活跃 run（B 从没连上 / 新会话无 sessionId）：以前这里
      // 只重置状态、不重新建连，所以"页内重连"点了没反应、得退回首页重进。
      // 改成清掉建连守卫后，重跑与"首页重进"完全一致的完整建连链 _ensureConnected。
      _stopObserveTimer();
      _closeSse();
      setState(() {
        _sessionId = null;
        _chatApi = null;
        _boundKey = null;
        _attemptedKey = null;
        _error = null;
        _observeMode = false;
        _observeHolderDeviceId = null;
        _attempting = false;
      });
      if (session != null) {
        _ensureConnected(session);
      }
    } finally {
      if (!mounted) {
        runtime.reconnecting = false;
      } else if (_isActiveRuntime(runtime)) {
        setState(() => runtime.reconnecting = false);
      } else {
        runtime.reconnecting = false;
      }
    }
  }

  Future<Connection?> _resolveActiveConnection() async {
    final conn = ref.read(activeConnectionProvider);
    if (conn == null) return null;
    final resolved = await const ConnectionResolver().resolve(conn);
    if (resolved == null || resolved.url == conn.url) return conn;
    final updated = await ref
            .read(connectionsProvider.notifier)
            .updateUrl(conn.id, resolved.url) ??
        conn.copyWith(url: resolved.url);
    ref.read(activeConnectionProvider.notifier).state = updated;
    _serverToken = updated.token;
    return updated;
  }

  void _onSseEvent(SseEvent ev, {_ChatSessionRuntime? runtime}) {
    final target = runtime ?? _runtime;
    final previous = _runtime;
    _runtime = target;
    var restore = true;
    try {
      // Internal transport signals come through with a `__` prefix; surface them
      // as connection-level state changes rather than wire messages.
      if (ev.type.startsWith('__')) {
        if (ev.type == '__gap') {
          if (!mounted) return;
          setState(() {
            _error = 'event gap, reloading…';
            _connected = false;
          });
        } else if (ev.type == '__auth_error') {
          if (!mounted) return;
          _sseClient?.close();
          setState(() => _authFailed = true);
          return;
        } else if (ev.type == '__not_found') {
          if (!mounted) return;
          _closeSse();
          setState(() {
            _error = null;
            _connected = true;
            _busy = false;
            _busyStartedAt = null;
            _interrupting = false;
            _mode = AiStreamMode.requesting;
          });
          _syncForegroundStreamService(busy: false);
          unawaited(_refreshActiveRunState());
          return;
        } else if (ev.type == '__client_error') {
          // Transient — the SSE client will retry. Surface the latest error.
          if (!mounted) return;
          setState(() {
            _error = ev.data;
            _connected = false;
          });
          if (_busy) {
            unawaited(_refreshActiveRunState());
          }
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
      restore = !_isActiveRuntime(target);
    } finally {
      if (restore) {
        _runtime = _selectedRuntime ?? previous;
      }
    }
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
    final eventRuntime = _runtime;
    final msg = IncomingMessage.fromJson(json);
    final wireUuid = json['uuid'] as String?;
    final isCodexSnapshot = _isCodexRealtimeSnapshot(json, wireUuid);
    if (wireUuid != null &&
        wireUuid.isNotEmpty &&
        !isCodexSnapshot &&
        !_seenRealtimeUuids.add(wireUuid)) {
      return;
    }

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
          _mode = AiStreamMode.responding;
        }
      } else if (msg is ResultMsg) {
        final shouldNotify = _busy;
        final runtimeSession =
            _runtime.session ?? ref.read(currentSessionProvider);
        final completionPayload = runtimeSession == null
            ? null
            : _completionPayloadFor(runtimeSession);
        final last = _messages.isNotEmpty ? _messages.last : null;
        if (last is StreamingAssistant) last.stopped = true;
        _busy = false;
        _busyStartedAt = null;
        _interrupting = false;
        _mode = AiStreamMode.requesting;
        _thoughtForTimer?.cancel();
        _thoughtSeconds = null;
        _currentBlockKind = null;
        // 一轮结束 → 清零本 session 的 thinking tokens 估算 + 清掉已完成的
        // 后台 task（保留运行中的）。按事件所属 session 的 key 写，后台 session
        // 收尾不会影响当前显示页面。
        final liveKey = _liveStatusKey(eventRuntime);
        if (liveKey != null) {
          ref.read(thinkingTokensProvider(liveKey).notifier).state = 0;
          ref.read(tasksProvider(liveKey).notifier).purgeCompleted();
        }
        _messages.add(msg);
        _debugTrack(msg, json);
        _localUserEchoes.removeWhere((echo) => echo.serverAcked);
        if (completionPayload != null) {
          unawaited(StreamingForegroundService.instance
              .complete(completionPayload)
              .timeout(const Duration(seconds: 4))
              .catchError((_) {}));
          if (shouldNotify) {
            unawaited(ChatCompletionNotifier.instance.notifyTurnComplete(
              payload: completionPayload,
              appInForeground: _appInForeground,
            ));
          }
        }
        // 如果 AI 这一轮根本没有响应（中断发生在响应之前），
        // 保留 _unrespondedUserText，让"重新编辑"条出现。
        // 否则清掉。
        if (_aiRespondedThisTurn) _unrespondedUserText = null;
        // 当前轮结束 — 看看队列里有没有用户在 busy 期间堆的消息，
        // 有就出队继续发（递归触发下一轮）。
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _isActiveRuntime(eventRuntime)) {
            _withRuntime(eventRuntime, _drainQueue);
          }
        });
        // Turn finished — cancel subscription and close SSE proactively so the
        // SseClient's reconnect loop never fires after the server's grace period ends.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            _withRuntime(eventRuntime, () {
              _sseSub?.cancel();
              _sseSub = null;
              unawaited(_sseClient?.close() ?? Future.value());
              setState(() => _sseClient = null);
            });
          }
        });
      } else if (msg is ErrorMsg) {
        _interrupting = false;
        _error = msg.message;
        _messages.add(msg);
        _debugTrack(msg, json);
      } else if (msg is StreamBlockStart) {
        _markAiOutputStarted();
        _currentBlockKind = msg.kind;
        switch (msg.kind) {
          case 'text':
            _mode = AiStreamMode.responding;
            _thoughtForTimer?.cancel();
            _thoughtSeconds = null;
            _messages.add(StreamingAssistant());
            break;
          case 'thinking':
            _mode = AiStreamMode.thinking;
            _thinkingStartedAt = DateTime.now();
            _thoughtForTimer?.cancel();
            break;
          case 'tool_use':
            _mode = AiStreamMode.toolInput;
            break;
        }
        _syncForegroundStreamService();
      } else if (msg is StreamDelta) {
        _markAiOutputStarted();
        if (msg.kind == 'text') {
          _mode = AiStreamMode.responding;
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
          _mode = AiStreamMode.thoughtFor;
          _thoughtForTimer?.cancel();
          _thoughtForTimer = Timer(const Duration(seconds: 2), () {
            if (!mounted) return;
            setState(() {
              // 2 秒后回落到 responding 提示（除非新的 block 已经来）。
              if (_mode == AiStreamMode.thoughtFor) {
                _mode = AiStreamMode.responding;
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
        _markAiOutputStarted();
        if (_upsertCodexRealtimeSnapshot(wireUuid, msg, json)) {
          _applyAssistantSideEffects(msg);
          return;
        }
        _messages.add(msg);
        _debugTrack(msg, json);
        _applyAssistantSideEffects(msg);
      } else if (msg is PongMsg || msg is SystemMsg) {
        // skip
      } else if (msg is UserMsg && _consumeLocalUserEcho(msg)) {
        // 本机 optimistic 气泡已经展示；服务端事件只作为"已记录，不可撤回"信号。
      } else if (_upsertCodexRealtimeSnapshot(wireUuid, msg, json)) {
        // Codex item snapshots are progressive; keep the latest native shape.
      } else if (msg is CompactBoundaryMsg) {
        // 实时也可能收到（用户在会话中触发了 /compact）。
        _messages.add(msg);
        _debugTrack(msg, json);
      } else if (msg is RateLimitInfoMsg) {
        // 限流是账号级状态，不进消息流；写到全局 provider 给 composer chip 用。
        ref.read(rateLimitInfoProvider.notifier).state = msg.info;
      } else if (_applyClaudeWireMessage(msg, eventRuntime, json)) {
        // Claude SDK 专属 wire 消息（session status / informational / tool
        // progress / thinking tokens / 后台 task）委托给 chat_tab_claude.dart
        // 的 _ClaudeChatLogic 处理。返回 true 表示已消费，不再走默认追加。
      } else {
        _messages.add(msg);
        _debugTrack(msg, json);
      }
    });
    _scheduleCodexApprovalSideEffects(runtime: eventRuntime);
    _publishRuntimeStatus(eventRuntime);
    if (_isActiveRuntime(eventRuntime)) _scrollToEnd();
  }

  // _isCodexRealtimeSnapshot / _upsertCodexRealtimeSnapshot 已移到
  // chat_tab_codex.dart（CodexChatLogic extension），行为不变。

  void _applyAssistantSideEffects(AssistantMsg msg) {
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
      // 工具结果到达 → 清理对应的 toolProgress entry，避免长会话累积。
      // 用事件所属 session 的 key（此处 _runtime 即 eventRuntime）。
      if (block is ToolResultBlock && block.toolUseId.isNotEmpty) {
        final liveKey = _liveStatusKey(_runtime);
        if (liveKey != null) {
          final notifier = ref.read(toolProgressProvider(liveKey).notifier);
          if (notifier.state.containsKey(block.toolUseId)) {
            final next = Map<String, double>.from(notifier.state);
            next.remove(block.toolUseId);
            notifier.state = next;
          }
        }
      }
    }
    _syncRuntimeModelFromAssistant(msg);
  }

  /// 把 assistant 消息里 SDK 实际使用的 model 回写到 runtime，让 picker
  /// 显示真正在跑的模型——避免"客户端默认 Sonnet 4.6 但 SDK 实际在用别的"
  /// 这种对不上的情况。仅当 runtime 没显式指定 model 时才同步（用户主动
  /// 切换过就尊重选择，不被覆盖）。
  void _syncRuntimeModelFromAssistant(AssistantMsg msg) {
    final model = msg.model?.trim();
    if (model == null || model.isEmpty) return;
    final session = ref.read(currentSessionProvider);
    if (session == null) return;
    final existing = (session.runtime['model'] ?? '').toString().trim();
    if (existing == model) return;
    if (existing.isNotEmpty) return; // 用户已经选过，不要覆盖
    final nextRuntime = {...session.runtime, 'model': model};
    ref.read(currentSessionProvider.notifier).state =
        session.copyWith(runtime: nextRuntime);
  }

  void _markAiOutputStarted() {
    _aiRespondedThisTurn = true;
    _unrespondedUserText = null;
  }

  bool _consumeLocalUserEcho(UserMsg msg) {
    final text = _plainUserText(msg);
    if (text == null) return false;
    for (final echo in _localUserEchoes) {
      if (echo.text == text && !echo.serverAcked) {
        echo.serverAcked = true;
        return true;
      }
    }
    return _localUserEchoes
        .any((echo) => echo.text == text && echo.serverAcked);
  }

  String? _plainUserText(UserMsg msg) {
    final parts = <String>[];
    for (final block in msg.content) {
      if (block is TextBlock) parts.add(block.text);
    }
    final text = parts.join('\n').trim();
    return text.isEmpty ? null : text;
  }

  /// 滚动到底部。
  /// - [force] = true：无论 _stickToBottom 是什么都强制滚（用于浮动按钮 / 提交消息后）
  /// - [force] = false（默认）：仅在当前已经"贴底"时滚（用于流式 delta 自动跟随）
  void _scrollToEnd({bool force = false}) {
    if (!force && !_stickToBottom) return;
    if (!force) {
      final now = DateTime.now();
      final suppressUntil = _suppressAutoScrollUntil;
      if (suppressUntil != null && now.isBefore(suppressUntil)) return;
      final last = _lastAutoScrollAt;
      if (last != null &&
          now.difference(last) < const Duration(milliseconds: 220)) {
        return;
      }
      _lastAutoScrollAt = now;
    }

    if (force) {
      _settleScrollToEnd(_runtime);
    } else {
      // force=false：流式 delta 自动跟随，用 animateTo 保持流畅。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_scrollController.hasClients || _scrollingToUserMessage) return;
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeOut,
        );
      });
    }
  }

  void _settleScrollToEnd(
    _ChatSessionRuntime target, {
    int minFrames = 3,
    int maxFrames = 8,
  }) {
    if (!_isActiveRuntime(target)) return;
    final requestId = ++_settleScrollRequestId;
    var frames = 0;
    var stableFrames = 0;
    double? lastMaxExtent;

    void step() {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || requestId != _settleScrollRequestId) return;
        if (!_isActiveRuntime(target)) return;

        if (!_scrollController.hasClients) {
          frames++;
          if (frames < maxFrames) step();
          return;
        }

        final position = _scrollController.position;
        final maxExtent = position.maxScrollExtent;
        position.jumpTo(maxExtent);
        if (!_stickToBottom && mounted) {
          setState(() => _stickToBottom = true);
        }

        if (lastMaxExtent != null && (maxExtent - lastMaxExtent!).abs() < 0.5) {
          stableFrames++;
        } else {
          stableFrames = 0;
          lastMaxExtent = maxExtent;
        }

        frames++;
        if (frames < minFrames || (frames < maxFrames && stableFrames < 2)) {
          step();
        }
      });
    }

    step();
  }

  void _submit() {
    if (!_connected) return;
    // 任何附件没就绪（uploading/failed）就不让发，UI 上 send 按钮已 disabled
    // —— 这里二次防御，避免极端情况下漏掉一条 ref。
    if (!_attachmentsAllReady) return;
    final raw = _textController.text.trim();
    final attachLines = _attachments
        .where(
            (a) => a.status == _AttachmentStatus.ready && a.remotePath != null)
        .map((a) => '`${a.remotePath!}`')
        .toList();
    final text =
        attachLines.isEmpty ? raw : '$raw\n\n附件：\n${attachLines.join('\n')}';
    if (text.isEmpty) return;
    _textController.clear();
    setState(() => _attachments.clear());
    // busy 或已有 pending 时排队，保证恢复后仍按 FIFO，不让新输入绕过旧队列。
    if (_busy || _pending.isNotEmpty) {
      setState(() => _pending.add(text));
      unawaited(_persistPendingQueue());
      if (!_queuePausedOnUnknown) _drainQueue();
      _scrollToEnd(force: true);
      return;
    }
    _sendNow(text);
  }

  /// 实际把一条 user_message 发到 server，并设置 busy / spinner 状态。
  /// 已经假设 !_busy。调用者应自己处理排队。
  void _sendNow(String text, {bool requeueOnFailure = false}) {
    final runtime = _runtime;
    setState(() {
      _queuePausedOnUnknown = false;
      final local = LocalUserInput(text);
      _messages.add(local);
      _localUserEchoes.add(local);
      _busy = true;
      _busyStartedAt = DateTime.now();
      _mode = AiStreamMode.requesting;
      _currentBlockKind = null;
      _thoughtSeconds = null;
      _thoughtForTimer?.cancel();
      _aiRespondedThisTurn = false;
      _unrespondedUserText = text; // 暂存；AI 开始响应后清除
    });
    final uuid = _sessionId;
    final config = ref.read(activeConnectionProvider);
    final session = runtime.session ?? ref.read(currentSessionProvider);
    if (uuid != null && _chatApi != null && config != null && session != null) {
      _syncForegroundStreamService(session: session, busy: true);
      final model = ref.read(currentModelProvider);
      final permMode = ref.read(permissionModeProvider);
      final isClaude = session.agent == AgentKind.claude;
      unawaited(_chatApi!
          .stream(
        uuid: uuid,
        cwd: session.cwd,
        text: text,
        deviceId: _deviceId,
        model: isClaude ? model.id : null,
        // 权限模式只对声明了该能力的 agent 传（Codex 走 approval_policy）。
        permissionMode:
            session.agent.profile.permissionMode ? permMode.wire : null,
        agent: session.agent,
        runtime: session.runtime,
      )
          .then((started) {
        _withRuntime(runtime, () {
          var streamUuid = uuid;
          final actualSessionId = started.sessionId;
          if (!isClaude &&
              actualSessionId != null &&
              actualSessionId.isNotEmpty &&
              actualSessionId != uuid) {
            streamUuid = actualSessionId;
            if (mounted) {
              final previousForegroundPayload =
                  _completionPayloadFor(session, resumeId: uuid);
              final previousWindowKey = _sessionKey(session);
              final adoptedKey =
                  _sessionKeyFor(session.agent, session.cwd, actualSessionId);
              final previousPendingKey = _pendingKey;
              final mappedRuntime = _runtimes[previousWindowKey];
              if (identical(mappedRuntime, runtime)) {
                _runtimes.remove(previousWindowKey);
                _runtimes[adoptedKey] = runtime;
              }
              if (_isActiveRuntime(runtime)) {
                setState(() {
                  _sessionId = actualSessionId;
                  _boundKey = adoptedKey;
                  _attemptedKey = adoptedKey;
                  _pendingKey = adoptedKey;
                });
              } else {
                _sessionId = actualSessionId;
                _boundKey = adoptedKey;
                _attemptedKey = adoptedKey;
                _pendingKey = adoptedKey;
              }
              unawaited(StreamingForegroundService.instance
                  .remove(previousForegroundPayload));
              _syncForegroundStreamService(session: session, busy: true);
              unawaited(_persistUuid(actualSessionId));
              if (previousPendingKey != null &&
                  previousPendingKey != adoptedKey) {
                unawaited(SharedPreferences.getInstance().then((prefs) async {
                  await prefs.remove(_pendingPrefsKey(previousPendingKey));
                  await _persistPendingQueue();
                }));
              }
              final adoptedSession =
                  session.copyWith(resumeId: actualSessionId);
              runtime.session = adoptedSession;
              if (_isActiveRuntime(runtime)) {
                ref.read(currentSessionProvider.notifier).state =
                    adoptedSession;
                final windows = ref.read(openChatWindowsProvider.notifier);
                windows.open(adoptedSession);
                if (previousWindowKey != adoptedKey) {
                  windows.close(previousWindowKey);
                }
              }
            }
          }
          // Turn started — connect SSE if not already connected.
          if (mounted && _sseClient == null) {
            _subscribeSse(config.apiBase, streamUuid, session.agent,
                runtime: runtime);
          }
        });
      }).catchError((e) {
        _withRuntime(runtime, () {
          if (!mounted) return;
          void applyFailure() {
            _busy = false;
            _interrupting = false;
            _error = '$e';
            if (requeueOnFailure) {
              _pending.insert(0, text);
            }
          }

          if (_isActiveRuntime(runtime)) {
            setState(applyFailure);
          } else {
            _withRuntime(runtime, applyFailure);
          }
          _syncForegroundStreamService(session: session, busy: false);
          if (requeueOnFailure) unawaited(_persistPendingQueue());
        });
      }));
    }
    _scrollToEnd(force: true);
  }

  /// busy 解除后调用：从队列头取一条发出。递归调用直至队列空或下一条 result。
  void _scheduleDrainQueue(_ChatSessionRuntime runtime) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_isActiveRuntime(runtime)) return;
      _withRuntime(runtime, _drainQueue);
    });
  }

  void _drainQueue() {
    if (_busy || !_connected || _queuePausedOnUnknown || _pending.isEmpty) {
      return;
    }
    final next = _pending.removeAt(0);
    unawaited(_persistPendingQueue());
    _sendNow(next, requeueOnFailure: true);
  }

  /// 删除队列中某条 pending 消息（用户撤回未发出的输入）。
  void _removePending(int index) {
    if (index < 0 || index >= _pending.length) return;
    setState(() {
      _pending.removeAt(index);
      if (_pending.isEmpty) _queuePausedOnUnknown = false;
    });
    unawaited(_persistPendingQueue());
  }

  void _editPending(int index) {
    if (index < 0 || index >= _pending.length) return;
    final text = _pending[index];
    setState(() {
      _pending.removeAt(index);
      if (_pending.isEmpty) _queuePausedOnUnknown = false;
      _textController.text = text;
      _textController.selection = TextSelection.fromPosition(
        TextPosition(offset: text.length),
      );
    });
    unawaited(_persistPendingQueue());
  }

  void _reorderPending(int oldIndex, int newIndex) {
    if (oldIndex < 0 || oldIndex >= _pending.length) return;
    if (newIndex > _pending.length) return;
    if (newIndex > oldIndex) newIndex -= 1;
    if (newIndex < 0 || oldIndex == newIndex) return;
    setState(() {
      final item = _pending.removeAt(oldIndex);
      _pending.insert(newIndex, item);
    });
    unawaited(_persistPendingQueue());
  }

  void _interrupt() {
    final session = _runtime.session ?? ref.read(currentSessionProvider);
    if (_interrupting) return;
    if (_busy && _sessionId != null && _chatApi != null && session != null) {
      final uuid = _sessionId!;
      final api = _chatApi!;
      setState(() {
        _interrupting = true;
        _error = null;
      });
      unawaited(api.interrupt(uuid, agent: session.agent).then((_) {
        if (!mounted) return;
        setState(() => _interrupting = false);
      }).catchError((error) {
        if (!mounted) return;
        if (error is ChatApiException && error.status == 404) {
          _closeSse();
          setState(() {
            _interrupting = false;
            _busy = false;
            _busyStartedAt = null;
            _mode = AiStreamMode.requesting;
            _currentBlockKind = null;
            _thinkingStartedAt = null;
            _thoughtSeconds = null;
            _thoughtForTimer?.cancel();
            _error = null;
          });
          _syncForegroundStreamService(session: session, busy: false);
          unawaited(_refreshActiveRunState());
          return;
        }
        setState(() {
          _interrupting = false;
          _error = '$error';
        });
      }));
    }
  }

  /// 输入框内容变化时同步 _hasText 标志，驱动发送/排队按钮切换。
  void _onTextChanged() {
    final h = _textController.text.isNotEmpty;
    if (h != _hasText) setState(() => _hasText = h);
  }

  void _useIdeaAsDraft(String text) {
    final idea = text.trim();
    if (idea.isEmpty) return;
    final current = _textController.text;
    final next = current.trim().isEmpty
        ? idea
        : current.endsWith('\n')
            ? '$current\n$idea'
            : '$current\n\n$idea';
    _textController.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: next.length),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _textFocusNode.requestFocus();
    });
  }

  void _sendIdea(String text) {
    final idea = text.trim();
    if (idea.isEmpty) return;
    if (!_connected) {
      _useIdeaAsDraft(idea);
      return;
    }
    if (_busy || _pending.isNotEmpty) {
      setState(() => _pending.add(idea));
      unawaited(_persistPendingQueue());
      if (!_queuePausedOnUnknown) _drainQueue();
      _scrollToEnd(force: true);
      return;
    }
    _sendNow(idea);
  }

  /// 重新编辑上一条未被 AI 响应的消息：
  /// 把文本放回输入框，并从消息列表里撤销那次发送的记录。
  void _reEditLastMessage() {
    final text = _unrespondedUserText;
    if (text == null) return;
    final localIdx = _messages.lastIndexWhere(
      (m) => m is LocalUserInput && m.text == text,
    );
    final local = localIdx >= 0 ? _messages[localIdx] as LocalUserInput : null;
    final serverAcked = local?.serverAcked ?? false;
    _interrupt();
    setState(() {
      _unrespondedUserText = null;
      _busy = false;
      _busyStartedAt = null;
      _interrupting = false;
      _mode = AiStreamMode.requesting;
      _currentBlockKind = null;
      _thinkingStartedAt = null;
      _thoughtSeconds = null;
      _thoughtForTimer?.cancel();
      _error = null;
      // 服务端尚未确认 user 事件时，撤掉本地 optimistic 气泡。
      // 已确认时保留气泡，因为服务端历史里已经有这条输入，后续查询会恢复它。
      if (!serverAcked && localIdx >= 0) {
        if (localIdx + 1 < _messages.length &&
            _messages[localIdx + 1] is ResultMsg) {
          _messages.removeAt(localIdx + 1);
        }
        final removed = _messages.removeAt(localIdx);
        _localUserEchoes.remove(removed);
      }
    });
    _closeSse();
    _textController.text = text;
    _textController.selection = TextSelection.fromPosition(
      TextPosition(offset: text.length),
    );
  }

  /// 长按队列中某条消息时：把它提到最前面，然后中断当前响应。
  /// ResultMsg 到达后 _drainQueue 会立刻发送这条优先消息。
  void _prioritizePending(int index) {
    if (index < 0 || index >= _pending.length) return;
    setState(() {
      final item = _pending.removeAt(index);
      _pending.insert(0, item);
    });
    unawaited(_persistPendingQueue());
    _interrupt();
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

  // _sendCodexApproval / _sendCodexApprovalForRuntime 已移到
  // chat_tab_codex.dart（CodexChatLogic extension），行为不变。

  // _notifyCodexApprovalIfNeeded / _approvalNotificationTitle /
  // _approvalNotificationBody 已移到 chat_tab_codex.dart，行为不变。

  String _notificationSessionName(CurrentSession session) {
    final cwdName = _basename(session.cwd);
    if (cwdName.isNotEmpty) return _shortenNotificationText(cwdName);
    final label = session.label.trim();
    if (label.isNotEmpty) return _shortenNotificationText(label);
    return '当前会话';
  }

  String _basename(String path) {
    final normalized = path.trim().replaceAll('\\', '/');
    if (normalized.isEmpty) return '';
    final parts = normalized.split('/').where((part) => part.isNotEmpty);
    return parts.isEmpty ? normalized : parts.last;
  }

  String _shortenNotificationText(String value) {
    const max = 28;
    if (value.length <= max) return value;
    return '${value.substring(0, max - 1)}…';
  }

  Map<String, ToolResultBlock> _buildToolResultIndex() {
    final toolResults = <String, ToolResultBlock>{};
    for (final m in _messages) {
      final content = switch (m) {
        UserMsg(:final content) => content,
        AssistantMsg(:final content) => content,
        _ => const <ContentBlock>[],
      };
      for (final b in content) {
        if (b is ToolResultBlock && b.toolUseId.isNotEmpty) {
          toolResults[b.toolUseId] = b;
        }
      }
    }
    return toolResults;
  }

  /// 渲染时判断 AI 是否在"等待用户操作"，返回对应 spinner 模式；都没有则 null
  /// （照常用 _mode）。按"等到的是问题还是审批"区分文案/态，不按 agent——
  /// Codex 只会命中审批，Claude 命中问题（以后接了工具审批也会命中审批）。
  AiStreamMode? _pendingUserActionMode() {
    final toolResults = _buildToolResultIndex();
    // 待审批：Codex 现有；Claude 工具审批以后接进来也走这条。
    if (_latestPendingCodexApproval(toolResults) != null) {
      return AiStreamMode.awaitingApproval;
    }
    // 待回答：有个 AskUserQuestion 的 tool_use 还没配上 tool_result。
    for (final m in _messages.reversed) {
      final content = switch (m) {
        AssistantMsg(:final content) => content,
        _ => const <ContentBlock>[],
      };
      for (final b in content) {
        if (b is ToolUseBlock &&
            b.name.endsWith('AskUserQuestion') &&
            !toolResults.containsKey(b.id)) {
          return AiStreamMode.awaitingAnswer;
        }
      }
    }
    return null;
  }

  // _scheduleCodexApprovalSideEffects / _showCodexApprovalSheetIfNeeded
  // 已移到 chat_tab_codex.dart，行为不变。

  void _syncForegroundStreamService({
    CurrentSession? session,
    bool? busy,
  }) {
    final current = session ?? ref.read(currentSessionProvider);
    if (current == null) return;
    final isBusy = busy ?? _busy;
    final payload = _completionPayloadFor(current);
    if (isBusy) {
      unawaited(StreamingForegroundService.instance.upsert(
        payload,
        activity: _foregroundActivityLabel(),
      ));
    } else {
      unawaited(StreamingForegroundService.instance.complete(payload));
    }
  }

  String _foregroundActivityLabel() {
    return switch (_mode) {
      AiStreamMode.requesting => '连接中',
      AiStreamMode.thinking => '思考中',
      AiStreamMode.thoughtFor => '思考了 ${_thoughtSeconds ?? 0}s',
      AiStreamMode.responding => '生成回复',
      AiStreamMode.toolInput => '准备工具',
      // _mode 不会被设成这两个（awaiting 只在渲染时由 _pendingUserActionMode
      // 计算），列出仅为 switch 穷尽。
      AiStreamMode.awaitingAnswer => '等待回答',
      AiStreamMode.awaitingApproval => '等待确认',
    };
  }

  ChatCompletionPayload _completionPayloadFor(
    CurrentSession session, {
    String? resumeId,
  }) {
    return ChatCompletionPayload(
      cwd: session.cwd,
      resumeId: resumeId ?? _sessionId ?? session.resumeId,
      label: session.label,
      agent: session.agent,
      runtime: session.runtime,
    );
  }

  // _latestPendingCodexApproval / _pendingCodexApprovals 已移到
  // chat_tab_codex.dart，行为不变。

  /// 弹文件选择器，把每个选中的文件都登记为 uploading 状态并启动并发上传。
  // 附件选择/上传方法（_pickAndUploadAttachments / _uploadOne /
  // _removeAttachment / _retryAttachment / _attachmentsAllReady）已移到
  // chat_tab_attachments.dart（_AttachmentLogic extension），行为不变。

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    final s = ref.watch(stringsProvider);
    final session = ref.watch(currentSessionProvider);
    final config = ref.watch(activeConnectionProvider);
    final openWindows = ref.watch(openChatWindowsProvider);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _disposeClosedRuntimes(openWindows.windows.map((w) => w.key).toSet());
    });

    if (session == null) {
      return _EmptyState(
        icon: Icons.chat_bubble_outline,
        title: s.chatEmptyTitle,
        subtitle: s.chatEmptyPickProject,
      );
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref
          .read(openChatWindowsProvider.notifier)
          .setStatus(sessionKey(session), _statusForSession(session));
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _ensureConnected(session);
    });

    // ToolUseBlock 渲染时需要匹配 result 一起折叠显示。
    final toolResults = _buildToolResultIndex();
    _pruneMessageKeys();

    return Column(
      children: [
        if (_observeMode && _observeHolderDeviceId != null)
          _ObserveBanner(
            holderDeviceId: _observeHolderDeviceId!,
            onTakeover: _takeoverFromObserve,
          )
        else
          _StatusRow(
            connected: _connected,
            busy: _busy,
            reconnecting: _reconnecting,
            error: _error,
            uuid: _sessionId,
            onReconnect: _manualReconnect,
            gitApi: config == null
                ? null
                : GitApi(config.apiBase, token: config.token),
            gitCwd: session.cwd,
            onGitTap: widget.onGitTap,
          ),
        if (_authFailed)
          Container(
            color: t.error.withValues(alpha: 0.1),
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
            child: Row(
              children: [
                Icon(Icons.lock_outline, size: 16, color: t.error),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '令牌已失效，请重新配对',
                    style: TextStyle(
                        color: t.error,
                        fontSize: 13,
                        fontWeight: FontWeight.w500),
                  ),
                ),
                TextButton(
                  onPressed: () =>
                      Navigator.of(context).popUntil((route) => route.isFirst),
                  style: TextButton.styleFrom(
                    foregroundColor: t.error,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                  ),
                  child: const Text(
                    '返回',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
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
                              : (_connected
                                  ? s.chatStartTalking
                                  : s.chatConnecting),
                        ))
                  : NotificationListener<UserScrollNotification>(
                      onNotification: _onUserScroll,
                      child: Scrollbar(
                        controller: _scrollController,
                        thumbVisibility: false,
                        thickness: 3,
                        radius: const Radius.circular(1.5),
                        child: ListView.builder(
                          controller: _scrollController,
                          padding: const EdgeInsets.fromLTRB(16, 12, 19, 8),
                          itemCount: _messages.length,
                          itemBuilder: (_, i) {
                            final m = _messages[i];
                            Widget child;
                            if (m is LocalUserInput) {
                              child = _UserMessage(
                                  text: m.text, timestamp: m.timestamp);
                            } else if (m is StreamingAssistant) {
                              child = _StreamingMessage(
                                buffer: m,
                                onOpenFilePath: _openRemoteFilePreview,
                              );
                            } else {
                              child = MessageView(
                                message: m,
                                toolResults: toolResults,
                                subMsgsMap: _subMsgs,
                                onAnswerQuestion: _sendAnswerQuestion,
                                onAnswerCodexApproval: _sendCodexApproval,
                                codexApprovalDecisions: _codexApprovalDecisions,
                                onOpenFilePath: _openRemoteFilePreview,
                                onSaveFilePath: _saveRemoteFileRef,
                                rawJson: kDebugMode ? _debugRaw[m] : null,
                              );
                            }
                            return KeyedSubtree(
                              key: _messageKeyFor(m),
                              child: child,
                            );
                          },
                        ),
                      ),
                    ),
              if (_loadingOlder)
                const Positioned(
                  top: 10,
                  left: 0,
                  right: 0,
                  child: IgnorePointer(
                    child: _OlderMessagesLoadingPill(),
                  ),
                ),
              // Right-bottom "jump to bottom" button — only shown when the user
              // scrolled away from the latest message.
              if (!_stickToBottom)
                Positioned(
                  right: 12,
                  bottom: 12,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _JumpButton(
                        icon: Icons.keyboard_arrow_up_rounded,
                        onTap: _scrollToPreviousUserMessage,
                      ),
                      const SizedBox(height: 8),
                      _JumpButton(
                        icon: Icons.arrow_downward_rounded,
                        onTap: () => _scrollToEnd(force: true),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
        // 重新编辑胶囊：移出 spinner 行，单独占一行放在它正上方，避免和
        // 状态/耗时/进度 chip 挤在一行。streaming 时也显示。
        if (_unrespondedUserText != null && _busy)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 12, 0),
            child: Row(
              children: [
                const Spacer(),
                _ReEditAction(onReEdit: _reEditLastMessage),
              ],
            ),
          ),
        if (_busy && _busyStartedAt != null)
          AiSpinnerLine(
            startedAt: _busyStartedAt!,
            // 在等用户回答/审批时覆盖成"等待"态（spinner 冻住变黄）。
            mode: _pendingUserActionMode() ?? _mode,
            thoughtSeconds: _thoughtSeconds,
            color: t.accent,
            dimColor: t.textDim,
            // spinner 行只留：状态 + 耗时 + tokens + Todo/Task 进度 chip + 停止。
            // Todo/Task 都是「图标+几杠几」，点开看详情。
            trailing: const TodoChip(),
            actions: const [
              // tasks chip 只在有活跃后台 task 时显示（内部判断）
              TasksChip(),
            ],
          )
        else if (ref.watch(todoListProvider).isNotEmpty ||
            ref.watch(activeTasksCountProvider(_sessionKey(session))) > 0)
          // 非 streaming 也要看到 todo / tasks 进度 —— 单独占一行
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 4, 12, 4),
            child: Row(
              children: [Spacer(), TodoChip(), SizedBox(width: 6), TasksChip()],
            ),
          ),
        if (_pending.isNotEmpty)
          _PendingQueueBar(
            messages: _pending,
            onRemove: _removePending,
            onEdit: _editPending,
            onPrioritize: _prioritizePending,
            onReorder: _reorderPending,
          ),
        if (_unrespondedUserText != null && !_busy)
          _ReEditBar(
            text: _unrespondedUserText!,
            onReEdit: _reEditLastMessage,
          ),
        // 输入框上方的上下文窗口占用进度条（设置可关、仅 Claude 有数据）。
        const ContextUsageBar(),
        Divider(color: t.borderSubt, height: 0.5, thickness: 0.5),
        if (!_observeMode)
          _Composer(
            controller: _textController,
            focusNode: _textFocusNode,
            connected: _connected,
            busy: _busy,
            interrupting: _interrupting,
            hasText: _hasText,
            attachments: _attachments,
            attachmentsAllReady: _attachmentsAllReady,
            onPickAttachment: _pickAndUploadAttachments,
            onRemoveAttachment: _removeAttachment,
            onRetryAttachment: _retryAttachment,
            onSubmit: _submit,
            onStop: _interrupt,
            onSwitchModel: _switchModel,
            onSwitchPermissionMode: _switchPermissionMode,
            onPatchRuntime: _patchRuntime,
            onOpenSessionFiles: _showSessionFiles,
            onUseIdea: _useIdeaAsDraft,
            onSendIdea: _sendIdea,
            chatApi: _chatApi,
            agent: session.agent,
            runtime: session.runtime,
            sessionId: _sessionId ?? session.resumeId,
          ),
      ],
    );
  }

  Future<void> _openRemoteFilePreview(String path) async {
    final conn = ref.read(activeConnectionProvider);
    if (conn == null) return;
    final uri = FilesApi(conn.httpBase, token: conn.token).previewUri(path);
    final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!opened && mounted) {
      showTopToast(context, '无法打开预览');
    }
  }

  Future<void> _saveRemoteFileRef(String path) async {
    final conn = ref.read(activeConnectionProvider);
    final session = _runtime.session ?? ref.read(currentSessionProvider);
    final sessionId = _sessionId ?? session?.resumeId;
    if (conn == null || session == null || sessionId == null) return;
    try {
      await SessionFilesApi(conn.httpBase, token: conn.token).add(
        sessionId: sessionId,
        path: path,
        cwd: session.cwd,
      );
      if (mounted) {
        showTopToast(
          context,
          '已加入会话文件',
          duration: const Duration(seconds: 1),
          icon: Icons.bookmark_added_outlined,
        );
      }
    } catch (err) {
      if (mounted) showTopToast(context, '收藏失败: $err');
    }
  }

  Future<void> _showSessionFiles() async {
    final conn = ref.read(activeConnectionProvider);
    final session = _runtime.session ?? ref.read(currentSessionProvider);
    final sessionId = _sessionId ?? session?.resumeId;
    if (conn == null || sessionId == null) return;
    await showSessionFilesDrawer(
      context,
      api: SessionFilesApi(conn.httpBase, token: conn.token),
      filesApi: FilesApi(conn.httpBase, token: conn.token),
      sessionId: sessionId,
    );
  }
}

class _PendingCodexApproval {
  final ToolUseBlock toolUse;
  final ToolResultBlock? result;

  const _PendingCodexApproval({
    required this.toolUse,
    required this.result,
  });
}

bool _isCodexApprovalRequestName(String name) {
  return name == 'item/commandExecution/requestApproval' ||
      name == 'item/fileChange/requestApproval' ||
      name == 'item/permissions/requestApproval';
}

class _ApprovalBottomSheet extends StatelessWidget {
  final ToolUseBlock toolUse;
  final ToolResultBlock? result;
  final void Function(String requestId, String decision, String? scope)
      onSubmit;

  const _ApprovalBottomSheet({
    required this.toolUse,
    required this.result,
    required this.onSubmit,
  });

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return SafeArea(
      top: false,
      child: Container(
        margin: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: t.surface,
          borderRadius: const BorderRadius.vertical(
            top: Radius.circular(18),
            bottom: Radius.circular(10),
          ),
          border: Border.all(color: t.border, width: 0.5),
        ),
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: t.border,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Icon(Icons.privacy_tip_outlined, size: 16, color: t.warning),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '当前会话需要审批',
                    style: TextStyle(
                      color: t.text,
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                IconButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  icon: Icon(Icons.close_rounded, size: 18, color: t.textDim),
                  visualDensity: VisualDensity.compact,
                  tooltip: '忽略',
                ),
              ],
            ),
            CodexApprovalCard(
              toolUse: toolUse,
              answeredResult: result,
              initiallyExpanded: true,
              onSubmit: onSubmit,
            ),
          ],
        ),
      ),
    );
  }
}

class _ObserveBanner extends StatelessWidget {
  final String holderDeviceId;
  final VoidCallback onTakeover;
  const _ObserveBanner(
      {required this.holderDeviceId, required this.onTakeover});

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    final label = holderDeviceId == 'server'
        ? 'PC 端 Claude CLI'
        : '设备 ${holderDeviceId.substring(0, 8)}…';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: t.surfaceHi,
      child: Row(
        children: [
          Icon(Icons.visibility_outlined, size: 14, color: t.warning),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '旁观中 · $label',
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
                    fontSize: 11, color: t.error, fontWeight: FontWeight.w600),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _JumpButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  const _JumpButton({required this.icon, required this.onTap});

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
          width: 40,
          height: 40,
          child: Icon(icon, size: 20, color: t.text),
        ),
      ),
    );
  }
}

class _OlderMessagesLoadingPill extends StatelessWidget {
  const _OlderMessagesLoadingPill();

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return Center(
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: t.surface.withValues(alpha: 0.94),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: t.border, width: 0.5),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.12),
              blurRadius: 14,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(
                  strokeWidth: 1.6,
                  color: t.accent,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '加载更早消息',
                style: TextStyle(
                  color: t.textMuted,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StatusRow extends StatelessWidget {
  final bool connected;
  final bool busy;
  final bool reconnecting;
  final String? error;
  final String? uuid;
  final VoidCallback onReconnect;
  final GitApi? gitApi;
  final String? gitCwd;
  final VoidCallback? onGitTap;
  const _StatusRow({
    required this.connected,
    required this.busy,
    required this.reconnecting,
    required this.error,
    required this.onReconnect,
    this.uuid,
    this.gitApi,
    this.gitCwd,
    this.onGitTap,
  });

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    final dotColor = reconnecting
        ? t.accent
        : error != null
            ? t.error
            : (connected ? (busy ? t.warning : t.success) : t.textDim);
    final statusText = reconnecting
        ? 'reconnecting…'
        : error != null
            ? 'error'
            : (connected ? (busy ? 'streaming' : 'ready') : 'connecting…');

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      color: t.surface,
      child: Row(
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(color: dotColor, shape: BoxShape.circle),
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              statusText,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11, color: t.textMuted),
            ),
          ),
          const Spacer(),
          if (gitApi != null && gitCwd != null) ...[
            _StatusGitBranchChip(
              api: gitApi!,
              cwd: gitCwd!,
              onTap: onGitTap,
            ),
            const SizedBox(width: 6),
          ],
          if (uuid != null) ...[
            GestureDetector(
              onTap: () {
                Clipboard.setData(ClipboardData(text: uuid!));
                showTopToast(
                  context,
                  'UUID copied',
                  duration: const Duration(seconds: 1),
                  icon: Icons.copy_rounded,
                );
              },
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                decoration: BoxDecoration(
                  color: AppTokens.of(context).surfaceHi,
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(
                      color: AppTokens.of(context).border, width: 0.5),
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
          if (reconnecting || error != null || (!connected && !busy))
            InkWell(
              onTap: reconnecting ? null : onReconnect,
              borderRadius: BorderRadius.circular(4),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                child: Row(
                  children: [
                    if (reconnecting)
                      SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                          strokeWidth: 1.8,
                          valueColor: AlwaysStoppedAnimation<Color>(t.accent),
                        ),
                      )
                    else
                      Icon(Icons.refresh, size: 14, color: t.accent),
                    const SizedBox(width: 4),
                    Text(
                      reconnecting ? 'reconnecting' : 'reconnect',
                      style: TextStyle(
                          fontSize: 11,
                          color: t.accent,
                          fontWeight: FontWeight.w500),
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

class _StatusGitBranchChip extends StatefulWidget {
  final GitApi api;
  final String cwd;
  final VoidCallback? onTap;

  const _StatusGitBranchChip({
    required this.api,
    required this.cwd,
    required this.onTap,
  });

  @override
  State<_StatusGitBranchChip> createState() => _StatusGitBranchChipState();
}

class _StatusGitBranchChipState extends State<_StatusGitBranchChip> {
  static const _refreshInterval = Duration(seconds: 30);

  Timer? _refreshTimer;
  GitStatus? _status;
  Object? _error;
  int _requestSerial = 0;
  bool _refreshing = false;

  @override
  void initState() {
    super.initState();
    _refresh();
    _refreshTimer = Timer.periodic(_refreshInterval, (_) => _refresh());
  }

  @override
  void didUpdateWidget(covariant _StatusGitBranchChip oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.cwd != widget.cwd ||
        oldWidget.api.baseUrl != widget.api.baseUrl) {
      _refresh(force: true);
    }
  }

  Future<void> _refresh({bool force = false}) async {
    if (_refreshing && !force) return;
    final serial = ++_requestSerial;
    _refreshing = true;
    try {
      final status = await widget.api.status(widget.cwd);
      if (!mounted || serial != _requestSerial) return;
      setState(() {
        _status = status;
        _error = null;
      });
    } catch (error) {
      if (!mounted || serial != _requestSerial) return;
      setState(() {
        _error = error;
      });
    } finally {
      if (serial == _requestSerial) {
        _refreshing = false;
      }
    }
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    if (_error != null && _status == null) return const SizedBox.shrink();
    final branch = _status?.branch ?? '...';
    final count = _status?.files.length ?? 0;
    return InkWell(
      onTap: widget.onTap,
      borderRadius: BorderRadius.circular(4),
      child: Container(
        constraints: const BoxConstraints(maxWidth: 132),
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
        decoration: BoxDecoration(
          color: t.surfaceHi,
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: t.border, width: 0.5),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.account_tree_outlined, size: 12, color: t.textDim),
            const SizedBox(width: 5),
            Flexible(
              child: Text(
                branch,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 10.5,
                  color: t.textDim,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            if (count > 0) ...[
              const SizedBox(width: 5),
              Text(
                '$count',
                style: TextStyle(
                  fontSize: 10,
                  color: t.accent,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _UserMessage extends ConsumerStatefulWidget {
  final String text;
  final int? timestamp;
  const _UserMessage({required this.text, this.timestamp});

  @override
  ConsumerState<_UserMessage> createState() => _UserMessageState();
}

class _UserMessageState extends ConsumerState<_UserMessage> {
  /// 超过该字符数时折叠显示（换行符也算）。
  static const _kCollapseThreshold = 300;

  /// 超过该行数时折叠显示。
  static const _kCollapseLines = 6;

  bool _expanded = false;

  bool get _shouldCollapse {
    final lines = '\n'.allMatches(widget.text).length + 1;
    return widget.text.length > _kCollapseThreshold || lines > _kCollapseLines;
  }

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    final s = ref.watch(stringsProvider);
    final ts = tsFromMillis(widget.timestamp);
    final maxW = MediaQuery.of(context).size.width * 0.78;

    final bubble =
        _shouldCollapse ? _collapsibleBubble(t, maxW) : _normalBubble(t, maxW);

    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          bubble,
          if (ts != null)
            Padding(
              padding: const EdgeInsets.only(top: 4, right: 2),
              child: Text(
                formatMessageTime(ts, yesterdayLabel: s.timeYesterday),
                style: TextStyle(
                    fontFamily: 'monospace', fontSize: 10, color: t.textDim),
              ),
            ),
        ],
      ),
    );
  }

  Widget _normalBubble(AppTokens t, double maxW) {
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxW),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: _bubbleDecoration(t),
        child: SelectableText(
          widget.text,
          style: TextStyle(fontSize: 14, color: t.text, height: 1.45),
        ),
      ),
    );
  }

  Widget _collapsibleBubble(AppTokens t, double maxW) {
    final lines = '\n'.allMatches(widget.text).length + 1;
    final chars = widget.text.length;
    final firstLine = widget.text.split('\n').first.trim();
    final preview =
        firstLine.length > 60 ? '${firstLine.substring(0, 60)}…' : firstLine;

    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxW),
      child: GestureDetector(
        onTap: () => setState(() => _expanded = !_expanded),
        child: Container(
          decoration: _bubbleDecoration(t),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ── 头部：行数/字数 + 展开按钮 ──────────────────────
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
                child: Row(
                  children: [
                    Icon(Icons.subject, size: 14, color: t.accent),
                    const SizedBox(width: 6),
                    Text(
                      '$lines 行 · $chars 字',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: t.accent,
                        fontFamily: 'monospace',
                      ),
                    ),
                    const Spacer(),
                    Icon(
                      _expanded ? Icons.expand_less : Icons.expand_more,
                      size: 14,
                      color: t.textMuted,
                    ),
                  ],
                ),
              ),
              // ── 分隔线 ──────────────────────────────────────────
              Divider(
                  height: 0.5,
                  thickness: 0.5,
                  color: t.accent.withValues(alpha: 0.2)),
              // ── 内容：折叠时只显示首行预览，展开后显示全文 ──────
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
                child: _expanded
                    ? SelectableText(
                        widget.text,
                        style: TextStyle(
                            fontSize: 13, color: t.text, height: 1.45),
                      )
                    : Text(
                        preview,
                        style: TextStyle(
                            fontSize: 13, color: t.textMuted, height: 1.4),
                        overflow: TextOverflow.ellipsis,
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  BoxDecoration _bubbleDecoration(AppTokens t) => BoxDecoration(
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
      );
}

class _Composer extends ConsumerWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final bool connected;
  final bool busy;
  final bool interrupting;
  final bool hasText;
  final List<_AttachmentState> attachments;
  final bool attachmentsAllReady;
  final VoidCallback onPickAttachment;
  final void Function(_AttachmentState) onRemoveAttachment;
  final void Function(_AttachmentState) onRetryAttachment;
  final VoidCallback onSubmit;
  final VoidCallback onStop;
  final void Function(ModelOption) onSwitchModel;
  final void Function(CcPermissionMode) onSwitchPermissionMode;
  final void Function(Map<String, dynamic>) onPatchRuntime;
  final Future<void> Function() onOpenSessionFiles;
  final ValueChanged<String> onUseIdea;
  final ValueChanged<String> onSendIdea;
  final ChatApi? chatApi;
  final AgentKind agent;
  final Map<String, dynamic> runtime;
  final String? sessionId;
  const _Composer({
    required this.controller,
    required this.focusNode,
    required this.connected,
    required this.busy,
    required this.interrupting,
    required this.hasText,
    required this.attachments,
    required this.attachmentsAllReady,
    required this.onPickAttachment,
    required this.onRemoveAttachment,
    required this.onRetryAttachment,
    required this.onSubmit,
    required this.onStop,
    required this.onSwitchModel,
    required this.onSwitchPermissionMode,
    required this.onPatchRuntime,
    required this.onOpenSessionFiles,
    required this.onUseIdea,
    required this.onSendIdea,
    this.chatApi,
    required this.agent,
    required this.runtime,
    required this.sessionId,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = AppTokens.of(context);
    final conn = ref.watch(activeConnectionProvider);
    final model = ref.watch(currentModelProvider);
    // 限流提示：只在 SDK 推过 RateLimitInfo 且 status != 'allowed' 时显示。
    // 仅 Claude 适用；Codex 走 OpenAI 自己的计费。
    final rateLimitInfo = ref.watch(rateLimitInfoProvider);
    final showRateChip = agent == AgentKind.claude &&
        rateLimitInfo != null &&
        rateLimitInfo.status != 'allowed';
    // canSend：非 busy 且附件就绪才能直接发。
    // canQueue：busy 中且有文字，点击可排队。
    // busy + !hasText：显示停止按钮。
    final canSend = connected && !busy && attachmentsAllReady;
    final canQueue = connected && busy && hasText;
    final editable = connected; // 文本框 busy 时仍可编辑（用户能预写下一条），但发送被 stop 按钮替代。
    final agentLabel = switch (agent) {
      AgentKind.claude => 'Claude',
      AgentKind.codex => 'Codex',
      AgentKind.gemini => 'Gemini',
    };
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (showRateChip)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: _RateLimitChip(info: rateLimitInfo),
              ),
            Container(
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
                      focusNode: focusNode,
                      minLines: 2,
                      maxLines: 6,
                      enabled: editable,
                      cursorColor: t.accent,
                      style:
                          TextStyle(fontSize: 14, color: t.text, height: 1.4),
                      decoration: InputDecoration(
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        disabledBorder: InputBorder.none,
                        isDense: true,
                        filled: false,
                        contentPadding: const EdgeInsets.symmetric(vertical: 4),
                        hintText: editable ? '询问 $agentLabel…' : '正在连接…',
                        hintStyle: TextStyle(color: t.textDim, fontSize: 14),
                      ),
                      textInputAction: TextInputAction.newline,
                      keyboardType: TextInputType.multiline,
                    ),
                  ),
                  const SizedBox(width: 8),
                  _SendOrStopButton(
                    busy: busy,
                    interrupting: interrupting,
                    canSend: canSend,
                    canQueue: canQueue,
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
                  GestureDetector(
                    onTap: conn == null
                        ? null
                        : () => unawaited(_withComposerOverlayFocus(
                              focusNode,
                              () => showInspirationDrawer(
                                context,
                                api: IdeasApi(conn.httpBase, token: conn.token),
                                onUseIdea: onUseIdea,
                                onSendIdea: connected ? onSendIdea : null,
                              ),
                            )),
                    behavior: HitTestBehavior.opaque,
                    child: Container(
                      width: 32,
                      height: 32,
                      alignment: Alignment.center,
                      child: Icon(
                        Icons.lightbulb_outline,
                        size: 18,
                        color: conn == null ? t.textDim : t.textMuted,
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  GestureDetector(
                    onTap: conn == null || sessionId == null
                        ? null
                        : () => unawaited(_withComposerOverlayFocus(
                              focusNode,
                              onOpenSessionFiles,
                            )),
                    behavior: HitTestBehavior.opaque,
                    child: Container(
                      width: 32,
                      height: 32,
                      alignment: Alignment.center,
                      child: Icon(
                        Icons.folder_special_outlined,
                        size: 18,
                        color: conn == null || sessionId == null
                            ? t.textDim
                            : t.textMuted,
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  _ModelPickerButton(
                    agent: agent,
                    model: _modelForRuntime(agent, model, runtime),
                    runtime: runtime,
                    focusNode: focusNode,
                    chatApi: chatApi,
                    onSwitchModel: onSwitchModel,
                    onPatchRuntime: onPatchRuntime,
                  ),
                  const SizedBox(width: 4),
                  _RuntimeSettingsButton(
                    agent: agent,
                    runtime: runtime,
                    focusNode: focusNode,
                    chatApi: chatApi,
                    permissionMode: ref.watch(permissionModeProvider),
                    onSwitchPermissionMode: onSwitchPermissionMode,
                    onPatchRuntime: onPatchRuntime,
                  ),
                  const Spacer(),
                ],
              ),
            ],
          ),
            ),
          ],
        ),
      ),
    );
  }

  ModelOption _modelForRuntime(
      AgentKind agent, ModelOption fallback, Map<String, dynamic> runtime) {
    final id = (runtime['model'] ?? '').toString().trim();
    if (id.isEmpty || id == fallback.id) return fallback;
    final candidates =
        agent == AgentKind.codex ? const <ModelOption>[] : knownModels;
    for (final candidate in candidates) {
      if (candidate.id == id) return candidate;
    }
    return ModelOption.custom(id);
  }
}

/// Composer 上方的限流提示 chip。
/// - allowed_warning: 橙色，显示"5h 配额 87%"
/// - rejected: 红色，显示"已限流 · 14:32 重置"
///
/// 用 utilization 字段渲染百分比，resetsAt 渲染倒计时。SDK 推送的事件
/// 只在状态变化时来，不会高频刷新；这里也不订阅 ticker——一分钟内
/// 准确度足够，下一条事件来时自然更新。
class _RateLimitChip extends StatelessWidget {
  final RateLimitInfo info;
  const _RateLimitChip({required this.info});

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    final isRejected = info.status == 'rejected';
    final color = isRejected ? t.error : t.warning;
    final label = _label();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.30), width: 0.5),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            isRejected ? Icons.block_rounded : Icons.warning_amber_rounded,
            size: 14,
            color: color,
          ),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              label,
              style: TextStyle(
                color: color,
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  String _label() {
    final window = _windowLabel(info.rateLimitType);
    if (info.status == 'rejected') {
      final reset = _resetText(info.resetsAt);
      return reset == null
          ? '$window 配额已用尽'
          : '$window 配额已用尽 · $reset 重置';
    }
    // allowed_warning
    final pct = info.utilization;
    final pctText = pct == null ? '' : ' ${(pct * 100).round()}%';
    return '$window 配额$pctText（接近上限）';
  }

  String _windowLabel(String? type) {
    return switch (type) {
      'five_hour' => '5h',
      'seven_day' => '7d',
      'seven_day_opus' => '7d Opus',
      'seven_day_sonnet' => '7d Sonnet',
      'overage' => '充值',
      _ => '当前',
    };
  }

  /// 把 resetsAt epoch ms 转成 "HH:mm" 或 "Xd Yh"（>24h）。
  /// null 时返回 null（让调用方决定是否拼接）。
  String? _resetText(int? resetsAt) {
    if (resetsAt == null) return null;
    final reset = DateTime.fromMillisecondsSinceEpoch(resetsAt);
    final now = DateTime.now();
    final diff = reset.difference(now);
    if (diff.isNegative) return null;
    if (diff.inHours >= 24) {
      final days = diff.inDays;
      final hours = diff.inHours - days * 24;
      return '${days}d${hours}h 后';
    }
    final hh = reset.hour.toString().padLeft(2, '0');
    final mm = reset.minute.toString().padLeft(2, '0');
    return '$hh:$mm';
  }
}

Future<T?> _withComposerOverlayFocus<T>(
  FocusNode focusNode,
  Future<T?> Function() open,
) async {
  FocusManager.instance.primaryFocus?.unfocus();
  final result = await open();
  WidgetsBinding.instance.addPostFrameCallback((_) {
    if (focusNode.hasFocus) {
      focusNode.unfocus();
    }
  });
  return result;
}

class _ModelPickerButton extends StatefulWidget {
  final AgentKind agent;
  final ModelOption model;
  final Map<String, dynamic> runtime;
  final FocusNode focusNode;
  final ChatApi? chatApi;
  final void Function(ModelOption) onSwitchModel;
  final void Function(Map<String, dynamic>) onPatchRuntime;
  const _ModelPickerButton({
    required this.agent,
    required this.model,
    required this.runtime,
    required this.focusNode,
    required this.chatApi,
    required this.onSwitchModel,
    required this.onPatchRuntime,
  });

  @override
  State<_ModelPickerButton> createState() => _ModelPickerButtonState();
}

class _ModelPickerButtonState extends State<_ModelPickerButton> {
  ServerModels? _serverModels;
  bool _loadingModels = false;

  @override
  void initState() {
    super.initState();
    _prefetchServerModels();
  }

  @override
  void didUpdateWidget(covariant _ModelPickerButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.chatApi != widget.chatApi ||
        oldWidget.agent != widget.agent) {
      _prefetchServerModels();
    }
  }

  /// 拉服务端 `/models`，知道当前 agent 的"默认 current"和官方列表。
  ///
  /// 之前只在 codex 场景下拉，且 runtime 已有 model 时跳过 —— 导致 Claude
  /// 的 picker 按钮一直拿不到 server 的 current 值，按钮上显示的永远是
  /// 客户端 `knownModels.first`（"Sonnet 4.6"），跟 Claude Code CLI 实际
  /// 使用的可能对不上。这里改成全 agent 都预拉一次，无论 runtime 是否
  /// 已经写入 model。
  Future<void> _prefetchServerModels() async {
    if (widget.chatApi == null) return;
    if (_loadingModels) return;
    _loadingModels = true;
    try {
      final models = await widget.chatApi!.fetchModels(agent: widget.agent);
      if (!mounted) return;
      setState(() => _serverModels = models);
    } catch (_) {
      // Keep the local fallback; the full sheet will try again when opened.
    } finally {
      _loadingModels = false;
    }
  }

  Future<void> _open(BuildContext context) async {
    final picked = await _withComposerOverlayFocus<ModelOption>(
      widget.focusNode,
      () async {
        ServerModels? serverModels = _serverModels;
        if (widget.chatApi != null) {
          try {
            serverModels =
                await widget.chatApi!.fetchModels(agent: widget.agent);
            if (mounted) setState(() => _serverModels = serverModels);
          } catch (_) {}
        }
        if (!context.mounted) return null;

        final models = serverModels != null
            ? serverModels.models.map(ModelOption.fromServer).toList()
            : widget.agent == AgentKind.codex
                ? <ModelOption>[_displayModel()]
                : knownModels;
        final current =
            _currentFromServer(_displayModel(), serverModels, models);
        return showModalBottomSheet<ModelOption>(
          context: context,
          requestFocus: false,
          backgroundColor: Colors.transparent,
          barrierColor: Colors.black.withValues(alpha: 0.35),
          isScrollControlled: true,
          builder: (_) => _ModelSheet(
            current: current,
            models: models,
            providerLabel: serverModels?.providerLabel,
            reasoningEffort: widget.agent == AgentKind.codex
                ? _reasoningEffort(widget.runtime)
                : null,
            onPickModelInline:
                widget.agent == AgentKind.codex ? widget.onSwitchModel : null,
            onPickReasoningEffort: widget.agent == AgentKind.codex
                ? (value) => widget.onPatchRuntime({'reasoning_effort': value})
                : null,
          ),
        );
      },
    );
    if (picked != null) widget.onSwitchModel(picked);
  }

  String _reasoningEffort(Map<String, dynamic> runtime) {
    final value = (runtime['reasoning_effort'] ?? 'medium').toString().trim();
    return value.isEmpty ? 'medium' : value;
  }

  ModelOption _currentFromServer(ModelOption fallback,
      ServerModels? serverModels, List<ModelOption> models) {
    if (fallback.id.isNotEmpty || serverModels == null) return fallback;
    final currentId = serverModels.current.trim();
    if (currentId.isEmpty) return fallback;
    for (final candidate in models) {
      if (candidate.id == currentId) return candidate;
    }
    return ModelOption.custom(currentId);
  }

  /// 计算按钮上要显示的 ModelOption。优先级：
  ///   1. runtime 显式设置的 model（带 label 的话尽量补全）
  ///   2. server `/models` 返回的 current
  ///   3. 父级算好的 widget.model（来自 _modelForRuntime / knownModels.first）
  ///
  /// 关键：之前对所有 runtimeId.isNotEmpty 都返回 `ModelOption.custom`，
  /// 等于把已知模型的 label 丢了；现在改成先在 server 列表 + knownModels
  /// 里找匹配，找不到再 custom。
  ModelOption _displayModel() {
    final runtimeId = (widget.runtime['model'] ?? '').toString().trim();
    if (runtimeId.isNotEmpty) {
      if (widget.model.id == runtimeId) return widget.model;
      final serverMatch = _matchServer(runtimeId);
      if (serverMatch != null) return serverMatch;
      for (final candidate in knownModels) {
        if (candidate.id == runtimeId) return candidate;
      }
      return ModelOption.custom(runtimeId);
    }
    final serverCurrent = (_serverModels?.current ?? '').trim();
    if (serverCurrent.isNotEmpty) {
      final serverMatch = _matchServer(serverCurrent);
      if (serverMatch != null) return serverMatch;
      for (final candidate in knownModels) {
        if (candidate.id == serverCurrent) return candidate;
      }
      return ModelOption.custom(serverCurrent);
    }
    return widget.model;
  }

  ModelOption? _matchServer(String id) {
    for (final model in _serverModels?.models ?? const <ServerModelInfo>[]) {
      if (model.id == id) return ModelOption.fromServer(model);
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    final current = _displayModel();
    final label = current.label.trim().isNotEmpty ? current.label : current.id;
    return Tooltip(
      message: '选择模型',
      preferBelow: false,
      child: GestureDetector(
        onTap: () => _open(context),
        behavior: HitTestBehavior.opaque,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 168),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.auto_awesome,
                  size: 18,
                  color: Color(0xFF7C3AED),
                ),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: t.textMuted,
                      fontSize: 11.5,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
                const SizedBox(width: 2),
                Icon(Icons.expand_more, size: 13, color: t.textDim),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _RuntimeSettingsButton extends StatelessWidget {
  final AgentKind agent;
  final Map<String, dynamic> runtime;
  final FocusNode focusNode;
  final ChatApi? chatApi;
  final CcPermissionMode permissionMode;
  final void Function(CcPermissionMode) onSwitchPermissionMode;
  final void Function(Map<String, dynamic>) onPatchRuntime;
  const _RuntimeSettingsButton({
    required this.agent,
    required this.runtime,
    required this.focusNode,
    required this.chatApi,
    required this.permissionMode,
    required this.onSwitchPermissionMode,
    required this.onPatchRuntime,
  });

  Future<void> _open(BuildContext context) async {
    await _withComposerOverlayFocus<void>(
      focusNode,
      () => showModalBottomSheet<void>(
        context: context,
        requestFocus: false,
        backgroundColor: Colors.transparent,
        barrierColor: Colors.black.withValues(alpha: 0.35),
        isScrollControlled: true,
        builder: (_) => _RuntimeSettingsSheet(
          agent: agent,
          runtime: runtime,
          chatApi: chatApi,
          permissionMode: permissionMode,
          onSwitchPermissionMode: onSwitchPermissionMode,
          onPatchRuntime: onPatchRuntime,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return Tooltip(
      message: '运行设置',
      preferBelow: false,
      child: GestureDetector(
        onTap: () => _open(context),
        behavior: HitTestBehavior.opaque,
        child: Container(
          width: 32,
          height: 32,
          alignment: Alignment.center,
          child: Icon(Icons.tune_rounded, size: 18, color: t.textMuted),
        ),
      ),
    );
  }
}

enum _RuntimeSettingsPage { overview, permissions, permissionAdvanced, thinking }

class _CodexPermissionMode {
  final String label;
  final String sandbox;
  final String approvalPolicy;
  final String description;
  final IconData icon;
  const _CodexPermissionMode({
    required this.label,
    required this.sandbox,
    required this.approvalPolicy,
    required this.description,
    required this.icon,
  });
}

const _codexPermissionModes = <_CodexPermissionMode>[
  _CodexPermissionMode(
    label: 'Read-only',
    sandbox: 'read-only',
    approvalPolicy: 'on-request',
    description: '只读文件系统，需要执行或写入时请求确认',
    icon: Icons.visibility_outlined,
  ),
  _CodexPermissionMode(
    label: 'Auto',
    sandbox: 'workspace-write',
    approvalPolicy: 'on-request',
    description: '允许工作区写入，越权或高风险操作按需确认',
    icon: Icons.rule_folder_outlined,
  ),
  _CodexPermissionMode(
    label: 'Full Access',
    sandbox: 'danger-full-access',
    approvalPolicy: 'never',
    description: '完整文件系统访问，不再弹出审批请求',
    icon: Icons.warning_amber_rounded,
  ),
];

const _codexSandboxOptions = <_RuntimeOption>[
  _RuntimeOption(
    value: 'read-only',
    label: 'read-only',
    description: '只读沙箱，不允许直接写入文件',
    icon: Icons.visibility_outlined,
  ),
  _RuntimeOption(
    value: 'workspace-write',
    label: 'workspace-write',
    description: '允许写入工作区，工作区外仍受限',
    icon: Icons.folder_copy_outlined,
  ),
  _RuntimeOption(
    value: 'danger-full-access',
    label: 'danger-full-access',
    description: '不限制文件系统访问范围',
    icon: Icons.warning_amber_rounded,
  ),
];

const _codexApprovalPolicyOptions = <_RuntimeOption>[
  _RuntimeOption(
    value: 'untrusted',
    label: 'untrusted',
    description: '更保守，更多操作需要你确认',
    icon: Icons.lock_outline_rounded,
  ),
  _RuntimeOption(
    value: 'on-request',
    label: 'on-request',
    description: '按需请求确认，适合日常使用',
    icon: Icons.rule_folder_outlined,
  ),
  _RuntimeOption(
    value: 'never',
    label: 'never',
    description: '不主动请求审批，适合完全信任的环境',
    icon: Icons.no_encryption_gmailerrorred_outlined,
  ),
];

_CodexPermissionMode? _codexPermissionModeFor(
  String sandbox,
  String approvalPolicy,
) {
  for (final mode in _codexPermissionModes) {
    if (mode.sandbox == sandbox && mode.approvalPolicy == approvalPolicy) {
      return mode;
    }
  }
  return null;
}

class _RuntimeSettingsSheet extends StatefulWidget {
  final AgentKind agent;
  final Map<String, dynamic> runtime;
  final ChatApi? chatApi;
  final CcPermissionMode permissionMode;
  final void Function(CcPermissionMode) onSwitchPermissionMode;
  final void Function(Map<String, dynamic>) onPatchRuntime;
  const _RuntimeSettingsSheet({
    required this.agent,
    required this.runtime,
    required this.chatApi,
    required this.permissionMode,
    required this.onSwitchPermissionMode,
    required this.onPatchRuntime,
  });

  @override
  State<_RuntimeSettingsSheet> createState() => _RuntimeSettingsSheetState();
}

class _RuntimeSettingsSheetState extends State<_RuntimeSettingsSheet> {
  late Map<String, dynamic> _runtime = _normalizeRuntime(widget.runtime);
  late CcPermissionMode _permissionMode = widget.permissionMode;
  _RuntimeSettingsPage _page = _RuntimeSettingsPage.overview;

  Map<String, dynamic> _normalizeRuntime(Map<String, dynamic> value) {
    final next = Map<String, dynamic>.from(value);
    if (widget.agent == AgentKind.codex) {
      next['agent'] = 'codex';
      next['sandbox'] = (next['sandbox'] ?? 'workspace-write').toString();
      next['approval_policy'] =
          (next['approval_policy'] ?? 'on-request').toString();
      next['reasoning_effort'] =
          (next['reasoning_effort'] ?? 'medium').toString();
    }
    return next;
  }

  void _patchRuntime(Map<String, dynamic> patch) {
    setState(() => _runtime = {..._runtime, ...patch});
    widget.onPatchRuntime(patch);
  }

  void _setPermissionMode(CcPermissionMode mode) {
    setState(() => _permissionMode = mode);
    widget.onSwitchPermissionMode(mode);
  }

  @override
  void didUpdateWidget(covariant _RuntimeSettingsSheet oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.runtime != widget.runtime) {
      _runtime = _normalizeRuntime(widget.runtime);
    }
    if (oldWidget.permissionMode != widget.permissionMode) {
      _permissionMode = widget.permissionMode;
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    final rootTitle = switch (widget.agent) {
      AgentKind.claude => 'Claude 运行设置',
      AgentKind.codex => 'Codex 运行设置',
      AgentKind.gemini => 'Gemini 运行设置',
    };
    final title = switch (_page) {
      _RuntimeSettingsPage.overview => rootTitle,
      _RuntimeSettingsPage.permissions => '权限设置',
      _RuntimeSettingsPage.permissionAdvanced => '高级权限',
      _RuntimeSettingsPage.thinking => 'Thinking',
    };
    final icon = switch (_page) {
      _RuntimeSettingsPage.permissions ||
      _RuntimeSettingsPage.permissionAdvanced =>
        Icons.shield_outlined,
      _RuntimeSettingsPage.thinking => Icons.psychology_outlined,
      _ => Icons.tune_rounded,
    };
    return Container(
      height: 470,
      margin: const EdgeInsets.all(8),
      clipBehavior: Clip.antiAlias,
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
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: t.border,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
            ),
            _RuntimeSheetHeader(
              title: title,
              icon: icon,
              showBack: _page != _RuntimeSettingsPage.overview,
              onBack: () =>
                  setState(() => _page = _RuntimeSettingsPage.overview),
            ),
            Divider(color: t.borderSubt, height: 0.5),
            Expanded(
              child: ClipRect(
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 220),
                  transitionBuilder: (child, animation) {
                    final enteringOverview =
                        child.key == const ValueKey('overview');
                    final begin = enteringOverview
                        ? const Offset(-1, 0)
                        : const Offset(1, 0);
                    return SlideTransition(
                      position: Tween<Offset>(
                        begin: begin,
                        end: Offset.zero,
                      ).animate(CurvedAnimation(
                        parent: animation,
                        curve: Curves.easeOutCubic,
                      )),
                      child: FadeTransition(opacity: animation, child: child),
                    );
                  },
                  child: switch (_page) {
                    _RuntimeSettingsPage.permissions =>
                      _runtimePermissionPage(),
                    _RuntimeSettingsPage.permissionAdvanced =>
                      _codexPermissionAdvancedPage(),
                    _RuntimeSettingsPage.thinking => _runtimeThinkingPage(),
                    _RuntimeSettingsPage.overview => _runtimeOverviewPage(),
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _runtimeOverviewPage() {
    if (widget.agent == AgentKind.codex) {
      return ListView(
        key: const ValueKey('overview'),
        padding: const EdgeInsets.fromLTRB(0, 6, 0, 10),
        children: [
          _RuntimeActionRow(
            icon: Icons.rule_folder_outlined,
            title: '权限',
            value: _codexPermissionSummary(
              (_runtime['sandbox'] ?? 'workspace-write').toString(),
              (_runtime['approval_policy'] ?? 'on-request').toString(),
            ),
            onTap: () =>
                setState(() => _page = _RuntimeSettingsPage.permissions),
          ),
        ],
      );
    }
    return ListView(
      key: const ValueKey('overview'),
      padding: const EdgeInsets.fromLTRB(0, 6, 0, 10),
      children: [
        _RuntimeActionRow(
          icon: Icons.shield_outlined,
          title: '权限',
          value: _permissionLabel(_permissionMode),
          onTap: () => setState(() => _page = _RuntimeSettingsPage.permissions),
        ),
        // Thinking 仅 Claude 暴露；Codex 自有 reasoning_effort 走另一条路径。
        _RuntimeActionRow(
          icon: Icons.psychology_outlined,
          title: 'Thinking',
          value: _thinkingLabel(_runtime['thinking']),
          onTap: () =>
              setState(() => _page = _RuntimeSettingsPage.thinking),
        ),
      ],
    );
  }

  String _thinkingLabel(dynamic config) {
    if (config is! Map) return '默认（adaptive）';
    final type = (config['type'] ?? '').toString();
    return switch (type) {
      'adaptive' => '自适应',
      'disabled' => '关闭',
      'enabled' => '固定预算',
      _ => '默认（adaptive）',
    };
  }

  Widget _runtimeThinkingPage() {
    final current = _runtime['thinking'];
    final currentType = current is Map ? (current['type'] ?? '').toString() : '';
    const options = [
      ('', '默认', '让 SDK 决定（Opus 4.6+ 默认 adaptive）'),
      ('adaptive', '自适应', 'Claude 自行决定何时及多少 thinking'),
      ('disabled', '关闭', '完全关闭 extended thinking'),
    ];
    return ListView.separated(
      key: const ValueKey('thinking'),
      padding: const EdgeInsets.fromLTRB(0, 6, 0, 10),
      itemCount: options.length,
      separatorBuilder: (context, _) {
        final t = AppTokens.of(context);
        return Divider(
          color: t.borderSubt,
          height: 0.5,
          indent: 16,
          endIndent: 16,
        );
      },
      itemBuilder: (context, index) {
        final (typeKey, label, desc) = options[index];
        final t = AppTokens.of(context);
        final selected = typeKey == currentType ||
            (typeKey == '' && currentType.isEmpty);
        return InkWell(
          onTap: () {
            // 未选中"默认" → 写 thinking 字段；选"默认"→ 删字段，让 SDK 用默认。
            final patch = <String, dynamic>{};
            if (typeKey.isEmpty) {
              patch['thinking'] = null;
            } else {
              patch['thinking'] = {'type': typeKey};
            }
            _patchRuntime(patch);
          },
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            child: Row(
              children: [
                Icon(
                  selected
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                  size: 18,
                  color: selected ? t.accent : t.textMuted,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        label,
                        style: TextStyle(
                          color: selected ? t.accent : t.text,
                          fontSize: 13,
                          fontWeight: selected
                              ? FontWeight.w700
                              : FontWeight.w500,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        desc,
                        style: TextStyle(
                          color: t.textDim,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _runtimePermissionPage() {
    if (widget.agent == AgentKind.codex) {
      return _CodexRuntimePermissionPage(
        key: const ValueKey('permission'),
        approvalPolicy:
            (_runtime['approval_policy'] ?? 'on-request').toString(),
        sandbox: (_runtime['sandbox'] ?? 'workspace-write').toString(),
        onPatchRuntime: _patchRuntime,
        onOpenAdvanced: () =>
            setState(() => _page = _RuntimeSettingsPage.permissionAdvanced),
      );
    }
    return ListView.separated(
      key: const ValueKey('permission'),
      padding: const EdgeInsets.fromLTRB(0, 6, 0, 10),
      itemCount: CcPermissionMode.values.length,
      separatorBuilder: (context, index) {
        final t = AppTokens.of(context);
        return Divider(
          color: t.borderSubt,
          height: 0.5,
          indent: 16,
          endIndent: 16,
        );
      },
      itemBuilder: (context, index) {
        final mode = CcPermissionMode.values[index];
        final t = AppTokens.of(context);
        return _PermissionModeRow(
          mode: mode,
          label: _permissionLabel(mode),
          description: _permissionDescription(mode),
          glyph: _permissionGlyph(mode, t),
          selected: mode == _permissionMode,
          onTap: () => _setPermissionMode(mode),
        );
      },
    );
  }

  Widget _codexPermissionAdvancedPage() {
    return _CodexRuntimePermissionAdvancedPage(
      key: const ValueKey('permissionAdvanced'),
      approvalPolicy: (_runtime['approval_policy'] ?? 'on-request').toString(),
      sandbox: (_runtime['sandbox'] ?? 'workspace-write').toString(),
      onPatchRuntime: _patchRuntime,
    );
  }

  String _permissionLabel(CcPermissionMode m) => switch (m) {
        CcPermissionMode.defaultMode => 'Claude 配置策略',
        CcPermissionMode.acceptEdits => 'Accept Edits',
        CcPermissionMode.plan => 'Plan',
        CcPermissionMode.bypass => 'Bypass',
      };

  String _codexPermissionSummary(String sandbox, String approvalPolicy) {
    final mode = _codexPermissionModeFor(sandbox, approvalPolicy);
    final prefix = mode?.label ?? '自定义';
    return '$prefix · $sandbox · $approvalPolicy';
  }

  String _permissionDescription(CcPermissionMode m) => switch (m) {
        CcPermissionMode.defaultMode => '按 Claude Code 配置策略询问',
        CcPermissionMode.acceptEdits => '自动接受文件编辑，高风险操作仍询问',
        CcPermissionMode.plan => '只规划，不直接修改文件',
        CcPermissionMode.bypass => '跳过权限检查，完整访问',
      };

  (IconData, Color) _permissionGlyph(CcPermissionMode m, AppTokens t) =>
      switch (m) {
        CcPermissionMode.defaultMode => (Icons.front_hand_outlined, t.warning),
        CcPermissionMode.acceptEdits => (Icons.edit_note_outlined, t.accent),
        CcPermissionMode.plan => (Icons.checklist_outlined, t.toolRead),
        CcPermissionMode.bypass => (Icons.rocket_launch_outlined, t.toolBash),
      };
}

class _RuntimeSheetHeader extends StatelessWidget {
  final String title;
  final IconData icon;
  final bool showBack;
  final VoidCallback onBack;
  const _RuntimeSheetHeader({
    required this.title,
    required this.icon,
    required this.showBack,
    required this.onBack,
  });

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 16, 8),
      child: Row(
        children: [
          if (showBack)
            IconButton(
              onPressed: onBack,
              icon: Icon(Icons.arrow_back_rounded, size: 18, color: t.text),
              visualDensity: VisualDensity.compact,
              tooltip: '返回',
            )
          else
            Padding(
              padding: const EdgeInsets.only(left: 8, right: 8),
              child: Icon(icon, size: 16, color: t.textMuted),
            ),
          if (showBack) const SizedBox(width: 2),
          Text(
            title,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: t.text,
            ),
          ),
        ],
      ),
    );
  }
}

class _RuntimeActionRow extends StatelessWidget {
  final IconData icon;
  final String title;
  final String value;
  final VoidCallback onTap;
  const _RuntimeActionRow({
    required this.icon,
    required this.title,
    required this.value,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 13, 16, 13),
        child: Row(
          children: [
            Icon(icon, size: 17, color: t.textDim),
            const SizedBox(width: 12),
            Text(title, style: TextStyle(color: t.text, fontSize: 14)),
            const Spacer(),
            Flexible(
              child: Text(
                value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: t.textMuted,
                  fontSize: 12,
                  fontFamily: 'monospace',
                ),
              ),
            ),
            const SizedBox(width: 8),
            Icon(Icons.chevron_right, size: 17, color: t.textDim),
          ],
        ),
      ),
    );
  }
}

class _CodexRuntimePermissionPage extends StatelessWidget {
  final String approvalPolicy;
  final String sandbox;
  final void Function(Map<String, dynamic>) onPatchRuntime;
  final VoidCallback onOpenAdvanced;
  const _CodexRuntimePermissionPage({
    super.key,
    required this.approvalPolicy,
    required this.sandbox,
    required this.onPatchRuntime,
    required this.onOpenAdvanced,
  });

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    final selected = _codexPermissionModeFor(sandbox, approvalPolicy);
    return ListView(
      key: const ValueKey('permission'),
      padding: const EdgeInsets.fromLTRB(0, 6, 0, 12),
      children: [
        _InlineSectionLabel(label: 'Preset', t: t),
        for (var i = 0; i < _codexPermissionModes.length; i++) ...[
          if (i > 0)
            Divider(
              color: t.borderSubt,
              height: 0.5,
              indent: 16,
              endIndent: 16,
            ),
          _CodexRuntimeOptionRow(
            option: _RuntimeOption(
              value: _codexPermissionModes[i].label,
              label: _codexPermissionModes[i].label,
              description:
                  '${_codexPermissionModes[i].sandbox} · ${_codexPermissionModes[i].approvalPolicy}\n${_codexPermissionModes[i].description}',
              icon: _codexPermissionModes[i].icon,
            ),
            selected: selected == _codexPermissionModes[i],
            onTap: () => onPatchRuntime({
              'sandbox': _codexPermissionModes[i].sandbox,
              'approval_policy': _codexPermissionModes[i].approvalPolicy,
            }),
          ),
        ],
        if (selected == null) ...[
          Divider(
            color: t.borderSubt,
            height: 0.5,
            indent: 16,
            endIndent: 16,
          ),
          _CodexRuntimeOptionRow(
            option: _RuntimeOption(
              value: 'custom',
              label: '自定义',
              description: '$sandbox · $approvalPolicy',
              icon: Icons.tune_rounded,
            ),
            selected: true,
            onTap: () {},
          ),
        ],
        Divider(color: t.borderSubt, height: 20),
        _RuntimeActionRow(
          icon: Icons.tune_rounded,
          title: '高级设置',
          value: '$sandbox · $approvalPolicy',
          onTap: onOpenAdvanced,
        ),
      ],
    );
  }
}

class _CodexRuntimePermissionAdvancedPage extends StatelessWidget {
  final String approvalPolicy;
  final String sandbox;
  final void Function(Map<String, dynamic>) onPatchRuntime;
  const _CodexRuntimePermissionAdvancedPage({
    super.key,
    required this.approvalPolicy,
    required this.sandbox,
    required this.onPatchRuntime,
  });

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return ListView(
      key: const ValueKey('permissionAdvanced'),
      padding: const EdgeInsets.fromLTRB(0, 6, 0, 12),
      children: [
        _InlineSectionLabel(label: 'sandbox', t: t),
        _CodexRuntimeOptionList(
          value: sandbox,
          options: _codexSandboxOptions,
          onPick: (value) => onPatchRuntime({'sandbox': value}),
        ),
        Divider(color: t.borderSubt, height: 20),
        _InlineSectionLabel(label: 'approval_policy', t: t),
        _CodexRuntimeOptionList(
          value: approvalPolicy,
          options: _codexApprovalPolicyOptions,
          onPick: (value) => onPatchRuntime({'approval_policy': value}),
        ),
      ],
    );
  }
}

class _InlineSectionLabel extends StatelessWidget {
  final String label;
  final AppTokens t;
  const _InlineSectionLabel({required this.label, required this.t});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Text(
        label,
        style: TextStyle(
          color: t.textDim,
          fontSize: 11,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _RuntimeOption {
  final String value;
  final String label;
  final String description;
  final IconData icon;
  const _RuntimeOption({
    required this.value,
    required this.label,
    required this.description,
    required this.icon,
  });
}

class _CodexRuntimeOptionList extends StatelessWidget {
  final String value;
  final List<_RuntimeOption> options;
  final void Function(String) onPick;
  const _CodexRuntimeOptionList({
    required this.value,
    required this.options,
    required this.onPick,
  });

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < options.length; i++) ...[
            if (i > 0)
              Divider(
                color: t.borderSubt,
                height: 0.5,
                indent: 16,
                endIndent: 16,
              ),
            _CodexRuntimeOptionRow(
              option: options[i],
              selected: options[i].value == value,
              onTap: () => onPick(options[i].value),
            ),
          ],
        ],
      ),
    );
  }
}

class _CodexRuntimeOptionRow extends StatelessWidget {
  final _RuntimeOption option;
  final bool selected;
  final VoidCallback onTap;
  const _CodexRuntimeOptionRow({
    required this.option,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 13, 16, 13),
        child: Row(
          children: [
            Container(
              width: 18,
              height: 18,
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
            Icon(option.icon, size: 16, color: t.textMuted),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    option.label,
                    style: TextStyle(
                      color: t.text,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    option.description,
                    style: TextStyle(color: t.textDim, fontSize: 11.5),
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

/// 输入框右侧的 40×40 圆形按钮（黑白主题，对照 cxclaw）。
/// - busy=false, canSend=true  → 发送上箭头（深色）
/// - busy=false, canSend=false → 发送上箭头（浅灰，禁用）
/// - busy=true, canQueue=true  → 排队上箭头（accent 色背景，表示"加入队列"）
/// - busy=true, canQueue=false → 停止方块
class _SendOrStopButton extends StatefulWidget {
  final bool busy;
  final bool interrupting;
  final bool canSend;
  final bool canQueue;
  final VoidCallback onSubmit;
  final VoidCallback onStop;
  const _SendOrStopButton({
    required this.busy,
    required this.interrupting,
    required this.canSend,
    required this.canQueue,
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

    // 三种视觉态
    final Color bg;
    final Color fg;
    final Widget icon;

    if (widget.interrupting) {
      bg = dark ? t.text : const Color(0xFF101828);
      fg = dark ? const Color(0xFF0B1210) : Colors.white;
      icon = SizedBox(
        width: 16,
        height: 16,
        child: CircularProgressIndicator(
          strokeWidth: 2,
          valueColor: AlwaysStoppedAnimation<Color>(fg),
        ),
      );
    } else if (widget.busy && widget.canQueue) {
      // 排队模式：accent 色背景 + 上箭头
      bg = t.accent;
      fg = Colors.white;
      icon = Icon(Icons.arrow_upward_rounded, size: 18, color: fg);
    } else if (!widget.canSend && !widget.busy) {
      // 禁用态
      bg = dark ? t.borderSubt : const Color(0xFFE4E7EC);
      fg = dark ? t.textDim : const Color(0xFF98A2B3);
      icon = Icon(Icons.arrow_upward_rounded, size: 18, color: fg);
    } else {
      // 正常发送 或 停止
      bg = dark ? t.text : const Color(0xFF101828);
      fg = dark ? const Color(0xFF0B1210) : Colors.white;
      icon = widget.busy
          ? Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                color: fg,
                borderRadius: BorderRadius.circular(2),
              ),
            )
          : Icon(Icons.arrow_upward_rounded, size: 18, color: fg);
    }

    // 点击行为
    final VoidCallback? onTap;
    if (widget.interrupting) {
      onTap = null;
    } else if (widget.busy) {
      onTap = widget.canQueue ? widget.onSubmit : widget.onStop;
    } else {
      onTap = widget.canSend ? widget.onSubmit : null;
    }

    return GestureDetector(
      onTapDown: (_) {
        if (onTap == null) return;
        HapticFeedback.lightImpact();
        setState(() => _pressed = true);
      },
      onTapUp: (_) {
        if (_pressed) setState(() => _pressed = false);
      },
      onTapCancel: () {
        if (_pressed) setState(() => _pressed = false);
      },
      onTap: onTap,
      child: AnimatedScale(
        scale: _pressed ? 0.96 : 1.0,
        duration: const Duration(milliseconds: 100),
        curve: Curves.easeOut,
        child: SizedBox(
          width: 44,
          height: 44,
          child: Center(
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOut,
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
              child: icon,
            ),
          ),
        ),
      ),
    );
  }
}

class _ModelSheet extends StatefulWidget {
  final ModelOption current;
  final List<ModelOption> models;
  final String? providerLabel;
  final String? reasoningEffort;
  final ValueChanged<ModelOption>? onPickModelInline;
  final ValueChanged<String>? onPickReasoningEffort;
  const _ModelSheet({
    required this.current,
    required this.models,
    this.providerLabel,
    this.reasoningEffort,
    this.onPickModelInline,
    this.onPickReasoningEffort,
  });

  @override
  State<_ModelSheet> createState() => _ModelSheetState();
}

class _ModelSheetState extends State<_ModelSheet> {
  bool _showCustomInput = false;
  final _customController = TextEditingController();
  late ModelOption _current = widget.current;
  late String? _reasoningEffort = widget.reasoningEffort;
  _ModelSheetPage _page = _ModelSheetPage.models;

  @override
  void dispose() {
    _customController.dispose();
    super.dispose();
  }

  bool _isReasoningModel(ModelOption model) {
    if (widget.reasoningEffort == null ||
        widget.onPickReasoningEffort == null) {
      return false;
    }
    final id = model.id.toLowerCase();
    final description = model.description.toLowerCase();
    return model.tier == 'powerful' ||
        id.contains('reasoning') ||
        id.startsWith('o3') ||
        id.startsWith('o4') ||
        id == 'gpt-5.5' ||
        description.contains('reasoning') ||
        description.contains('深度推理');
  }

  void _pickModel(ModelOption model) {
    if (_isReasoningModel(model)) {
      widget.onPickModelInline?.call(model);
      setState(() {
        _current = model;
        _page = _ModelSheetPage.reasoning;
      });
      return;
    }
    Navigator.of(context).pop(model);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    final title = switch (_page) {
      _ModelSheetPage.models => '选择模型',
      _ModelSheetPage.reasoning => '推理强度',
    };
    return Container(
      height: 470,
      margin: const EdgeInsets.all(8),
      clipBehavior: Clip.antiAlias,
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
            // drag handle
            Padding(
              padding: const EdgeInsets.only(top: 10, bottom: 4),
              child: Center(
                child: Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: t.border,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
            ),
            _RuntimeSheetHeader(
              title: title,
              icon: Icons.auto_awesome_outlined,
              showBack: _page != _ModelSheetPage.models,
              onBack: () => setState(() => _page = _ModelSheetPage.models),
            ),
            Divider(color: t.borderSubt, height: 0.5),
            Flexible(
              child: ClipRect(
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 220),
                  transitionBuilder: (child, animation) {
                    final enteringModels =
                        child.key == const ValueKey('modelPage');
                    final begin = enteringModels
                        ? const Offset(-1, 0)
                        : const Offset(1, 0);
                    return SlideTransition(
                      position: Tween<Offset>(
                        begin: begin,
                        end: Offset.zero,
                      ).animate(CurvedAnimation(
                        parent: animation,
                        curve: Curves.easeOutCubic,
                      )),
                      child: FadeTransition(opacity: animation, child: child),
                    );
                  },
                  child: switch (_page) {
                    _ModelSheetPage.models => _modelPage(t),
                    _ModelSheetPage.reasoning => _reasoningPage(t),
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _modelPage(AppTokens t) {
    return ListView(
      key: const ValueKey('modelPage'),
      shrinkWrap: true,
      padding: const EdgeInsets.fromLTRB(0, 0, 0, 6),
      children: [
        if (widget.providerLabel != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 2),
            child: Align(
              alignment: Alignment.centerRight,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: t.accent.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: t.accent.withValues(alpha: 0.2)),
                ),
                child: Text(
                  widget.providerLabel!,
                  style: TextStyle(
                    fontSize: 10.5,
                    color: t.accent,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ),
        for (final m in widget.models) ...[
          Divider(color: t.borderSubt, height: 0.5, indent: 16, endIndent: 16),
          _ModelRow(
            model: m,
            selected: m.id == _current.id,
            onTap: () => _pickModel(m),
          ),
        ],
        Divider(color: t.borderSubt, height: 0.5, indent: 16, endIndent: 16),
        if (!_showCustomInput)
          InkWell(
            onTap: () => setState(() => _showCustomInput = true),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
              child: Row(
                children: [
                  Container(
                    width: 18,
                    height: 18,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(color: t.border, width: 1.5),
                    ),
                    child: Icon(Icons.add, size: 11, color: t.textDim),
                  ),
                  const SizedBox(width: 12),
                  Text('自定义 Model ID',
                      style: TextStyle(color: t.textMuted, fontSize: 14)),
                ],
              ),
            ),
          )
        else
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _customController,
                    autofocus: true,
                    style: TextStyle(
                        fontSize: 13, color: t.text, fontFamily: 'monospace'),
                    decoration: InputDecoration(
                      hintText: 'e.g. gpt-5.5',
                      hintStyle: TextStyle(fontSize: 12, color: t.textDim),
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 10),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide(color: t.border),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide(color: t.border),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide(color: t.accent),
                      ),
                    ),
                    onSubmitted: (v) {
                      final id = v.trim();
                      if (id.isNotEmpty) {
                        Navigator.of(context).pop(ModelOption.custom(id));
                      }
                    },
                  ),
                ),
                const SizedBox(width: 8),
                GestureDetector(
                  onTap: () {
                    final id = _customController.text.trim();
                    if (id.isNotEmpty) {
                      Navigator.of(context).pop(ModelOption.custom(id));
                    }
                  },
                  child: Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: t.accent,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child:
                        const Icon(Icons.check, size: 16, color: Colors.white),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _reasoningPage(AppTokens t) {
    return ListView(
      key: const ValueKey('reasoningPage'),
      padding: const EdgeInsets.fromLTRB(0, 6, 0, 12),
      children: [
        _CodexRuntimeOptionList(
          value: _reasoningEffort ?? 'medium',
          options: const [
            _RuntimeOption(
              value: 'low',
              label: 'low',
              description: '更快响应，适合轻量修改',
              icon: Icons.speed_rounded,
            ),
            _RuntimeOption(
              value: 'medium',
              label: 'medium',
              description: '均衡速度和推理质量',
              icon: Icons.tune_rounded,
            ),
            _RuntimeOption(
              value: 'high',
              label: 'high',
              description: '更强推理，适合复杂代码任务',
              icon: Icons.psychology_alt_outlined,
            ),
          ],
          onPick: (value) {
            setState(() => _reasoningEffort = value);
            widget.onPickReasoningEffort!(value);
            Navigator.of(context).pop();
          },
        ),
      ],
    );
  }
}

enum _ModelSheetPage { models, reasoning }

class _ModelRow extends StatelessWidget {
  final ModelOption model;
  final bool selected;
  final VoidCallback onTap;
  const _ModelRow(
      {required this.model, required this.selected, required this.onTap});

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
              width: 18,
              height: 18,
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
              width: 18,
              height: 18,
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
    if (RegExp(
            r'\.(ts|tsx|js|jsx|py|dart|go|rs|java|c|cpp|h|hpp|json|yaml|yml|md|sh)$')
        .hasMatch(lower)) {
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
/// 当前 turn 结束后 FIFO 出队继续发。长按某条可优先发送并中断当前响应。
class _PendingQueueBar extends StatelessWidget {
  final List<String> messages;
  final void Function(int) onRemove;
  final void Function(int) onEdit;
  final void Function(int) onPrioritize;
  final void Function(int oldIndex, int newIndex) onReorder;
  const _PendingQueueBar({
    required this.messages,
    required this.onRemove,
    required this.onEdit,
    required this.onPrioritize,
    required this.onReorder,
  });

  @override
  Widget build(BuildContext context) {
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
                const SizedBox(width: 6),
                Text(
                  '拖动排序 · 长按优先',
                  style: TextStyle(
                      fontSize: 10, color: t.textDim.withValues(alpha: 0.6)),
                ),
              ],
            ),
          ),
          ReorderableListView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            buildDefaultDragHandles: false,
            proxyDecorator: (child, index, animation) {
              return Material(
                color: Colors.transparent,
                child: ScaleTransition(
                  scale: Tween<double>(begin: 1, end: 1.02).animate(
                    CurvedAnimation(
                      parent: animation,
                      curve: Curves.easeOutCubic,
                    ),
                  ),
                  child: child,
                ),
              );
            },
            itemCount: messages.length,
            onReorder: onReorder,
            itemBuilder: (context, i) => Padding(
              key: ValueKey('pending_${i}_${messages[i].hashCode}'),
              padding: const EdgeInsets.only(bottom: 6),
              child: _PendingQueueItem(
                index: i,
                text: messages[i],
                onRemove: () => onRemove(i),
                onEdit: () => onEdit(i),
                onPrioritize: () => onPrioritize(i),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 单条队列消息 item：支持长按抖动 → 优先发送。
class _PendingQueueItem extends StatefulWidget {
  final int index;
  final String text;
  final VoidCallback onRemove;
  final VoidCallback onEdit;
  final VoidCallback onPrioritize;
  const _PendingQueueItem({
    required this.index,
    required this.text,
    required this.onRemove,
    required this.onEdit,
    required this.onPrioritize,
  });

  @override
  State<_PendingQueueItem> createState() => _PendingQueueItemState();
}

class _PendingQueueItemState extends State<_PendingQueueItem>
    with SingleTickerProviderStateMixin {
  late final AnimationController _shakeCtrl;

  @override
  void initState() {
    super.initState();
    _shakeCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
    );
  }

  @override
  void dispose() {
    _shakeCtrl.dispose();
    super.dispose();
  }

  void _onLongPress() {
    HapticFeedback.heavyImpact();
    _shakeCtrl.forward(from: 0).then((_) {
      if (mounted) widget.onPrioritize();
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return AnimatedBuilder(
      animation: _shakeCtrl,
      builder: (_, child) {
        // 衰减正弦抖动：2.5 次振荡，幅度随进度衰减
        final dx =
            sin(_shakeCtrl.value * pi * 5) * 6.0 * (1 - _shakeCtrl.value);
        return Transform.translate(offset: Offset(dx, 0), child: child);
      },
      child: GestureDetector(
        onLongPress: _onLongPress,
        child: Container(
          decoration: BoxDecoration(
            color: t.accent.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: t.accent.withValues(alpha: 0.18)),
          ),
          padding: const EdgeInsets.fromLTRB(12, 8, 6, 8),
          child: Row(
            children: [
              ReorderableDragStartListener(
                index: widget.index,
                child: Tooltip(
                  message: '拖动排序',
                  child: SizedBox(
                    width: 28,
                    height: 32,
                    child: Icon(
                      Icons.drag_indicator_rounded,
                      size: 18,
                      color: t.textDim,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 2),
              Expanded(
                child: Text(
                  widget.text,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 13, color: t.text, height: 1.3),
                ),
              ),
              InkResponse(
                onTap: widget.onEdit,
                radius: 18,
                child: Padding(
                  padding: const EdgeInsets.all(6),
                  child: Icon(Icons.edit_outlined, size: 14, color: t.accent),
                ),
              ),
              InkResponse(
                onTap: widget.onRemove,
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
    );
  }
}

class _ReEditAction extends StatelessWidget {
  final VoidCallback onReEdit;
  const _ReEditAction({required this.onReEdit});

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Tooltip(
      message: '撤回并重新编辑',
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(999),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onReEdit,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: t.accent.withValues(alpha: dark ? 0.12 : 0.09),
              borderRadius: BorderRadius.circular(999),
              boxShadow: [
                BoxShadow(
                  color: t.accent.withValues(alpha: dark ? 0.08 : 0.06),
                  blurRadius: 12,
                  offset: const Offset(0, 3),
                ),
              ],
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.undo_rounded, size: 14, color: t.accent),
                const SizedBox(width: 4),
                Text(
                  '重新编辑',
                  style: TextStyle(
                    fontSize: 11,
                    height: 1.1,
                    color: t.accent,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// "重新编辑"快捷条：当用户中断且 AI 未响应时显示。
/// 点击把上一条用户消息放回输入框，撤销那次发送记录。
class _ReEditBar extends StatelessWidget {
  final String text;
  final VoidCallback onReEdit;
  const _ReEditBar({required this.text, required this.onReEdit});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
      child: Row(
        children: [
          const Spacer(),
          _ReEditAction(onReEdit: onReEdit),
        ],
      ),
    );
  }
}

class _StreamingMessage extends StatelessWidget {
  final StreamingAssistant buffer;
  final void Function(String path)? onOpenFilePath;

  const _StreamingMessage({
    required this.buffer,
    this.onOpenFilePath,
  });

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    final text = buffer.text.toString();
    final approxTokens = (text.length / 4).round();
    final dotColor = buffer.stopped ? t.success : t.textMuted;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 18,
            child: Padding(
              padding: const EdgeInsets.only(top: 2),
              child: buffer.stopped
                  ? Text(
                      '●',
                      style: TextStyle(
                        fontSize: 11,
                        color: dotColor,
                        height: 1.4,
                      ),
                    )
                  : _PulsingDot(color: dotColor),
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                MarkdownBody(
                  data: text,
                  selectable: true,
                  onTapLink: onOpenFilePath == null
                      ? null
                      : (label, href, title) {
                          final path = _localFilePathFromMarkdownHref(href);
                          if (path != null) onOpenFilePath!(path);
                        },
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

String? _localFilePathFromMarkdownHref(String? href) {
  if (href == null || href.trim().isEmpty) return null;
  final value = href.trim();
  if (value.startsWith('/')) return Uri.decodeFull(value);

  final uri = Uri.tryParse(value);
  if (uri == null || uri.scheme != 'file') return null;
  final path = uri.path;
  if (!path.startsWith('/')) return null;
  return Uri.decodeFull(path);
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
              width: 8,
              height: 8,
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
              width: 8,
              height: 8,
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
                Container(
                    width: 14,
                    height: 14,
                    decoration: BoxDecoration(
                        color: c, borderRadius: BorderRadius.circular(3))),
                const SizedBox(width: 8),
                Container(
                    width: 60,
                    height: 10,
                    decoration: BoxDecoration(
                        color: c, borderRadius: BorderRadius.circular(3))),
                const SizedBox(width: 8),
                Expanded(
                    child: Container(
                        height: 10,
                        decoration: BoxDecoration(
                            color: c, borderRadius: BorderRadius.circular(3)))),
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
          Text(title,
              style: TextStyle(
                  fontSize: 14,
                  color: t.textMuted,
                  fontWeight: FontWeight.w500)),
          if (subtitle != null) ...[
            const SizedBox(height: 4),
            Text(subtitle!, style: TextStyle(fontSize: 12, color: t.textDim)),
          ],
        ],
      ),
    );
  }
}
