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
│   │   ├── ssh_key_manager.dart       # 鍵の生成・インポート・保存
│   │   └── connection_config.dart     # 接続設定モデル
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
│   │   ├── terminal_provider.dart         # ターミナル状態管理
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

  void onTextInputAction(TextEditingValue value) {
    final hasComposingRange = value.composing != TextRange.empty;

    if (hasComposingRange) {
      // 変換中: バッファに保持し、SSHには送信しない
      _isComposing = true;
      _composingText = value.text.substring(
        value.composing.start,
        value.composing.end,
      );
      // ターミナル上にインライン表示（未確定文字として）
      _showComposingPreview(_composingText);
    } else if (_isComposing) {
      // 変換確定: 確定テキストをSSHに送信
      _isComposing = false;
      final confirmedText = value.text;
      _sendToSsh(confirmedText);
      _clearComposingPreview();
    } else {
      // 通常入力（英数字等）: 即座に送信
      _sendToSsh(value.text);
    }
  }
}
```

**xterm.dart との統合ポイント**:
- `xterm.dart` v3.x は `TerminalView` ウィジェットに `inputHandler` コールバックを提供
- `TextInputClient` の `updateEditingValue` でcomposingレンジを検出
- composing中はターミナルのカーソル位置に未確定文字をオーバーレイ描画

**テスト項目**:
- [ ] 日本語ひらがな入力 → 漢字変換 → 確定で正しい文字のみ送信
- [ ] 変換候補選択中にバックスペースで文字削除
- [ ] 変換キャンセル（Escキー）で入力なし
- [ ] 英語 → 日本語 → 英語のIME切替
- [ ] 予測変換（サジェスト）タップでの確定

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

  Future<void> pastePathToTerminal(String path) async {
    // ターミナルプロバイダ経由でSSHチャネルに送信
    ref.read(terminalProvider).writeToSsh(path);
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
  /// SSH exec でtmuxセッション一覧を取得
  Future<List<TmuxSession>> fetchSessions() async {
    final result = await sshClient.execute(
      'tmux list-sessions -F '
      '\'#{session_name}\t#{session_windows}\t#{session_attached}\t#{session_created}\' '
      '2>/dev/null || echo "__NO_TMUX__"',
    );

    final output = utf8.decode(result);
    if (output.contains('__NO_TMUX__')) return [];

    return output.trim().split('\n').map((line) {
      final parts = line.split('\t');
      return TmuxSession(
        name: parts[0],
        windowCount: int.parse(parts[1]),
        isAttached: parts[2] == '1',
        createdAt: DateTime.fromMillisecondsSinceEpoch(
          int.parse(parts[3]) * 1000,
        ),
      );
    }).toList();
  }

  /// セッションにattach（ターミナルチャネル経由）
  Future<void> attachSession(String sessionName) async {
    ref.read(terminalProvider).writeToSsh('tmux attach -t $sessionName\n');
  }

  /// 新規セッション作成
  Future<void> createSession(String name) async {
    await sshClient.execute('tmux new-session -d -s ${shellEscape(name)}');
    ref.invalidateSelf(); // 一覧を更新
  }
}
```

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
| パスワード保存 | 同上、オプショナル（保存しない選択も可） |
| ホスト鍵検証 | 初回接続時にフィンガープリント表示・承認、以降はknown_hostsに保存して検証 |
| 接続情報DB | SQLite (drift) をアプリサンドボックス内に保存 |
| クリップボード | パスコピー後、一定時間で自動クリア（オプション） |

---

## 6. 実装フェーズ

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
| xterm.dart のIMEサポートが不十分 | 日本語入力が正しく動かない | xterm.dart の TerminalView をカスタマイズ、必要に応じてフォークして修正 |
| Bluetooth外付けキーボードでの問題 | 一部キーが効かない | xterm.dart既知問題(Android BACKSPACE)、ワークアラウンド実装 |
| 大量ファイルのSFTP listdir | UI フリーズ | ページネーション or 仮想スクロール（ListView.builder） |
| SSH接続のモバイル特有の切断 | セッション喪失 | 自動再接続、mosh対応検討（将来） |
| App Store審査 | リモートコード実行と見なされる可能性 | ターミナルアプリは前例多数、説明文で用途を明記 |

---

## 9. 参考プロジェクト

| プロジェクト | URL | 参考ポイント |
|---|---|---|
| ServerBox | github.com/lollipopkit/flutter_server_box | Flutter SSH/SFTPアプリの実装全般 |
| xterm.dart | github.com/TerminalStudio/xterm.dart | ターミナルエミュレータの使い方 |
| dartssh2 | github.com/TerminalStudio/dartssh2 | SSH/SFTP APIの使い方 |
| sesh | github.com/joshmedeski/sesh | tmuxセッション管理のUXデザイン |
