---
goal: "Phase 42 - ダウンロード停止バグ修正 + 矢印ボタン感度改善"
verifyCommands:
  - ~/flutter/bin/flutter analyze
  - ~/flutter/bin/flutter test
  - ~/flutter/bin/flutter build apk --debug
maxAttempts: 5
executeModel: claude-sonnet-4-6
evaluateModel: claude-sonnet-4-6
---

# Phase 42: ダウンロード停止バグ修正 + 矢印ボタン感度改善

全体の実装計画は `plans/terminal-ssh-app/implementation-plan.md` を参照すること。
Flutter SDK は `~/flutter/bin/flutter` にある（PATH に含まれていないため、フルパスで実行すること）。

---

## 問題

### 問題 1: ファイルのダウンロードが進まなくなる

Phase 40 で `Future.microtask` → `Future.delayed(Duration.zero)` に変更したことが原因。

`subscription.pause()` 後に `Future.delayed(Duration.zero)` で resume をスケジュールするが、
`Future.delayed` は Timer キューに入るため、microtask より遅延する。
この遅延中に dartssh2 内部のストリームバッファが枯渇し、SSH ウィンドウ調整が
送信されなくなり、サーバー側がデータ送信を停止 → **デッドロック**。

`Future.microtask` は同じイベントループターン内で処理されるため、
SSH の内部フロー制御と競合せず、正常にデータが流れる。

### 問題 2: ダウンロード中にバックグラウンドにすると黒画面

`doneFallback` が最大 30 秒ブロック。フォアグラウンド復帰時に進捗状態が残ったまま。

### 問題 3: 矢印ボタンの感度が低すぎる

`_RepeatableActionButton` の `_activationDelay` が 150ms。
短いタップ（< 150ms）では `_startRepeat()` が発火前に `_stopRepeat()` で打ち消され、
**キー入力が全く送信されない**。

---

## 実装手順

### ステップ 1: yield を `Future.microtask` に戻す

**ファイル:** `lib/features/file_browser/file_browser_provider.dart`

```dart
// BEFORE:
          // 64KB 受信ごとにストリームを一時停止し、
          // Timer キュー経由で UI フレーム描画の時間を確保してから再開する。
          // Future.delayed(Duration.zero) は Timer キューに入るため、
          // microtask と違いフレーム描画コールバックの実行機会がある。
          if (receivedSinceYield >= yieldThreshold) {
            receivedSinceYield = 0;
            subscription?.pause();
            Future<void>.delayed(Duration.zero, () {
              if (!completer.isCompleted) {
                subscription?.resume();
              }
            });
          }

// AFTER:
          // 64KB 受信ごとにストリームを一時停止し、
          // microtask で再開する。
          // microtask は同じイベントループターン内で処理されるため、
          // dartssh2 の SSH ウィンドウ調整と競合しない。
          // Future.delayed だと Timer キュー遅延中にバッファが枯渇し
          // デッドロックする。
          if (receivedSinceYield >= yieldThreshold) {
            receivedSinceYield = 0;
            subscription?.pause();
            Future.microtask(() {
              if (!completer.isCompleted) {
                subscription?.resume();
              }
            });
          }
```

---

### ステップ 2: doneFallback の最大待機時間を短縮

**ファイル:** `lib/features/file_browser/file_browser_provider.dart`

```dart
// BEFORE:
      // session.done フォールバック:
      // データ受信が止まってから 1 秒経過したら発動。
      // 大容量ファイルのバッファ drain に最大 30 秒待機。
      final doneFallback = execSession.done.then((_) async {
        var idleTicks = 0;
        var prev = received;
        for (var i = 0; i < 300 && !completer.isCompleted; i++) {

// AFTER:
      // session.done フォールバック:
      // データ受信が止まってから 1 秒経過したら発動。
      // 大容量ファイルのバッファ drain に最大 5 秒待機。
      // バックグラウンド復帰時に長時間ブロックしないよう短縮。
      final doneFallback = execSession.done.then((_) async {
        var idleTicks = 0;
        var prev = received;
        for (var i = 0; i < 50 && !completer.isCompleted; i++) {
```

---

### ステップ 3: ダウンロードエラー時の状態クリーンアップ

**ファイル:** `lib/features/file_browser/file_browser_provider.dart`

`downloadFile` の catch ブロックに重複した進捗クリアがあるので整理する。
finally で必ずクリアされるため、catch 内は不要。

```dart
// BEFORE:
  Future<void> downloadFile(String remotePath) async {
    if (_isDownloading) return;
    _isDownloading = true;
    final baseState = state.valueOrNull ?? const FileBrowserState();
    try {
      await _downloadFileCore(remotePath, baseState);
    } catch (e) {
      debugPrint('downloadFile error: $e');
      // エラー時は進捗を即座にクリアし、ファイルブラウザを操作可能な状態に戻す
      final cur = state.valueOrNull;
      if (cur != null) {
        state = AsyncData(cur.copyWith(downloadProgress: null));
      }
    } finally {
      _isDownloading = false;
      final cur = state.valueOrNull;
      if (cur != null && cur.downloadProgress != null) {
        state = AsyncData(cur.copyWith(downloadProgress: null));
      }
      // ダウンロード終了後、接続が切れていたら AsyncError に遷移
      if (_channelManager == null) {
        state = AsyncError(NetworkError('SSH not connected'), StackTrace.current);
      }
    }
  }

// AFTER:
  Future<void> downloadFile(String remotePath) async {
    if (_isDownloading) return;
    _isDownloading = true;
    final baseState = state.valueOrNull ?? const FileBrowserState();
    try {
      await _downloadFileCore(remotePath, baseState);
    } catch (e) {
      debugPrint('downloadFile error: $e');
    } finally {
      _isDownloading = false;
      // 進捗を確実にクリア（正常完了時は _downloadFileCore 内で null になっているはず）
      final cur = state.valueOrNull;
      if (cur != null && cur.downloadProgress != null) {
        state = AsyncData(cur.copyWith(downloadProgress: null));
      }
      // ダウンロード終了後、接続が切れていたら AsyncError に遷移
      if (_channelManager == null) {
        state = AsyncError(NetworkError('SSH not connected'), StackTrace.current);
      }
    }
  }
```

---

### ステップ 4: 矢印ボタンの即時タップ対応

**ファイル:** `lib/widgets/quick_action_bar.dart`

`_stopRepeat()` でタイマー未発火の短いタップでも 1 回キー送信する。

```dart
// BEFORE:
  void _stopRepeat() {
    _activationTimer?.cancel();
    _activationTimer = null;
    _repeatTimer?.cancel();
    _repeatTimer = null;
    _downPosition = null;
    if (mounted) {
      setState(() => _isPressed = false);
    }
  }

// AFTER:
  void _stopRepeat() {
    final wasPendingActivation = _activationTimer?.isActive ?? false;
    _activationTimer?.cancel();
    _activationTimer = null;
    _repeatTimer?.cancel();
    _repeatTimer = null;
    _downPosition = null;
    // タイマー発火前の短いタップでも 1 回キー送信する。
    // _isCancelled（スクロール操作）の場合は送信しない。
    // _isPressed が false = まだ _startRepeat が呼ばれていない = タップが短い
    if (wasPendingActivation && !_isCancelled && !_isPressed && mounted) {
      widget.onPressed();
    }
    if (mounted) {
      setState(() => _isPressed = false);
    }
  }
```

---

### ステップ 5: activationDelay を短縮

**ファイル:** `lib/widgets/quick_action_bar.dart`

150ms → 80ms に短縮。長押しリピートの開始もより素早くなる。

```dart
// BEFORE:
  // ボタン押下と判定するまでの遅延
  static const _activationDelay = Duration(milliseconds: 150);

// AFTER:
  // ボタン押下と判定するまでの遅延（長押しリピート開始）
  static const _activationDelay = Duration(milliseconds: 80);
```

---

## 変更ファイル一覧

| ファイル | 変更内容 |
|---------|---------|
| `lib/features/file_browser/file_browser_provider.dart` | yield を `Future.delayed` → `Future.microtask` に戻す、doneFallback 30→5秒、エラー時進捗クリア整理 |
| `lib/widgets/quick_action_bar.dart` | タップ即時発火 + activationDelay 150→80ms |

---

## 検証項目

1. `~/flutter/bin/flutter analyze` — 静的解析エラーなし
2. `~/flutter/bin/flutter test` — 全テスト通過
3. `~/flutter/bin/flutter build apk --debug` — デバッグビルド成功
4. **手動テスト（デバイス）:**
   - 100MB+ のファイルをダウンロード → 進捗バーが更新されダウンロードが完了すること
   - ダウンロード中にバックグラウンド → 復帰時に 5 秒以内にエラーまたは完了すること
   - 矢印ボタンを素早くタップ → 即座にキー入力が送信されること
   - 矢印ボタンを長押し → リピート入力が発生すること
   - ショートカットバーを横スクロール中 → 矢印ボタンが誤発火しないこと
