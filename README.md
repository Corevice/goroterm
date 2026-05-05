# GoroTerm

A mobile SSH terminal app optimized for **Claude Code** development on the go.

Connect to remote servers, run Claude Code sessions, and manage your workflow — all from iOS or Android.

<p align="center">
  <img src="https://img.shields.io/badge/Flutter-3.27+-02569B?style=flat&logo=flutter" alt="Flutter" />
  <img src="https://img.shields.io/badge/License-MIT-green.svg" alt="MIT License" />
  <img src="https://img.shields.io/badge/iOS-Android-lightgray" alt="Platforms" />
</p>

## Why GoroTerm?

GoroTerm is built for developers who use **Claude Code** as their primary coding assistant on remote servers. Every feature is designed around this workflow:

### Claude Code Optimized

- **One-tap Claude commands** — Quick action buttons to launch `claude` and `claude --continue` without typing
- **Real-time status detection** — Automatically detects when Claude Code is running and shows a spinner indicator on the tab
- **Usage tracking** — View Claude Code subscription and usage directly in the app (via Anthropic OAuth)
- **Plan mode support** — Terminal alt buffer handling works seamlessly with Claude Code's interactive plan mode

### Terminal Features

- **Full SSH support** — Password and key-based authentication
- **Japanese IME** — Complete Japanese input support for terminal commands
- **tmux integration** — Manage multiple tmux sessions and windows
- **SFTP file browser** — Upload/download files with progress tracking
- **Mobile quick action bar** — Ctrl shortcuts (C-c, C-d, C-j), arrow keys, Tab/Shift+Tab, paste
- **Voice input** — Dictate commands hands-free
- **Encrypted credentials** — SSH passwords and keys stored in Keychain/Keystore

## Screenshots

| Terminal | Quick Actions | File Browser |
|----------|--------------|--------------|
| SSH terminal with Claude Code running | One-tap Claude commands and shortcuts | SFTP file management |

## Quick Start

```bash
git clone https://github.com/Corevice/goroterm.git
cd goroterm
flutter pub get
flutter run
```

## Claude Code Workflow

1. SSH into your server
2. Tap the **Claude** button to start a Claude Code session
3. Claude Code status appears on the tab while running
4. Tap **Continue** to resume with `claude --continue`
5. Check **Usage** to view subscription details

## Architecture

| Layer | Technology |
|-------|-----------|
| State management | Riverpod |
| SSH | dartssh2 |
| Terminal | xterm (forked for IME / mobile) |
| Database | drift (SQLite) |
| Secure storage | flutter_secure_storage |

## Requirements

- Flutter 3.27+
- Dart 3.6+
- iOS 12.0+ / Android 7.0+

## Documentation

- [日本語版 README](README.ja.md)

## License

MIT — see [LICENSE](LICENSE)
