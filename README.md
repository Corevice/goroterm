# GoroTerm

SSH terminal app for iOS and Android, built with Flutter.

## Features

- SSH connection with password and key-based authentication
- Full terminal emulation with IME (Japanese input) support
- SFTP file browser with upload/download
- tmux session management
- Mobile-optimized quick action bar (Ctrl shortcuts, arrow keys, paste)
- Connection management with encrypted credential storage
- Voice input support

## Requirements

- Flutter 3.27+
- Dart 3.6+

## Getting Started

```bash
flutter pub get
flutter run
```

## Architecture

- **State management**: Riverpod (`flutter_riverpod`)
- **SSH**: `dartssh2`
- **Terminal**: `xterm` (forked and heavily modified for IME / mobile)
- **Database**: `drift` (SQLite)
- **Secure storage**: `flutter_secure_storage` (Keychain / Keystore)

## License

MIT — see [LICENSE](LICENSE)
