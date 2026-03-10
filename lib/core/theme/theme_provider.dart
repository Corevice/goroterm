import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The three supported app themes.
enum AppThemeMode {
  dark,
  light,
  highContrast,
}

class ThemeModeNotifier extends Notifier<AppThemeMode> {
  @override
  AppThemeMode build() => AppThemeMode.dark;

  void setTheme(AppThemeMode mode) => state = mode;
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

  @override
  double build() => _defaultSize;

  void setFontSize(double size) {
    state = size.clamp(_minSize, _maxSize);
  }

  /// Increases font size by one step (volume up).
  void increase() {
    state = (state + _step).clamp(_minSize, _maxSize);
  }

  /// Decreases font size by one step (volume down).
  void decrease() {
    state = (state - _step).clamp(_minSize, _maxSize);
  }
}

final fontSizeProvider = NotifierProvider<FontSizeNotifier, double>(
  FontSizeNotifier.new,
);
