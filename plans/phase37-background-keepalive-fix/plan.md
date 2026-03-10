---
goal: "Phase 37 - バックグラウンド接続維持の強化（TCP keepalive 調整 + keepalive 頻度向上 + ログ追加）"
verifyCommands:
  - ~/flutter/bin/flutter analyze
  - ~/flutter/bin/flutter test
  - ~/flutter/bin/flutter build apk --debug
maxAttempts: 5
executeModel: claude-sonnet-4-6
evaluateModel: claude-sonnet-4-6
---

# Phase 37: バックグラウンド接続維持の強化

全体の実装計画は `plans/terminal-ssh-app/implementation-plan.md` を参照すること。
Flutter SDK は `~/flutter/bin/flutter` にある（PATH に含まれていないため、フルパスで実行すること）。

---

## 問題

Phase 32 で以下の対策を実施したが、数分バックグラウンドにするとまだ接続が切れる:
- `FlutterForegroundTask.initCommunicationPort()` 追加
- TCP keepalive（`KeepaliveSSHSocket`）
- SSH keepalive interval 10 秒

## 根本原因分析

### 原因 1: TCP_KEEPIDLE が 60 秒は長すぎる

モバイルキャリアの NAT テーブルは **30〜60 秒**でタイムアウトするものがある。
`TCP_KEEPIDLE=60` では、アイドル開始から最初の TCP keepalive パケット送信まで
60 秒かかるため、NAT エントリが消えてから送信することになり手遅れ。

### 原因 2: activeKeepAlive が 30 秒間隔で不十分

現在の `terminal_screen.dart` の `_onTaskData`:

```dart
_keepAliveCounter++;
if (_keepAliveCounter % 3 == 0) {
  // 30秒に1回だけ activeKeepAlive（exec チャネル）
  activeKeepAlive();
} else {
  // 他は lightHealthCheck（isConnected フラグのみ）
  lightHealthCheck();
}
```

- `lightHealthCheck()` は `_sshService!.isConnected` フラグを見るだけ — **ネットワークパケットを送信しない**
- Dart イベントループがスロットルされたバックグラウンドでは、dartssh2 の `keepAliveInterval: 10s`（Dart Timer ベースの SSH_MSG_IGNORE）も遅延する
- 結果: 実質的にネットワークパケットが送信されるのは 30 秒に 1 回の `execute('true')` だけ
- NAT の 30 秒タイムアウトに間に合わない可能性がある

### 原因 3: setRawOption のサイレント失敗

`KeepaliveSSHSocket` で TCP keepalive を設定する `setRawOption` は全例外を `catch (_) {}` で握り潰している。
Android のカーネルバージョンやセキュリティポリシーによっては、`setRawOption` が `SocketException` を投げる可能性がある。
この場合、TCP keepalive が**全く有効になっていない**のに気づけない。

---

## 修正方針

1. **TCP_KEEPIDLE を 15 秒に短縮** — NAT テーブル消失前に keepalive パケットを送信
2. **activeKeepAlive を毎 10 秒に変更** — counter%3 を廃止し、毎回 exec keepalive を実行
3. **setRawOption の結果をログ出力** — TCP keepalive が実際に有効になったか確認可能にする
4. **lightHealthCheck で activeKeepAlive にフォールバック** — isConnected が true でも定期的にパケットを送信

---

## 実装手順

### ステップ 1: TCP_KEEPIDLE を 60 → 15 秒に短縮

**ファイル:** `lib/core/ssh/keepalive_ssh_socket.dart`

```dart
// BEFORE:
      // TCP_KEEPIDLE: 最初の keepalive パケットまでのアイドル時間（秒）
      // 60 秒: モバイル NAT の一般的なタイムアウト (30-120秒) に対応
      // Linux: IPPROTO_TCP=6, TCP_KEEPIDLE=4
      socket.setRawOption(
        RawSocketOption.fromInt(RawSocketOption.levelTcp, 4, 60),
      );

// AFTER:
      // TCP_KEEPIDLE: 最初の keepalive パケットまでのアイドル時間（秒）
      // 15 秒: モバイル NAT の最短タイムアウト (30秒) より十分短い値。
      // NAT エントリが消える前に keepalive パケットが送信される。
      // Linux/Android: IPPROTO_TCP=6, TCP_KEEPIDLE=4
      socket.setRawOption(
        RawSocketOption.fromInt(RawSocketOption.levelTcp, 4, 15),
      );
```

---

### ステップ 2: setRawOption のエラーログ追加

**ファイル:** `lib/core/ssh/keepalive_ssh_socket.dart`

```dart
// BEFORE:
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

// AFTER:
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';
```

```dart
// BEFORE:
    } catch (_) {
      // プラットフォームが raw socket option をサポートしない場合は無視
      // （SSH レベルの keepalive がフォールバックとして動作する）
    }

// AFTER:
    } catch (e) {
      // プラットフォームが raw socket option をサポートしない場合。
      // SSH レベルの keepalive がフォールバックとして動作するが、
      // バックグラウンドでは Dart Timer が遅延するため信頼性が低下する。
      debugPrint('TCP keepalive setup failed: $e');
    }
```

---

### ステップ 3: activeKeepAlive を毎 10 秒に変更

**ファイル:** `lib/features/terminal/terminal_screen.dart`

counter%3 のロジックを廃止し、毎回 activeKeepAlive を実行する。
`execute('true')` の SSH チャネル消費は小さく（open→close で完了）、
10 秒間隔なら過負荷にならない。

```dart
// BEFORE:
  int _keepAliveCounter = 0;

  void _onTaskData(Object data) {
    if (data == 'keepalive' && mounted) {
      _keepAliveCounter++;
      final managerState = ref.read(sessionManagerProvider);
      if (_keepAliveCounter % 3 == 0) {
        // 3回に1回（約30秒間隔）だけ能動的 keepalive（exec チャネル）
        // 毎回 exec すると SSH チャネル消費が多すぎるため
        for (final session in managerState.sessions) {
          ref
              .read(terminalConnectionProvider(session.sessionId).notifier)
              .activeKeepAlive();
        }
      } else {
        // 通常は軽量な isConnected フラグチェックのみ
        for (final session in managerState.sessions) {
          ref
              .read(terminalConnectionProvider(session.sessionId).notifier)
              .lightHealthCheck();
        }
      }
    }
  }

// AFTER:
  void _onTaskData(Object data) {
    if (data == 'keepalive' && mounted) {
      final managerState = ref.read(sessionManagerProvider);
      // 毎回（10秒間隔）activeKeepAlive を実行。
      // SSH exec チャネルでネットワークパケットを送信し、
      // NAT テーブルを維持し続ける。
      // execute('true') は軽量（open→close）なので 10 秒間隔なら過負荷にならない。
      for (final session in managerState.sessions) {
        ref
            .read(terminalConnectionProvider(session.sessionId).notifier)
            .activeKeepAlive();
      }
    }
  }
```

**注意:** `_keepAliveCounter` フィールドは使われなくなるので削除すること。

---

### ステップ 4: activeKeepAlive の SSH keepalive タイムアウト短縮

**ファイル:** `lib/features/terminal/terminal_connection_provider.dart`

バックグラウンドで Dart Timer が遅延する場合、`keepAlive()` のデフォルトタイムアウト（5秒）でも
イベントループが詰まって timeout が発火しない可能性がある。
ただし、これ以上短くするとネットワーク遅延でフォールスポジティブが増えるため、
代わりに activeKeepAlive の連続失敗閾値を調整する。

現在の実装は Phase 34 で連続 2 回失敗を要求しているが、
10 秒ごとに実行するようになるので、1 回失敗でも 10 秒後にリトライされる。
閾値は 3 回に引き上げて、30 秒以内の一時的な遅延を吸収する。

```dart
// BEFORE (_activeKeepAliveCore 内):
      } else if (!alive) {
        // 1 回の失敗では再接続しない。一時的なネットワーク遅延を吸収する。
        // 連続 2 回失敗したら切断と判定する。
        _keepAliveFailCount++;
        if (_keepAliveFailCount >= 2) {
          _keepAliveFailCount = 0;
          _onDisconnected();
        }
      }

// AFTER:
      } else if (!alive) {
        // 1〜2 回の失敗では再接続しない。一時的なネットワーク遅延を吸収する。
        // keepalive は 10 秒ごとに実行されるため、連続 3 回失敗（30 秒間応答なし）
        // で切断と判定する。
        _keepAliveFailCount++;
        if (_keepAliveFailCount >= 3) {
          _keepAliveFailCount = 0;
          _onDisconnected();
        }
      }
```

---

### ステップ 5: フォアグラウンドサービスの repeat 間隔を確認・維持

**ファイル:** `lib/core/background/ssh_foreground_service.dart`

現在 `ForegroundTaskEventAction.repeat(10000)` で 10 秒間隔。これは維持する。
変更なし（確認のみ）。

---

## 変更ファイル一覧

| ファイル | 変更内容 |
|---------|---------|
| `lib/core/ssh/keepalive_ssh_socket.dart` | TCP_KEEPIDLE 60→15 秒 + debugPrint 追加 + import 追加 |
| `lib/features/terminal/terminal_screen.dart` | counter%3 廃止、毎回 activeKeepAlive + `_keepAliveCounter` 削除 |
| `lib/features/terminal/terminal_connection_provider.dart` | keepAlive 連続失敗閾値 2→3 回 |

---

## 検証項目

1. `~/flutter/bin/flutter analyze` — 静的解析エラーなし
2. `~/flutter/bin/flutter test` — 全テスト通過
3. `~/flutter/bin/flutter build apk --debug` — デバッグビルド成功
4. **手動テスト（デバイス）:**
   - SSH 接続してバックグラウンドに移動、5 分後にフォアグラウンドに戻って接続維持を確認
   - logcat で `TCP keepalive setup failed` が出力されないことを確認（TCP keepalive が有効）
   - 接続中に Wi-Fi を一瞬 OFF→ON して、30 秒以内に復帰すれば再接続されないことを確認

---

## 技術的補足

### なぜ TCP keepalive が最も重要か

Android バックグラウンドでは、アプリの Dart イベントループがスロットルされる:
- Dart の `Timer`（dartssh2 の `keepAliveInterval: 10s`）→ 遅延する
- Dart の `Future`（`execute('true')` による activeKeepAlive）→ 遅延する
- OS カーネルの TCP keepalive → **遅延しない**（カーネルレベルで実行）

TCP keepalive はアプリのプロセスとは独立してカーネルが送信するため、
Dart イベントループが完全に停止していても NAT テーブルを維持できる。
`TCP_KEEPIDLE=15` なら、アイドルから 15 秒後にカーネルが自動でパケットを送信する。

### activeKeepAlive を毎 10 秒にしても大丈夫な理由

- `execute('true')` は SSH チャネルを 1 つ open → exit → close するだけ
- 転送データは数十バイト（SSH ヘッダのみ）
- サーバー側の負荷もほぼゼロ（`true` は即座に終了する組み込みコマンド）
- 毎 10 秒でもセッション数 × 数十バイト/10秒 = 実質的に帯域消費なし
