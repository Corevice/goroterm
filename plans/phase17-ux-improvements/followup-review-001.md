# Phase 17 Follow-up: FontSizeNotifier Unit Tests Missing

## Issue

`lib/core/theme/theme_provider.dart` の `FontSizeNotifier` は正しく実装されているが、
対応するユニットテストファイル `test/core/theme/theme_provider_test.dart` が存在しない。

元のプランに明記されていた要件:
> `FontSizeNotifier` のテスト: `validSizes` リストの削除 + `increase()`/`decrease()` メソッドのテスト追加

## 対応内容

`test/core/theme/theme_provider_test.dart` を新規作成し、以下のテストケースを追加する:

```dart
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:terminal_ssh_app/core/theme/theme_provider.dart';

void main() {
  group('FontSizeNotifier', () {
    late ProviderContainer container;

    setUp(() {
      container = ProviderContainer();
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
  });
}
```

## ファイル

- 作成: `test/core/theme/theme_provider_test.dart`

## 確認コマンド

```bash
~/flutter/bin/flutter test test/core/theme/theme_provider_test.dart
~/flutter/bin/flutter analyze
```
