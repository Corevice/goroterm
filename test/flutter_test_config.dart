import 'dart:async';
import 'package:flutter_test/flutter_test.dart';

@Timeout(Duration(seconds: 30))
Future<void> testExecutable(FutureOr<void> Function() testMain) async =>
    testMain();
