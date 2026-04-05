import 'package:flutter/widgets.dart' show TextEditingValue;

class CompositionBuffer {
  String _composingText = '';
  String _previousConfirmedText = '';
  bool _isComposing = false;

  String get composingText => _composingText;
  String get previousConfirmedText => _previousConfirmedText;
  bool get isComposing => _isComposing;

  void updateComposing(String text) {
    _isComposing = true;
    _composingText = text;
  }

  void clearComposing() {
    _isComposing = false;
    _composingText = '';
  }

  void updateConfirmedText(String text) {
    _previousConfirmedText = text;
  }

  void reset() {
    _composingText = '';
    _previousConfirmedText = '';
    _isComposing = false;
  }

  /// Extract the delta (newly added text) between previous and current text.
  /// Returns the new portion that should be sent to SSH.
  static String extractDelta(String previous, String current) {
    if (current.isEmpty) return '';
    if (previous.isEmpty) return current;

    if (current.startsWith(previous)) {
      return current.substring(previous.length);
    }

    // Text was replaced entirely (predictive conversion, etc.).
    // Send the full current text.
    return current;
  }

  /// Check if composing was cancelled (text unchanged or empty after composing).
  static bool isCancelled(TextEditingValue value, String previousText) {
    return value.text.isEmpty || value.text == previousText;
  }
}
