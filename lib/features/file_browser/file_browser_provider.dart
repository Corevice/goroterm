import 'dart:async';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../../core/platform/download_helper.dart';
import '../../core/platform/download_isolate.dart';
import 'dart:io';

import '../../core/error/app_error.dart';
import '../../core/ssh/ssh_channel_manager.dart';
import '../../core/utils/shell_utils.dart';

class FileBrowserState {
  const FileBrowserState({
    this.currentPath = '/',
    this.items = const [],
    this.showHidden = false,
    this.downloadProgress,
    this.downloadedFilePath,
    this.uploadProgress,
    this.uploadCompleteFile,
  });

  final String currentPath;
  final List<SftpName> items;
  final bool showHidden;

  /// Progress 0.0–1.0 while downloading, null otherwise.
  final double? downloadProgress;

  /// Path of the last successfully downloaded file.
  final String? downloadedFilePath;

  /// Progress 0.0–1.0 while uploading, null otherwise.
  final double? uploadProgress;

  /// Filename of the last successfully uploaded file.
  final String? uploadCompleteFile;

  FileBrowserState copyWith({
    String? currentPath,
    List<SftpName>? items,
    bool? showHidden,
    Object? downloadProgress = _absent,
    Object? downloadedFilePath = _absent,
    Object? uploadProgress = _absent,
    Object? uploadCompleteFile = _absent,
  }) {
    return FileBrowserState(
      currentPath: currentPath ?? this.currentPath,
      items: items ?? this.items,
      showHidden: showHidden ?? this.showHidden,
      downloadProgress: identical(downloadProgress, _absent)
          ? this.downloadProgress
          : downloadProgress as double?,
      downloadedFilePath: identical(downloadedFilePath, _absent)
          ? this.downloadedFilePath
          : downloadedFilePath as String?,
      uploadProgress: identical(uploadProgress, _absent)
          ? this.uploadProgress
          : uploadProgress as double?,
      uploadCompleteFile: identical(uploadCompleteFile, _absent)
          ? this.uploadCompleteFile
          : uploadCompleteFile as String?,
    );
  }

  /// Items visible under the current [showHidden] setting.
  List<SftpName> get visibleItems {
    if (showHidden) return items;
    return items.where((e) => !e.filename.startsWith('.')).toList();
  }

  /// Parent path of [currentPath], or null if already at '/'.
  String? get parentPath {
    if (currentPath == '/') return null;
    final parent = p.dirname(currentPath);
    return parent.isEmpty ? '/' : parent;
  }

  static const _absent = Object();
}

class FileBrowserNotifier
    extends FamilyAsyncNotifier<FileBrowserState, String> {
  SshChannelManager? _channelManager;
  SftpClient? _sftp;
  int _loadGeneration = 0;
  bool _isDownloading = false;
  int _downloadGeneration = 0;
  DownloadIsolate? _activeDownload;

  // ダウンロード専用 Isolate のための接続情報
  String? _host;
  int _port = 22;
  String? _username;
  String? _password;
  String? _privateKeyPem;
  String? _passphrase;

  /// ダウンロード用の接続情報を設定する。
  void setConnectionCredentials({
    required String host,
    required int port,
    required String username,
    String? password,
    String? privateKeyPem,
    String? passphrase,
  }) {
    _host = host;
    _port = port;
    _username = username;
    _password = password;
    _privateKeyPem = privateKeyPem;
    _passphrase = passphrase;
  }

  /// Called by TerminalScreen when the SSH channelManager changes.
  void setChannelManager(SshChannelManager? channelManager) {
    if (_channelManager == channelManager) return;
    _channelManager = channelManager;
    _sftp = null;
    _downloadGeneration++;
    _activeDownload?.cancel();
    _activeDownload = null;
    if (channelManager != null) {
      _initializeState(channelManager);
    } else {
      // ダウンロード中は AsyncError 遷移を遅延
      // downloadFile() の finally で _channelManager == null をチェックし遷移する
      if (!_isDownloading) {
        state = AsyncError(NetworkError('SSH not connected'), StackTrace.current);
      }
    }
  }

  Future<void> _initializeState(SshChannelManager channelManager) async {
    state = const AsyncLoading();
    try {
      _sftp = await channelManager.openSftpChannel();
      String initialPath = '/';
      try {
        initialPath = await _sftp!.absolute('.');
      } catch (_) {
        // Fall back to / if absolute path resolution fails
      }
      final items = await _fetchItems(initialPath);
      state = AsyncData(FileBrowserState(
        currentPath: initialPath,
        items: items ?? [],
      ));
    } catch (e, st) {
      state = AsyncError(e, st);
    }
  }

  @override
  Future<FileBrowserState> build(String arg) async {
    final channelManager = _channelManager;
    if (channelManager == null) {
      throw NetworkError('SSH not connected');
    }
    _sftp = await channelManager.openSftpChannel();

    String initialPath = '/';
    try {
      initialPath = await _sftp!.absolute('.');
    } catch (_) {
      // Fall back to / if absolute path resolution fails
    }

    final items = await _fetchItems(initialPath);
    return FileBrowserState(currentPath: initialPath, items: items ?? []);
  }

  /// Fetch and sort directory items. Returns null if load was superseded.
  Future<List<SftpName>?> _fetchItems(String path) async {
    final sftp = _sftp;
    if (sftp == null) throw NetworkError('SFTP not initialized');
    final gen = ++_loadGeneration;
    try {
      final items = await sftp.listdir(path);
      if (gen != _loadGeneration) return null;
      return items
          .where((e) => e.filename != '.' && e.filename != '..')
          .toList()
        ..sort((a, b) {
          final aIsDir = a.attr.isDirectory;
          final bIsDir = b.attr.isDirectory;
          if (aIsDir != bIsDir) return aIsDir ? -1 : 1;
          return a.filename.compareTo(b.filename);
        });
    } catch (e) {
      if (gen != _loadGeneration) return null;
      if (e is SftpStatusError && e.code == SftpStatusCode.permissionDenied) {
        throw PermissionError('Permission denied: $path');
      }
      rethrow;
    }
  }

  /// Navigates to the terminal's current working directory if available,
  /// otherwise falls back to the SSH login home directory.
  /// Called when the file browser drawer is opened.
  ///
  /// CWD 取得は Linux の /proc を利用した best-effort アプローチ。
  /// macOS/BSD リモートホストや権限不足の場合はホームディレクトリにフォールバック。
  Future<void> navigateToInitialDirectory({String? tmuxSessionName}) async {
    final sftp = _sftp;
    if (sftp == null) return;

    final channelManager = _channelManager;
    if (channelManager != null) {
      try {
        String? cwd;

        // tmux セッション内の場合は tmux コマンドで CWD を取得（最も正確）
        if (tmuxSessionName != null && tmuxSessionName.isNotEmpty) {
          cwd = await channelManager.getTmuxPaneCwd(tmuxSessionName);
        }

        // tmux CWD が取れなかった場合は /proc ベースのフォールバック
        cwd ??= await channelManager.getShellCwd();

        // getShellCwd() は非同期のため、結果が返る前に channelManager が
        // 差し替わっている可能性がある（再接続等）。stale result を無視する。
        if (cwd != null && cwd.isNotEmpty && _channelManager == channelManager) {
          await navigateTo(cwd);
          return;
        }
      } catch (_) {
        // CWD 取得失敗 → ホームディレクトリにフォールバック
      }
    }

    // フォールバック: ホームディレクトリ
    try {
      final home = await sftp.absolute('.');
      if (home.isNotEmpty) {
        await navigateTo(home);
      }
    } catch (_) {
      // If resolution fails, leave the current path unchanged.
    }
  }

  Future<void> navigateTo(String path) async {
    final prevState = state.valueOrNull ?? const FileBrowserState();
    state = const AsyncLoading();
    try {
      final items = await _fetchItems(path);
      if (items == null) return; // superseded
      state = AsyncData(
        prevState.copyWith(currentPath: path, items: items),
      );
    } catch (e, st) {
      state = AsyncError(e, st);
    }
  }

  Future<void> refresh() async {
    final current = state.valueOrNull;
    if (current == null) return;
    await navigateTo(current.currentPath);
  }

  void toggleHidden() {
    final current = state.valueOrNull;
    if (current == null) return;
    state = AsyncData(current.copyWith(showHidden: !current.showHidden));
  }

  /// Reads up to [maxBytes] of a remote file for preview.
  Future<Uint8List> readFileBytes(
    String remotePath, {
    int maxBytes = 1024 * 1024,
  }) async {
    final sftp = _sftp ?? (throw NetworkError('SFTP not initialized'));
    final file = await sftp.open(remotePath, mode: SftpFileOpenMode.read);
    try {
      // Try to get precise size; fall back to maxBytes if unavailable.
      int readLength = maxBytes;
      try {
        final stat = await file.stat();
        final fileSize = stat.size;
        if (fileSize != null && fileSize > 0 && fileSize < maxBytes) {
          readLength = fileSize;
        }
      } catch (_) {
        // Stat failed; read up to maxBytes.
      }
      return await file.readBytes(length: readLength);
    } finally {
      await file.close();
    }
  }

  /// Downloads a remote file to Downloads (Android) or share sheet (iOS).
  /// Updates [FileBrowserState.downloadProgress] during transfer.
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

  Future<void> _downloadFileCore(
    String remotePath,
    FileBrowserState baseState,
  ) async {
    final host = _host;
    final username = _username;
    if (host == null || username == null) {
      throw NetworkError('Connection credentials not set');
    }

    final sftp = _sftp ?? (throw NetworkError('SFTP not initialized'));
    final filename = p.basename(remotePath);
    final generation = _downloadGeneration;

    // 一時ファイルにダウンロード
    final tempDir = await getTemporaryDirectory();
    final tempPath = p.join(tempDir.path, filename);
    final tempFile = File(tempPath);
    if (await tempFile.exists()) await tempFile.delete();

    // ファイルサイズを SFTP で取得（進捗表示用）
    int totalBytes = 0;
    try {
      final stat = await sftp.stat(remotePath);
      totalBytes = stat.size ?? 0;
    } catch (_) {}

    // ダウンロード全体を別 Isolate で実行。
    // SSH 接続の確立・SFTP プロトコル処理・ファイル書き込みのすべてが
    // バックグラウンド Isolate で行われるため、メインアイソレートの
    // UI スレッドを一切ブロックしない。
    final download = await DownloadIsolate.start(
      host: host,
      port: _port,
      username: username,
      password: _password,
      privateKeyPem: _privateKeyPem,
      passphrase: _passphrase,
      remotePath: remotePath,
      localPath: tempPath,
      totalBytes: totalBytes,
    );
    _activeDownload = download;

    // 進捗をリスンして UI を更新
    StreamSubscription<double>? progressSub;
    progressSub = download.progressStream.listen((progress) {
      if (_downloadGeneration != generation) {
        progressSub?.cancel();
        return;
      }
      final cur = state.valueOrNull;
      if (cur != null) {
        state = AsyncData(cur.copyWith(downloadProgress: progress));
      }
    });

    try {
      final error = await download.result;
      _activeDownload = null;
      await progressSub.cancel();

      if (_downloadGeneration != generation) {
        throw NetworkError('Download cancelled');
      }

      if (error != null) {
        throw NetworkError(error);
      }
    } catch (e) {
      _activeDownload = null;
      await progressSub.cancel();
      rethrow;
    }

    // MediaStore で Downloads に保存（Android）/ シェアシート（iOS）
    String savedName;
    try {
      savedName = await DownloadHelper.saveToDownloads(
        tempFilePath: tempPath,
        fileName: filename,
      );
    } catch (e) {
      debugPrint('saveToDownloads error: $e');
      savedName = filename;
    }

    if (_downloadGeneration != generation) {
      throw NetworkError('Download cancelled');
    }

    final cur = state.valueOrNull ?? baseState;
    state = AsyncData(
      cur.copyWith(
        downloadProgress: null,
        downloadedFilePath: savedName,
      ),
    );
  }

  /// Clears the downloaded file notification.
  void clearDownloadNotification() {
    final current = state.valueOrNull;
    if (current == null) return;
    state = AsyncData(current.copyWith(downloadedFilePath: null));
  }

  /// Uploads a local file to the current remote directory.
  /// Updates [FileBrowserState.uploadProgress] during transfer.
  Future<void> uploadFile(String localPath) async {
    final sftp = _sftp ?? (throw NetworkError('SFTP not initialized'));
    final current = state.valueOrNull ?? const FileBrowserState();
    final fileName = p.basename(localPath);
    final remotePath = '${current.currentPath}/$fileName';

    state = AsyncData(current.copyWith(
      uploadProgress: 0.0,
      uploadCompleteFile: null,
    ));

    final localFile = File(localPath);
    final fileSize = await localFile.length();

    try {
      final remoteFile = await sftp.open(
        remotePath,
        mode: SftpFileOpenMode.write |
            SftpFileOpenMode.create |
            SftpFileOpenMode.truncate,
      );
      try {
        final inputStream =
            localFile.openRead().map((chunk) => Uint8List.fromList(chunk));
        await remoteFile
            .write(
              inputStream,
              onProgress: (bytesWritten) {
                if (fileSize > 0) {
                  final cur = state.valueOrNull ?? current;
                  state = AsyncData(cur.copyWith(
                    uploadProgress: bytesWritten / fileSize,
                  ));
                }
              },
            )
            .done;
      } finally {
        await remoteFile.close();
      }
    } catch (e) {
      final cur = state.valueOrNull ?? current;
      state = AsyncData(cur.copyWith(uploadProgress: null));
      rethrow;
    }

    final cur = state.valueOrNull ?? current;
    state = AsyncData(cur.copyWith(
      uploadProgress: null,
      uploadCompleteFile: fileName,
    ));

    await refresh();
  }

  /// Clears the upload complete notification.
  void clearUploadNotification() {
    final current = state.valueOrNull;
    if (current == null) return;
    state = AsyncData(current.copyWith(uploadCompleteFile: null));
  }

  /// Deletes a remote file or empty directory, then refreshes the listing.
  Future<void> deleteFile(String remotePath, {bool isDirectory = false}) async {
    final sftp = _sftp ?? (throw NetworkError('SFTP not initialized'));
    if (isDirectory) {
      await sftp.rmdir(remotePath);
    } else {
      await sftp.remove(remotePath);
    }
    await refresh();
  }

  /// Renames/moves a remote file or directory, then refreshes the listing.
  Future<void> renameFile(String oldPath, String newPath) async {
    final sftp = _sftp ?? (throw NetworkError('SFTP not initialized'));
    await sftp.rename(oldPath, newPath);
    await refresh();
  }
}

final fileBrowserProvider = AsyncNotifierProvider.family<FileBrowserNotifier,
    FileBrowserState, String>(
  FileBrowserNotifier.new,
);

// ---------------------------------------------------------------------------
// Shell escape utility (also used by path_bar_widget)
// ---------------------------------------------------------------------------

/// Wraps [path] in single quotes and escapes any embedded single quotes.
/// Safe against all shell metacharacters (spaces, $, ;, |, etc.).
String shellEscapePath(String path) => shellQuote(path);

/// Human-readable file size (e.g. "1.2 MB").
String humanReadableSize(int? bytes) {
  if (bytes == null) return '';
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
}

/// Unix permission string from [SftpFileMode], e.g. "rwxr-xr-x".
String permissionString(SftpFileMode? mode) {
  if (mode == null) return '---------';
  String bit(bool r, bool w, bool x) =>
      (r ? 'r' : '-') + (w ? 'w' : '-') + (x ? 'x' : '-');
  return bit(mode.userRead, mode.userWrite, mode.userExecute) +
      bit(mode.groupRead, mode.groupWrite, mode.groupExecute) +
      bit(mode.otherRead, mode.otherWrite, mode.otherExecute);
}
