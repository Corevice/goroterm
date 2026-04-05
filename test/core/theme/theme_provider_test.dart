@Timeout(Duration(seconds: 90))
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:terminal_ssh_app/core/theme/theme_provider.dart';

class MockFlutterSecureStorage extends Mock implements FlutterSecureStorage {}

ProviderContainer _makeContainer(MockFlutterSecureStorage storage) {
  return ProviderContainer(
    overrides: [
      themeStorageProvider.overrideWith((ref) => storage),
    ],
  );
}

void main() {
  late MockFlutterSecureStorage mockStorage;

  setUp(() {
    mockStorage = MockFlutterSecureStorage();
    // Default: read returns null (no persisted value)
    when(() => mockStorage.read(key: any(named: 'key')))
        .thenAnswer((_) async => null);
    when(() => mockStorage.write(key: any(named: 'key'), value: any(named: 'value')))
        .thenAnswer((_) async {});
  });

  group('ThemeModeNotifier', () {
    late ProviderContainer container;

    setUp(() {
      container = _makeContainer(mockStorage);
    });

    tearDown(() {
      container.dispose();
    });

    test('default theme is dark', () {
      expect(container.read(themeModeProvider), AppThemeMode.dark);
    });

    test('setTheme() changes to light', () {
      container.read(themeModeProvider.notifier).setTheme(AppThemeMode.light);
      expect(container.read(themeModeProvider), AppThemeMode.light);
    });

    test('setTheme() changes to highContrast', () {
      container
          .read(themeModeProvider.notifier)
          .setTheme(AppThemeMode.highContrast);
      expect(container.read(themeModeProvider), AppThemeMode.highContrast);
    });

    test('setTheme() back to dark', () {
      container.read(themeModeProvider.notifier).setTheme(AppThemeMode.light);
      container.read(themeModeProvider.notifier).setTheme(AppThemeMode.dark);
      expect(container.read(themeModeProvider), AppThemeMode.dark);
    });

    test('loads persisted theme from storage on build', () async {
      when(() => mockStorage.read(key: 'pref_theme_mode'))
          .thenAnswer((_) async => 'light');

      final c = _makeContainer(mockStorage);
      addTearDown(c.dispose);

      // Initial state is dark (synchronous build return)
      expect(c.read(themeModeProvider), AppThemeMode.dark);

      // Wait for async _loadFromStorage to complete
      await Future<void>.delayed(Duration.zero);

      expect(c.read(themeModeProvider), AppThemeMode.light);
    });

    test('ignores unknown persisted theme value', () async {
      when(() => mockStorage.read(key: 'pref_theme_mode'))
          .thenAnswer((_) async => 'unknown_value');

      final c = _makeContainer(mockStorage);
      addTearDown(c.dispose);

      c.read(themeModeProvider); // trigger lazy init
      await Future<void>.delayed(Duration.zero);
      expect(c.read(themeModeProvider), AppThemeMode.dark);
    });
  });

  group('FontSizeNotifier', () {
    late ProviderContainer container;

    setUp(() {
      container = _makeContainer(mockStorage);
    });

    tearDown(() {
      container.dispose();
    });

    test('default size is 14.0', () {
      expect(container.read(fontSizeProvider), 14.0);
    });

    test('increase() adds step size', () {
      container.read(fontSizeProvider.notifier).increase();
      expect(container.read(fontSizeProvider), 16.0);
    });

    test('decrease() subtracts step size', () {
      container.read(fontSizeProvider.notifier).decrease();
      expect(container.read(fontSizeProvider), 12.0);
    });

    test('increase() clamps at maxSize (32.0)', () {
      final notifier = container.read(fontSizeProvider.notifier);
      notifier.setFontSize(31.0);
      notifier.increase();
      expect(container.read(fontSizeProvider), 32.0);
      notifier.increase(); // already at max
      expect(container.read(fontSizeProvider), 32.0);
    });

    test('decrease() clamps at minSize (8.0)', () {
      final notifier = container.read(fontSizeProvider.notifier);
      notifier.setFontSize(9.0);
      notifier.decrease();
      expect(container.read(fontSizeProvider), 8.0);
      notifier.decrease(); // already at min
      expect(container.read(fontSizeProvider), 8.0);
    });

    test('setFontSize() clamps within [8.0, 32.0]', () {
      final notifier = container.read(fontSizeProvider.notifier);
      notifier.setFontSize(100.0);
      expect(container.read(fontSizeProvider), 32.0);
      notifier.setFontSize(-5.0);
      expect(container.read(fontSizeProvider), 8.0);
      notifier.setFontSize(20.0);
      expect(container.read(fontSizeProvider), 20.0);
    });

    test('loads persisted font size from storage on build', () async {
      when(() => mockStorage.read(key: 'pref_font_size'))
          .thenAnswer((_) async => '18.0');

      final c = _makeContainer(mockStorage);
      addTearDown(c.dispose);

      expect(c.read(fontSizeProvider), 14.0);
      await Future<void>.delayed(Duration.zero);
      expect(c.read(fontSizeProvider), 18.0);
    });

    test('clamps out-of-range persisted font size', () async {
      when(() => mockStorage.read(key: 'pref_font_size'))
          .thenAnswer((_) async => '100.0');

      final c = _makeContainer(mockStorage);
      addTearDown(c.dispose);

      c.read(fontSizeProvider); // trigger lazy init
      await Future<void>.delayed(Duration.zero);
      expect(c.read(fontSizeProvider), 32.0);
    });

    test('ignores non-numeric persisted font size', () async {
      when(() => mockStorage.read(key: 'pref_font_size'))
          .thenAnswer((_) async => 'not_a_number');

      final c = _makeContainer(mockStorage);
      addTearDown(c.dispose);

      c.read(fontSizeProvider); // trigger lazy init
      await Future<void>.delayed(Duration.zero);
      expect(c.read(fontSizeProvider), 14.0);
    });
  });
}
