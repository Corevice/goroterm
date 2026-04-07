import 'dart:async';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
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
import '../../core/notification/notification_service.dart';
import '../claude_usage/claude_usage_dialog.dart';
import '../server_monitor/server_monitor_dialog.dart';
import '../../widgets/terminal_selection_toolbar.dart';
import '../../core/platform/clipboard_image_helper.dart';

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
      // 毎回（30秒間隔）activeKeepAlive を実行。
      // SSH exec チャネルでネットワークパケットを送信し、接続ヘルスチェックを行う。
      // NAT 維持は dartssh2 の SSH keepalive (10s) + TCP keepalive (15s) が担当。
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
      TerminalConnectionNotifier.setAppInBackground(true);
      // フォアグラウンドで蓄積されたバイトカウントをリセット
      final sessions = ref.read(sessionManagerProvider).sessions;
      for (final session in sessions) {
        ref
            .read(terminalConnectionProvider(session.sessionId).notifier)
            .resetIdleCounter();
      }
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
      TerminalConnectionNotifier.setAppInBackground(false);
      // 全セッションの通知をキャンセル＋フラグリセット
      final managerState = ref.read(sessionManagerProvider);
      for (final session in managerState.sessions) {
        NotificationService.instance.cancelForSession(session.sessionId);
        ref
            .read(terminalConnectionProvider(session.sessionId).notifier)
            .clearNotificationFlag();
      }
      // フォアグラウンドサービスのおかげで通常は接続維持されているが、
      // 万一の切断に備えて短い遅延後にチェック
      Future.delayed(const Duration(milliseconds: 1500), () {
        if (!mounted) return;
        final sessions = ref.read(sessionManagerProvider).sessions;
        // 全セッションの接続を確認（バックグラウンドで全部死んでいる可能性がある）
        for (final session in sessions) {
          ref
              .read(terminalConnectionProvider(session.sessionId).notifier)
              .checkConnection();
        }
      });

    }
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

    ref.listen<bool>(
      sessionManagerProvider.select((s) => s.batteryWarning),
      (prev, next) {
        if (next && !(prev ?? false)) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'バッテリー最適化が有効です。バックグラウンドでSSH接続が切れる可能性があります。',
              ),
              duration: Duration(seconds: 5),
            ),
          );
        }
      },
    );

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
              } else if (value == 'server_monitor') {
                ServerMonitorDialog.show(context, activeSession.sessionId);
              } else if (value == 'refresh_screen') {
                // PTY サイズを再送信して tmux に強制リドローさせる
                final connState = ref.read(
                    terminalConnectionProvider(activeSession.sessionId));
                final terminal = connState.terminal;
                final cm = connState.channelManager;
                if (terminal != null && cm != null) {
                  cm.resizePty(terminal.viewWidth, terminal.viewHeight);
                }
              }
            },
            itemBuilder: (_) => [
              const PopupMenuItem(
                value: 'refresh_screen',
                child: Row(
                  children: [
                    Icon(Icons.refresh, size: 20),
                    SizedBox(width: 12),
                    Text('Refresh Screen'),
                  ],
                ),
              ),
              const PopupMenuItem(
                value: 'server_monitor',
                child: Row(
                  children: [
                    Icon(Icons.monitor_heart_outlined, size: 20),
                    SizedBox(width: 12),
                    Text('Server Monitor'),
                  ],
                ),
              ),
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
            onReorder: (oldIndex, newIndex) => ref
                .read(sessionManagerProvider.notifier)
                .reorderSessions(oldIndex, newIndex),
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

class _TabStrip extends StatefulWidget {
  const _TabStrip({
    required this.sessions,
    required this.activeSessionId,
    required this.onSelect,
    required this.onClose,
    required this.onReorder,
  });

  final List<TerminalSession> sessions;
  final String activeSessionId;
  final ValueChanged<String> onSelect;
  final ValueChanged<String> onClose;
  final void Function(int oldIndex, int newIndex) onReorder;

  @override
  State<_TabStrip> createState() => _TabStripState();
}

class _TabStripState extends State<_TabStrip> {
  final _scrollController = ScrollController();
  final _tabKeys = <String, GlobalKey>{};

  @override
  void didUpdateWidget(covariant _TabStrip oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.activeSessionId != oldWidget.activeSessionId) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _scrollToActiveTab();
      });
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _scrollToActiveTab() {
    final key = _tabKeys[widget.activeSessionId];
    if (key == null) return;
    final ctx = key.currentContext;
    if (ctx == null) return;
    Scrollable.ensureVisible(
      ctx,
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    // 不要なキーを削除
    final sessionIds = widget.sessions.map((s) => s.sessionId).toSet();
    _tabKeys.removeWhere((id, _) => !sessionIds.contains(id));

    return SizedBox(
      height: 36,
      child: ReorderableListView.builder(
        scrollController: _scrollController,
        scrollDirection: Axis.horizontal,
        buildDefaultDragHandles: false,
        onReorder: widget.onReorder,
        proxyDecorator: (child, index, animation) {
          return Material(
            elevation: 4,
            color: Colors.transparent,
            borderRadius: BorderRadius.circular(4),
            child: child,
          );
        },
        itemCount: widget.sessions.length,
        itemBuilder: (context, index) {
          final session = widget.sessions[index];
          final isActive = session.sessionId == widget.activeSessionId;
          final tabKey = _tabKeys.putIfAbsent(
            session.sessionId,
            () => GlobalKey(),
          );
          return ReorderableDragStartListener(
            key: ValueKey(session.sessionId),
            index: index,
            child: InkWell(
              key: tabKey,
              onTap: () => widget.onSelect(session.sessionId),
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
                    onTap: () => widget.onClose(session.sessionId),
                    child: Icon(
                      Icons.close,
                      size: 14,
                      color: Colors.grey[400],
                    ),
                  ),
                ],
              ),
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
    with AutomaticKeepAliveClientMixin, WidgetsBindingObserver {
  final _terminalController = TerminalController();
  final _focusNode = FocusNode();
  final _scrollController = ScrollController();
  /// タブごとにキーボード表示状態を記憶する。
  /// true ならタブ切り替え時にフォーカスを復元（キーボード表示）する。
  /// viewInsets.bottom で実際のキーボード表示を追跡する。
  bool _wantKeyboard = true;
  OverlayEntry? _toolbarOverlay;
  Timer? _toolbarAutoHideTimer;
  ProviderSubscription<SshChannelManager?>? _channelManagerSubscription;
  bool _isSelectMode = false;

  // Voice input
  final stt.SpeechToText _speech = stt.SpeechToText();
  bool _isListening = false;
  bool _speechAvailable = false;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    // ref.listenManual は initState 内で一度だけ登録（rebuild で再登録されない）
    _terminalController.addListener(_onSelectionChanged);
    widget.drawerClosedNotifier?.addListener(_onDrawerClosed);
    WidgetsBinding.instance.addObserver(this);
    _initSpeech();
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
      // シェル終了を検知してタブを自動クローズ
      ref.listenManual(
        terminalConnectionProvider(widget.sessionId)
            .select((s) => s.shellExited),
        (prev, next) {
          if (next && !(prev ?? false)) {
            ref.read(sessionManagerProvider.notifier)
                .removeSession(widget.sessionId);
          }
        },
      );
    });
  }

  @override
  void didUpdateWidget(covariant _TerminalTabContent oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isActive && !oldWidget.isActive) {
      // タブがアクティブになったら通知をキャンセル＋フラグリセット
      NotificationService.instance.cancelForSession(widget.sessionId);
      ref
          .read(terminalConnectionProvider(widget.sessionId).notifier)
          .clearNotificationFlag();
      // 前回の状態に基づいてフォーカスを復元
      if (_wantKeyboard) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && widget.isActive) {
            _focusNode.requestFocus();
          }
        });
      }
    } else if (!widget.isActive && oldWidget.isActive) {
      // タブが非アクティブになったらフォーカスを外す
      // これにより新しいアクティブタブの requestFocus() が確実に成功する
      _focusNode.unfocus();
    }
  }

  @override
  void dispose() {
    _speech.stop();
    _terminalController.removeListener(_onSelectionChanged);
    widget.drawerClosedNotifier?.removeListener(_onDrawerClosed);
    WidgetsBinding.instance.removeObserver(this);
    _toolbarAutoHideTimer?.cancel();
    _longPressSelectTimer?.cancel();
    _hideToolbar();
    _channelManagerSubscription?.close();
    _terminalController.dispose();
    _focusNode.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  /// 実際のキーボード表示/非表示を viewInsets で追跡する。
  /// Android の戻るボタンやキーボード閉じるボタンでも正しく検知できる。
  @override
  void didChangeMetrics() {
    if (!widget.isActive || !mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !widget.isActive) return;
      final bottomInset = MediaQuery.of(context).viewInsets.bottom;
      _wantKeyboard = bottomInset > 0;
    });
  }

  void _onDrawerClosed() {
    // ドロワーが閉じた後、アクティブタブならフォーカスを復元。
    // ドロワーのアニメーション完了後（300ms）にフォーカスを取る。
    if (!widget.isActive || !_wantKeyboard) return;
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
      // 選択がクリアされたら選択モード / 長押し選択を解除
      if (_altSelectActive) {
        _altSelectActive = false;
        _terminalController.setSuspendPointerInput(false);
      }
      _exitSelectMode();
    }
  }

  /// URL 検出用の正規表現
  static final _urlRegExp = RegExp(
    r'https?://[^\s\x00-\x1F\x7F<>"{}|\\^`\[\]）】」』）]+',
  );

  /// 選択範囲を含む行からURLを検出する。
  /// 選択の開始位置を含むURLを優先的に返す。
  String? _detectUrlAroundSelection(Terminal terminal) {
    final selection = _terminalController.selection;
    if (selection == null) return null;

    final buffer = terminal.buffer;
    final startY = selection.begin.y;

    // 選択開始行のテキストを取得（wrapped 行を結合）
    final lineText = _getFullLineText(buffer, startY);
    if (lineText == null) return null;

    // 行内のすべての URL を検出し、選択開始列を含むものを返す
    final startX = selection.begin.x;
    for (final match in _urlRegExp.allMatches(lineText)) {
      if (startX >= match.start && startX <= match.end) {
        return _cleanUrl(match.group(0)!);
      }
    }

    // 選択位置と完全に重ならなくても、行内にURLがあればそれを返す
    final firstMatch = _urlRegExp.firstMatch(lineText);
    if (firstMatch != null) {
      return _cleanUrl(firstMatch.group(0)!);
    }

    return null;
  }

  /// バッファから指定行のテキストを取得する。wrapped 行を結合する。
  String? _getFullLineText(dynamic buffer, int absoluteY) {
    final lines = buffer.lines;
    if (absoluteY < 0 || absoluteY >= lines.length) return null;
    return lines[absoluteY].getText();
  }

  /// URL 末尾の不要な句読点・括弧を除去する。
  String _cleanUrl(String url) {
    // 末尾の句読点や閉じ括弧を除去（URL の一部でないことが多い）
    while (url.isNotEmpty && '.,:;!?)>」』）】'.contains(url[url.length - 1])) {
      url = url.substring(0, url.length - 1);
    }
    return url;
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

    final detectedUrl = _detectUrlAroundSelection(terminal);

    _toolbarOverlay = OverlayEntry(
      builder: (ctx) => Positioned(
        top: MediaQuery.of(ctx).padding.top + kToolbarHeight + 8,
        left: 0,
        right: 0,
        child: Center(
          child: TerminalSelectionToolbar(
            terminal: terminal,
            controller: _terminalController,
            detectedUrl: detectedUrl,
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

  bool _altSelectActive = false;
  Timer? _longPressSelectTimer;

  void _onPointerDownForSelection(PointerDownEvent event) {
    final isMouse = event.kind == PointerDeviceKind.mouse;
    final optionPressed = Platform.isMacOS &&
        isMouse &&
        HardwareKeyboard.instance.isAltPressed;

    if (optionPressed || _isSelectMode) {
      if (!_altSelectActive) {
        _altSelectActive = true;
        _terminalController.setSuspendPointerInput(true);
      }
      return;
    }

    // 長押し (400ms) で自動的に選択モードに入る
    _longPressSelectTimer?.cancel();
    _longPressSelectTimer = Timer(const Duration(milliseconds: 400), () {
      if (!_altSelectActive && !_isSelectMode) {
        _altSelectActive = true;
        _terminalController.setSuspendPointerInput(true);
      }
    });
  }

  void _onPointerUpForSelection(PointerUpEvent event) {
    _longPressSelectTimer?.cancel();
    _longPressSelectTimer = null;

    if (!_altSelectActive) return;
    if (_terminalController.selection != null) {
      // 選択中 — タップで選択解除されるまで維持
      return;
    }
    _altSelectActive = false;
    if (!_isSelectMode) {
      _terminalController.setSuspendPointerInput(false);
    }
  }

  PointerInputs get _defaultPointerInputs {
    return const PointerInputs({PointerInput.tap});
  }

  void _toggleSelectMode() {
    setState(() {
      _isSelectMode = !_isSelectMode;
      if (_isSelectMode) {
        // 選択モード: tmux へのマウスイベント転送を無効化
        // → 長押し / ドラッグで xterm ネイティブのテキスト選択が動作
        _terminalController.setPointerInputs(const PointerInputs.none());
      } else {
        // 通常モード: タップイベントを tmux に転送
        _terminalController.setPointerInputs(_defaultPointerInputs);
        _terminalController.clearSelection();
        _hideToolbar();
      }
    });
  }

  void _exitSelectMode() {
    if (!_isSelectMode) return;
    setState(() {
      _isSelectMode = false;
      _terminalController.setPointerInputs(_defaultPointerInputs);
    });
  }

  Future<void> _initSpeech() async {
    _speechAvailable = await _speech.initialize(
      onError: (error) {
        if (mounted) {
          setState(() => _isListening = false);
        }
      },
      onStatus: (status) {
        if (status == 'done' || status == 'notListening') {
          if (mounted) {
            setState(() => _isListening = false);
          }
        }
      },
    );
  }

  void _toggleVoiceInput() {
    if (_isListening) {
      _speech.stop();
      setState(() => _isListening = false);
      return;
    }

    if (!_speechAvailable) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Speech recognition not available')),
      );
      return;
    }

    setState(() => _isListening = true);
    _speech.listen(
      onResult: (result) {
        if (result.finalResult && result.recognizedWords.isNotEmpty) {
          final connectionState =
              ref.read(terminalConnectionProvider(widget.sessionId));
          connectionState.terminal?.paste(result.recognizedWords);
        }
      },
      listenOptions: stt.SpeechListenOptions(
        listenMode: stt.ListenMode.dictation,
      ),
      localeId: 'ja_JP',
    );
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

  static const _videoExtensions = {
    '.mp4', '.mov', '.avi', '.mkv', '.webm', '.m4v', '.3gp',
  };

  static const _uploadDir = '/tmp/.terminal-uploads';

  bool _isVideo(String fileName) {
    final lower = fileName.toLowerCase();
    return _videoExtensions.any((ext) => lower.endsWith(ext));
  }

  String _timestamp() {
    final now = DateTime.now();
    return '${now.year}'
        '${now.month.toString().padLeft(2, '0')}'
        '${now.day.toString().padLeft(2, '0')}'
        '_'
        '${now.hour.toString().padLeft(2, '0')}'
        '${now.minute.toString().padLeft(2, '0')}'
        '${now.second.toString().padLeft(2, '0')}';
  }

  Future<void> _pasteMedia() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: [
        'jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp',
        'mp4', 'mov', 'avi', 'mkv', 'webm', 'm4v', '3gp',
      ],
    );
    if (result == null || result.files.isEmpty) return;
    final file = result.files.first;
    if (file.path == null) return;

    final localFile = File(file.path!);
    final fileSize = await localFile.length();

    // 画像 10MB / 動画 100MB
    final isVideo = _isVideo(file.name);
    final maxSize = isVideo ? 100 * 1024 * 1024 : 10 * 1024 * 1024;
    if (fileSize > maxSize) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
                'File too large (max ${isVideo ? "100MB" : "10MB"})'),
          ),
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
    final ts = _timestamp();

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(isVideo
              ? 'Uploading & converting: $fileName'
              : 'Uploading: $fileName'),
          duration: const Duration(seconds: 30),
        ),
      );
    }

    SftpClient? sftp;
    try {
      sftp = await channelManager.openIndependentSftpChannel();

      // ディレクトリがなければ作成
      try {
        await sftp.stat(_uploadDir);
      } catch (_) {
        await sftp.mkdir(_uploadDir);
      }

      final remotePath = '$_uploadDir/${ts}_$fileName';

      // SFTP アップロード
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

      String pastePath = remotePath;

      if (isVideo) {
        // 動画 → GIF 変換（サーバー側 ffmpeg）
        final gifPath = '$_uploadDir/${ts}_${fileName.split('.').first}.gif';
        final ffmpegCmd =
            "ffmpeg -i ${shellQuote(remotePath)}"
            " -vf 'fps=10,scale=480:-1:flags=lanczos'"
            " -t 15 -y"
            " ${shellQuote(gifPath)}";

        if (mounted) {
          ScaffoldMessenger.of(context)
            ..hideCurrentSnackBar()
            ..showSnackBar(
              const SnackBar(
                content: Text('Converting to GIF...'),
                duration: Duration(seconds: 60),
              ),
            );
        }

        try {
          await channelManager.runCommand(ffmpegCmd);
          // 変換成功 → GIF パスを使用、元動画を削除
          pastePath = gifPath;
          try {
            await channelManager.runCommand("rm -f ${shellQuote(remotePath)}");
          } catch (_) {}
        } catch (e) {
          // ffmpeg 失敗（未インストール等）→ 元動画パスをそのまま使用
          if (mounted) {
            ScaffoldMessenger.of(context)
              ..hideCurrentSnackBar()
              ..showSnackBar(
                SnackBar(
                  content: Text(
                      'GIF conversion failed (ffmpeg not found?). '
                      'Video uploaded as: $remotePath'),
                  duration: const Duration(seconds: 5),
                ),
              );
          }
        }
      }

      if (mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(content: Text('Ready: $pastePath')),
          );

        // パスをターミナルに自動ペースト（再接続で terminal が変わっている可能性があるため最新を取得）
        ref.read(terminalConnectionProvider(widget.sessionId)).terminal?.paste(pastePath);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(content: Text('Upload failed: $e')),
          );
      }
    } finally {
      try { sftp?.close(); } catch (_) {}
    }
  }

  /// クリップボードの画像を SFTP アップロードしてパスをペースト。
  /// 画像がなければテキストペーストにフォールバック。
  Future<void> _pasteClipboardImageOrText() async {
    final connectionState =
        ref.read(terminalConnectionProvider(widget.sessionId));

    // macOS: クリップボードに画像があるか確認
    final localPath = await ClipboardImageHelper.getClipboardImageFile();
    if (localPath != null) {
      await _uploadLocalFile(localPath, 'clipboard.png');
      return;
    }

    // テキストフォールバック
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (data?.text != null && data!.text!.isNotEmpty) {
      connectionState.terminal?.paste(data.text!);
    }
  }

  /// ローカルファイルを SFTP アップロードしてパスをペースト。
  Future<void> _uploadLocalFile(String localPath, String fileName) async {
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

    final ts = _timestamp();

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Uploading: $fileName'),
          duration: const Duration(seconds: 30),
        ),
      );
    }

    try {
      final sftp = await channelManager.openSftpChannel();

      try {
        await sftp.stat(_uploadDir);
      } catch (_) {
        await sftp.mkdir(_uploadDir);
      }

      final remotePath = '$_uploadDir/${ts}_$fileName';
      final localFile = File(localPath);

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

      // 一時ファイル削除
      try {
        await localFile.delete();
      } catch (_) {}

      if (mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(content: Text('Ready: $remotePath')),
          );
        connectionState.terminal?.paste(remotePath);
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

  static const _terminalTheme = TerminalTheme(
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
  );

  Widget _buildTerminalView(
    TerminalConnectionState connectionState,
    double fontSize,
  ) {
    return TerminalView(
      connectionState.terminal!,
      controller: _terminalController,
      focusNode: _focusNode,
      autofocus: false,
      autoResize: true,
      // macOS: deleteDetection=false にして _initEditingState を空文字列にする。
      // "  " パディングが Google IME で IME 確定時にテキスト二重化を引き起こすため。
      // macOS はハードウェアキーボードなので backspace は KeyEvent で検出される。
      deleteDetection: !Platform.isMacOS,
      simulateScroll: true,
      textScaler: TextScaler.linear(fontSize / 14.0),
      scrollController: _scrollController,
      onTapUp: (_, __) {
        if (_terminalController.selection == null) {
          _hideToolbar();
        }
      },
      theme: _terminalTheme,
    );
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
                    child: Listener(
                      onPointerDown: _onPointerDownForSelection,
                      onPointerUp: _onPointerUpForSelection,
                      child: _buildTerminalView(
                        connectionState, fontSize),
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
          onVoiceInput: connectionState.terminal != null ? _toggleVoiceInput : null,
          isListening: _isListening,
          onImagePaste: connectionState.terminal != null ? _pasteMedia : null,
          onClipboardPaste: connectionState.terminal != null
              ? _pasteClipboardImageOrText
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
