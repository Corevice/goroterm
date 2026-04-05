import 'package:flutter/widgets.dart';

import '../../../core/utils/shell_utils.dart';
import 'composition_buffer.dart';

typedef SendToSshCallback = void Function(String text);
typedef ShowComposingOverlayCallback = void Function(String text);
typedef ClearComposingOverlayCallback = void Function();

class ImeInputHandler {
  ImeInputHandler({
    required this.onSendToSsh,
    required this.onShowComposingOverlay,
    required this.onClearComposingOverlay,
  });

  final SendToSshCallback onSendToSsh;
  final ShowComposingOverlayCallback onShowComposingOverlay;
  final ClearComposingOverlayCallback onClearComposingOverlay;

  final CompositionBuffer _buffer = CompositionBuffer();

  bool get isComposing => _buffer.isComposing;
  String get composingText => _buffer.composingText;

  void onTextInputAction(TextEditingValue value) {
    final hasComposingRange = value.composing != TextRange.empty;

    if (hasComposingRange) {
      // Composing (converting) - do NOT send to SSH
      _buffer.updateComposing(
        value.text.substring(value.composing.start, value.composing.end),
      );
      onShowComposingOverlay(_buffer.composingText);
    } else if (_buffer.isComposing) {
      // Composing just ended: either confirmed or cancelled
      _buffer.clearComposing();
      onClearComposingOverlay();

      if (CompositionBuffer.isCancelled(value, _buffer.previousConfirmedText)) {
        // Cancelled: do not send anything
        return;
      }

      // Confirmed: send the delta only
      final delta = CompositionBuffer.extractDelta(
        _buffer.previousConfirmedText,
        value.text,
      );
      if (delta.isNotEmpty) {
        onSendToSsh(delta);
      }
      _buffer.updateConfirmedText(value.text);
    } else {
      // Normal input (ASCII, etc.) - send delta
      final delta = CompositionBuffer.extractDelta(
        _buffer.previousConfirmedText,
        value.text,
      );
      if (delta.isNotEmpty) {
        onSendToSsh(delta);
      }
      _buffer.updateConfirmedText(value.text);
    }
  }

  void onEnterKey() {
    if (_buffer.isComposing) {
      // During composing, let IME handle Enter (do not send \r to SSH)
      return;
    }
    onSendToSsh('\r');
  }

  void onPaste(String text) {
    onSendToSsh(sanitizeForTerminal(text));
  }

  void reset() {
    _buffer.reset();
    onClearComposingOverlay();
  }
}
