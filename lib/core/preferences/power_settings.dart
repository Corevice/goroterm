import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

const _tickKey = 'pref_foreground_tick_seconds';
const _tcpKeepaliveKey = 'pref_tcp_keepalive_idle_seconds';

const _defaultTickSeconds = 300; // 5 min
const _defaultTcpKeepaliveSeconds = 45;

/// Foreground service の health-check 間隔（秒）の選択肢。
const tickPresetSeconds = <int>[60, 180, 300, 600];

/// TCP keepalive idle（秒）の選択肢。NAT / 信頼性とバッテリーのトレードオフ。
const tcpKeepalivePresetSeconds = <int>[15, 30, 45, 60, 120];

/// アプリ起動時に読み込んだ値を保持するシングルトン。
/// foreground service init や SSH ソケット接続のような Riverpod 外から
/// 同期的に読みたいので、Notifier 側からも書き込みでミラーする。
class PowerSettings {
  PowerSettings._();

  static int _tickSeconds = _defaultTickSeconds;
  static int _tcpKeepaliveIdleSeconds = _defaultTcpKeepaliveSeconds;

  static int get tickSeconds => _tickSeconds;
  static int get tcpKeepaliveIdleSeconds => _tcpKeepaliveIdleSeconds;

  /// main() で WidgetsFlutterBinding.ensureInitialized() の後、
  /// SshForegroundService.init() より先に呼ぶ。失敗しても黙ってデフォルトを使う。
  static Future<void> init() async {
    try {
      const storage = FlutterSecureStorage();
      final tick = await storage.read(key: _tickKey);
      final tcp = await storage.read(key: _tcpKeepaliveKey);
      if (tick != null) {
        final parsed = int.tryParse(tick);
        if (parsed != null && tickPresetSeconds.contains(parsed)) {
          _tickSeconds = parsed;
        }
      }
      if (tcp != null) {
        final parsed = int.tryParse(tcp);
        if (parsed != null && tcpKeepalivePresetSeconds.contains(parsed)) {
          _tcpKeepaliveIdleSeconds = parsed;
        }
      }
    } catch (_) {
      // テスト環境等で SecureStorage が使えない場合は無視
    }
  }

  static Future<void> setTickSeconds(int v) async {
    _tickSeconds = v;
    try {
      const storage = FlutterSecureStorage();
      await storage.write(key: _tickKey, value: v.toString());
    } catch (_) {}
  }

  static Future<void> setTcpKeepaliveIdleSeconds(int v) async {
    _tcpKeepaliveIdleSeconds = v;
    try {
      const storage = FlutterSecureStorage();
      await storage.write(key: _tcpKeepaliveKey, value: v.toString());
    } catch (_) {}
  }
}

class TickIntervalNotifier extends Notifier<int> {
  @override
  int build() => PowerSettings.tickSeconds;

  Future<void> setValue(int v) async {
    if (!tickPresetSeconds.contains(v)) return;
    state = v;
    await PowerSettings.setTickSeconds(v);
  }
}

class TcpKeepaliveIdleNotifier extends Notifier<int> {
  @override
  int build() => PowerSettings.tcpKeepaliveIdleSeconds;

  Future<void> setValue(int v) async {
    if (!tcpKeepalivePresetSeconds.contains(v)) return;
    state = v;
    await PowerSettings.setTcpKeepaliveIdleSeconds(v);
  }
}

final tickIntervalProvider =
    NotifierProvider<TickIntervalNotifier, int>(TickIntervalNotifier.new);

final tcpKeepaliveIdleProvider =
    NotifierProvider<TcpKeepaliveIdleNotifier, int>(
  TcpKeepaliveIdleNotifier.new,
);
