# Connection Model Merge Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Merge `PairedServer` + `ServerEntry` into a single `Connection` model, update the LAN scan card to show custom names and IP-change indicators, and add 401 re-pairing prompts throughout the app.

**Architecture:** Replace the dual-store design (`connections_v1` + `paired_servers` SharedPreferences keys) with a single `Connection` model stored at `connections_v2`. All pairing identity (`serverId`, `recentHosts`) and display fields (`name`, `emoji`, `lastConnected`) live on one object. No historical data migration — clean break with new storage key.

**Tech Stack:** Flutter/Dart, Riverpod (`StateNotifierProvider`), SharedPreferences, `uuid` package (already a dependency)

---

## File Map

| File | Action | Responsibility |
|---|---|---|
| `app/lib/state/server_config.dart` | **Full rewrite** | `Connection` model, `ConnectionsNotifier`, providers |
| `app/lib/screens/pair_sheet.dart` | **Modify** | Save `Connection` instead of `PairedServer` |
| `app/lib/screens/lan_scan_sheet.dart` | **Modify** | Improved tile UI (custom name, IP-changed badge), return `Connection` |
| `app/lib/screens/add_connection_sheet.dart` | **Modify** | Single-store, simpler LAN/QR/manual flows |
| `app/lib/screens/connections_screen.dart` | **Modify** | `Connection` type annotations, simplified delete |
| `app/lib/state/reconnect_service.dart` | **Modify** | Single store, `updateUrl()` replaces `updateHost` + `_syncEntryUrl` |
| `app/lib/screens/project_picker_screen.dart` | **Modify** | `Connection` type annotations + 401 re-pair pop |
| `app/lib/screens/main_shell.dart` | **Modify** | `ServerEntry` → `Connection` type annotation |
| `app/lib/api/sse_client.dart` | **Modify** | Emit `__auth_error` on HTTP 401, stop reconnect loop |
| `app/lib/screens/tabs/chat_tab.dart` | **Modify** | `_authFailed` state + error banner on `__auth_error` |

Files that need **no changes** (use inferred types, compatible interface):
`add_project_sheet.dart`, `files_tab.dart`, `shell_tab.dart`, `projects_store.dart`

> ⚠️ **Compilation note:** Tasks 1–6 must all complete before `flutter analyze` passes. Do not run the analyzer mid-way.

---

## Task 1: New `Connection` model

**Files:**
- Full rewrite: `app/lib/state/server_config.dart`

- [ ] **Step 1: Replace the file entirely**

```dart
// app/lib/state/server_config.dart
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

/// Single model replacing the former ServerEntry + PairedServer split.
/// [serverId] non-null means the connection was established via PIN/QR pairing.
/// Manual (unauthenticated) connections have serverId == null.
class Connection {
  final String id;               // local UUID, list key
  final String name;             // user-editable display name
  final String emoji;
  final String url;              // http://host:port — single source of truth for address
  final String? token;           // device token from pairing (null = no auth)
  final String? serverId;        // stable server identity; null = manually added
  final List<String> recentHosts; // past IPs for cross-network reconnect
  final DateTime? lastConnected;
  final DateTime? lastSeen;

  const Connection({
    required this.id,
    required this.name,
    required this.emoji,
    required this.url,
    this.token,
    this.serverId,
    this.recentHosts = const [],
    this.lastConnected,
    this.lastSeen,
  });

  bool get isPaired => serverId != null && token != null;

  String get httpBase => url;
  String get wsBase => url.replaceFirst(RegExp(r'^http'), 'ws');
  String get host => Uri.parse(url).host;
  int get port => Uri.parse(url).port;

  Map<String, String> get authHeaders =>
      token != null && token!.isNotEmpty
          ? {'Authorization': 'Bearer $token'}
          : const {};

  Connection copyWith({
    String? name,
    String? emoji,
    String? url,
    String? token,
    String? serverId,
    List<String>? recentHosts,
    DateTime? lastConnected,
    DateTime? lastSeen,
  }) =>
      Connection(
        id: id,
        name: name ?? this.name,
        emoji: emoji ?? this.emoji,
        url: url ?? this.url,
        token: token ?? this.token,
        serverId: serverId ?? this.serverId,
        recentHosts: recentHosts ?? this.recentHosts,
        lastConnected: lastConnected ?? this.lastConnected,
        lastSeen: lastSeen ?? this.lastSeen,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'emoji': emoji,
        'url': url,
        if (token != null) 'token': token,
        if (serverId != null) 'serverId': serverId,
        'recentHosts': recentHosts,
        'lastConnected': lastConnected?.toIso8601String(),
        'lastSeen': lastSeen?.toIso8601String(),
      };

  factory Connection.fromJson(Map<String, dynamic> j) => Connection(
        id: j['id'] as String,
        name: j['name'] as String,
        emoji: j['emoji'] as String? ?? '🖥️',
        url: j['url'] as String,
        token: j['token'] as String?,
        serverId: j['serverId'] as String?,
        recentHosts: ((j['recentHosts'] as List?) ?? []).cast<String>(),
        lastConnected: j['lastConnected'] != null
            ? DateTime.tryParse(j['lastConnected'] as String)
            : null,
        lastSeen: j['lastSeen'] != null
            ? DateTime.tryParse(j['lastSeen'] as String)
            : null,
      );
}

class ConnectionsNotifier extends StateNotifier<List<Connection>> {
  ConnectionsNotifier() : super([]) {
    _load();
  }

  static const _key = 'connections_v2';   // new key — clean break from v1 + paired_servers
  static const _deviceIdKey = 'device_id';
  static const _uuid = Uuid();

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null) return;
    try {
      final list = (jsonDecode(raw) as List)
          .cast<Map<String, dynamic>>()
          .map(Connection.fromJson)
          .toList();
      state = list;
    } catch (_) {}
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        _key, jsonEncode(state.map((e) => e.toJson()).toList()));
  }

  Future<Connection> add(Connection conn) async {
    state = [...state, conn];
    await _save();
    return conn;
  }

  Future<void> update(Connection conn) async {
    state = [for (final e in state) e.id == conn.id ? conn : e];
    await _save();
  }

  Future<void> remove(String id) async {
    state = state.where((e) => e.id != id).toList();
    await _save();
  }

  Future<void> touch(String id) async {
    state = [
      for (final e in state)
        e.id == id ? e.copyWith(lastConnected: DateTime.now()) : e,
    ];
    await _save();
  }

  /// Updates url for a paired connection after LAN rediscovery.
  /// Pushes old host into recentHosts (capped at 5).
  Future<void> updateUrl(String id, String newUrl) async {
    state = [
      for (final c in state)
        if (c.id == id)
          c.copyWith(
            url: newUrl,
            lastSeen: DateTime.now(),
            recentHosts: newUrl != c.url
                ? [
                    c.host,
                    ...c.recentHosts
                        .where((h) => h != Uri.parse(newUrl).host),
                  ].take(5).toList()
                : c.recentHosts,
          )
        else
          c,
    ];
    await _save();
  }

  // ─── Static helpers (formerly on PairedServersNotifier) ───────────────────

  static Future<String> getOrCreateDeviceId() async {
    final prefs = await SharedPreferences.getInstance();
    var id = prefs.getString(_deviceIdKey);
    if (id == null) {
      id = const Uuid().v4();
      await prefs.setString(_deviceIdKey, id);
    }
    return id;
  }

  static String get deviceName {
    try {
      if (Platform.isAndroid) return 'Android device';
      if (Platform.isIOS) return 'iPhone / iPad';
      return '${Platform.operatingSystem} device';
    } catch (_) {
      return 'Mobile device';
    }
  }

  /// Creates a new [Connection] ID.
  static String newId() => _uuid.v4();
}

final connectionsProvider =
    StateNotifierProvider<ConnectionsNotifier, List<Connection>>(
        (_) => ConnectionsNotifier());

final activeConnectionProvider = StateProvider<Connection?>((_) => null);
```

---

## Task 2: Update `pair_sheet.dart`

**Files:**
- Modify: `app/lib/screens/pair_sheet.dart`

Key changes:
- `PairedServer? _savedServer` → `Connection? _savedConn`
- `_saveImmediately`: write to `connectionsProvider` instead of `pairedServersProvider`
- `_onDone`: update `Connection.name` in `connectionsProvider`
- Return type: `Connection` (was `PairedServer`)
- Use `ConnectionsNotifier.getOrCreateDeviceId()` / `ConnectionsNotifier.deviceName`

- [ ] **Step 1: Update imports and field**

Replace the import section and change `PairedServer? _savedServer` field:

```dart
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';

import '../i18n/locale_provider.dart';
import '../i18n/strings.dart';
import '../state/lan_scanner.dart';
import '../state/server_config.dart';
import '../theme.dart';
```

Change field declaration (around line 51):
```dart
// Before:
PairedServer? _savedServer;

// After:
Connection? _savedConn;
```

- [ ] **Step 2: Update `_saveImmediately`**

Replace the entire method:

```dart
Future<void> _saveImmediately(String serverId, String deviceToken) async {
  final url = 'http://${widget.server.host}:${widget.server.port}';

  // Check for existing Connection with same serverId (re-pair case)
  final existing = ref.read(connectionsProvider)
      .where((c) => c.serverId == serverId)
      .firstOrNull;

  late final Connection conn;
  if (existing != null) {
    conn = existing.copyWith(
      token: deviceToken,
      url: url,
      lastSeen: DateTime.now(),
    );
    await ref.read(connectionsProvider.notifier).update(conn);
  } else {
    conn = Connection(
      id: ConnectionsNotifier.newId(),
      name: widget.server.name,
      emoji: '🖥️',
      url: url,
      token: deviceToken,
      serverId: serverId,
      lastSeen: DateTime.now(),
    );
    await ref.read(connectionsProvider.notifier).add(conn);
  }

  if (!mounted) return;
  if (widget.skipSuccess) {
    Navigator.of(context).pop(conn);
    return;
  }
  setState(() {
    _savedConn = conn;
    _serverName = widget.server.name;
    _nameCtrl.text = _serverName;
    _phase = _PairPhase.success;
  });
}
```

- [ ] **Step 3: Update `_onDone`**

```dart
Future<void> _onDone() async {
  final saved = _savedConn;
  if (saved == null) {
    Navigator.of(context).pop();
    return;
  }
  Connection result = saved;
  final newName = _nameCtrl.text.trim();
  if (newName.isNotEmpty && newName != saved.name) {
    result = saved.copyWith(name: newName);
    await ref.read(connectionsProvider.notifier).update(result);
  }
  if (mounted) Navigator.of(context).pop(result);
}
```

- [ ] **Step 4: Update `_startAutoPair` and `_pairWithPin` device-ID calls**

Replace all occurrences of `PairedServersNotifier.getOrCreateDeviceId()` with `ConnectionsNotifier.getOrCreateDeviceId()` and `PairedServersNotifier.deviceName` with `ConnectionsNotifier.deviceName`.

There are 4 occurrences (2 in `_startAutoPair`, 1 in `_pairWithPin`):
```dart
// In _startAutoPair (line ~83):
final deviceId = await ConnectionsNotifier.getOrCreateDeviceId();
final deviceName = ConnectionsNotifier.deviceName;

// In _pairWithPin (line ~225):
final deviceId = await ConnectionsNotifier.getOrCreateDeviceId();
final deviceName = ConnectionsNotifier.deviceName;
```

---

## Task 3: Update `lan_scan_sheet.dart`

**Files:**
- Modify: `app/lib/screens/lan_scan_sheet.dart`

Key changes:
- Build `Map<String, Connection>` keyed by `serverId`
- Return `Connection?` instead of `PairedServer | LanScanResult | null`
- `_ServerTile`: show custom name+emoji for paired, show IP-changed badge

- [ ] **Step 1: Update imports and state fields**

```dart
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../i18n/locale_provider.dart';
import '../i18n/strings.dart';
import '../state/lan_scanner.dart';
import '../state/server_config.dart';
import '../theme.dart';
import 'pair_sheet.dart';

export '../state/lan_scanner.dart' show LanScanResult;

/// Bottom sheet that scans the LAN for PawTerm servers.
///
/// Returns on pop:
///  - [Connection] when a server was paired or a known server was tapped
///  - null if dismissed
class LanScanSheet extends ConsumerStatefulWidget {
  const LanScanSheet({super.key});

  @override
  ConsumerState<LanScanSheet> createState() => _LanScanSheetState();
}
```

- [ ] **Step 2: Add `_connByServerId` to state and update `_startScan`**

Add field declaration alongside other state fields:
```dart
Map<String, Connection> _connByServerId = {};
```

Replace the `_startScan` method:
```dart
void _startScan() {
  final port = int.tryParse(_portCtrl.text.trim());
  if (port == null || port < 1 || port > 65535) return;
  _sub?.cancel();

  // Build serverId → Connection map for already-paired display
  final connections = ref.read(connectionsProvider);
  final connMap = <String, Connection>{
    for (final c in connections)
      if (c.serverId != null) c.serverId!: c,
  };

  setState(() {
    _scanning = true;
    _done = false;
    _results = [];
    _connByServerId = connMap;
  });

  final pairedIds = connMap.keys.toSet();

  _sub = LanScanner.scan(ports: {port}).listen(
    (snapshot) {
      if (!mounted) return;
      for (final r in snapshot) {
        r.alreadyPaired = pairedIds.contains(r.serverId);
      }
      setState(() => _results = snapshot);
    },
    onDone: () {
      if (!mounted) return;
      setState(() {
        _scanning = false;
        _done = true;
      });
    },
  );
}
```

- [ ] **Step 3: Update `_onTapResult`**

```dart
Future<void> _onTapResult(LanScanResult result) async {
  if (result.alreadyPaired) {
    final conn = _connByServerId[result.serverId];
    if (conn != null) {
      final freshUrl = result.httpBase;
      if (freshUrl != conn.url) {
        await ref.read(connectionsProvider.notifier).updateUrl(conn.id, freshUrl);
      }
      if (mounted) Navigator.of(context).pop(conn);
    } else {
      if (mounted) Navigator.of(context).pop();
    }
    return;
  }

  // New pairing — open PairSheet; it saves the Connection internally.
  final paired = await showModalBottomSheet<Connection>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => PairSheet(server: result),
  );

  if (paired != null && mounted) {
    Navigator.of(context).pop(paired);
  }
}
```

- [ ] **Step 4: Update `itemBuilder` in `ListView.builder` to pass `pairedConn`**

In the `build` method, find the `_ServerTile` instantiation and update it:
```dart
itemBuilder: (ctx, i) {
  final r = _results[i];
  return _ServerTile(
    result: r,
    pairedConn: r.alreadyPaired ? _connByServerId[r.serverId] : null,
    onTap: _onTapResult,
    t: t,
    s: s,
  );
},
```

- [ ] **Step 5: Rewrite `_ServerTile`**

Replace the entire `_ServerTile` class:

```dart
class _ServerTile extends StatelessWidget {
  final LanScanResult result;
  final Connection? pairedConn;
  final Future<void> Function(LanScanResult) onTap;
  final AppTokens t;
  final Strings s;

  const _ServerTile({
    required this.result,
    required this.pairedConn,
    required this.onTap,
    required this.t,
    required this.s,
  });

  @override
  Widget build(BuildContext context) {
    final conn = pairedConn;
    final displayName = conn?.name ?? result.name;
    final ipChanged = conn != null && conn.host != result.host;

    return ListTile(
      leading: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: result.alreadyPaired ? t.accentSubt : t.surfaceHi,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Center(
          child: result.alreadyPaired
              ? Text(conn?.emoji ?? '🖥️', style: const TextStyle(fontSize: 18))
              : Icon(Icons.computer_rounded, size: 18, color: t.textMuted),
        ),
      ),
      title: Row(
        children: [
          Expanded(
            child: Text(
              displayName,
              style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: t.text),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (result.alreadyPaired)
            _Badge(
              label: ipChanged ? 'IP 已更新' : s.pairSheetAlreadyPaired,
              color: ipChanged ? const Color(0xFFF59E0B) : t.accent,
              bgColor: ipChanged
                  ? const Color(0xFFF59E0B).withValues(alpha: 0.12)
                  : t.accentSubt,
              borderColor: ipChanged
                  ? const Color(0xFFF59E0B).withValues(alpha: 0.4)
                  : t.accent.withValues(alpha: 0.3),
            ),
          if (!result.alreadyPaired && result.pairingOpen) ...[
            const SizedBox(width: 4),
            _Badge(
              label: s.pairSheetPinOpen,
              color: const Color(0xFF22C55E),
              bgColor: const Color(0xFF22C55E).withValues(alpha: 0.1),
              borderColor: const Color(0xFF22C55E).withValues(alpha: 0.4),
            ),
          ],
        ],
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Show machine hostname if it differs from display name
          if (conn != null && result.name != displayName)
            Text(
              result.name,
              style: TextStyle(fontSize: 11.5, color: t.textMuted),
              overflow: TextOverflow.ellipsis,
            ),
          Text(
            [
              '${result.host}:${result.port}',
              if (ipChanged) '(原: ${conn!.host})',
              if (result.version.isNotEmpty) 'v${result.version}',
            ].join('  ·  '),
            style: TextStyle(
                fontSize: 11.5,
                fontFamily: 'monospace',
                color: t.textMuted),
          ),
        ],
      ),
      trailing: Icon(Icons.chevron_right, color: t.textDim, size: 18),
      onTap: () => onTap(result),
    );
  }
}

class _Badge extends StatelessWidget {
  final String label;
  final Color color;
  final Color bgColor;
  final Color borderColor;
  const _Badge({
    required this.label,
    required this.color,
    required this.bgColor,
    required this.borderColor,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: borderColor),
      ),
      child: Text(
        label,
        style: TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.w600,
            color: color),
      ),
    );
  }
}
```

---

## Task 4: Update `add_connection_sheet.dart`

**Files:**
- Modify: `app/lib/screens/add_connection_sheet.dart`

Key changes:
- `editing` field type: `Connection?`
- `_pairedServer` field type: `Connection?`
- `_openLanScan`: receives `Connection?`, just pops on success (connection already saved)
- `_saveAndClose`: uses `Connection` API
- `_openQrScan`: creates single `Connection`, uses `ConnectionsNotifier.getOrCreateDeviceId()`
- `_save` (edit mode): updates `Connection`

- [ ] **Step 1: Update class declaration and fields**

```dart
class AddConnectionSheet extends ConsumerStatefulWidget {
  final Connection? editing;   // was: ServerEntry?
  const AddConnectionSheet({super.key, this.editing});
  // ...
}

class _AddConnectionSheetState extends ConsumerState<AddConnectionSheet> {
  // ...
  Connection? _pairedConn;   // was: PairedServer? _pairedServer
  // ...
}
```

- [ ] **Step 2: Update `initState` (editing branch)**

The editing branch references `e.url` — `Connection` has the same field:
```dart
final e = widget.editing;
if (e != null) {
  final uri = Uri.tryParse(e.url);
  _ipCtrl = TextEditingController(
      text: uri?.host ?? e.url.replaceFirst(RegExp(r'^https?://'), '').split(':').first);
  _portCtrl = TextEditingController(
      text: uri?.port != null && uri!.port != 0 ? '${uri.port}' : '8765');
  _phase = _SheetState.detected;
} else {
  _ipCtrl = TextEditingController();
  _portCtrl = TextEditingController(text: '8765');
}
_nameCtrl = TextEditingController(text: e?.name ?? '');
_emoji = e?.emoji ?? '🖥️';
```

- [ ] **Step 3: Update `_save` (edit-mode save)**

```dart
Future<void> _save() async {
  final url = _normalizedUrl;
  final name = _nameCtrl.text.trim().isNotEmpty
      ? _nameCtrl.text.trim()
      : (_detectedName ?? _ipCtrl.text.trim());
  final notifier = ref.read(connectionsProvider.notifier);
  if (widget.editing != null) {
    await notifier.update(widget.editing!.copyWith(
      name: name,
      emoji: _emoji,
      url: url,
    ));
  }
  if (mounted) Navigator.of(context).pop();
}
```

- [ ] **Step 4: Update `_openPairSheet`**

Change the return type cast and field name:
```dart
Future<void> _openPairSheet() async {
  final host = _ipCtrl.text.trim();
  final port = int.tryParse(_portCtrl.text.trim()) ?? 8765;
  final scanResult = LanScanResult(
    serverId: '',
    name: _detectedName ?? host,
    host: host,
    port: port,
    version: _detectedVersion ?? '',
    pairingOpen: true,
  );
  final result = await showModalBottomSheet<Connection>(   // was: PairedServer
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => PairSheet(server: scanResult, skipSuccess: true),
  );
  if (!mounted) return;
  if (result == null) {
    setState(() => _phase = _SheetState.input);
    return;
  }
  setState(() {
    _pairedConn = result;           // was: _pairedServer = result
    _nameCtrl.text = result.name;
    _emoji = result.emoji;
    _phase = _SheetState.detected;
  });
}
```

- [ ] **Step 5: Update `_saveAndClose`**

Connection is already saved by `PairSheet._saveImmediately`. Only update name/emoji if changed:
```dart
Future<void> _saveAndClose() async {
  final paired = _pairedConn;     // was: _pairedServer
  if (paired == null) return;
  final name = _nameCtrl.text.trim().isNotEmpty
      ? _nameCtrl.text.trim()
      : paired.name;
  // Only update if name/emoji changed from what PairSheet saved
  if (name != paired.name || _emoji != paired.emoji) {
    await ref.read(connectionsProvider.notifier).update(
      paired.copyWith(name: name, emoji: _emoji),
    );
  }
  if (mounted) Navigator.of(context).pop();
}
```

- [ ] **Step 6: Update `_openQrScan`**

Replace the method (removes `pairedServersProvider`, creates single `Connection`):
```dart
Future<void> _openQrScan() async {
  final result = await Navigator.of(context).push<PawTermQrResult>(
    MaterialPageRoute(builder: (_) => const QrScanScreen()),
  );
  if (result == null || !mounted) return;

  setState(() { _phase = _SheetState.detecting; _errorMsg = null; });
  try {
    final deviceId = await ConnectionsNotifier.getOrCreateDeviceId();
    final deviceName = ConnectionsNotifier.deviceName;
    final claimResp = await http.post(
      Uri.parse('${result.url}/pair/qr-claim'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'deviceId': deviceId,
        'deviceName': deviceName,
        'claim': result.claim,
      }),
    ).timeout(const Duration(seconds: 10));
    if (!mounted) return;
    if (claimResp.statusCode == 200) {
      final body = jsonDecode(claimResp.body) as Map<String, dynamic>;
      final deviceToken = body['deviceToken'] as String;
      final serverId = body['serverId'] as String? ?? '';

      String name = result.url
          .replaceFirst(RegExp(r'^https?://'), '')
          .split(':')
          .first;
      try {
        final healthResp = await http
            .get(Uri.parse('${result.url}/health'))
            .timeout(const Duration(seconds: 5));
        if (healthResp.statusCode == 200) {
          final h = jsonDecode(healthResp.body) as Map<String, dynamic>;
          name = h['hostname'] as String? ?? name;
        }
      } catch (_) {}

      // Check for existing connection with same serverId
      final existing = ref.read(connectionsProvider)
          .where((c) => c.serverId == serverId)
          .firstOrNull;
      if (existing != null) {
        await ref.read(connectionsProvider.notifier).update(
          existing.copyWith(token: deviceToken, url: result.url, lastSeen: DateTime.now()),
        );
      } else {
        await ref.read(connectionsProvider.notifier).add(Connection(
          id: ConnectionsNotifier.newId(),
          name: name,
          emoji: '🖥️',
          url: result.url,
          token: deviceToken,
          serverId: serverId.isNotEmpty ? serverId : null,
          lastSeen: DateTime.now(),
        ));
      }
      if (mounted) Navigator.of(context).pop();
    } else {
      final s = ref.read(stringsProvider);
      setState(() {
        _errorMsg = s.addConnectionServerReturnedTpl.replaceAll('{code}', '${claimResp.statusCode}');
        _phase = _SheetState.error;
      });
    }
  } catch (e) {
    if (!mounted) return;
    final s = ref.read(stringsProvider);
    setState(() { _errorMsg = s.addConnectionUnreachable; _phase = _SheetState.error; });
  }
}
```

- [ ] **Step 7: Update `_openLanScan`**

Replace entirely — much simpler now:
```dart
Future<void> _openLanScan() async {
  await showModalBottomSheet<Connection>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => const LanScanSheet(),
  );
  // Connection already saved to store by PairSheet or LanScanSheet.
  // Just close this sheet regardless of whether we got a result.
  if (mounted) Navigator.of(context).pop();
}
```

- [ ] **Step 8: Fix the detected-state display string**

Find the `_pairedServer != null` check in the build method and update the field reference:
```dart
// Before:
_pairedServer != null

// After:
_pairedConn != null
```

---

## Task 5: Update `connections_screen.dart`

**Files:**
- Modify: `app/lib/screens/connections_screen.dart`

Key changes:
- `List<ServerEntry>` → `List<Connection>`, `ServerEntry?` → `Connection?`, `ServerEntry entry` → `Connection entry`
- Delete action: no cascade (single `remove` call)
- Copy-token action: still works (`entry.token` exists on `Connection`)

- [ ] **Step 1: Update `_ConnectionList`**

```dart
class _ConnectionList extends ConsumerWidget {
  final List<Connection> connections;    // was: List<ServerEntry>
  final Connection? active;             // was: ServerEntry?
  const _ConnectionList({required this.connections, required this.active});
  // ... rest unchanged
}
```

- [ ] **Step 2: Update `_ConnCard`**

```dart
class _ConnCard extends ConsumerWidget {
  final Connection entry;   // was: ServerEntry
  final bool isActive;
  const _ConnCard({required this.entry, required this.isActive});
```

- [ ] **Step 3: Update `_connect`**

Change to `async` and await the push to handle repair result:
```dart
Future<void> _connect(BuildContext context, WidgetRef ref) async {
  ref.read(activeConnectionProvider.notifier).state = entry;
  ref.read(connectionsProvider.notifier).touch(entry.id);
  final result = await Navigator.of(context).push<String>(
    CupertinoPageRoute(builder: (_) => const ProjectPickerScreen()),
  );
  if (result == 'repair' && context.mounted) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const AddConnectionSheet(),
    );
  }
}
```

- [ ] **Step 4: Simplify delete action**

In `_showActions`, replace the delete `onTap` (remove cascade logic, single call):
```dart
onTap: () {
  Navigator.pop(ctx);
  ref.read(connectionsProvider.notifier).remove(entry.id);
  if (ref.read(activeConnectionProvider)?.id == entry.id) {
    ref.read(activeConnectionProvider.notifier).state = null;
  }
},
```

- [ ] **Step 5: Remove `pairedServersProvider` import**

Remove from the import of `server_config.dart` — there's no separate import line, it's already `import '../state/server_config.dart'`. Just ensure no `pairedServersProvider` references remain in the file.

---

## Task 6: Simplify `reconnect_service.dart`

**Files:**
- Full rewrite: `app/lib/state/reconnect_service.dart`

- [ ] **Step 1: Replace the file entirely**

```dart
import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'lan_scanner.dart';
import 'server_config.dart';

enum ReconnectStatus { idle, scanning, found, notFound }

class ReconnectState {
  final ReconnectStatus status;
  final String? updatedConnectionId;   // Connection.id (was: updatedServerId)

  const ReconnectState({
    this.status = ReconnectStatus.idle,
    this.updatedConnectionId,
  });
}

class ReconnectNotifier extends StateNotifier<ReconnectState> {
  final Ref _ref;
  StreamSubscription<List<ConnectivityResult>>? _connSub;
  Timer? _debounce;
  bool _running = false;

  ReconnectNotifier(this._ref) : super(const ReconnectState()) {
    _startListening();
    _scheduleRun(delay: const Duration(seconds: 2));
  }

  void _startListening() {
    _connSub = Connectivity().onConnectivityChanged.listen((results) {
      final hasNetwork = results.any((r) =>
          r == ConnectivityResult.wifi ||
          r == ConnectivityResult.mobile ||
          r == ConnectivityResult.ethernet);
      if (hasNetwork) {
        _debounce?.cancel();
        _debounce = Timer(const Duration(seconds: 2), _run);
      }
    });
  }

  void _scheduleRun({Duration delay = Duration.zero}) {
    Future.delayed(delay, _run);
  }

  Future<void> _run() async {
    if (_running) return;

    // Only consider paired connections (those with a serverId)
    final paired = _ref
        .read(connectionsProvider)
        .where((c) => c.serverId != null)
        .toList();
    if (paired.isEmpty) return;

    _running = true;
    state = const ReconnectState(status: ReconnectStatus.scanning);

    final sweepPorts = <int>{8765, for (final c in paired) c.port};

    String? foundId;
    try {
      await for (final snapshot in LanScanner.scan(ports: sweepPorts)) {
        for (final found in snapshot) {
          final match = paired
              .where((c) => c.serverId == found.serverId)
              .firstOrNull;
          if (match != null) {
            await _ref
                .read(connectionsProvider.notifier)
                .updateUrl(match.id, found.httpBase);
            foundId = match.id;
          }
        }
      }
    } catch (_) {}

    if (foundId != null) {
      state = ReconnectState(
          status: ReconnectStatus.found, updatedConnectionId: foundId);
    } else {
      // Fallback: probe recentHosts for each paired connection
      for (final conn in paired) {
        if (conn.recentHosts.isEmpty) continue;
        final liveHost =
            await LanScanner.probeRecentHosts(conn.recentHosts, conn.port);
        if (liveHost != null) {
          final freshUrl = 'http://$liveHost:${conn.port}';
          await _ref
              .read(connectionsProvider.notifier)
              .updateUrl(conn.id, freshUrl);
          foundId = conn.id;
          break;
        }
      }
      state = foundId != null
          ? ReconnectState(
              status: ReconnectStatus.found, updatedConnectionId: foundId)
          : const ReconnectState(status: ReconnectStatus.notFound);
    }

    _running = false;
  }

  @override
  void dispose() {
    _connSub?.cancel();
    _debounce?.cancel();
    super.dispose();
  }
}

final reconnectProvider =
    StateNotifierProvider<ReconnectNotifier, ReconnectState>(
        (ref) => ReconnectNotifier(ref));
```

---

## Task 7: Fix remaining type annotations

**Files:**
- Modify: `app/lib/screens/project_picker_screen.dart`
- Modify: `app/lib/screens/main_shell.dart`

- [ ] **Step 1: Fix `project_picker_screen.dart` type annotations**

Find and replace the 3 explicit `ServerEntry` annotations:

```dart
// Line ~121 — change method signature:
// Before:
Widget _connectingView(BuildContext context, ServerEntry conn, AppTokens t)
// After:
Widget _connectingView(BuildContext context, Connection conn, AppTokens t)

// Line ~131 — change method signature:
// Before:
Widget _readyView(BuildContext context, ServerEntry conn, AppTokens t)
// After:
Widget _readyView(BuildContext context, Connection conn, AppTokens t)

// Line ~303 — change field in _ConnectingView (or wherever ServerEntry is used as a field type):
// Before:
final ServerEntry conn;
// After:
final Connection conn;
```

Also find `final ServerEntry conn;` in any inner widget class (around line 552) and update:
```dart
// Before:
final ServerEntry conn;
// After:
final Connection conn;
```

- [ ] **Step 2: Fix `main_shell.dart` type annotation**

```dart
// Line ~156:
// Before:
final ServerEntry? conn;
// After:
final Connection? conn;
```

- [ ] **Step 3: Run `flutter analyze` and fix any remaining issues**

Run from the `app/` directory:
```bash
cd app && flutter analyze
```

Expected: no errors. If errors reference `ServerEntry` or `PairedServer`, those are missed type annotations — fix each one. If errors reference `updatedServerId` (old `ReconnectState` field name), those are leftover references to the old field — update to `updatedConnectionId`.

---

## Task 8: 401 in SSE client

**Files:**
- Modify: `app/lib/api/sse_client.dart`

- [ ] **Step 1: Add `__auth_error` on HTTP 401**

In `_connectOnce()`, add the 401 case **before** the existing `statusCode != 200` check:

```dart
// Around line 60, after:
// if (response.statusCode == 412) { ... }

// Add BEFORE the existing "if (response.statusCode != 200)" block:
if (response.statusCode == 401) {
  _events.add(SseEvent(type: '__auth_error', data: 'token rejected by server'));
  _closed = true;   // stop the reconnect loop — auth errors won't fix themselves
  return;
}
```

The existing code around line 65 becomes:
```dart
if (response.statusCode == 412) {
  _events.add(SseEvent(type: '__gap', data: 'event gap, reload required'));
  _closed = true;
  return;
}
if (response.statusCode == 401) {
  _events.add(SseEvent(type: '__auth_error', data: 'token rejected by server'));
  _closed = true;
  return;
}
if (response.statusCode != 200) {
  throw Exception('SSE HTTP ${response.statusCode}');
}
```

---

## Task 9: 401 re-pair flow in `project_picker_screen.dart`

**Files:**
- Modify: `app/lib/screens/project_picker_screen.dart`

- [ ] **Step 1: Add `_needsRepair` flag to state**

In `_ProjectPickerScreenState`, add a field:
```dart
bool _needsRepair = false;
```

- [ ] **Step 2: Update `_checkConnection` to detect 401**

Replace the status-check block in `_checkConnection`:
```dart
// Before:
if (resp.statusCode == 200) {
  setState(() => _phase = _PhaseStatus.ready);
} else {
  setState(() {
    _connectError = '服务端返回 ${resp.statusCode}';
    _phase = _PhaseStatus.failed;
  });
}

// After:
if (resp.statusCode == 200) {
  setState(() { _phase = _PhaseStatus.ready; _needsRepair = false; });
} else if (resp.statusCode == 401) {
  if (!mounted) return;
  setState(() {
    _connectError = '服务端已拒绝令牌，配对信息已失效';
    _phase = _PhaseStatus.failed;
    _needsRepair = true;
  });
} else {
  setState(() {
    _connectError = '服务端返回 ${resp.statusCode}';
    _phase = _PhaseStatus.failed;
    _needsRepair = false;
  });
}
```

- [ ] **Step 3: Pass `needsRepair` and `onRepair` to `_ConnectingView`**

In `_connectingView` method:
```dart
Widget _connectingView(BuildContext context, Connection conn, AppTokens t) {
  return _ConnectingView(
    key: const ValueKey('connecting'),
    conn: conn,
    error: _phase == _PhaseStatus.failed ? _connectError : null,
    needsRepair: _needsRepair,
    onBack: () => Navigator.of(context).pop(),
    onRetry: _checkConnection,
    onRepair: () => Navigator.of(context).pop('repair'),
  );
}
```

- [ ] **Step 4: Update `_ConnectingView` to show "重新配对" button**

Find the `_ConnectingView` widget class and add `needsRepair`, `onRepair` parameters:
```dart
class _ConnectingView extends StatelessWidget {
  final Connection conn;         // was: ServerEntry
  final String? error;
  final bool needsRepair;
  final VoidCallback onBack;
  final VoidCallback onRetry;
  final VoidCallback onRepair;

  const _ConnectingView({
    super.key,
    required this.conn,
    required this.error,
    this.needsRepair = false,
    required this.onBack,
    required this.onRetry,
    required this.onRepair,
  });
  // ...
}
```

In the error state section of `_ConnectingView.build`, add a "重新配对" button when `needsRepair` is true. Locate the retry button in the error display and add beneath it:
```dart
if (error != null) ...[
  // ... existing error text and retry button ...
  if (needsRepair) ...[
    const SizedBox(height: 8),
    FilledButton.icon(
      onPressed: onRepair,
      icon: const Icon(Icons.link_off_rounded, size: 16),
      label: const Text('重新配对'),
      style: FilledButton.styleFrom(
        backgroundColor: const Color(0xFFF59E0B),
        foregroundColor: Colors.white,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    ),
  ],
],
```

---

## Task 10: 401 error banner in `chat_tab.dart`

**Files:**
- Modify: `app/lib/screens/tabs/chat_tab.dart`

- [ ] **Step 1: Add `_authFailed` flag to `_ChatTabState`**

Add a field (alongside existing state fields):
```dart
bool _authFailed = false;
```

Also reset it in `_ensureConnected` / `_startNewSession` where `_subMsgs.clear()` and `_subStreaming.clear()` are:
```dart
_authFailed = false;
```

- [ ] **Step 2: Handle `__auth_error` in `_handleWireMessage`**

In the `switch (event.type)` block, find where `'__client_error'` and `'__gap'` are handled. Add a case before or alongside:

```dart
case '__auth_error':
  _sse?.close();
  setState(() => _authFailed = true);
  return;
```

- [ ] **Step 3: Add auth-failed banner to the build method**

In the `build` method of `_ChatTabState`, find the main `Column` or `Stack` that wraps the chat content. Add the banner as a conditional widget at the top of the chat body (above the message list but below the top bar):

```dart
if (_authFailed)
  Container(
    color: AppTokens.of(context).error.withValues(alpha: 0.1),
    padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
    child: Row(
      children: [
        Icon(Icons.lock_outline, size: 16,
            color: AppTokens.of(context).error),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            '令牌已失效，请重新配对',
            style: TextStyle(
                color: AppTokens.of(context).error,
                fontSize: 13,
                fontWeight: FontWeight.w500),
          ),
        ),
        TextButton(
          onPressed: () =>
              Navigator.of(context).popUntil((route) => route.isFirst),
          style: TextButton.styleFrom(
            foregroundColor: AppTokens.of(context).error,
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
```

- [ ] **Step 4: Run `flutter analyze` to confirm zero errors**

```bash
cd app && flutter analyze
```

Expected output: `No issues found!` (or only the pre-existing `_loadPersistedUuid` unused warning).

---

## Self-Review

### Spec coverage check

| Requirement | Task |
|---|---|
| Merge `PairedServer` + `ServerEntry` into single `Connection` | Task 1 |
| No historical data migration | Task 1 (`connections_v2` key, clean start) |
| LAN scan shows user custom name | Task 3 (`pairedConn?.name`) |
| LAN scan shows user emoji | Task 3 (emoji in avatar) |
| LAN scan shows IP-changed badge | Task 3 (`ipChanged` logic) |
| Delete is a single operation | Task 5 |
| Reconnect service simplified | Task 6 |
| 401 stops SSE retry loop | Task 8 |
| 401 in project picker → re-pair button | Task 9 |
| 401 in chat → banner + back button | Task 10 |

### Type consistency check
- `Connection.id` used as list key throughout ✓
- `Connection.serverId` used for LAN scan matching ✓
- `ConnectionsNotifier.newId()` used in all creation sites ✓
- `ReconnectState.updatedConnectionId` (renamed from `updatedServerId`) — check that no other file reads `updatedServerId` (only `reconnect_service.dart` exposes this, check if anything reads it elsewhere with `grep updatedServerId`)
- `LanScanSheet` return type `Connection?` matches `AddConnectionSheet._openLanScan` cast `showModalBottomSheet<Connection>` ✓
- `PairSheet` return type `Connection?` matches everywhere it's used ✓

### Placeholder check
No TBDs or placeholder patterns found.
