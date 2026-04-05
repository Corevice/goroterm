import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

const _fontSizeKey = 'pref_font_size';
const _themeKey = 'pref_theme_mode';

/// Provides the [FlutterSecureStorage] instance used by theme/font providers.
/// Override in tests to avoid platform-channel calls.
final themeStorageProvider = Provider<FlutterSecureStorage>(
  (ref) => const FlutterSecureStorage(),
);

/// The three supported app themes.
enum AppThemeMode {
  dark,
  light,
  highContrast,
}

class ThemeModeNotifier extends Notifier<AppThemeMode> {
  late final FlutterSecureStorage _storage;

  @override
  AppThemeMode build() {
    _storage = ref.read(themeStorageProvider);
    _loadFromStorage();
    return AppThemeMode.dark;
  }

  Future<void> _loadFromStorage() async {
    try {
      final value = await _storage.read(key: _themeKey);
      if (value != null) {
        final mode =
            AppThemeMode.values.where((e) => e.name == value).firstOrNull;
        if (mode != null && mode != state) {
          state = mode;
        }
      }
    } catch (_) {
      // テスト環境等でプラットフォームチャネルが使えない場合は無視
    }
  }

  void setTheme(AppThemeMode mode) {
    state = mode;
    _save(mode);
  }

  Future<void> _save(AppThemeMode mode) async {
    try {
      await _storage.write(key: _themeKey, value: mode.name);
    } catch (_) {}
  }
}

final themeModeProvider = NotifierProvider<ThemeModeNotifier, AppThemeMode>(
  ThemeModeNotifier.new,
);

/// Terminal font size in logical pixels.
class FontSizeNotifier extends Notifier<double> {
  static const _defaultSize = 14.0;
  static const _minSize = 8.0;
  static const _maxSize = 32.0;
  static const _step = 2.0;

  late final FlutterSecureStorage _storage;

  @override
  double build() {
    _storage = ref.read(themeStorageProvider);
    _loadFromStorage();
    return _defaultSize;
  }

  Future<void> _loadFromStorage() async {
    try {
      final value = await _storage.read(key: _fontSizeKey);
      if (value != null) {
        final size = double.tryParse(value);
        if (size != null) {
          state = size.clamp(_minSize, _maxSize);
        }
      }
    } catch (_) {
      // テスト環境等でプラットフォームチャネルが使えない場合は無視
    }
  }

  void setFontSize(double size) {
    state = size.clamp(_minSize, _maxSize);
    _save(state);
  }

  Future<void> _save(double size) async {
    try {
      await _storage.write(key: _fontSizeKey, value: size.toString());
    } catch (_) {}
  }

  /// Increases font size by one step (volume up).
  void increase() {
    setFontSize(state + _step);
  }

  /// Decreases font size by one step (volume down).
  void decrease() {
    setFontSize(state - _step);
  }
}

final fontSizeProvider = NotifierProvider<FontSizeNotifier, double>(
  FontSizeNotifier.new,
);
