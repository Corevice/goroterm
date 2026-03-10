---
goal: "Phase 34 - 復帰時の不要な再接続防止 + 重いファイルダウンロード中の UI フリーズ修正"
verifyCommands:
  - ~/flutter/bin/flutter analyze
  - ~/flutter/bin/flutter test
  - ~/flutter/bin/flutter build apk --debug
  - ~/flutter/bin/flutter build apk --release
maxAttempts: 5
executeModel: claude-sonnet-4-6
evaluateModel: claude-sonnet-4-6
---

# Phase 34: 復帰時の不要な再接続防止 + ダウンロード中 UI フリーズ修正

全体の実装計画は `plans/terminal-ssh-app/implementation-plan.md` を参照すること。
Flutter SDK は `~/flutter/bin/flutter` にある（PATH に含まれていないため、フルパスで実行すること）。

---

## 問題

1. **アプリが復帰したときに再接続されて元のコネクション（PTY セッション）が失われる**
2. **重いファイルのダウンロード中に UI がフリーズする**（ダウンロード自体は進んでいる）

---

## 根本原因分析

### 問題 1: 復帰時の不要な再接続

Phase 29 で `_lastAliveConfirmed` による 10 秒キャッシュを導入済み。
Phase 32 で `initCommunicationPort()` を修正し、`activeKeepAlive()` が 30 秒ごとにバックグラウンドで動くようになった。

しかし以下の問題が残る:

#### 原因 A: `_lastAliveConfirmed` のスキップ窓 10 秒が短すぎる

`activeKeepAlive()` は **30 秒ごと**に実行される（サービスの 10 秒イベント × 3 回に 1 回）。
つまり `_lastAliveConfirmed` は最新でも **30 秒前**のタイムスタンプになる。

`checkConnection()` のスキップ条件は「10 秒以内」なので、**ほぼ毎回スキップされずに `keepAlive()` が実行される**。

```dart
// terminal_connection_provider.dart:329-333
if (_lastAliveConfirmed != null &&
    DateTime.now().difference(_lastAliveConfirmed!) <
        const Duration(seconds: 10)) {  // ← 30秒間隔のため、ほぼ常にスキップされない
  return;
}
```

#### 原因 B: Wi-Fi 復帰の遅延で `keepAlive()` がタイムアウトする

バックグラウンドから復帰直後は Wi-Fi が省電力モードから復帰するまで 1-3 秒かかる。
この間に `keepAlive()` が実行されると、`execute('true')` がハングする。

現在のタイムアウトは 10 秒だが、Wi-Fi 復帰 + SSH ハンドシェイクに必要な時間が微妙にオーバーする場合がある。
タイムアウトすると `_cleanupConnections()` → `reconnect()` → **新しい PTY セッション = 元のシェル状態を喪失**。

#### 原因 C: `_onDisconnected()` がバックグラウンドで即座に `reconnect()` を呼ぶ

バックグラウンドで一瞬でもネットワークが不安定になると:
1. `lightHealthCheck()` または `activeKeepAlive()` が切断を検知
2. `_onDisconnected()` → 即座に `reconnect()`
3. reconnect が成功 → 新しい SSH 接続 + 新しい PTY チャネル
4. 元の PTY セッション（シェルの状態、カレントディレクトリ等）は失われる

**接続が一時的に不安定なだけでも、既存の PTY を破棄して新規 PTY を作ってしまう。**

#### 原因 D: `keepAlive()` が 1 回失敗しただけで再接続をトリガーする

`checkConnection()` と `_activeKeepAliveCore()` の両方で、`keepAlive()` が 1 回 `false` を返しただけで `_onDisconnected()` を呼ぶ。一時的なネットワーク遅延でも再接続が発火する。

---

### 問題 2: 重いファイルダウンロード中の UI フリーズ

Phase 31 で `FileWriterIsolate`（ファイル I/O のオフロード）と Kotlin coroutines（MediaStore コピーのバックグラウンド化）を実装済み。

しかし以下が**まだメインアイソレートで実行されている**:

#### 原因 E: dartssh2 の SSH パケット処理がメインアイソレートを占有

- SSH ストリームの受信 → 復号 → 解凍 → チャネルデータのパースはすべてメインアイソレートで実行
- 高速ダウンロード時、dartssh2 がイベントループを連続的に占有し、UI フレーム描画の時間がない
- `writer.addChunk(chunk)` の `SendPort.send(Uint8List)` も、大きな chunk のコピーコストがある

#### 原因 F: ストリームリスナーが同期的に連続実行される

`execSession.stdout.listen((chunk) { ... })` は、ストリームにバッファされたデータがある限り同期的にコールバックを連続呼び出しする。UI のフレーム描画（16ms ごと）に割り込む隙間がない。

dartssh2 の SSH ウィンドウサイズはデフォルト 2MB（`localInitialWindowSize`）。
ストリームが一度も pause されない限り、2MB 分のデータが連続でリスナーに到着する。

---

## 修正方針

### Fix 1: `_lastAliveConfirmed` のスキップ窓を拡大（10秒 → 45秒）

`activeKeepAlive()` が 30 秒ごとに実行されるため、スキップ窓を 45 秒に拡大する。
これにより、バックグラウンドでの keepalive 成功から 45 秒以内の復帰は probe をスキップする。

### Fix 2: `keepAlive()` 失敗時にリトライしてから再接続を判断する

`checkConnection()` で `keepAlive()` が失敗した場合、即座に再接続せず **1 秒待ってからもう 1 回リトライ**する。
Wi-Fi 復帰の遅延による一時的な失敗を吸収する。

### Fix 3: `_onDisconnected()` での即時 reconnect を遅延化する

`_onDisconnected()` で即座に `reconnect()` を呼ぶのではなく、**2 秒の遅延を入れてから接続状態を再確認**する。
一時的なネットワーク不安定で PTY セッションを無駄に破棄するのを防ぐ。

### Fix 4: `activeKeepAlive()` でも失敗閾値を導入する

`_activeKeepAliveCore()` で `keepAlive()` が失敗しても、**連続 2 回失敗するまでは `_onDisconnected()` を呼ばない**。
単発のタイムアウトでは再接続しない。

### Fix 5: ダウンロードストリームに定期的な pause/resume を導入する

SSH ストリームリスナー内で、一定量のデータ受信ごとにストリームを一時停止し、`await Future.delayed(Duration.zero)` でイベントループに制御を返す。UI フレーム描画の時間を確保する。

### Fix 6: 進捗更新の頻度を下げる（200ms → 500ms）

進捗タイマーの `state = AsyncData(...)` は Riverpod のリビルドを発火する。
重いダウンロード中はこの頻度を下げて UI スレッドの負荷を軽減する。

---

## 変更対象ファイル

1. `lib/features/terminal/terminal_connection_provider.dart` — 修正
2. `lib/features/file_browser/file_browser_provider.dart` — 修正

---

## Step 1: 復帰時の不要な再接続を防止

### ファイル: `lib/features/terminal/terminal_connection_provider.dart`

#### 1-1. `_keepAliveFailCount` フィールドを追加

**before (フィールド宣言部分):**
```dart
  bool _isActiveKeepAliveRunning = false;
```

**after:**
```dart
  bool _isActiveKeepAliveRunning = false;
  int _keepAliveFailCount = 0;
```

#### 1-2. `_onDisconnected()` に遅延確認を追加

**before:**
```dart
  void _onDisconnected() {
    // 再接続中なら無視（reconnect() が完了を処理する）
    if (state.status == ConnectionStatus.reconnecting) return;
    // 既に切断状態なら無視
    if (state.status == ConnectionStatus.disconnected) return;
    _lastAliveConfirmed = null;
    state = state.copyWith(
      status: ConnectionStatus.disconnected,
      errorMessage: 'Connection lost',
      clearChannelManager: true,
    );
    // バックグラウンドでも即座に再接続を試みる
    // フォアグラウンドサービスが動いている限りプロセスは生きている
    if (_config != null) {
      reconnect();
    }
  }
```

**after:**
```dart
  void _onDisconnected() {
    // 再接続中なら無視（reconnect() が完了を処理する）
    if (state.status == ConnectionStatus.reconnecting) return;
    // 既に切断状態なら無視
    if (state.status == ConnectionStatus.disconnected) return;
    _lastAliveConfirmed = null;
    _keepAliveFailCount = 0;
    state = state.copyWith(
      status: ConnectionStatus.disconnected,
      errorMessage: 'Connection lost',
      clearChannelManager: true,
    );
    // 一時的なネットワーク不安定で PTY セッションを無駄に破棄しないよう、
    // 2 秒遅延してから接続状態を再確認して reconnect する。
    if (_config != null) {
      Future.delayed(const Duration(seconds: 2), () {
        // 遅延中に既に reconnect/connect が始まっていたら何もしない
        if (state.status == ConnectionStatus.reconnecting ||
            state.status == ConnectionStatus.connecting ||
            state.status == ConnectionStatus.connected) {
          return;
        }
        reconnect();
      });
    }
  }
```

#### 1-3. `checkConnection()` のスキップ窓を 45 秒に拡大 + リトライロジック追加

**before:**
```dart
      // ケース A: state が connected — 本当に生きているか確認
      if (_sshService != null && _sshService!.isConnected) {
        // 最後の確認から 10 秒以内なら probe をスキップ
        // （keepalive / reconnect で確認済み）
        if (_lastAliveConfirmed != null &&
            DateTime.now().difference(_lastAliveConfirmed!) <
                const Duration(seconds: 10)) {
          return;
        }

        try {
          // keepAlive() は `true` コマンドを exec して session.done を待つだけ。
          // stdout を await ...join() で読まないため dartssh2 の Channel_Close
          // バグによるハングリスクが低い。
          // バックグラウンド復帰直後は Wi-Fi 再接続に時間がかかるため
          // タイムアウトを 10 秒に延長する。
          final service = _sshService!;
          final alive = await service.keepAlive(
            executeTimeout: const Duration(seconds: 10),
            doneTimeout: const Duration(seconds: 10),
          );
          if (alive && identical(service, _sshService)) {
            _lastAliveConfirmed = DateTime.now();
            return; // 生きている
          }
        } catch (_) {
          // keepAlive 失敗 = 接続は死んでいる
        }
      }

      // ゾンビ接続: state を disconnected に変更してから reconnect
      // （reconnect() は disconnected 状態でないと実行しないため）
      _cleanupConnections();
      state = state.copyWith(
        status: ConnectionStatus.disconnected,
        errorMessage: 'Connection lost',
        clearChannelManager: true,
      );
      await reconnect();
```

**after:**
```dart
      // ケース A: state が connected — 本当に生きているか確認
      if (_sshService != null && _sshService!.isConnected) {
        // 最後の確認から 45 秒以内なら probe をスキップ。
        // activeKeepAlive() が 30 秒ごとに _lastAliveConfirmed を更新するため、
        // 45 秒窓なら直近の keepalive 成功をカバーできる。
        if (_lastAliveConfirmed != null &&
            DateTime.now().difference(_lastAliveConfirmed!) <
                const Duration(seconds: 45)) {
          return;
        }

        // keepAlive() で生存確認。失敗した場合は 1 秒待ってリトライする。
        // バックグラウンド復帰直後は Wi-Fi が省電力モードから復帰するまで
        // 数秒かかるため、1 回の失敗で即座に再接続しない。
        final service = _sshService!;
        for (var attempt = 0; attempt < 2; attempt++) {
          try {
            final alive = await service.keepAlive(
              executeTimeout: const Duration(seconds: 10),
              doneTimeout: const Duration(seconds: 10),
            );
            if (alive && identical(service, _sshService)) {
              _lastAliveConfirmed = DateTime.now();
              return; // 生きている
            }
          } catch (_) {
            // keepAlive 失敗
          }
          // 1 回目の失敗: Wi-Fi 復帰を待ってリトライ
          if (attempt == 0) {
            await Future.delayed(const Duration(seconds: 1));
            // 遅延中に状態が変わっていたら中断
            if (!identical(service, _sshService)) return;
          }
        }
      }

      // ゾンビ接続: state を disconnected に変更してから reconnect
      // （reconnect() は disconnected 状態でないと実行しないため）
      _cleanupConnections();
      state = state.copyWith(
        status: ConnectionStatus.disconnected,
        errorMessage: 'Connection lost',
        clearChannelManager: true,
      );
      await reconnect();
```

#### 1-4. `_activeKeepAliveCore()` に失敗閾値を導入

**before:**
```dart
  Future<void> _activeKeepAliveCore() async {
    if (state.status == ConnectionStatus.connected) {
      final service = _sshService;
      if (service == null) return;
      final alive = await service.keepAlive();
      // await 中にサービスが差し替わった場合はタイムスタンプを更新しない
```

`alive` の分岐を含む前後のコードを修正する。connected ブランチの全体を書き換え:

**before (connected ブランチ全体):**
```dart
    if (state.status == ConnectionStatus.connected) {
      final service = _sshService;
      if (service == null) return;
      final alive = await service.keepAlive();
      // await 中にサービスが差し替わった場合はタイムスタンプを更新しない
      if (alive && identical(service, _sshService)) {
        if (state.status == ConnectionStatus.connected) {
          _lastAliveConfirmed = DateTime.now();
        }
      } else if (!alive) {
        _onDisconnected();
      }
      return;
    }
```

**after:**
```dart
    if (state.status == ConnectionStatus.connected) {
      final service = _sshService;
      if (service == null) return;
      final alive = await service.keepAlive();
      // await 中にサービスが差し替わった場合はタイムスタンプを更新しない
      if (alive && identical(service, _sshService)) {
        if (state.status == ConnectionStatus.connected) {
          _lastAliveConfirmed = DateTime.now();
          _keepAliveFailCount = 0;
        }
      } else if (!alive) {
        // 1 回の失敗では再接続しない。一時的なネットワーク遅延を吸収する。
        // 連続 2 回失敗したら切断と判定する。
        _keepAliveFailCount++;
        if (_keepAliveFailCount >= 2) {
          _keepAliveFailCount = 0;
          _onDisconnected();
        }
      }
      return;
    }
```

#### 1-5. `reconnect()` 成功時と `_cleanupConnections()` で `_keepAliveFailCount` をリセット

`reconnect()` メソッド内の成功パス:

**before:**
```dart
      _retryCount = 0;
      _lastReconnectAttempt = null;
      _lastAliveConfirmed = DateTime.now();
```

**after:**
```dart
      _retryCount = 0;
      _lastReconnectAttempt = null;
      _lastAliveConfirmed = DateTime.now();
      _keepAliveFailCount = 0;
```

`_cleanupConnections()` メソッド内:

**before:**
```dart
  void _cleanupConnections() {
    _lastAliveConfirmed = null;
    _healthCheckTimer?.cancel();
```

**after:**
```dart
  void _cleanupConnections() {
    _lastAliveConfirmed = null;
    _keepAliveFailCount = 0;
    _healthCheckTimer?.cancel();
```

---

## Step 2: ダウンロード中の UI フリーズを修正

### ファイル: `lib/features/file_browser/file_browser_provider.dart`

#### 2-1. 進捗タイマーの間隔を 200ms → 500ms に変更

**before:**
```dart
      // 進捗タイマー: 200ms ごとに UI を更新
      // AsyncError/Loading 状態を上書きしないよう valueOrNull の null チェックを行う
      final progressTimer = Timer.periodic(
        const Duration(milliseconds: 200),
        (_) {
```

**after:**
```dart
      // 進捗タイマー: 500ms ごとに UI を更新。
      // 頻度を下げて Riverpod リビルドによる UI スレッド負荷を軽減する。
      // AsyncError/Loading 状態を上書きしないよう valueOrNull の null チェックを行う
      final progressTimer = Timer.periodic(
        const Duration(milliseconds: 500),
        (_) {
```

#### 2-2. ストリームリスナーに定期的な yield を導入

SSH ストリームから大量のデータが連続到着すると、リスナーがイベントループを占有して UI フレーム描画がブロックされる。
一定量のデータ受信ごとにストリームを一時停止し、マイクロタスクで制御をイベントループに返す。

**before:**
```dart
      subscription = execSession.stdout.listen(
        (chunk) {
          if (completer.isCompleted) return;
          if (_downloadGeneration != generation) {
            streamError = NetworkError('Download cancelled');
            subscription?.cancel();
            if (!completer.isCompleted) completer.complete();
            return;
          }
          // リスナーは最小限の処理のみ:
          // chunk を Isolate に転送 + カウンタ更新（state 更新や flush は行わない）
          writer.addChunk(chunk);
          received += chunk.length;
          // 全データ受信済み → ストリーム終了を待たずに完了
          if (totalBytes > 0 && received >= totalBytes) {
            subscription?.cancel();
            if (!completer.isCompleted) completer.complete();
          }
        },
        onError: (Object e) {
          // エラー連発でリスナーが動き続けるのを防ぐため、即座にキャンセル
          if (completer.isCompleted) return;
          streamError ??= e;
          subscription?.cancel();
          completer.complete();
        },
        onDone: () {
          if (!completer.isCompleted) completer.complete();
        },
        cancelOnError: false,
      );
```

**after:**
```dart
      // 連続データ受信でイベントループが占有されないよう、
      // 256KB ごとにストリームを一時停止して UI に制御を返す。
      var receivedSinceYield = 0;
      const yieldThreshold = 256 * 1024; // 256KB

      subscription = execSession.stdout.listen(
        (chunk) {
          if (completer.isCompleted) return;
          if (_downloadGeneration != generation) {
            streamError = NetworkError('Download cancelled');
            subscription?.cancel();
            if (!completer.isCompleted) completer.complete();
            return;
          }
          // リスナーは最小限の処理のみ:
          // chunk を Isolate に転送 + カウンタ更新（state 更新や flush は行わない）
          writer.addChunk(chunk);
          received += chunk.length;
          receivedSinceYield += chunk.length;
          // 全データ受信済み → ストリーム終了を待たずに完了
          if (totalBytes > 0 && received >= totalBytes) {
            subscription?.cancel();
            if (!completer.isCompleted) completer.complete();
            return;
          }
          // 256KB 受信ごとにストリームを一時停止し、
          // マイクロタスクで UI フレーム描画の時間を確保してから再開する。
          if (receivedSinceYield >= yieldThreshold) {
            receivedSinceYield = 0;
            subscription?.pause();
            Future.microtask(() {
              if (!completer.isCompleted) {
                subscription?.resume();
              }
            });
          }
        },
        onError: (Object e) {
          // エラー連発でリスナーが動き続けるのを防ぐため、即座にキャンセル
          if (completer.isCompleted) return;
          streamError ??= e;
          subscription?.cancel();
          completer.complete();
        },
        onDone: () {
          if (!completer.isCompleted) completer.complete();
        },
        cancelOnError: false,
      );
```

**重要**: `Future.microtask()` は `Future.delayed(Duration.zero)` よりも軽量で、イベントキューの次のマイクロタスクとして実行される。これにより:
1. 現在のイベント（SSH パケット処理）が完了
2. UI フレーム描画のためのイベントが処理される機会を得る
3. ストリームが再開され、次の chunk が到着する

`pause()` → `resume()` のサイクルにより dartssh2 側では:
- `pause()` → `_channelDataSubscription.pause()` → `_remoteStream.isPaused = true`
- `_sendWindowAdjustIfNeeded()` が `isPaused` ガードでスキップされるが、**resume 時に `onResume: _sendWindowAdjustIfNeeded` が呼ばれる**ため SSH ウィンドウは正常に回復する
- 256KB は dartssh2 の 2MB ウィンドウに対して十分小さく、ウィンドウ枯渇は起きない

---

## 変更まとめ

| # | 修正 | ファイル | 効果 |
|---|---|---|---|
| 1 | スキップ窓 10 秒 → 45 秒 | `terminal_connection_provider.dart` | 直近の keepalive 成功をカバーし、不要な probe を回避 |
| 2 | `checkConnection()` リトライ（1 秒待ち × 2 回） | `terminal_connection_provider.dart` | Wi-Fi 復帰遅延による一時的失敗を吸収 |
| 3 | `_onDisconnected()` 2 秒遅延 | `terminal_connection_provider.dart` | 一時的なネットワーク不安定で PTY を無駄に破棄しない |
| 4 | `activeKeepAlive()` 連続 2 回失敗閾値 | `terminal_connection_provider.dart` | 単発タイムアウトで再接続しない |
| 5 | 進捗タイマー 200ms → 500ms | `file_browser_provider.dart` | Riverpod リビルドの UI 負荷を軽減 |
| 6 | 256KB ごとの pause/resume yield | `file_browser_provider.dart` | SSH ストリームによるイベントループ占有を防止 |

---

## 検証手順

1. `~/flutter/bin/flutter analyze` — 静的解析エラーなし
2. `~/flutter/bin/flutter test` — 既存テスト全パス
3. `~/flutter/bin/flutter build apk --debug` — デバッグビルド成功
4. `~/flutter/bin/flutter build apk --release` — リリースビルド成功
5. 実機テスト（復帰時の再接続）:
   - SSH 接続 → バックグラウンド 30 秒 → フォアグラウンド復帰 → **再接続されない、元のシェル状態が維持される**
   - SSH 接続 → バックグラウンド 2 分 → フォアグラウンド復帰 → **再接続されない、または短時間で復旧**
   - tmux セッション接続中 → バックグラウンド → 復帰 → **tmux セッションが維持される**
   - Wi-Fi 一瞬切断 → すぐ復帰 → **再接続されない**
6. 実機テスト（ダウンロードフリーズ）:
   - 10MB 程度のファイルダウンロード → **UI がスムーズに動作（フリーズしない）**
   - ダウンロード中にターミナル画面のスクロール → **滑らかに動く**
   - ダウンロード中にタブ切り替え → **即座に切り替わる**
   - 進捗バーが 500ms 間隔で更新される → **ぎこちなさがない**
   - ダウンロード完了 → **ファイルが正常に保存される**
