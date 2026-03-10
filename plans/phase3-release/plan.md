---
goal: "Phase 3 - 品質向上 & リリース準備: テスト・最適化・ストア申請"
verifyCommands:
  - flutter analyze
  - flutter test
  - flutter build apk --release
maxAttempts: 5
executeModel: claude-sonnet-4-6
evaluateModel: claude-sonnet-4-6
---

# Phase 3: 品質向上 & リリース準備

全体の実装計画は `plans/terminal-ssh-app/implementation-plan.md` を参照すること。

## 前提条件

Phase 1（コア機能 MVP）と Phase 2（ファイルブラウザ & tmux）が完了していること:
- SSH 接続・ターミナル・日本語 IME・接続管理・ファイルブラウザ・tmux 管理が動作する
- `flutter analyze` と `flutter test` がパスする
- `lib/features/file_browser/*` と `lib/features/tmux/*` の既存テストが全て green
- iOS ビルド (`flutter build ios --release --no-codesign`) は macOS 環境でのみ検証する（Linux CI では skip）

---

## Step 1: テスト強化

1. 単体テストのカバレッジを確認し、不足部分を追加する:
   - `test/core/ssh/ssh_client_service_test.dart`: 接続成功/失敗、タイムアウト、keepalive
   - `test/core/ssh/ssh_channel_manager_test.dart`: 各チャネル種別の開閉
   - `test/core/ssh/known_hosts_store_test.dart`: フィンガープリント計算、不一致検出
   - `test/core/error/app_error_test.dart`: エラー種別の網羅
   - `test/features/terminal/ime/ime_input_handler_test.dart`:
     - ひらがな → 漢字変換 → 確定
     - 変換キャンセル（空テキスト / 前回と同テキスト）
     - 連続確定（差分送信の正確性）
     - ペースト（制御文字サニタイズ）
     - Enter キー（composing 中は送信しない）
     - 絵文字・サロゲートペア
   - `test/features/file_browser/file_browser_provider_test.dart`: SFTP エラーケース
   - `test/features/tmux/tmux_provider_test.dart`: パース異常系の網羅
2. ウィジェットテストを強化する:
   - `test/features/connections/connection_list_screen_test.dart`: 一覧表示、タップ遷移、削除
   - `test/features/connections/connection_edit_screen_test.dart`: バリデーション
   - `test/features/terminal/terminal_screen_test.dart`: ショートカットバー動作
   - `test/features/file_browser/file_browser_screen_test.dart`: ドロワー開閉、パスコピー
   - `test/features/tmux/tmux_manager_screen_test.dart`: 一覧表示、作成・削除
3. 統合テストを作成する（`integration_test/`）:
   - `app_test.dart`: アプリ起動 → 接続追加 → ターミナル画面遷移の E2E フロー
   - **注意**: 実際のSSHサーバーは使わず、モックを使用する
4. `flutter test --coverage` を実行し、カバレッジレポートを出力する

### Codex レビュー

```bash
codex exec --full-auto "テストコード全体をレビューしてください。(1) テストカバレッジが十分か（特にIME処理、エラーケース）、(2) モックの使い方が適切か（mocktailの正しい使用）、(3) テストが脆弱（flaky）でないか、(4) エッジケースの漏れはないか。問題があれば修正してください。変更対象: test/** のみ（プロダクションコードは変更しない）。テスト: flutter test --coverage。カバレッジ計測: lcov で lib/features/**, lib/core/** を対象、生成コード (*.g.dart, *.freezed.dart) は除外。"
```

---

## Step 2: パフォーマンス最適化

1. ターミナル出力のパフォーマンスを最適化する:
   - `flutter run --profile` + DevTools の Frame Rendering で計測する
   - 目標: 大量出力時（10万行）でも UI スレッドの jank フレーム率 5% 以下
   - スクロールバック上限を超えた行の破棄処理を確認する
   - 必要に応じてバッチ書き込み（複数行をまとめて `Terminal` に書き込み、16ms間隔でフラッシュ）を実装する
2. SFTP ファイルブラウザの大規模ディレクトリ対応を確認する:
   - 1000+ ファイルのディレクトリで `ListView.builder` が仮想スクロールしていることを確認する
   - ソートが取得完了後に実行されることを確認する
   - ディレクトリ移動時に前のロードがキャンセルされることを確認する
3. メモリリークを確認する:
   - SSH 接続の開閉を繰り返してメモリ使用量が増加し続けないことを確認する
   - `TerminalView` の dispose 時にリソースが解放されることを確認する
   - Provider の dispose でチャネル・タイマーがクリーンアップされることを確認する
4. 端末回転・マルチウィンドウ対応:
   - 画面回転時に PTY のウィンドウサイズ（`SIGWINCH`）を再送信する
   - `xterm.dart` の `onResize` コールバックでリサイズを処理する
   - ターミナル内容が回転後に正しく再描画されることを確認する

### Codex レビュー

```bash
codex exec --full-auto "パフォーマンス最適化の実装をレビューしてください。(1) ターミナル出力のバッチ処理が正しいか（16msフラッシュ間隔）、(2) メモリリークの可能性がないか（dispose、タイマー、ストリーム、StreamSubscription.cancel）、(3) リサイズ処理（SIGWINCH再送）が正しいか。問題があれば修正してください。変更対象: lib/features/terminal/**, lib/core/ssh/** のみ。テスト: flutter test"
```

---

## Step 3: セキュリティ最終確認

1. ログ/クラッシュレポートのマスキングを実装する:
   - SSH コマンド内容をログに出力しない
   - ファイルパスをログに出力する場合はホームディレクトリを `~` にマスキングする
   - 秘密鍵の断片がクラッシュレポートに含まれないことを確認する
2. ホスト鍵検証の UI を最終確認する:
   - 初回接続: SHA-256 フィンガープリントを表示し承認を求める
   - 鍵変更時: **赤色の警告画面**で MITM の可能性を警告する
   - 承認済みホスト: 自動的に接続する
3. 鍵種別の警告を実装する:
   - ssh-rsa (SHA-1) の鍵をインポートした場合に非推奨警告を表示する
   - Ed25519/ECDSA を推奨する
4. エージェント転送はデフォルト無効であることを確認する

### Codex レビュー

```bash
codex exec --full-auto "セキュリティ実装を最終レビューしてください。(1) ログにSSHコマンド・パスワード・秘密鍵が含まれていないか（grep -r 'print\|debugPrint\|log' lib/ で確認）、(2) ホスト鍵検証のUI/ロジックが正しいか、(3) flutter_secure_storageの使い方が安全か、(4) シェルエスケープが全箇所（tmux, SFTP パス貼り付け）で適用されているか。問題があれば修正してください。変更対象: lib/** のみ（API変更禁止）。テスト: flutter test"
```

---

## Step 4: アクセシビリティ & テーマ

1. フォントサイズ変更を実装する:
   - 設定画面でフォントサイズ選択（12, 14, 16, 18, 20, 24）
   - ピンチズームでリアルタイム変更（オプション）
2. カラーテーマを実装する:
   - ダークテーマ（デフォルト）
   - ライトテーマ
   - ハイコントラストテーマ
   - テーマ切替は設定画面から
3. アクセシビリティの最低限対応:
   - 全ての画面タイトルに `Semantics` ラベルを設定する
   - ボタン・アイコンに `tooltip` / `semanticsLabel` を設定する
   - タップターゲットサイズ: 最低 48x48dp を確保する

### Codex レビュー

```bash
codex exec --full-auto "アクセシビリティとテーマの実装をレビューしてください。(1) Semanticsラベルが全画面に設定されているか、(2) タップターゲットサイズが48dp以上か（SizedBox/ConstrainedBox確認）、(3) テーマ切替が全画面に反映されるか。問題があれば修正してください。変更対象: lib/features/**, lib/core/theme/**, lib/widgets/** のみ。テスト: flutter test"
```

---

## Step 5: リリース準備

1. アプリアイコンを設定する:
   - `flutter_launcher_icons` パッケージで iOS/Android 用アイコンを生成する
   - アイコンのデザイン: ターミナルをイメージしたシンプルなデザイン
2. スプラッシュ画面を設定する:
   - `flutter_native_splash` パッケージで設定する
3. ライセンス表記画面を追加する:
   - `flutter_oss_licenses` パッケージで使用 OSS のライセンス一覧を表示する
   - 設定画面から遷移する
4. プライバシーポリシーを作成する:
   - SSH 鍵・パスワード等の機密データの取り扱い説明
   - データの保存場所（端末ローカルのみ、外部送信なし）の説明
   - 設定画面からリンクする
5. リリースビルドを確認する:
   ```bash
   flutter build apk --release
   flutter build ios --release --no-codesign
   ```
6. クラッシュレポートを組み込む:
   - `flutter pub add firebase_core firebase_crashlytics` を追加する
   - `flutterfire configure` で Firebase プロジェクトを設定する（google-services.json / GoogleService-Info.plist）
   - `main.dart` で `FlutterError.onError = FirebaseCrashlytics.instance.recordFlutterFatalError` を設定する
   - 機密情報マスキングフィルター: `FirebaseCrashlytics.instance.setCustomKey()` に SSH コマンド・パスワード・鍵断片を渡さないことを確認する
7. バージョン情報を設定する:
   - `pubspec.yaml` の `version` を `1.0.0+1` に設定する

### Codex レビュー（最終）

```bash
codex exec --full-auto "リリース準備の全体を最終レビューしてください。(1) リリースビルド（APK）が成功するか、(2) アイコン・スプラッシュが正しく設定されているか、(3) ライセンス表記に漏れはないか（pubspec.yamlの全依存パッケージ）、(4) プライバシーポリシーの内容が適切か、(5) Crashlyticsで機密情報がマスキングされているか、(6) debugPrint/kDebugMode がリリースビルドで無効化されるか。問題があれば修正してください。変更対象: pubspec.yaml, lib/**, assets/** のみ。テスト: flutter analyze && flutter test && flutter build apk --release"
```

---

## Expected Outcome

- `flutter analyze` がエラーなしで通る
- `flutter test` で全テスト（Phase 1 + 2 + 3）がパスする
- `flutter build apk --release` と `flutter build ios --release --no-codesign` が成功する
- テストカバレッジが主要ロジック（IME, tmux パーサー, SFTP 操作）で 80% 以上
- セキュリティレビュー指摘事項が全て対応済み
- ダーク/ライト/ハイコントラストのテーマ切替が動作する
- ライセンス表記とプライバシーポリシーが表示される
- アプリがストア申請可能な状態になっている

## 制約

- Phase 1, 2 で実装した機能を壊さないこと
- 全ての既存テストが通り続けること
- リリースビルドに debug 用コードが含まれないこと
