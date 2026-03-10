---
goal: "Phase 30 - ファイルダウンロードの速度改善 + 大容量ファイルでの停止バグ修正"
verifyCommands:
  - ~/flutter/bin/flutter analyze
  - ~/flutter/bin/flutter test
  - ~/flutter/bin/flutter build apk --debug
maxAttempts: 5
executeModel: claude-sonnet-4-6
evaluateModel: claude-sonnet-4-6
---

# Phase 30: ファイルダウンロード速度改善 + 停止バグ修正

全体の実装計画は `plans/terminal-ssh-app/implementation-plan.md` を参照すること。
Flutter SDK は `~/flutter/bin/flutter` にある（PATH に含まれていないため、フルパスで実行すること）。

---

## 問題

Phase 28 の実装以降:
1. **少し重めのファイルをダウンロードすると全く進まない（停止する）**
2. **ダウンロード速度が非常に遅い**

---

## 根本原因分析

### 原因 1: ストリームリスナー内での Riverpod state 更新がイベントループを圧迫

現在のコード（`_downloadFileCore` 内）:

```dart
subscription = execSession.stdout.cast<List<int>>().listen(
  (chunk) {
    sink.add(chunk);
    received += chunk.length;
    // 1MB ごとに flush（unawaited）
    if (received - lastFlush >= 1024 * 1024) {
      lastFlush = received;
      sink.flush();  // ← Future が await されない
    }
    // 64KB ごとに state 更新
    if (totalBytes > 0 && received - lastProgressUpdate >= 65536) {
      lastProgressUpdate = received;
      state = AsyncData(                           // ← ここが問題
        cur.copyWith(downloadProgress: received / totalBytes),
      );
    }
    ...
  },
  cancelOnError: true,
);
```

**`state = AsyncData(...)` は同期的に Riverpod の通知チェーンを起動する。** 64KB（約 2 チャンク）ごとに:

1. 新しい `FileBrowserState` オブジェクトを作成（`copyWith`）
2. `AsyncData` で状態を更新
3. Riverpod が全リスナーに同期通知
4. Flutter がウィジェットリビルドをスケジュール
5. リビルドがフレーム描画時にイベントループを占有

50MB のファイルでは **~780 回の state 更新** が発生し、イベントループが Riverpod 通知 + UI リビルドに占有される。その結果:

- SSH パケット処理（ウィンドウ調整を含む）が遅延
- ダウンロード速度が大幅に低下
- UI から見ると「全く進まない」ように見える

### 原因 2: dartssh2 のウィンドウ制御 — ストリーム pause 時にウィンドウ調整が停止

dartssh2 の `_sendWindowAdjustIfNeeded()`（ssh_channel.dart:313-329）:

```dart
void _sendWindowAdjustIfNeeded() {
  if (_done.isCompleted) return;
  if (_remoteStream.isPaused) return;    // ← pause 中は adjust を送らない
  if (_localWindow <= 0) return;          // ← ウィンドウが枯渇すると永久に送らない
  final bytesToAdd = localInitialWindowSize - _localWindow;
  _localWindow = localInitialWindowSize;
  sendMessage(SSH_Message_Channel_Window_Adjust(...));
}
```

**ストリームが pause されると SSH_MSG_CHANNEL_WINDOW_ADJUST が送信されなくなる。** `_localWindow` が 0 以下になると、resume 後も `_localWindow <= 0` ガードにより調整が永久に送られず、サーバーが送信を停止する。

Dart のストリーム基盤は、リスナーがイベント処理中に自動的にストリームを pause することがある。特に `_stdoutController`（SSHSession.stdout）は `onPause`/`onResume` コールバックで `_channelDataSubscription` を pause/resume する。

イベントループが圧迫されている状態（原因 1）で Dart のストリームスケジューラがバックプレッシャーを適用すると:

1. `_stdoutController` が pause される
2. `_channelDataSubscription.pause()` → `_remoteStream.isPaused = true`
3. SSH パケットは到着し `_localWindow` は減少し続ける
4. しかし `_sendWindowAdjustIfNeeded()` は `isPaused` ガードで何もしない
5. `_localWindow` が 0 以下に到達
6. resume 後も `_localWindow <= 0` ガードでウィンドウ調整が送られない
7. **サーバーが送信を完全に停止 → ダウンロードが永久に停止**

### 原因 3: unawaited `sink.flush()` のメモリ圧縮 + 副作用

`sink.flush()` が await されないため:
- IOSink の内部バッファが際限なく成長
- flush の Future 完了がマイクロタスクキューに積み上がる
- GC 圧力が増加しイベントループがさらに遅延

### 原因 4: `cancelOnError: true` による早期キャンセル

ストリーム上のエラー（一時的な SSH エラーを含む）でサブスクリプションが即座にキャンセルされる。大容量ファイルのダウンロード中に一時的なエラーが発生するとダウンロードが中断する。

### 原因 5: `session.done` フォールバックの 200ms タイムアウト

```dart
final doneFallback = execSession.done.then((_) async {
  await Future<void>.delayed(const Duration(milliseconds: 200));
  if (!completer.isCompleted) {
    streamError ??= NetworkError('Channel closed before stdout done');
    completer.complete();
  }
});
```

`cat` コマンド終了後、SSH チャネルの CLOSE がデータ配信完了前に到達した場合、200ms は不十分な可能性がある（大容量ファイルで StreamController にバッファされたデータの処理中に発火）。

---

## 修正方針

### A. 進捗更新をストリームリスナーから完全に分離（タイマーベース）

リスナーコールバックを最小限に: `sink.add(chunk)` + `received += chunk.length` のみ。
進捗更新は `Timer.periodic(200ms)` で `received` を読んで `state` を更新する。

これにより:
- リスナーが軽量化（1 チャンクあたり数マイクロ秒）
- イベントループの圧迫が大幅に解消
- SSH パケット処理とウィンドウ調整が遅延なく実行
- UI 更新は 200ms 間隔（5fps）で十分なめらか

### B. IOSink のバックプレッシャーを適切に実装

`sink.flush()` を await せずに呼ぶのではなく、`sink.add()` の代わりに `sink.addStream()` を使うか、定期的にストリームを pause して flush → resume するパターンを使う。

ただし、`.listen()` の同期コールバック内で `await` はできないため、以下のアプローチを採用:

**`IOSink.addStream()` を活用する方式:**

`stdout` ストリームを `StreamTransformer` で変換し、`sink.addStream()` に渡す。`addStream` は内部でバックプレッシャーを処理する。ただし、進捗トラッキングやキャンセルが難しくなる。

**採用方式: pause/resume + flush:**

受信バイト数が一定量（4MB）を超えたらストリームを pause し、`await sink.flush()` で確実にディスクに書き込み、その後 resume する。ただし、リスナーコールバック内で async 操作はできないため、Completer パターンが必要。

**最もシンプルな方式（採用）:** リスナー内では `sink.add()` のみ（flush なし）。IOSink は内部で自動的にバッファリングとフラッシュを行う。ダウンロード完了後の `sink.close()` で全データがフラッシュされる。中間 flush は不要（IOSink が OS レベルの非同期 I/O を利用するため、メインアイソレートをブロックしない）。

### C. `cancelOnError` を `false` に変更

一時的なストリームエラーでダウンロードが中断しないようにする。エラーは `streamError` に記録し、ストリーム完了後にチェックする。

### D. `session.done` フォールバックの改善

200ms 固定ではなく、最後のデータ受信からの経過時間で判定する。データがまだ流れている間はフォールバックを発動しない。

### E. 不要な `.cast<List<int>>()` を削除

`Uint8List` は `List<int>` のサブタイプなので、キャストは不要。ストリーム変換レイヤーを 1 つ削減する。

### F. `sink.close()` 前に `sink.flush()` を明示的に呼ぶ

Dart の `IOSink.close()` は OS レベルの flush を保証しない。ダウンロード完了後にデータが確実にディスクに書き込まれるよう、`finally` ブロックで `await sink.flush()` → `await sink.close()` の順で呼ぶ。

### G. dartssh2 の `_localWindow <= 0` バグ（ライブラリ側の課題）

dartssh2 の `ssh_channel.dart:318` で `if (_localWindow <= 0) return;` というガードがある。ストリームが pause 中にウィンドウが枯渇すると、resume 後も `_sendWindowAdjustIfNeeded()` が `_localWindow <= 0` で早期リターンし、ウィンドウ調整が永久に送信されなくなる。

**本来のロジック:**
```dart
// 現在（バグ）
if (_localWindow <= 0) return;
final bytesToAdd = localInitialWindowSize - _localWindow;

// 修正後（あるべき姿）
final bytesToAdd = localInitialWindowSize - _localWindow;
if (bytesToAdd <= 0) return;
```

この修正は dartssh2 ライブラリ側の変更が必要。本 Phase ではアプリ側の対策（リスナー軽量化でストリーム pause を防止）で症状を緩和する。ライブラリの fork/PR は将来課題とする。

---

## 実装手順

### 手順 1: `_downloadFileCore()` のストリーム処理を全面書き換え

ファイル: `lib/features/file_browser/file_browser_provider.dart`

変更前（`_downloadFileCore` のストリーム処理部分、`try` ブロック内）:
```dart
    try {
      // 【重要】await for を使わない。dartssh2 のバグにより stdout ストリームが
      // 閉じない場合がある。.listen() + Completer + session.done で回避。
      final completer = Completer<void>();
      StreamSubscription<List<int>>? subscription;
      Object? streamError;

      subscription = execSession.stdout.cast<List<int>>().listen(
        (chunk) {
          if (completer.isCompleted) return;
          if (_downloadGeneration != generation) {
            streamError = NetworkError('Download cancelled');
            subscription?.cancel();
            if (!completer.isCompleted) completer.complete();
            return;
          }
          sink.add(chunk);
          received += chunk.length;
          // 1MB ごとに flush（メモリ効率改善）
          if (received - lastFlush >= 1024 * 1024) {
            lastFlush = received;
            sink.flush();
          }
          if (totalBytes > 0 && received - lastProgressUpdate >= 65536) {
            lastProgressUpdate = received;
            final cur = state.valueOrNull ?? baseState;
            state = AsyncData(
              cur.copyWith(downloadProgress: received / totalBytes),
            );
          }
          // 全データ受信済み → ストリーム終了を待たずに完了
          if (totalBytes > 0 && received >= totalBytes) {
            subscription?.cancel();
            if (!completer.isCompleted) completer.complete();
          }
        },
        onError: (Object e) {
          streamError = e;
          if (!completer.isCompleted) completer.complete();
        },
        onDone: () {
          if (!completer.isCompleted) completer.complete();
        },
        cancelOnError: true,
      );

      // session.done は stdout が完全に drain される前に完了する可能性がある。
      // 200ms 遅延を入れて tail bytes のドロップを防ぐ。
      final doneFallback = execSession.done.then((_) async {
        await Future<void>.delayed(const Duration(milliseconds: 200));
        if (!completer.isCompleted) {
          streamError ??= NetworkError('Channel closed before stdout done');
          completer.complete();
        }
      });

      await completer.future;
      await subscription.cancel();
      await doneFallback.catchError((_) {});

      if (streamError != null) throw streamError!;

      if (totalBytes > 0) {
        final cur = state.valueOrNull ?? baseState;
        state = AsyncData(cur.copyWith(downloadProgress: 1.0));
      }
    } finally {
      await sink.close();
      // SSH チャネル（2MB バッファ）を解放
      execSession.close();
    }
```

変更後:
```dart
    try {
      // 進捗更新はタイマーベース（200ms 間隔）。
      // ストリームリスナー内では state 更新や flush を行わない。
      // これにより Dart イベントループを軽量に保ち、
      // dartssh2 の SSH ウィンドウ調整が遅延なく処理される。
      final completer = Completer<void>();
      StreamSubscription<Uint8List>? subscription;
      Object? streamError;

      // 進捗タイマー: 200ms ごとに UI を更新
      // AsyncError/Loading 状態を上書きしないよう valueOrNull の null チェックを行う
      final progressTimer = Timer.periodic(
        const Duration(milliseconds: 200),
        (_) {
          if (totalBytes > 0 && received > 0) {
            final cur = state.valueOrNull;
            if (cur == null) return; // AsyncError/Loading を上書きしない
            state = AsyncData(
              cur.copyWith(downloadProgress: received / totalBytes),
            );
          }
        },
      );

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
          // sink.add() + カウンタ更新（state 更新や flush は行わない）
          sink.add(chunk);
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

      // session.done フォールバック:
      // データ受信が止まってから 1 秒経過したら発動。
      // 大容量ファイルのバッファ drain に最大 30 秒待機。
      final doneFallback = execSession.done.then((_) async {
        var idleTicks = 0;
        var prev = received;
        for (var i = 0; i < 300 && !completer.isCompleted; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
          if (received == prev) {
            idleTicks++;
            if (idleTicks >= 10) break; // 1 秒間データなし → 発動
          } else {
            prev = received;
            idleTicks = 0;
          }
        }
        if (!completer.isCompleted) {
          streamError ??= NetworkError('Channel closed before stdout done');
          completer.complete();
        }
      });

      await completer.future;
      progressTimer.cancel();
      await subscription.cancel();
      await doneFallback.catchError((_) {});

      if (streamError != null) throw streamError!;

      if (totalBytes > 0) {
        final cur = state.valueOrNull ?? baseState;
        state = AsyncData(cur.copyWith(downloadProgress: 1.0));
      }
    } finally {
      // IOSink.close() は OS レベルの flush を保証しないため、明示的に flush する
      await sink.flush();
      await sink.close();
      // SSH チャネル（2MB バッファ）を解放
      execSession.close();
    }
```

### 手順 2: 不要な変数の削除

ファイル: `lib/features/file_browser/file_browser_provider.dart`

`_downloadFileCore` メソッドの先頭で宣言されている変数から不要なものを削除。

変更前:
```dart
  int received = 0;
  int lastProgressUpdate = 0;
  int lastFlush = 0;
  final sink = tempFile.openWrite();
```

変更後:
```dart
  int received = 0;
  final sink = tempFile.openWrite();
```

### 手順 3: `dart:async` import の確認

ファイル: `lib/features/file_browser/file_browser_provider.dart`

`Timer` クラスを使用するため、`dart:async` が import されていることを確認する。ファイル先頭に既に `import 'dart:async';` が存在するので追加は不要。

---

## テストへの影響

- `_downloadFileCore()` のストリーム処理が変更。モックテストで `stdout` ストリームのイベント送信タイミングが変わる可能性あり
- `cancelOnError: false` に変更: ストリームエラーがあっても subscription が継続する。エラー後の動作テストが必要
- `Timer.periodic` の追加: テストで `fakeAsync` を使用している場合、タイマーの tick が必要
- `session.done` フォールバック: 200ms → 最大 3 秒のポーリングに変更。タイミング依存のテストは更新が必要

## 実装順序

1. `lib/features/file_browser/file_browser_provider.dart`:
   - `_downloadFileCore()` のストリーム処理全面書き換え
   - 不要な変数（`lastProgressUpdate`, `lastFlush`）の削除
   - `dart:async` import の確認
2. テスト確認・修正
3. `~/flutter/bin/flutter analyze`
4. `~/flutter/bin/flutter test`
5. `~/flutter/bin/flutter build apk --debug`
