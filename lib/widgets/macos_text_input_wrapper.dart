import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// macOS 用 IME 対応 TextInputClient。
/// xterm の CustomTextEdit が持つ setEditingState リセット問題を回避する。
///
/// - composing 中は onInsert を呼ばない
/// - composing 確定時に delta のみ送信
/// - setEditingState は composing 完了後に **短い遅延** を入れて
///   次のキー入力が失われないようにする
class MacosTextInputWrapper extends StatefulWidget {
  const MacosTextInputWrapper({
    super.key,
    required this.child,
    required this.focusNode,
    required this.onInsert,
    required this.onDelete,
    required this.onComposing,
    required this.onAction,
    this.enabled = true,
  });

  final Widget child;
  final FocusNode focusNode;
  final void Function(String) onInsert;
  final void Function() onDelete;
  final void Function(String?) onComposing;
  final void Function(TextInputAction) onAction;
  final bool enabled;

  @override
  State<MacosTextInputWrapper> createState() => MacosTextInputWrapperState();
}

class MacosTextInputWrapperState extends State<MacosTextInputWrapper>
    implements TextInputClient {
  TextInputConnection? _connection;

  // deleteDetection 用の初期状態（スペース2つ + カーソル末尾）
  static const _initEditingState = TextEditingValue(
    text: '  ',
    selection: TextSelection.collapsed(offset: 2),
  );

  TextEditingValue _currentState = _initEditingState;
  String _confirmedText = _initEditingState.text;
  bool _isComposing = false;

  @override
  void initState() {
    super.initState();
    widget.focusNode.addListener(_onFocusChange);
  }

  @override
  void didUpdateWidget(MacosTextInputWrapper oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.focusNode != oldWidget.focusNode) {
      oldWidget.focusNode.removeListener(_onFocusChange);
      widget.focusNode.addListener(_onFocusChange);
    }
  }

  @override
  void dispose() {
    widget.focusNode.removeListener(_onFocusChange);
    _closeConnection();
    super.dispose();
  }

  void _onFocusChange() {
    if (!widget.enabled) return;
    if (widget.focusNode.hasFocus &&
        widget.focusNode.consumeKeyboardToken()) {
      _openConnection();
    } else if (!widget.focusNode.hasFocus) {
      _closeConnection();
    }
  }

  void _openConnection() {
    if (_connection != null && _connection!.attached) {
      _connection!.show();
      return;
    }
    _connection = TextInput.attach(
      this,
      const TextInputConfiguration(
        inputType: TextInputType.emailAddress,
        inputAction: TextInputAction.newline,
        keyboardAppearance: Brightness.dark,
        autocorrect: false,
        enableSuggestions: false,
        enableIMEPersonalizedLearning: false,
      ),
    );
    _connection!.show();
    _connection!.setEditingState(_initEditingState);
    _confirmedText = _initEditingState.text;
  }

  void _closeConnection() {
    _connection?.close();
    _connection = null;
  }

  void requestKeyboard() {
    if (widget.focusNode.hasFocus) {
      _openConnection();
    } else {
      widget.focusNode.requestFocus();
    }
  }

  bool get hasInputConnection =>
      _connection != null && _connection!.attached;

  @override
  TextEditingValue? get currentTextEditingValue => _currentState;

  @override
  AutofillScope? get currentAutofillScope => null;

  @override
  void updateEditingValue(TextEditingValue value) {
    _currentState = value;

    final hasComposing = !value.composing.isCollapsed;

    if (hasComposing) {
      // composing 中 — 送信しない
      _isComposing = true;
      final composingText =
          value.composing.textInside(value.text);
      widget.onComposing(composingText);
      return;
    }

    // composing 終了 or 通常入力
    widget.onComposing(null);
    final wasComposing = _isComposing;
    _isComposing = false;

    if (value.text.length < _confirmedText.length) {
      // 削除
      widget.onDelete();
    } else {
      // delta を計算
      final delta = value.text.substring(_confirmedText.length);
      if (delta.isNotEmpty) {
        widget.onInsert(delta);
      }
    }

    // 確定テキストを記憶してリセット
    _confirmedText = _initEditingState.text;
    _currentState = _initEditingState;

    // composing 直後はリセットを少し遅らせて次のキー入力を失わないようにする
    if (wasComposing) {
      Future.microtask(() {
        if (_connection?.attached == true && !_isComposing) {
          _connection!.setEditingState(_initEditingState);
        }
      });
    } else {
      _connection?.setEditingState(_initEditingState);
    }
  }

  @override
  void performAction(TextInputAction action) {
    widget.onAction(action);
  }

  @override
  void performPrivateCommand(String action, Map<String, dynamic> data) {}

  @override
  void showAutocorrectionPromptRect(int start, int end) {}

  @override
  void updateFloatingCursor(RawFloatingCursorPoint point) {}

  @override
  void connectionClosed() {}

  @override
  void insertTextPlaceholder(Size size) {}

  @override
  void removeTextPlaceholder() {}

  @override
  void showToolbar() {}

  @override
  void didChangeInputControl(
      TextInputControl? oldControl, TextInputControl? newControl) {}

  @override
  void insertContent(KeyboardInsertedContent content) {}

  @override
  void performSelector(String selectorName) {}

  @override
  Widget build(BuildContext context) {
    return widget.child;
  }
}
