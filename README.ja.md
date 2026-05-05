# GoroTerm

**Claude Code** 開発に最適化したモバイル SSH ターミナルアプリ。

外出先でもリモートサーバーに接続し、Claude Code セッションを実行して開発ワークフローを完遂できます。

<p align="center">
  <img src="https://img.shields.io/badge/Flutter-3.27+-02569B?style=flat&logo=flutter" alt="Flutter" />
  <img src="https://img.shields.io/badge/License-MIT-green.svg" alt="MIT License" />
  <img src="https://img.shields.io/badge/iOS-Android-lightgray" alt="Platforms" />
</p>

## GoroTerm の特徴

GoroTerm は、**Claude Code** をメインのコーディングアシスタントとしてリモートサーバーで使う開発者向けに設計されました。

### Claude Code 最適化

- **ワンタップ Claude コマンド** — `claude` と `claude --continue` をキーボード打たずにワンタップで起動
- **稼働状態の自動検出** — タブに Claude Code が稼働中であることをスピナーで表示
- **使用量確認** — アプリ内から Claude Code のサブスクリプションと使用量を確認（Anthropic OAuth 経由）
- **プランモード対応** — ターミナルの alt バッファをシームレスに扱い、Claude Code の対話型プランモードも問題なく動作

### ターミナル機能

- **完全な SSH 対応** — パスワード認証と鍵認証の両方対応
- **日本語 IME** — 日本語入力を完全サポート（全角/半角、変換確定など）
- **tmux 統合** — 複数の tmux セッションとウィンドウを管理
- **SFTP ファイルブラウザ** — 進捗表示付きファイルアップロード/ダウンロード
- **モバイルクイックアクションバー** — Ctrl ショートカット（C-c, C-d, C-j）、矢印キー、Tab/Shift+Tab、ペースト
- **音声入力** — ハンズフリーでコマンドを口述
- **暗号化クレデンシャル** — SSH パスワードと鍵を Keychain/Keystore に安全に保存

## 起動方法

```bash
git clone https://github.com/Corevice/goroterm.git
cd goroterm
flutter pub get
flutter run
```

## Claude Code ワークフロー

1. SSH でサーバーに接続
2. **Claude** ボタンをタップして Claude Code セッションを開始
3. タブに Claude Code 稼働中のスピナーが表示されます
4. **Continue** ボタンで `claude --continue` を実行
5. **使用量** でサブスクリプション詳細を確認

## アーキテクチャ

| レイヤー | テクノロジー |
|---------|-------------|
| ステート管理 | Riverpod |
| SSH | dartssh2 |
| ターミナル | xterm（IME/モバイル用フォーク） |
| データベース | drift（SQLite） |
| セキュアストレージ | flutter_secure_storage |

## 動作環境

- Flutter 3.27+
- Dart 3.6+
- iOS 12.0+ / Android 7.0+

## Documentation

- [English README](README.md)

## License

MIT — see [LICENSE](LICENSE)
