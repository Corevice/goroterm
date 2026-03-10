import 'package:flutter/material.dart';

/// Global navigator key used to show dialogs from outside the widget tree
/// (e.g., from Riverpod notifiers during SSH host key verification).
final globalNavigatorKey = GlobalKey<NavigatorState>();
