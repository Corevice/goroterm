---
goal: "Phase 26 - tmux セッション作成/リネーム時の IME 未確定文字バグ修正"
verifyCommands:
  - ~/flutter/bin/flutter analyze
  - ~/flutter/bin/flutter test
  - ~/flutter/bin/flutter build apk --debug
maxAttempts: 5
executeModel: claude-sonnet-4-6
evaluateModel: claude-sonnet-4-6
---

# Phase 26: tmux セッション作成時の IME 未確定文字バグ修正

全体の実装計画は `plans/terminal-ssh-app/implementation-plan.md` を参照すること。
Flutter SDK は `~/flutter/bin/flutter` にある（PATH に含まれていないため、フルパスで実行すること）。

---

## 問題: IME の未確定文字がある状態でセッション作成/リネームするとエラーになる

### 根本原因

`tmux_manager_screen.dart` の `_showCreateDialog` と `_showRenameDialog` に同じバグがある。

**IME 入力の仕組み**:
- ユーザーが日本語等の IME で文字を入力中、変換確定前のテキストは `TextEditingValue.composing` に保持される
- `TextField` の `onChanged` コールバックは **表示テキスト（確定済み + 未確定）** を `v` として受け取る
- しかし `controller.text` は **確定済みテキストのみ** を返す

**バグの流れ**:

1. ユーザーが IME で `"my-session"` と入力中（まだ変換未確定）
2. `onChanged` が `"my-session"` を受け取り、`validateTmuxSessionName("my-session")` → エラーなし → ボタン有効化
3. ユーザーが **未確定のまま**「作成」ボタンをタップ
4. `controller.text.trim()` → `""`（確定済みテキストがないため空文字）
5. `validateTmuxSessionName("")` → `'Session name cannot be empty'` → エラー表示

さらに問題: `createSession` 内の `catch (_)` でエラーが握りつぶされるため、万一不正な名前が通った場合もユーザーにフィードバックがない。

### 修正方針

「作成」/「リネーム」ボタンを押した際に、**IME の未確定テキストを強制確定してから** `controller.text` を読む。

Flutter では `TextInputConnection.finishComposing()` 相当の操作が直接公開されていないが、以下のアプローチで対応可能:

1. **`controller.text` の代わりに `controller.value` を使い、composing テキストを含めた全文字列を取得する**
2. または、ボタン押下時に `FocusScope.of(context).unfocus()` でフォーカスを外し、IME に変換を確定させてから `controller.text` を読む

**方式 1（推奨）**: `controller.value.text` ではなく、表示テキスト全体を使う。`TextEditingController.text` は実は `value.text` と同じで、composing 範囲の文字列も含まれている。

実際に確認すると、Flutter の `TextEditingController.text` は `TextEditingValue.text` の getter であり、**composing 範囲のテキストも含まれている**。composing はあくまで「どの範囲が未確定か」のマーカーであり、`text` プロパティ自体には未確定文字も含まれる。

つまり、`controller.text` が空になるケースは **IME が composing テキストをまだ `TextEditingValue.text` に反映していない** 特殊なタイミングに起きる可能性がある（プラットフォーム依存）。

**最も確実な対応**: ボタン押下時にフォーカスを外して IME の未確定状態を強制解除し、1フレーム待ってから `controller.text` を読む。

```dart
onPressed: () async {
  // IME の未確定テキストを強制確定
  FocusScope.of(ctx).unfocus();
  await Future<void>.delayed(Duration.zero);
  final name = controller.text.trim();
  // ... validation
}
```

ただし `async` にすると UI 遅延が気になる可能性がある。

**よりシンプルな対応**: `onChanged` で受け取った表示テキスト `v` を状態変数に保持し、ボタン押下時にその値を使う。`onChanged` は composing テキストも含んだ値を返すため、未確定文字の問題が発生しない。

---

## 実装手順

### 手順 1: _showCreateDialog の修正

ファイル: `lib/features/tmux/tmux_manager_screen.dart`

`onChanged` で受け取ったテキストを状態変数に保持し、ボタン押下時にそれを使う。

変更前:
```dart
void _showCreateDialog(List<String> existingNames) {
  final controller = TextEditingController();
  String? errorText;

  showDialog(
    context: context,
    builder: (ctx) {
      return StatefulBuilder(
        builder: (ctx, setDialogState) {
          return AlertDialog(
            // ...
            content: TextField(
              controller: controller,
              autofocus: true,
              decoration: InputDecoration(
                labelText: 'Session name',
                errorText: errorText,
              ),
              onChanged: (v) {
                setDialogState(() {
                  errorText = validateTmuxSessionName(v.trim(), existingNames);
                });
              },
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: errorText != null
                    ? null
                    : () {
                        final name = controller.text.trim();
                        final err =
                            validateTmuxSessionName(name, existingNames);
                        if (err != null) {
                          setDialogState(() => errorText = err);
                          return;
                        }
                        Navigator.of(ctx).pop();
                        _createSession(name);
                      },
                child: const Text('Create'),
              ),
            ],
          );
        },
      );
    },
  );
}
```

変更後:
```dart
void _showCreateDialog(List<String> existingNames) {
  final controller = TextEditingController();
  String? errorText;
  String currentInput = ''; // onChanged で受け取った表示テキストを保持

  showDialog(
    context: context,
    builder: (ctx) {
      return StatefulBuilder(
        builder: (ctx, setDialogState) {
          return AlertDialog(
            // ...
            content: TextField(
              controller: controller,
              autofocus: true,
              decoration: InputDecoration(
                labelText: 'Session name',
                errorText: errorText,
              ),
              onChanged: (v) {
                currentInput = v; // 表示テキスト（composing 含む）を保持
                setDialogState(() {
                  errorText = validateTmuxSessionName(v.trim(), existingNames);
                });
              },
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: errorText != null
                    ? null
                    : () {
                        // controller.text ではなく onChanged で受け取った
                        // 表示テキストを使う（IME 未確定文字を含む）
                        final name = currentInput.trim();
                        final err =
                            validateTmuxSessionName(name, existingNames);
                        if (err != null) {
                          setDialogState(() => errorText = err);
                          return;
                        }
                        Navigator.of(ctx).pop();
                        _createSession(name);
                      },
                child: const Text('Create'),
              ),
            ],
          );
        },
      );
    },
  );
}
```

### 手順 2: _showRenameDialog の同様の修正

ファイル: `lib/features/tmux/tmux_manager_screen.dart`

リネームダイアログにも同じ修正を適用。

変更前（リネームボタンのハンドラ部分）:
```dart
final controller = TextEditingController(text: currentName);
String? errorText;
```

変更後:
```dart
final controller = TextEditingController(text: currentName);
String? errorText;
String currentInput = currentName; // 初期値を現在の名前に設定
```

`onChanged`:
```dart
onChanged: (v) {
  currentInput = v; // 表示テキストを保持
  setDialogState(() {
    errorText = validateTmuxSessionName(v.trim(), existingNames);
  });
},
```

リネームボタンのハンドラ:
```dart
final newName = currentInput.trim(); // controller.text → currentInput
```

### 手順 3: createSession のエラーハンドリング改善

ファイル: `lib/features/tmux/tmux_provider.dart`

現在の `createSession` はエラーを `catch (_)` で握りつぶしている。呼び出し元（`_createSession` in `tmux_manager_screen.dart`）の `catch (e)` ブロックでユーザーに SnackBar を表示する設計なのに、`createSession` 内部でエラーが消されるため表示されない。

変更前:
```dart
Future<void> createSession(String name) async {
  try {
    final escaped = name.replaceAll("'", r"'\''");
    await _execCommand("tmux new-session -d -s '$escaped'");
    await _safeRefresh();
  } catch (_) {
    await _safeRefresh();
  }
}
```

変更後:
```dart
Future<void> createSession(String name) async {
  try {
    final escaped = name.replaceAll("'", r"'\''");
    await _execCommand("tmux new-session -d -s '$escaped'");
  } finally {
    await _safeRefresh();
  }
}
```

`try/finally` にすることで:
- 成功時: `_safeRefresh()` 実行、正常終了
- 失敗時: `_safeRefresh()` 実行後、**例外が呼び出し元に伝播**する → SnackBar でユーザーにフィードバック

`renameSession` にも同じ修正を適用:

変更前:
```dart
Future<void> renameSession(String oldName, String newName) async {
  try {
    final escapedOld = oldName.replaceAll("'", r"'\''");
    final escapedNew = newName.replaceAll("'", r"'\''");
    await _execCommand(
        "tmux rename-session -t '$escapedOld' '$escapedNew'");
    await _safeRefresh();
  } catch (_) {
    await _safeRefresh();
  }
}
```

変更後:
```dart
Future<void> renameSession(String oldName, String newName) async {
  try {
    final escapedOld = oldName.replaceAll("'", r"'\''");
    final escapedNew = newName.replaceAll("'", r"'\''");
    await _execCommand(
        "tmux rename-session -t '$escapedOld' '$escapedNew'");
  } finally {
    await _safeRefresh();
  }
}
```

---

## テストへの影響

- `_showCreateDialog` / `_showRenameDialog`: 変数追加とテキスト取得元変更。既存テストで `controller.text` を直接チェックしている場合は更新が必要
- `createSession` / `renameSession`: `catch (_)` → `try/finally` に変更。エラーが呼び出し元に伝播するようになるため、`tmux_provider_test.dart` でエラーケースのテストが影響を受ける可能性あり
- `tmux_manager_screen_test.dart`: SnackBar 表示テストがあれば、エラー時の SnackBar が表示されるようになるため、テスト期待値が変わる可能性

## 実装順序

1. `lib/features/tmux/tmux_manager_screen.dart`:
   - `_showCreateDialog` に `currentInput` 変数追加、ボタンで `currentInput` を使用
   - `_showRenameDialog` に同じ修正
2. `lib/features/tmux/tmux_provider.dart`:
   - `createSession` の `catch (_)` → `try/finally`
   - `renameSession` の `catch (_)` → `try/finally`
3. テスト確認・修正
4. `~/flutter/bin/flutter analyze`
5. `~/flutter/bin/flutter test`
6. `~/flutter/bin/flutter build apk --debug`
