# SSH Terminal App 実装計画

## 1. プロジェクト概要

Android/iOS 対応のSSHターミナルアプリ。既存アプリの以下の問題を解決する:

1. **日本語IME入力**: 変換前の文字が送信されてしまう問題を、Composition処理で正しく制御
2. **ファイルブラウザ**: SFTP経由でリモートサーバーのファイル/フォルダを閲覧、パスをコピー
3. **tmuxセッション管理**: セッション一覧・接続・作成・削除をGUIで簡単に操作

---

## 2. 技術スタック

| コンポーネント | 技術 | バージョン | 選定理由 |
|---|---|---|---|
| フレームワーク | Flutter | >= 3.20 | Impellerエンジンによる高フレームレート描画、IMEサポートの成熟度 |
| SSH クライアント | dartssh2 | ^2.x | Pure Dart実装、SFTP対応、xterm.dartと同一エコシステム |
| ターミナルエミュレータ | xterm.dart | ^3.2.6 | CJK文字対応、IME composing状態追跡、60FPS描画 |
| SFTP/ファイル操作 | dartssh2 (SFTPv3) | 同上 | listdir/upload/download/stat等フル対応 |
| tmux管理 | SSH exec + `-F` format parsing | - | dartssh2のexecute()経由 |
| 状態管理 | Riverpod | ^2.x | 非同期処理・依存注入に強い |
| ローカルDB | drift (SQLite) | ^2.x | 接続情報・鍵の暗号化保存 |
| セキュアストレージ | flutter_secure_storage | ^9.x | SSH秘密鍵・パスワードの安全な保管 |

### 技術選定の根拠

**Flutter を選んだ理由 (vs React Native / Native)**:
- React Native は日本語IMEのcomposition underlineが表示されない致命的バグ（issue #55257）が未解決で、「Japanese Market Blocker」としてラベル付けされている
- Flutter の `xterm.dart` はIME composing状態を明示的に追跡し、`composingBaseOffset`/`composingExtentOffset` で変換中の文字を管理する
- Native (Kotlin + Swift) は2つのコードベースが必要になり、開発コストが倍増する
- ServerBox（オープンソース）が同じスタックで本番稼働しており、実績がある

---

## 3. アプリアーキテクチャ

```
lib/
├── main.dart                     # エントリーポイント
├── app.dart                      # MaterialApp設定、ルーティング
├── core/
│   ├── ssh/
│   │   ├── ssh_client_service.dart    # SSH接続管理（dartssh2ラッパー）
│   │   ├── ssh_channel_manager.dart   # チャネル管理（PTY/exec/SFTP分離）
│   │   ├── ssh_key_manager.dart       # 鍵の生成・インポート・保存
│   │   ├── known_hosts_store.dart     # ホスト鍵の保存・検証
│   │   └── connection_config.dart     # 接続設定モデル
│   ├── error/
│   │   ├── app_error.dart             # 共通エラーモデル
│   │   └── error_handler.dart         # エラー分類・UIへの変換
│   ├── network/
│   │   └── connectivity_monitor.dart  # ネットワーク状態監視・再接続制御
│   ├── storage/
│   │   ├── database.dart              # drift DB定義
│   │   ├── secure_storage.dart        # flutter_secure_storageラッパー
│   │   └── connection_repository.dart # 接続情報CRUD
│   └── theme/
│       └── terminal_theme.dart        # ターミナルカラースキーム
├── features/
│   ├── connections/
│   │   ├── connection_list_screen.dart    # ホーム画面: 接続一覧
│   │   ├── connection_edit_screen.dart    # 接続追加・編集
│   │   └── connection_provider.dart       # 接続状態管理
│   ├── terminal/
│   │   ├── terminal_screen.dart           # ターミナル画面
│   │   ├── terminal_connection_provider.dart  # 接続ライフサイクル（再接続、keepalive）
│   │   ├── terminal_input_provider.dart       # 入力経路管理（IME/物理キー/ペースト）
│   │   ├── terminal_output_provider.dart      # 出力処理（デコード、スクロールバック上限）
│   │   └── ime/
│   │       ├── ime_input_handler.dart     # 日本語IME制御ロジック
│   │       └── composition_buffer.dart    # Composition状態バッファ
│   ├── file_browser/
│   │   ├── file_browser_screen.dart       # ファイルブラウザ画面
│   │   ├── file_browser_provider.dart     # SFTP操作・状態管理
│   │   ├── file_item_widget.dart          # ファイル/フォルダ表示
│   │   ├── file_preview_screen.dart       # テキストファイルプレビュー
│   │   └── path_bar_widget.dart           # パス表示・コピーバー
│   └── tmux/
│       ├── tmux_manager_screen.dart        # tmuxセッション一覧画面
│       ├── tmux_provider.dart             # tmuxコマンド実行・パース
│       └── tmux_session_model.dart        # セッションデータモデル
└── widgets/
    ├── ssh_toolbar.dart                    # ターミナル下部ツールバー
    └── quick_action_bar.dart              # Ctrl/Tab/Esc等ショートカットバー
```

### SSHチャネル設計

同一SSH接続内で用途別にチャネルを分離する:

| チャネル | 用途 | 種別 |
|---|---|---|
| PTYチャネル | ターミナル操作・tmux attach | Interactive Shell (PTY) |
| Execチャネル | tmux list-sessions 等の非対話コマンド | execute() |
| SFTPサブシステム | ファイルブラウザ操作 | SFTP subsystem |

これにより、ファイル一覧取得中でもターミナル操作がブロックされない。

### 画面遷移

```
接続一覧画面 (ホーム)
├── 接続追加/編集画面
├── ターミナル画面
│   ├── [ドロワー] tmuxセッション管理
│   ├── [ドロワー] ファイルブラウザ
│   │   └── ファイルプレビュー
│   └── [ボトムバー] ショートカットキー
└── 設定画面
```

---

## 4. 機能詳細設計

### 4.1 日本語IME入力の正しい処理

**問題の本質**: 既存アプリはIMEの composing 状態（変換中）を無視し、キー入力を即座にSSHチャネルに送信してしまう。

**解決策**:

```dart
// ime_input_handler.dart の概念設計
class ImeInputHandler {
  bool _isComposing = false;
  String _composingText = '';
  String _previousConfirmedText = '';

  /// 前回送信済みテキストとの差分のみを送信する
  void onTextInputAction(TextEditingValue value) {
    final hasComposingRange = value.composing != TextRange.empty;

    if (hasComposingRange) {
      // 変換中: バッファに保持し、SSHには送信しない
      _isComposing = true;
      _composingText = value.text.substring(
        value.composing.start,
        value.composing.end,
      );
      // ターミナル上にオーバーレイ表示（表示層のみ、ターミナルバッファには混入させない）
      _showComposingOverlay(_composingText);
    } else if (_isComposing) {
      // composing消失 = 確定 or キャンセル
      _isComposing = false;
      _clearComposingOverlay();

      if (value.text.isEmpty || value.text == _previousConfirmedText) {
        // キャンセル or フォーカス変化: 何も送信しない
        return;
      }

      // 差分計算: 前回送信済みテキストとの差分のみを送信
      final newText = _extractDelta(_previousConfirmedText, value.text);
      if (newText.isNotEmpty) {
        _sendToSsh(newText);
      }
      _previousConfirmedText = value.text;
    } else {
      // 通常入力（英数字等）: 差分のみ送信
      final newText = _extractDelta(_previousConfirmedText, value.text);
      if (newText.isNotEmpty) {
        _sendToSsh(newText);
      }
      _previousConfirmedText = value.text;
    }
  }

  /// 前回テキストと現在テキストの差分を抽出
  String _extractDelta(String previous, String current) {
    if (current.startsWith(previous)) {
      return current.substring(previous.length);
    }
    // テキストが置き換わった場合（予測変換等）は全文を送信
    return current;
  }

  /// ペースト時: IMEを経由せず直接SSH送信（制御文字をサニタイズ）
  void onPaste(String text) {
    final sanitized = _sanitizeForTerminal(text);
    _sendToSsh(sanitized);
  }

  /// 改行キー押下時: composing中なら確定として処理し、送信しない
  void onEnterKey() {
    if (_isComposing) {
      // IMEに確定を委ねる（改行をSSHに送信しない）
      return;
    }
    _sendToSsh('\r');
  }
}
```

**重要な設計原則: 表示層とバッファの分離**:
- 未確定文字はターミナルバッファ（`Terminal.buffer`）には**絶対に書き込まない**
- カーソル位置にFlutterの`Overlay`ウィジェットで未確定文字を描画
- 確定時にOverlayを除去し、確定テキストのみSSHチャネルに送信

**xterm.dart との統合ポイント**:
- `xterm.dart` v3.x は `TerminalView` ウィジェットに `inputHandler` コールバックを提供
- `TextInputClient` の `updateEditingValue` でcomposingレンジを検出
- xterm.dart 標準のIMEサポートで不足する場合は、`TerminalView` を継承してカスタム `TextInputClient` を実装
- composing中はターミナルのカーソル位置に未確定文字をオーバーレイ描画

**テスト項目**:
- [ ] 日本語ひらがな入力 → 漢字変換 → 確定で正しい文字のみ送信
- [ ] 変換候補選択中にバックスペースで文字削除
- [ ] 変換キャンセル（Escキー）で入力なし
- [ ] 英語 → 日本語 → 英語のIME切替
- [ ] 予測変換（サジェスト）タップでの確定
- [ ] 改行キー押下時にcomposing中なら確定のみ（改行送信しない）
- [ ] 連続確定（予測変換タップ → 即次入力）で前の入力が二重送信されない
- [ ] 絵文字・サロゲートペア・結合文字の正しい送信
- [ ] ペースト時にIMEを経由せず正しく送信
- [ ] ハードウェアキーボード（日本語配列 / US配列）での動作
- [ ] Android / iOS それぞれのIMEでの動作差異確認

---

### 4.2 ファイルブラウザ (SFTP)

**機能一覧**:

| 機能 | 説明 | 優先度 |
|---|---|---|
| ディレクトリ閲覧 | SFTP listdir()でファイル一覧表示 | P0 |
| パスコピー | 現在のパスまたは選択ファイルのパスをクリップボードにコピー | P0 |
| パス貼り付け | コピーしたパスをターミナルに挿入 | P0 |
| テキストファイルプレビュー | 小さいテキストファイルの内容表示 | P1 |
| ファイルダウンロード | ローカルへのダウンロード（進捗表示付き） | P1 |
| ファイルアップロード | ローカルからリモートへアップロード | P2 |
| ファイル操作 | 削除、リネーム、権限変更 | P2 |
| ブックマーク | よく使うディレクトリのブックマーク | P2 |

**SFTP操作のコード設計**:

```dart
// file_browser_provider.dart の概念設計
class FileBrowserProvider extends AsyncNotifier<FileBrowserState> {
  late SftpClient _sftp;

  Future<List<SftpName>> listDirectory(String path) async {
    final items = await _sftp.listdir(path);
    // '.' と '..' を除外し、ディレクトリ優先でソート
    return items
        .where((e) => e.filename != '.' && e.filename != '..')
        .toList()
      ..sort((a, b) {
        final aIsDir = a.attr.isDirectory;
        final bIsDir = b.attr.isDirectory;
        if (aIsDir != bIsDir) return aIsDir ? -1 : 1;
        return a.filename.compareTo(b.filename);
      });
  }

  Future<void> copyPathToClipboard(String path) async {
    await Clipboard.setData(ClipboardData(text: path));
  }

  Future<void> pastePathToTerminal(String path, {bool shellEscape = true}) async {
    // シェルメタ文字（空白、クォート、$、;、| 等）をエスケープして安全に送信
    final safePath = shellEscape ? _shellEscapePath(path) : path;
    ref.read(terminalInputProvider).writeToSsh(safePath);
  }

  /// シングルクォートで囲んでシェルインジェクションを防止
  String _shellEscapePath(String path) {
    // パス内のシングルクォートをエスケープ: ' → '\''
    final escaped = path.replaceAll("'", r"'\''");
    return "'$escaped'";
  }
}
```

**UI設計**:
- ターミナル画面から右スワイプまたはアイコンタップでドロワー表示
- パンくずリスト（PathBar）で現在のパスを表示、タップでコピー
- ファイルアイテムのロングプレスでコンテキストメニュー（コピー、ターミナルに貼り付け、プレビュー）
- 隠しファイル(.dotfiles)の表示トグル

---

### 4.3 tmuxセッション管理

**機能一覧**:

| 機能 | 説明 | 優先度 |
|---|---|---|
| セッション一覧 | 名前・ウィンドウ数・接続状態を表示 | P0 |
| セッション接続 | タップでattach | P0 |
| セッション作成 | 新規セッション作成（名前指定） | P0 |
| セッション切断 | detach | P0 |
| セッション削除 | kill-session | P1 |
| セッションリネーム | rename-session | P1 |
| 自動再接続 | 前回のセッションに自動attach | P2 |

**tmuxコマンドのパース設計**:

```dart
// tmux_provider.dart の概念設計
class TmuxProvider extends AsyncNotifier<List<TmuxSession>> {
  /// SSH exec チャネルでtmuxセッション一覧を取得（PTYチャネルとは独立）
  Future<List<TmuxSession>> fetchSessions() async {
    // ASCII Unit Separator (\x1F) を区切り文字に使用し、セッション名の衝突を回避
    final result = await sshClient.execute(
      r"tmux list-sessions -F '#{session_name}\x1F#{session_windows}\x1F#{session_attached}\x1F#{session_created}'",
    );

    // 終了コードで判定（文字列センチネルではなく）
    if (result.exitCode != 0) {
      // tmux未インストール or サーバー未起動
      return [];
    }

    final output = utf8.decode(result.stdout);
    const separator = '\x1F'; // ASCII Unit Separator
    final sessions = <TmuxSession>[];
    for (final line in output.trim().split('\n').where((l) => l.isNotEmpty)) {
      final parts = line.split(separator);
      if (parts.length != 4) {
        // パース失敗: スキップしてデバッグログに記録
        debugPrint('tmux parse skip: $line');
        continue;
      }
      sessions.add(TmuxSession(
        name: parts[0],
        windowCount: int.tryParse(parts[1]) ?? 0,
        isAttached: parts[2] == '1',
        createdAt: DateTime.fromMillisecondsSinceEpoch(
          (int.tryParse(parts[3]) ?? 0) * 1000,
        ),
      ));
    }
    return sessions;
  }

  /// セッションにattach（PTYチャネル経由で実行）
  /// 注意: execute()ではなくPTYチャネルに書き込む（対話的操作のため）
  Future<void> attachSession(String sessionName) async {
    final escaped = shellEscape(sessionName);
    ref.read(terminalInputProvider).writeToSsh('tmux attach -t $escaped\n');
  }

  /// 新規セッション作成（execチャネルで非対話実行）
  Future<void> createSession(String name) async {
    await sshClient.execute('tmux new-session -d -s ${shellEscape(name)}');
    ref.invalidateSelf(); // 一覧を更新
  }

  /// tmux未インストール時の案内メッセージ
  Future<TmuxAvailability> checkTmuxAvailability() async {
    final result = await sshClient.execute('command -v tmux');
    if (result.exitCode != 0) {
      return TmuxAvailability.notInstalled;
    }
    final versionResult = await sshClient.execute('tmux -V');
    return TmuxAvailability.available(
      version: utf8.decode(versionResult.stdout).trim(),
    );
  }
}
```

**パース仕様（確定）**:
- フィールド区切り: ASCII Unit Separator (`\x1F`) を使用（セッション名にタブや空白が含まれる場合の衝突を回避）
  - `-F` フォーマット: `'#{session_name}\x1F#{session_windows}\x1F#{session_attached}\x1F#{session_created}'`
- 行区切り: 改行 (`\n`)
- パース手順: 1) 出力を改行で分割 → 2) 各行を `\x1F` で分割 → 3) フィールド数が4でない行はスキップしログ出力
- パース失敗時は該当行をスキップし、UIにはパース成功分のみ表示（サイレントに失敗しない: デバッグログに記録）
- エラー時のUI遷移:
  - tmux未インストール → インストール案内表示（`apt install tmux` / `brew install tmux` 等のコマンド例）
  - attach失敗（セッション消失等） → エラーダイアログ + セッション一覧を自動リフレッシュ

**チャネルの使い分けルール**:
- `execute()` (Execチャネル): `list-sessions`, `new-session -d`, `kill-session`, `rename-session` 等の非対話コマンド
- PTYチャネル書き込み: `tmux attach` 等の対話的操作（ユーザーのシェルセッション内で実行）

**UI設計**:
- ターミナル画面から左スワイプまたはアイコンタップでドロワー表示
- セッションごとにカード形式で表示（名前、ウィンドウ数、接続状態バッジ）
- FABで新規セッション作成ダイアログ
- スワイプで削除（確認ダイアログ付き）
- 自動リフレッシュ（10秒間隔、またはプルダウンで手動）

---

## 5. セキュリティ設計

| 項目 | 対策 |
|---|---|
| SSH秘密鍵の保存 | `flutter_secure_storage` (iOS: Keychain, Android: EncryptedSharedPreferences) |
| パスフレーズ付き秘密鍵 | 復号はメモリ上のみ、パスフレーズは保存しない（毎回入力 or 生体認証でアンロック） |
| パスワード保存 | 同上、オプショナル（保存しない選択も可） |
| ホスト鍵検証 | SHA-256フィンガープリント表示、初回承認後 `known_hosts_store` に保存、鍵変更時は**警告強化**（MITM警告） |
| known_hosts保存 | `flutter_secure_storage` に暗号化保存、端末移行時のエクスポート/インポート対応 |
| 接続情報DB | SQLite (drift) をアプリサンドボックス内に保存 |
| クリップボード | パスコピー後30秒で自動クリア（設定可能）、機密パスは確認ダイアログ表示 |
| ログ/クラッシュレポート | コマンド内容・パス・鍵断片をマスキング、Crashlyticsに機密情報を送信しない |
| 鍵種別 | Ed25519/ECDSA推奨、ssh-rsa (SHA-1) は非推奨警告を表示 |
| エージェント転送 | デフォルト無効、有効化時に警告を表示 |

### エラーモデル（共通）

```dart
// core/error/app_error.dart
sealed class AppError {
  const AppError(this.message);
  final String message;
}

class AuthenticationError extends AppError { ... }  // パスワード不正、鍵不一致
class HostKeyError extends AppError { ... }         // ホスト鍵不一致（MITM警告）
class NetworkError extends AppError { ... }         // タイムアウト、DNS解決失敗
class PermissionError extends AppError { ... }      // SFTP権限エラー
class TmuxError extends AppError { ... }            // tmux未インストール、セッション不在
```

---

## 6. 実装フェーズ

各フェーズの詳細な実装手順は Archon plan-loop ファイルに定義されている。
各 Step の完了時に **Codex によるコードレビュー** を実施すること（レビュー指示は各 plan-loop ファイルに記載）。

| Phase | plan-loop ファイル | 概要 |
|---|---|---|
| Phase 1 | `plans/phase1-mvp/plan.md` | プロジェクト初期化、SSH接続、ターミナル、日本語IME、接続管理UI |
| Phase 2 | `plans/phase2-features/plan.md` | SFTPファイルブラウザ、tmuxセッション管理 |
| Phase 3 | `plans/phase3-release/plan.md` | テスト強化、パフォーマンス最適化、セキュリティ、リリース準備 |

### Codex レビュー方針

- 各 Step 完了後に `codex exec --full-auto` でレビューを実施する
- レビュー時の変更スコープは **該当 Step で変更したファイルのみ** に限定する
- API の破壊的変更は禁止（既存テストが壊れる変更をレビューで入れない）
- レビュー後に `flutter analyze` と `flutter test` がパスすることを確認する

### Phase 1: コア機能（MVP） - 4週間

**Week 1-2: プロジェクトセットアップ & SSH接続**
- [ ] Flutter プロジェクト初期化（iOS/Android）
- [ ] dartssh2 + xterm.dart の組み込み
- [ ] 接続情報のDB設計・実装（drift）
- [ ] 基本SSH接続（パスワード認証）
- [ ] ターミナル画面の基本実装
- [ ] ショートカットバー（Ctrl, Tab, Esc, 矢印キー）

**Week 3: 日本語IME対応**
- [ ] ImeInputHandler の実装
- [ ] composing状態の検出とバッファリング
- [ ] 未確定文字のインライン表示
- [ ] 変換確定時のSSH送信
- [ ] 各種IME（Google日本語入力、Apple標準、Gboard）でのテスト

**Week 4: 接続管理UI**
- [ ] 接続一覧画面
- [ ] 接続追加/編集フォーム
- [ ] SSH鍵認証（鍵のインポート・生成）
- [ ] ホスト鍵検証UI
- [ ] 接続のクイックアクション（接続/編集/削除）

### Phase 2: ファイルブラウザ & tmux - 3週間

**Week 5-6: ファイルブラウザ**
- [ ] SFTPクライアント初期化
- [ ] ディレクトリ一覧表示
- [ ] ファイル/フォルダのアイコン・権限・サイズ表示
- [ ] パスバー（表示・コピー）
- [ ] ファイルパスのターミナル貼り付け
- [ ] テキストファイルプレビュー
- [ ] ファイルダウンロード（進捗表示）

**Week 7: tmuxセッション管理**
- [ ] tmuxセッション一覧取得・パース
- [ ] セッション接続（attach）
- [ ] セッション作成・削除
- [ ] セッションリネーム
- [ ] UI ドロワー実装

### Phase 3: 品質向上 & リリース準備 - 2週間

**Week 8: テスト & 最適化**
- [ ] 単体テスト（IME処理、tmuxパーサー、SFTP操作）
- [ ] ウィジェットテスト（主要画面）
- [ ] 統合テスト（SSH接続 → ターミナル操作フロー）
- [ ] パフォーマンス最適化（大量出力時のスクロール、大規模ディレクトリ表示）
- [ ] メモリリーク確認

**Week 9: リリース準備**
- [ ] アプリアイコン・スプラッシュ画面
- [ ] App Store / Google Play ストア掲載情報
- [ ] プライバシーポリシー（SSH鍵等の機密データ取扱い説明）
- [ ] ベータテスト（TestFlight / Internal Testing）
- [ ] クラッシュレポート（Crashlytics）組み込み

---

## 7. 開発環境セットアップ

```bash
# Flutter SDK インストール確認
flutter --version  # >= 3.20 必須

# プロジェクト作成
flutter create --org com.example --project-name terminal_ssh_app .

# 依存パッケージ
flutter pub add dartssh2 xterm flutter_riverpod drift \
  flutter_secure_storage path_provider

# 開発用依存
flutter pub add --dev drift_dev build_runner flutter_test \
  integration_test mocktail

# iOS設定 (ios/Podfile)
# platform :ios, '13.0'

# Android設定 (android/app/build.gradle)
# minSdkVersion 23
# targetSdkVersion 34
```

---

## 8. リスクと対策

| リスク | 影響 | 対策 |
|---|---|---|
| xterm.dart のIMEサポートが不十分 | 日本語入力が正しく動かない | xterm.dart の TerminalView をカスタマイズ、必要に応じてフォークして修正。カスタム `TextInputClient` 実装の準備 |
| Bluetooth外付けキーボードでの問題 | 一部キーが効かない | xterm.dart既知問題(Android BACKSPACE)、ワークアラウンド実装 |
| 大量ファイルのSFTP listdir | UI フリーズ | `ListView.builder` で仮想スクロール、逐次表示、キャンセル可能なロード、ソートは取得完了後に実行 |
| SSH接続のモバイル特有の切断 | セッション喪失 | `connectivity_monitor` による自動再接続、バックグラウンド復帰時のPTY再描画、mosh対応検討（将来） |
| App Store審査 | リモートコード実行と見なされる可能性 | ターミナルアプリは前例多数、説明文で用途を明記 |
| 端末回転・マルチウィンドウ | ターミナル表示崩れ | PTY のウィンドウサイズ (`SIGWINCH`) を再送信、xterm.dart の `onResize` コールバックで対応 |
| 文字コード問題 | 文字化け | UTF-8前提、CRLF/LF変換はサーバー側に委ねる、ロケール設定 (`LANG=ja_JP.UTF-8`) を接続設定に追加 |

---

## 9. 追加考慮事項

### ネットワーク・ライフサイクル管理

- **ネットワーク切断検知**: `connectivity_plus` パッケージでネットワーク状態を監視、切断時にUI表示（「再接続中...」「手動再試行」ボタン）
- **バックグラウンド復帰**: アプリがフォアグラウンドに戻った際にSSH接続の生存確認、切断されていれば自動再接続
- **keepalive**: dartssh2 の keepalive 機能を有効化（30秒間隔）、モバイルのNAT timeout対策

### アクセシビリティ

- フォントサイズ変更（ピンチズーム or 設定画面）
- カラーテーマ（ダーク/ライト/ハイコントラスト）
- スクリーンリーダー最低限対応（画面タイトル、ボタンのセマンティクスラベル）

### tmux未インストール環境

- tmuxが見つからない場合、ドロワーに「tmuxが未インストールです」メッセージとインストールコマンド例を表示
- screen 等の代替は将来対応として扱う

### ライセンス・法的事項

- 使用OSSライブラリのライセンス表記画面（`flutter_oss_licenses` パッケージ）
- プライバシーポリシー（App Store / Google Play 必須）
- 輸出規制: SSH暗号化ライブラリ使用に伴うEAR/暗号輸出の確認

---

## 10. 参考プロジェクト

| プロジェクト | URL | 参考ポイント |
|---|---|---|
| ServerBox | github.com/lollipopkit/flutter_server_box | Flutter SSH/SFTPアプリの実装全般 |
| xterm.dart | github.com/TerminalStudio/xterm.dart | ターミナルエミュレータの使い方 |
| dartssh2 | github.com/TerminalStudio/dartssh2 | SSH/SFTP APIの使い方 |
| sesh | github.com/joshmedeski/sesh | tmuxセッション管理のUXデザイン |
