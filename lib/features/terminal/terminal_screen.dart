import 'dart:async';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:xterm/xterm.dart';

import '../../core/ssh/connection_config.dart';
import '../../core/ssh/ssh_channel_manager.dart';
import '../../core/ssh/ssh_key_manager.dart';
import '../../core/storage/database.dart';
import '../../core/theme/theme_provider.dart';
import '../connections/connection_provider.dart';
import 'password_dialog.dart';
import 'session_manager.dart';
import 'terminal_connection_provider.dart';
import '../file_browser/file_browser_provider.dart';
import '../file_browser/file_browser_screen.dart';
import '../tmux/tmux_manager_screen.dart';
import '../tmux/tmux_provider.dart';
import '../../widgets/quick_action_bar.dart';
import '../../core/utils/app_logger.dart';
import '../../core/utils/shell_utils.dart';
import '../../widgets/terminal_scroll_interceptor.dart';
import '../claude_usage/claude_usage_dialog.dart';
import '../../widgets/terminal_selection_toolbar.dart';

/// Multi-session terminal screen. Manages tabs via [SessionManagerNotifier].
class TerminalScreen extends ConsumerStatefulWidget {
  const TerminalScreen({super.key});

  @override
  ConsumerState<TerminalScreen> createState() => _TerminalScreenState();
}

class _TerminalScreenState extends ConsumerState<TerminalScreen>
    with WidgetsBindingObserver {
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  final _drawerClosedNotifier = ValueNotifier<int>(0);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    HardwareKeyboard.instance.addHandler(_handleHardwareKey);
    // フォアグラウンドサービスからの keepalive メッセージを受信
    FlutterForegroundTask.addTaskDataCallback(_onTaskData);
  }

  @override
  void dispose() {
    FlutterForegroundTask.removeTaskDataCallback(_onTaskData);
    HardwareKeyboard.instance.removeHandler(_handleHardwareKey);
    WidgetsBinding.instance.removeObserver(this);
    _drawerClosedNotifier.dispose();
    super.dispose();
  }

  void _onTaskData(Object data) {
    if (data == 'keepalive' && mounted) {
      AppLogger.instance.log('[SSH] keepalive tick from service');
      final managerState = ref.read(sessionManagerProvider);
      // 毎回（10秒間隔）activeKeepAlive を実行。
      // SSH exec チャネルでネットワークパケットを送信し、
      // NAT テーブルを維持し続ける。
      // execute('true') は軽量（open→close）なので 10 秒間隔なら過負荷にならない。
      for (final session in managerState.sessions) {
        ref
            .read(terminalConnectionProvider(session.sessionId).notifier)
            .activeKeepAlive();
      }
    }
  }

  bool _handleHardwareKey(KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return false;
    if (event.logicalKey == LogicalKeyboardKey.audioVolumeUp) {
      ref.read(fontSizeProvider.notifier).increase();
      _showFontSizeIndicator();
      return true;
    }
    if (event.logicalKey == LogicalKeyboardKey.audioVolumeDown) {
      ref.read(fontSizeProvider.notifier).decrease();
      _showFontSizeIndicator();
      return true;
    }
    return false;
  }

  void _showFontSizeIndicator() {
    final size = ref.read(fontSizeProvider);
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text('Font size: ${size.toInt()}'),
          duration: const Duration(seconds: 1),
          behavior: SnackBarBehavior.floating,
        ),
      );
  }

  void _attachTmuxSession(int connectionId, String tmuxSessionName) {
    final manager = ref.read(sessionManagerProvider.notifier);

    final existingId = manager.findSessionByTmux(connectionId, tmuxSessionName);
    if (existingId != null) {
      manager.setActiveSession(existingId);
    } else {
      manager.addTmuxSession(
        connectionId: connectionId,
        tmuxSessionName: tmuxSessionName,
      );
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      // バックグラウンド移行時に Drawer を閉じて黒画面を防止
      // inactive ではなく paused のみ（inactive はアプリスイッチャー等でも発火する）
      if (!mounted) return;
      final scaffoldState = _scaffoldKey.currentState;
      if (scaffoldState != null) {
        if (scaffoldState.isDrawerOpen || scaffoldState.isEndDrawerOpen) {
          Navigator.of(context).pop();
        }
      }
    }
    if (state == AppLifecycleState.resumed) {
      // フォアグラウンドサービスのおかげで通常は接続維持されているが、
      // 万一の切断に備えて短い遅延後にチェック
      Future.delayed(const Duration(milliseconds: 1500), () {
        if (!mounted) return;
        final managerState = ref.read(sessionManagerProvider);
        // 全セッションの接続を確認（バックグラウンドで全部死んでいる可能性がある）
        for (final session in managerState.sessions) {
          ref
              .read(terminalConnectionProvider(session.sessionId).notifier)
              .checkConnection();
        }
      });

      // 状態ベースでタブクリーンアップ判定:
      // 再接続中のセッションがなくなり、全 disconnected ならクリーンアップ
      _scheduleCleanupCheck(0);
    }
  }

  void _scheduleCleanupCheck(int attempt) {
    // 再接続が試行されるため、自動でタブを閉じない。
    // ユーザーが手動でタブを閉じるか、接続画面に戻ることで対応する。
  }

  Future<void> _showConnectionPicker(BuildContext context, WidgetRef ref) async {
    final connections = await ref.read(connectionListProvider.future);
    if (!context.mounted || connections.isEmpty) return;

    final selected = await showModalBottomSheet<Connection>(
      context: context,
      backgroundColor: Colors.grey[900],
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                'Select connection',
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.bold),
              ),
            ),
            ...connections.map((conn) => ListTile(
                  leading:
                      const Icon(Icons.dns, color: Colors.tealAccent),
                  title: Text(
                    conn.label.isNotEmpty ? conn.label : conn.host,
                    style: const TextStyle(color: Colors.white),
                  ),
                  subtitle: Text(
                    '${conn.username}@${conn.host}:${conn.port}',
                    style: TextStyle(color: Colors.grey[500]),
                  ),
                  onTap: () => Navigator.of(ctx).pop(conn),
                )),
          ],
        ),
      ),
    );

    if (selected != null) {
      final label =
          selected.label.isNotEmpty ? selected.label : selected.host;
      ref.read(sessionManagerProvider.notifier).addSession(
            connectionId: selected.id,
            label: label,
          );
    }
  }

  @override
  Widget build(BuildContext context) {
    final managerState = ref.watch(sessionManagerProvider);
    final sessions = managerState.sessions;

    ref.listen<SessionManagerState>(sessionManagerProvider, (prev, next) {
      if (next.batteryWarning && !(prev?.batteryWarning ?? false)) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'バッテリー最適化が有効です。バックグラウンドでSSH接続が切れる可能性があります。',
            ),
            duration: Duration(seconds: 5),
          ),
        );
      }
    });

    if (sessions.isEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.of(context).pop();
      });
      return const Scaffold(
        backgroundColor: Colors.black,
        body: Center(child: CircularProgressIndicator()),
      );
    }

    final activeId = managerState.activeSessionId ?? sessions.first.sessionId;
    final activeIdx =
        sessions.indexWhere((s) => s.sessionId == activeId).clamp(0, sessions.length - 1);
    final activeSession = sessions[activeIdx];

    final activeConnectionState =
        ref.watch(terminalConnectionProvider(activeSession.sessionId));

    return Scaffold(
      key: _scaffoldKey,
      backgroundColor: Colors.black,
      // Left drawer (right-swipe): File Browser for active session
      drawer: Drawer(
        width: MediaQuery.of(context).size.width * 0.85,
        backgroundColor: Colors.grey[900],
        child: SafeArea(
          child: FileBrowserScreen(connectionId: activeSession.sessionId),
        ),
      ),
      onDrawerChanged: (isOpened) {
        if (isOpened) {
          ref
              .read(fileBrowserProvider(activeSession.sessionId).notifier)
              .navigateToInitialDirectory(
                tmuxSessionName: activeSession.tmuxSessionName,
              );
        }
      },
      // Right drawer (left-swipe): tmux Session Manager for active session
      endDrawer: Drawer(
        width: MediaQuery.of(context).size.width * 0.85,
        backgroundColor: Colors.grey[900],
        child: SafeArea(
          child: TmuxManagerScreen(
            connectionId: activeSession.sessionId,
            onAttachSession: (tmuxSessionName) {
              // Drawer は _SessionListView 側の Navigator.pop() で閉じられる
              // ここで pop すると TerminalScreen 自体が pop されてしまう
              _attachTmuxSession(activeSession.connectionId, tmuxSessionName);
            },
          ),
        ),
      ),
      onEndDrawerChanged: (isOpened) {
        final notifier =
            ref.read(tmuxProvider(activeSession.sessionId).notifier);
        if (isOpened) {
          notifier.startAutoRefresh();
        } else {
          notifier.stopAutoRefresh();
          // ドロワーが閉じたらアクティブタブのフォーカス復帰を通知
          _drawerClosedNotifier.value++;
        }
      },
      appBar: AppBar(
        backgroundColor: Colors.grey[900],
        leading: Builder(
          builder: (context) => IconButton(
            icon: const Icon(Icons.folder_open),
            tooltip: 'File Browser',
            onPressed: () => Scaffold.of(context).openDrawer(),
          ),
        ),
        title: Text(activeConnectionState.hostLabel ?? activeSession.label),
        actions: [
          if (activeConnectionState.status == ConnectionStatus.reconnecting)
            const Padding(
              padding: EdgeInsets.all(16),
              child: SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          Builder(
            builder: (context) => IconButton(
              icon: const Icon(Icons.view_list),
              tooltip: 'tmux Sessions',
              onPressed: () => Scaffold.of(context).openEndDrawer(),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: 'New terminal tab',
            onPressed: () => _showConnectionPicker(context, ref),
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert),
            onSelected: (value) {
              if (value == 'claude_usage') {
                ClaudeUsageDialog.show(context, activeSession.sessionId);
              }
            },
            itemBuilder: (_) => [
              const PopupMenuItem(
                value: 'claude_usage',
                child: Row(
                  children: [
                    Icon(Icons.analytics_outlined, size: 20),
                    SizedBox(width: 12),
                    Text('Claude Code Usage'),
                  ],
                ),
              ),
            ],
          ),
        ],
        // Show tab strip below title (always visible so the current tab name is shown)
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(36),
          child: _TabStrip(
            sessions: sessions,
            activeSessionId: activeSession.sessionId,
            onSelect: (id) => ref
                .read(sessionManagerProvider.notifier)
                .setActiveSession(id),
            onClose: (id) => ref
                .read(sessionManagerProvider.notifier)
                .removeSession(id),
          ),
        ),
      ),
      body: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onHorizontalDragEnd: sessions.length > 1
            ? (details) {
                final velocity = details.primaryVelocity ?? 0;
                if (velocity > 300) {
                  // 右スワイプ → 前のタブ
                  if (activeIdx > 0) {
                    ref
                        .read(sessionManagerProvider.notifier)
                        .setActiveSession(sessions[activeIdx - 1].sessionId);
                  }
                } else if (velocity < -300) {
                  // 左スワイプ → 次のタブ
                  if (activeIdx < sessions.length - 1) {
                    ref
                        .read(sessionManagerProvider.notifier)
                        .setActiveSession(sessions[activeIdx + 1].sessionId);
                  }
                }
              }
            : null,
        child: IndexedStack(
          index: activeIdx,
          children: sessions
              .map((s) => _TerminalTabContent(
                    key: ValueKey(s.sessionId),
                    sessionId: s.sessionId,
                    connectionId: s.connectionId,
                    isActive: s.sessionId == activeSession.sessionId,
                    tmuxSessionName: s.tmuxSessionName,
                    drawerClosedNotifier: _drawerClosedNotifier,
                  ))
              .toList(),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------

class _TabStrip extends StatelessWidget {
  const _TabStrip({
    required this.sessions,
    required this.activeSessionId,
    required this.onSelect,
    required this.onClose,
  });

  final List<TerminalSession> sessions;
  final String activeSessionId;
  final ValueChanged<String> onSelect;
  final ValueChanged<String> onClose;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 36,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        itemCount: sessions.length,
        itemBuilder: (context, index) {
          final session = sessions[index];
          final isActive = session.sessionId == activeSessionId;
          return InkWell(
            onTap: () => onSelect(session.sessionId),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              decoration: BoxDecoration(
                color: isActive ? Colors.grey[800] : Colors.grey[900],
                border: isActive
                    ? const Border(
                        bottom: BorderSide(color: Colors.tealAccent, width: 2))
                    : null,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    session.label,
                    style: TextStyle(
                      color: isActive ? Colors.white : Colors.grey[400],
                      fontSize: 12,
                    ),
                  ),
                  const SizedBox(width: 4),
                  InkWell(
                    onTap: () => onClose(session.sessionId),
                    child: Icon(
                      Icons.close,
                      size: 14,
                      color: Colors.grey[400],
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

// ---------------------------------------------------------------------------

/// Terminal content for a single session tab. Manages its own lifecycle.
class _TerminalTabContent extends ConsumerStatefulWidget {
  const _TerminalTabContent({
    super.key,
    required this.sessionId,
    required this.connectionId,
    required this.isActive,
    this.tmuxSessionName,
    this.drawerClosedNotifier,
  });

  final String sessionId;
  final int connectionId;
  final bool isActive;

  /// If set, automatically runs `tmux attach -t <name>` once connected.
  final String? tmuxSessionName;

  /// ドロワーが閉じたことを通知する。フォーカス復帰に使用。
  final ValueNotifier<int>? drawerClosedNotifier;

  @override
  ConsumerState<_TerminalTabContent> createState() =>
      _TerminalTabContentState();
}

class _TerminalTabContentState extends ConsumerState<_TerminalTabContent>
    with AutomaticKeepAliveClientMixin {
  final _terminalController = TerminalController();
  final _focusNode = FocusNode();
  final _scrollController = ScrollController();
  OverlayEntry? _toolbarOverlay;
  Timer? _toolbarAutoHideTimer;
  ProviderSubscription<SshChannelManager?>? _channelManagerSubscription;
  bool _isSelectMode = false;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    // ref.listenManual は initState 内で一度だけ登録（rebuild で再登録されない）
    _terminalController.addListener(_onSelectionChanged);
    widget.drawerClosedNotifier?.addListener(_onDrawerClosed);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _channelManagerSubscription = ref.listenManual(
        terminalConnectionProvider(widget.sessionId)
            .select((s) => s.channelManager),
        (_, next) {
          ref
              .read(tmuxProvider(widget.sessionId).notifier)
              .setChannelManager(next);
          ref
              .read(fileBrowserProvider(widget.sessionId).notifier)
              .setChannelManager(next);
        },
        fireImmediately: true,
      );
      _startConnection();
    });
  }

  @override
  void didUpdateWidget(covariant _TerminalTabContent oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isActive && !oldWidget.isActive) {
      // タブがアクティブになったらフォーカスを要求
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && widget.isActive) {
          _focusNode.requestFocus();
        }
      });
    } else if (!widget.isActive && oldWidget.isActive) {
      // タブが非アクティブになったらフォーカスを外す
      // これにより新しいアクティブタブの requestFocus() が確実に成功する
      _focusNode.unfocus();
    }
  }

  @override
  void dispose() {
    _terminalController.removeListener(_onSelectionChanged);
    widget.drawerClosedNotifier?.removeListener(_onDrawerClosed);
    _toolbarAutoHideTimer?.cancel();
    _hideToolbar();
    _channelManagerSubscription?.close();
    _terminalController.dispose();
    _focusNode.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _onDrawerClosed() {
    // ドロワーが閉じた後、アクティブタブならフォーカスを要求。
    // ドロワーのアニメーション完了後（300ms）にフォーカスを取る。
    if (!widget.isActive) return;
    Future.delayed(const Duration(milliseconds: 300), () {
      if (mounted && widget.isActive) {
        _focusNode.requestFocus();
      }
    });
  }

  void _onSelectionChanged() {
    if (_terminalController.selection != null) {
      _showToolbar();
    } else {
      _hideToolbar();
      // 選択がクリアされたら選択モードを自動解除
      _exitSelectMode();
    }
  }

  void _showToolbar() {
    _hideToolbar();
    _toolbarAutoHideTimer?.cancel();
    _toolbarAutoHideTimer = Timer(const Duration(seconds: 5), _hideToolbar);
    final overlay = Overlay.of(context);
    final connectionState =
        ref.read(terminalConnectionProvider(widget.sessionId));
    final terminal = connectionState.terminal;
    if (terminal == null) return;
    _toolbarOverlay = OverlayEntry(
      builder: (ctx) => Positioned(
        top: MediaQuery.of(ctx).padding.top + kToolbarHeight + 8,
        left: 0,
        right: 0,
        child: Center(
          child: TerminalSelectionToolbar(
            terminal: terminal,
            controller: _terminalController,
            onPaste: (text) {
              ref
                  .read(terminalConnectionProvider(widget.sessionId))
                  .terminal
                  ?.paste(text);
            },
            onDismiss: _hideToolbar,
          ),
        ),
      ),
    );
    overlay.insert(_toolbarOverlay!);
  }

  void _hideToolbar() {
    _toolbarAutoHideTimer?.cancel();
    _toolbarAutoHideTimer = null;
    _toolbarOverlay?.remove();
    _toolbarOverlay = null;
  }

  void _toggleSelectMode() {
    setState(() {
      _isSelectMode = !_isSelectMode;
      if (_isSelectMode) {
        // 選択モード: tmux へのマウスイベント転送を無効化
        // → 長押しで xterm ネイティブのテキスト選択が動作
        _terminalController.setPointerInputs(const PointerInputs.none());
      } else {
        // 通常モード: タップイベントを tmux に転送
        _terminalController
            .setPointerInputs(const PointerInputs({PointerInput.tap}));
        _terminalController.clearSelection();
        _hideToolbar();
      }
    });
  }

  void _exitSelectMode() {
    if (!_isSelectMode) return;
    setState(() {
      _isSelectMode = false;
      _terminalController
          .setPointerInputs(const PointerInputs({PointerInput.tap}));
    });
  }

  Future<void> _startConnection() async {
    // 既に接続中または接続済みなら二重実行しない
    final currentState =
        ref.read(terminalConnectionProvider(widget.sessionId));
    if (currentState.status == ConnectionStatus.connecting ||
        currentState.status == ConnectionStatus.connected) {
      return;
    }

    final repo = ref.read(connectionRepositoryProvider);
    final conn = await repo.getById(widget.connectionId);
    if (conn == null || !mounted) return;

    final secureStorage = ref.read(secureStorageProvider);

    String? password;
    String? privateKeyPem;
    String? passphrase;

    if (conn.authMethod == 'password') {
      password = await secureStorage.loadPassword(widget.connectionId);
      if (password == null || password.isEmpty) {
        if (!mounted) return;
        password = await showPasswordDialog(context, host: conn.host);
        if (password == null) {
          if (mounted) Navigator.of(context).pop();
          return;
        }
      }
    } else if (conn.authMethod == 'key') {
      privateKeyPem = await secureStorage.loadPrivateKey(widget.connectionId);
      if (privateKeyPem != null && privateKeyPem.isNotEmpty) {
        final keyManager = SshKeyManager();
        if (keyManager.isEncrypted(privateKeyPem)) {
          passphrase =
              await secureStorage.loadPassphrase(widget.connectionId);
          if ((passphrase == null || passphrase.isEmpty) && mounted) {
            passphrase = await showPassphraseDialog(context);
            if (passphrase == null) {
              if (mounted) Navigator.of(context).pop();
              return;
            }
          }
        }
      }
    }

    if (!mounted) return;

    final config = ConnectionConfig(
      id: conn.id.toString(),
      label: conn.label,
      host: conn.host,
      port: conn.port,
      username: conn.username,
      authMethod:
          conn.authMethod == 'key' ? AuthMethod.key : AuthMethod.password,
    );

    // ダウンロード用 Isolate のための接続情報を設定
    ref
        .read(fileBrowserProvider(widget.sessionId).notifier)
        .setConnectionCredentials(
          host: conn.host,
          port: conn.port,
          username: conn.username,
          password: password,
          privateKeyPem: privateKeyPem,
          passphrase: passphrase,
        );

    await ref
        .read(terminalConnectionProvider(widget.sessionId).notifier)
        .connect(
          config: config,
          password: password,
          privateKeyPem: privateKeyPem,
          passphrase: passphrase,
          tmuxSessionName: widget.tmuxSessionName,
        );

    // Auto-attach tmux session after connection is established.
    if (widget.tmuxSessionName != null && mounted) {
      final notifier =
          ref.read(terminalConnectionProvider(widget.sessionId).notifier);
      // シェルが ready になるまで待機（最小 300ms + 最大 5 秒）
      await notifier.waitForShellReady();
      if (!mounted) return;
      final terminal =
          ref.read(terminalConnectionProvider(widget.sessionId)).terminal;
      if (terminal != null) {
        terminal.textInput('tmux attach -t ${shellQuote(widget.tmuxSessionName!)}\r');
      }
    }

    // 接続完了後にフォーカスを確実に要求
    // （特に新しいタブの場合、didUpdateWidget のタイミングでは
    //   TerminalView がまだ構築されていない可能性がある）
    if (mounted && widget.isActive) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && widget.isActive) {
          _focusNode.requestFocus();
        }
      });
    }
  }

  Future<void> _pasteImage() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.image,
    );
    if (result == null || result.files.isEmpty) return;
    final file = result.files.first;
    if (file.path == null) return;

    final localFile = File(file.path!);
    final fileSize = await localFile.length();

    if (fileSize > 10 * 1024 * 1024) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('File too large (max 10MB)')),
        );
      }
      return;
    }

    final connectionState =
        ref.read(terminalConnectionProvider(widget.sessionId));
    final channelManager = connectionState.channelManager;
    if (channelManager == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('SSH not connected')),
        );
      }
      return;
    }

    final fileName = file.name;

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Uploading: $fileName')),
      );
    }

    try {
      // アップロード先を決定: PTY の CWD → SFTP のホームディレクトリ → /tmp
      String uploadDir;
      try {
        final cwd = await channelManager.getShellCwd();
        if (cwd != null && cwd.isNotEmpty) {
          uploadDir = cwd;
        } else {
          final sftp = await channelManager.openSftpChannel();
          uploadDir = await sftp.absolute('.');
        }
      } catch (_) {
        uploadDir = '/tmp';
      }

      final remotePath = '$uploadDir/$fileName';

      final sftp = await channelManager.openSftpChannel();
      final remoteFile = await sftp.open(
        remotePath,
        mode: SftpFileOpenMode.write |
            SftpFileOpenMode.create |
            SftpFileOpenMode.truncate,
      );
      try {
        final inputStream =
            localFile.openRead().map((chunk) => Uint8List.fromList(chunk));
        await remoteFile.write(inputStream).done;
      } finally {
        await remoteFile.close();
      }

      if (mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(content: Text('Uploaded: $remotePath')),
          );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(content: Text('Upload failed: $e')),
          );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context); // AutomaticKeepAliveClientMixin required
    final connectionState =
        ref.watch(terminalConnectionProvider(widget.sessionId));
    final fontSize = ref.watch(fontSizeProvider);

    return Column(
      children: [
        if (connectionState.status == ConnectionStatus.disconnected)
          MaterialBanner(
            content: Row(
              children: [
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white70,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    connectionState.errorMessage ?? 'Connection lost',
                  ),
                ),
              ],
            ),
            backgroundColor: Colors.red[900],
            actions: [
              TextButton(
                onPressed: () => ref
                    .read(terminalConnectionProvider(widget.sessionId).notifier)
                    .reconnect(),
                child: const Text('Reconnect Now'),
              ),
            ],
          ),
        Expanded(
          child: connectionState.terminal != null
              ? ClipRect(
                  child: TerminalScrollInterceptor(
                    terminal: connectionState.terminal!,
                    disabled: _isSelectMode,
                    child: TerminalView(
                      connectionState.terminal!,
                      controller: _terminalController,
                      focusNode: _focusNode,
                      autofocus: true,
                      autoResize: true,
                      deleteDetection: true,
                      simulateScroll: false,
                      textScaler: TextScaler.linear(fontSize / 14.0),
                      scrollController: _scrollController,
                      onTapUp: (_, __) {
                        if (_terminalController.selection == null) {
                          _hideToolbar();
                        }
                      },
                      theme: const TerminalTheme(
                      cursor: Color(0xFFFFFFFF),
                      selection: Color(0x80FFFFFF),
                      foreground: Color(0xFFFFFFFF),
                      background: Color(0xFF000000),
                      black: Color(0xFF000000),
                      white: Color(0xFFFFFFFF),
                      red: Color(0xFFCD3131),
                      green: Color(0xFF0DBC79),
                      yellow: Color(0xFFE5E510),
                      blue: Color(0xFF2472C8),
                      magenta: Color(0xFFBC3FBC),
                      cyan: Color(0xFF11A8CD),
                      brightBlack: Color(0xFF666666),
                      brightRed: Color(0xFFF14C4C),
                      brightGreen: Color(0xFF23D18B),
                      brightYellow: Color(0xFFF5F543),
                      brightBlue: Color(0xFF3B8EEA),
                      brightMagenta: Color(0xFFD670D6),
                      brightCyan: Color(0xFF29B8DB),
                      brightWhite: Color(0xFFFFFFFF),
                      searchHitBackground: Color(0xFFFFDF5D),
                      searchHitBackgroundCurrent: Color(0xFFFF9632),
                      searchHitForeground: Color(0xFF000000),
                    ),
                  ),
                  ),
                )
              : const Center(
                  child: CircularProgressIndicator(),
                ),
        ),
        QuickActionBar(
          onKeyPressed: (key, {bool ctrl = false}) {
            connectionState.terminal?.keyInput(key, ctrl: ctrl);
          },
          onTextInput: (text) {
            connectionState.terminal?.textInput(text);
          },
          isSelectMode: _isSelectMode,
          onToggleSelectMode: _toggleSelectMode,
          onClaudeCommand: connectionState.terminal != null
              ? () => connectionState.terminal?.textInput('claude\r')
              : null,
          onImagePaste: connectionState.terminal != null ? _pasteImage : null,
          onClipboardPaste: connectionState.terminal != null
              ? () async {
                  final data =
                      await Clipboard.getData(Clipboard.kTextPlain);
                  if (data?.text != null && data!.text!.isNotEmpty) {
                    connectionState.terminal?.paste(data.text!);
                  }
                }
              : null,
          onScrollToTop: () {
            final terminal = connectionState.terminal;
            if (terminal != null && terminal.isUsingAltBuffer) {
              terminal.keyInput(TerminalKey.pageUp);
            } else if (_scrollController.hasClients &&
                _scrollController.position.maxScrollExtent > 0) {
              _scrollController.animateTo(
                0,
                duration: const Duration(milliseconds: 300),
                curve: Curves.easeOut,
              );
            }
          },
          onScrollToBottom: () {
            final terminal = connectionState.terminal;
            if (terminal != null && terminal.isUsingAltBuffer) {
              terminal.keyInput(TerminalKey.pageDown);
            } else if (_scrollController.hasClients) {
              _scrollController.animateTo(
                _scrollController.position.maxScrollExtent,
                duration: const Duration(milliseconds: 300),
                curve: Curves.easeOut,
              );
            }
          },
          onPageUp: () {
            connectionState.terminal?.keyInput(TerminalKey.pageUp);
          },
          onPageDown: () {
            connectionState.terminal?.keyInput(TerminalKey.pageDown);
          },
        ),
      ],
    );
  }
}
