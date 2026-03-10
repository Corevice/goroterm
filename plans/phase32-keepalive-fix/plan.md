---
goal: "Phase 32 - バックグラウンド接続維持の根本修正（initCommunicationPort + TCP keepalive + SSH keepalive 短縮）"
verifyCommands:
  - ~/flutter/bin/flutter analyze
  - ~/flutter/bin/flutter test
  - ~/flutter/bin/flutter build apk --debug
maxAttempts: 5
executeModel: claude-sonnet-4-6
evaluateModel: claude-sonnet-4-6
---

# Phase 32: バックグラウンド接続維持の根本修正

全体の実装計画は `plans/terminal-ssh-app/implementation-plan.md` を参照すること。
Flutter SDK は `~/flutter/bin/flutter` にある（PATH に含まれていないため、フルパスで実行すること）。

---

## 問題

アプリがバックグラウンドに移行すると SSH 接続が切れ、フォアグラウンド復帰時にリコネクトが発生する。
フォアグラウンドサービス（WAKE_LOCK + WIFI_LOCK + バッテリー最適化除外）を導入済みだが、接続は維持されない。

---

## 根本原因分析

### 原因 1（致命的）: `FlutterForegroundTask.initCommunicationPort()` が呼ばれていない

`lib/main.dart` で `SshForegroundService.init()` を呼んでいるが、`FlutterForegroundTask.initCommunicationPort()` が **一度も呼ばれていない**。

flutter_foreground_task のアーキテクチャ:
- `sendDataToMain(data)` は `IsolateNameServer.lookupPortByName(_kPortName)` で `SendPort` を取得
- `initCommunicationPort()` がこの名前付きポートを登録する
- **呼ばれていないため、`lookupPortByName()` は常に null を返し、`sendPort?.send(data)` は no-op**

結果:
- サービス Isolate の 10 秒ごとの `'keepalive'` → **全部捨てられている**
- `terminal_screen.dart` の `_onTaskData` → **一度も呼ばれない**
- `activeKeepAlive()` → **バックグラウンドでは一度も実行されない**
- SSH 接続の存続は dartssh2 の `keepAliveInterval: 15秒` のみに依存

**証拠**: `lib/` 以下に `initCommunicationPort` の呼び出しが一切ない:
```bash
grep -r "initCommunicationPort" lib/  # → 結果なし
```

flutter_foreground_task の README と example では `main()` 内で呼ぶことが必須とされている:
```dart
// example/lib/main.dart
void main() {
  FlutterForegroundTask.initCommunicationPort();
  runApp(const ExampleApp());
}
```

### 原因 2: TCP レベルの keepalive が設定されていない

dartssh2 の SSH レベル keepalive (SSH_MSG_GLOBAL_REQUEST) は Dart のイベントループから送信される。
バックグラウンドではイベントループが Android OS にスロットルされ、タイマーが遅延する可能性がある。

一方、**TCP keepalive は OS カーネルレベル**で動作するため、Dart のイベントループが止まっていても OS が自動的に keepalive パケットを送信する。これにより:
- NAT テーブルのエントリが維持される
- 中間ルーター/ファイアウォールが接続をタイムアウトしない
- 死んだ接続が OS レベルで検出される

現在のコードでは `SSHSocket.connect()` を使っており、内部の `dart:io Socket` に対する TCP keepalive 設定ができない。

### 原因 3: SSH keepAliveInterval が 15 秒で長すぎる可能性

モバイルキャリアの NAT テーブルタイムアウトは 30 秒〜60 秒と短い場合がある。
15 秒間隔でも、バックグラウンドでのタイマー遅延を加味すると実効間隔が 20-30 秒以上になり得る。

---

## 修正方針

### Fix 1: `initCommunicationPort()` を `main.dart` で呼ぶ

最も重要かつ簡単な修正。これにより service isolate → main isolate の通信が有効になり、
`activeKeepAlive()` がバックグラウンドで実行されるようになる。

### Fix 2: TCP keepalive 付きカスタム SSHSocket を実装

dartssh2 の `SSHSocket` は abstract class で、カスタム実装を `SSHClient` に渡せる。
`dart:io Socket` を直接生成し、`setRawOption()` で TCP keepalive を有効化してからラップする。

### Fix 3: SSH keepAliveInterval を 10 秒に短縮

dartssh2 のデフォルトは 10 秒だが、現在のコードでは 15 秒に設定している。10 秒に戻す。

---

## 変更対象ファイル

1. `lib/main.dart` — 修正（1行追加）
2. `lib/core/ssh/keepalive_ssh_socket.dart` — **新規作成**
3. `lib/core/ssh/ssh_client_service.dart` — 修正

---

## Step 1: `initCommunicationPort()` を `main.dart` に追加

### ファイル: `lib/main.dart`

**before:**
```dart
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'dart:io';

import 'app.dart';
import 'core/background/ssh_foreground_service.dart';
import 'core/storage/database.dart';
import 'features/connections/connection_provider.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SshForegroundService.init();

  final dbFolder = await getApplicationDocumentsDirectory();
  final file = File(p.join(dbFolder.path, 'terminal_ssh.db'));
  final db = AppDatabase(NativeDatabase(file));

  runApp(
    ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(db),
      ],
      child: const TerminalSshApp(),
    ),
  );
}
```

**after:**
```dart
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'dart:io';

import 'app.dart';
import 'core/background/ssh_foreground_service.dart';
import 'core/storage/database.dart';
import 'features/connections/connection_provider.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  FlutterForegroundTask.initCommunicationPort();
  SshForegroundService.init();

  final dbFolder = await getApplicationDocumentsDirectory();
  final file = File(p.join(dbFolder.path, 'terminal_ssh.db'));
  final db = AppDatabase(NativeDatabase(file));

  runApp(
    ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(db),
      ],
      child: const TerminalSshApp(),
    ),
  );
}
```

**変更点:**
- `import 'package:flutter_foreground_task/flutter_foreground_task.dart';` を追加
- `FlutterForegroundTask.initCommunicationPort();` を `SshForegroundService.init()` の前に追加

---

## Step 2: TCP keepalive 付きカスタム SSHSocket の実装

### 新規ファイル: `lib/core/ssh/keepalive_ssh_socket.dart`

dartssh2 の `SSHSocket` を実装し、`dart:io Socket` に TCP keepalive を設定する。

```dart
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

/// TCP keepalive を有効にした SSH ソケット。
/// OS カーネルレベルで keepalive パケットを送信するため、
/// Dart イベントループがスロットルされたバックグラウンドでも接続が維持される。
class KeepaliveSSHSocket implements SSHSocket {
  KeepaliveSSHSocket._(this._socket);

  final Socket _socket;

  /// TCP keepalive を有効にして接続する。
  static Future<KeepaliveSSHSocket> connect(
    String host,
    int port, {
    Duration? timeout,
  }) async {
    final socket = await Socket.connect(host, port, timeout: timeout);

    // TCP_NODELAY（dartssh2 デフォルトと同じ）
    socket.setOption(SocketOption.tcpNoDelay, true);

    // SO_KEEPALIVE を有効化（Linux: SOL_SOCKET=1, SO_KEEPALIVE=9）
    try {
      socket.setRawOption(
        RawSocketOption.fromBool(RawSocketOption.levelSocket, 9, true),
      );

      // TCP_KEEPIDLE: 最初の keepalive パケットまでのアイドル時間（秒）
      // 60 秒: モバイル NAT の一般的なタイムアウト (30-120秒) に対応
      // Linux: IPPROTO_TCP=6, TCP_KEEPIDLE=4
      socket.setRawOption(
        RawSocketOption.fromInt(RawSocketOption.levelTcp, 4, 60),
      );

      // TCP_KEEPINTVL: keepalive パケットの再送間隔（秒）
      // Linux: IPPROTO_TCP=6, TCP_KEEPINTVL=5
      socket.setRawOption(
        RawSocketOption.fromInt(RawSocketOption.levelTcp, 5, 10),
      );

      // TCP_KEEPCNT: 応答がない場合の最大再送回数
      // Linux: IPPROTO_TCP=6, TCP_KEEPCNT=6
      socket.setRawOption(
        RawSocketOption.fromInt(RawSocketOption.levelTcp, 6, 5),
      );
    } catch (_) {
      // プラットフォームが raw socket option をサポートしない場合は無視
      // （SSH レベルの keepalive がフォールバックとして動作する）
    }

    return KeepaliveSSHSocket._(socket);
  }

  @override
  Stream<Uint8List> get stream => _socket;

  @override
  StreamSink<List<int>> get sink => _socket;

  @override
  Future<void> get done => _socket.done;

  @override
  Future<void> close() => _socket.close();

  @override
  void destroy() => _socket.destroy();
}
```

**TCP keepalive パラメータの意味:**
- `TCP_KEEPIDLE = 60秒`: 60 秒データ送受信がなければ keepalive プローブ開始
- `TCP_KEEPINTVL = 10秒`: プローブの再送間隔
- `TCP_KEEPCNT = 5回`: 5 回連続失敗で接続を死亡と判定
- 合計: 最悪でも 60 + (10 × 5) = 110 秒で死んだ接続を検出

---

## Step 3: `ssh_client_service.dart` でカスタムソケットを使用 + keepalive 間隔短縮

### ファイル: `lib/core/ssh/ssh_client_service.dart`

**before:**
```dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

import 'connection_config.dart';
import 'known_hosts_store.dart';
import '../error/app_error.dart';

class SshClientService {
  SshClientService({required this.knownHostsStore});

  final KnownHostsStore knownHostsStore;
  SSHClient? _client;

  SSHClient? get client => _client;
  bool get isConnected => _client != null && !_client!.isClosed;

  Future<SSHClient> connect({
    required ConnectionConfig config,
    required String? password,
    String? privateKeyPem,
    String? passphrase,
    Future<bool> Function(String fingerprint)? onUnknownHostKey,
    Future<bool> Function(String storedFingerprint, String actualFingerprint)?
        onHostKeyMismatch,
  }) async {
    try {
      final socket = await SSHSocket.connect(
        config.host,
        config.port,
        timeout: const Duration(seconds: 10),
      );

      _client = SSHClient(
        socket,
        username: config.username,
        onPasswordRequest: config.authMethod == AuthMethod.password
            ? () => password
            : null,
        identities: config.authMethod == AuthMethod.key && privateKeyPem != null
            ? SSHKeyPair.fromPem(privateKeyPem, passphrase)
            : null,
        onVerifyHostKey: (type, fingerprint) async {
          return _verifyHostKey(
            config.host,
            config.port,
            fingerprint,
            onUnknownHostKey: onUnknownHostKey,
            onHostKeyMismatch: onHostKeyMismatch,
          );
        },
        keepAliveInterval: const Duration(seconds: 15),
      );

      await _client!.authenticated;
      return _client!;
    } on SocketException catch (e) {
      throw NetworkError(e.message);
    } on SSHAuthFailError {
      throw const AuthenticationError('Authentication failed');
    } on SSHAuthAbortError {
      throw const AuthenticationError('Authentication aborted');
    } on TimeoutException {
      throw const NetworkError('Connection timed out');
    }
  }
```

**after:**
```dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

import 'connection_config.dart';
import 'keepalive_ssh_socket.dart';
import 'known_hosts_store.dart';
import '../error/app_error.dart';

class SshClientService {
  SshClientService({required this.knownHostsStore});

  final KnownHostsStore knownHostsStore;
  SSHClient? _client;

  SSHClient? get client => _client;
  bool get isConnected => _client != null && !_client!.isClosed;

  Future<SSHClient> connect({
    required ConnectionConfig config,
    required String? password,
    String? privateKeyPem,
    String? passphrase,
    Future<bool> Function(String fingerprint)? onUnknownHostKey,
    Future<bool> Function(String storedFingerprint, String actualFingerprint)?
        onHostKeyMismatch,
  }) async {
    try {
      // TCP keepalive 付きカスタムソケットを使用。
      // OS カーネルがバックグラウンドでも keepalive パケットを送信し、
      // NAT テーブルの有効期限切れを防ぐ。
      final socket = await KeepaliveSSHSocket.connect(
        config.host,
        config.port,
        timeout: const Duration(seconds: 10),
      );

      _client = SSHClient(
        socket,
        username: config.username,
        onPasswordRequest: config.authMethod == AuthMethod.password
            ? () => password
            : null,
        identities: config.authMethod == AuthMethod.key && privateKeyPem != null
            ? SSHKeyPair.fromPem(privateKeyPem, passphrase)
            : null,
        onVerifyHostKey: (type, fingerprint) async {
          return _verifyHostKey(
            config.host,
            config.port,
            fingerprint,
            onUnknownHostKey: onUnknownHostKey,
            onHostKeyMismatch: onHostKeyMismatch,
          );
        },
        keepAliveInterval: const Duration(seconds: 10),
      );

      await _client!.authenticated;
      return _client!;
    } on SocketException catch (e) {
      throw NetworkError(e.message);
    } on SSHAuthFailError {
      throw const AuthenticationError('Authentication failed');
    } on SSHAuthAbortError {
      throw const AuthenticationError('Authentication aborted');
    } on TimeoutException {
      throw const NetworkError('Connection timed out');
    }
  }
```

**変更点:**
- `import 'keepalive_ssh_socket.dart';` を追加
- `SSHSocket.connect(...)` → `KeepaliveSSHSocket.connect(...)` に変更
- `keepAliveInterval: const Duration(seconds: 15)` → `const Duration(seconds: 10)` に短縮

---

## 変更まとめ

| ファイル | 変更内容 | 効果 |
|---|---|---|
| `lib/main.dart` | `initCommunicationPort()` 追加 | サービス→メインの通信が有効化。`activeKeepAlive()` がバックグラウンドで動作 |
| `lib/core/ssh/keepalive_ssh_socket.dart` | 新規作成: TCP keepalive 付きソケット | OS カーネルがバックグラウンドでも keepalive を送信。NAT 維持 |
| `lib/core/ssh/ssh_client_service.dart` | カスタムソケット使用 + 間隔短縮 | TCP + SSH 両レベルで接続を維持 |

## 三層 keepalive の全体像（修正後）

```
層1: TCP keepalive（OS カーネル）
  - TCP_KEEPIDLE=60s → TCP_KEEPINTVL=10s × TCP_KEEPCNT=5
  - Dart イベントループが停止していても動作
  - NAT テーブル維持 + 死んだ接続の OS レベル検出

層2: SSH keepalive（dartssh2）
  - keepAliveInterval=10s → SSH_MSG_GLOBAL_REQUEST パケット
  - サーバーが応答しなければ dartssh2 が切断を検出
  - Dart イベントループが動いている必要あり

層3: アプリレベル keepalive（flutter_foreground_task → activeKeepAlive）
  - 30 秒ごとに execute('true') を実行
  - SSH チャネルの開閉で双方向の生存確認
  - 最も信頼性が高いが最もコストが高い
  - ★ initCommunicationPort() 修正でようやく動作する
```

---

## 検証手順

1. `~/flutter/bin/flutter analyze` — 静的解析エラーなし
2. `~/flutter/bin/flutter test` — 既存テスト全パス
3. `~/flutter/bin/flutter build apk --debug` — ビルド成功
4. 実機テスト:
   - SSH 接続してバックグラウンドに移行 → 30 秒後にフォアグラウンドに戻る → リコネクト **発生しない**
   - SSH 接続してバックグラウンドに移行 → 2 分後にフォアグラウンドに戻る → リコネクト **発生しない**
   - SSH 接続してバックグラウンドに移行 → 5 分後にフォアグラウンドに戻る → 接続維持またはバックグラウンドでの自動リコネクト済み
   - ターミナル操作（コマンド入力、出力表示）が正常に動作
   - Wi-Fi オフ → オン → しばらく待つ → 自動リコネクト成功
