import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../rendering/editor.dart';
import 'editor.dart';

mixin RawEditorStateTextInputClientMixin on EditorState
    implements DeltaTextInputClient {
  TextInputConnection? _textInputConnection;
  TextEditingValue? _lastKnownRemoteTextEditingValue;

  /// Whether to create an input connection with the platform for text editing
  /// or not.
  ///
  /// Read-only input fields do not need a connection with the platform since
  /// there's no need for text editing capabilities (e.g. virtual keyboard).
  ///
  /// On the web, we always need a connection because we want some browser
  /// functionalities to continue to work on read-only input fields like:
  ///
  /// - Relevant context menu.
  /// - cmd/ctrl+c shortcut to copy.
  /// - cmd/ctrl+a to select all.
  /// - Changing the selection using a physical keyboard.
  bool get shouldCreateInputConnection => kIsWeb || !widget.readOnly;

  /// Returns `true` if there is open input connection.
  bool get hasConnection =>
      _textInputConnection != null && _textInputConnection!.attached;

  /// Opens or closes input connection based on the current state of
  /// [focusNode] and [value].
  void openOrCloseConnection() {
    if (effectiveFocusNode.hasFocus &&
        effectiveFocusNode.consumeKeyboardToken()) {
      openConnectionIfNeeded();
    } else if (!effectiveFocusNode.hasFocus) {
      closeConnectionIfNeeded();
    }
  }

  void openConnectionIfNeeded() {
    if (!shouldCreateInputConnection) {
      return;
    }

    if (!hasConnection) {
      _lastKnownRemoteTextEditingValue = textEditingValue;
      _textInputConnection = TextInput.attach(
        this,
        TextInputConfiguration(
          inputType: TextInputType.multiline,
          readOnly: widget.readOnly,
          obscureText: false,
          autocorrect: false,
          enableDeltaModel: true,
          inputAction: TextInputAction.newline,
          keyboardAppearance: widget.keyboardAppearance,
          textCapitalization: widget.textCapitalization,
        ),
      );

      _updateSizeAndTransform();
      _textInputConnection!.setEditingState(_lastKnownRemoteTextEditingValue!);
    }
    _textInputConnection!.show();
  }

  /// Closes input connection if it's currently open. Otherwise does nothing.
  void closeConnectionIfNeeded() {
    if (hasConnection) {
      _textInputConnection!.close();
      _textInputConnection = null;
      _lastKnownRemoteTextEditingValue = null;
    }
  }

  /// Updates remote value based on current state of [document] and
  /// [selection].
  ///
  /// This method may not actually send an update to native side if it thinks
  /// remote value is up to date or identical.
  void updateRemoteValueIfNeeded() {
    if (!hasConnection) return;

    final value = textEditingValue;

    // Since we don't keep track of composing range in value provided by
    // FleatherController we need to add it here manually before comparing
    // with the last known remote value.
    // It is important to prevent excessive remote updates as it can cause
    // race conditions.
    final actualValue = value.copyWith(
      composing: _lastKnownRemoteTextEditingValue?.composing,
    );

    if (actualValue == _lastKnownRemoteTextEditingValue) return;

    if (spellCheckEnabled &&
        actualValue.text.isNotEmpty &&
        actualValue.text != _lastKnownRemoteTextEditingValue?.text) {
      performSpellCheck(value.text);
    }

    _lastKnownRemoteTextEditingValue = actualValue;
    _textInputConnection!.setEditingState(actualValue);
  }

  // Start TextInputClient implementation
  @override
  TextEditingValue? get currentTextEditingValue =>
      _lastKnownRemoteTextEditingValue;

  // autofill is not needed
  @override
  AutofillScope? get currentAutofillScope => null;

  @override
  void updateEditingValueWithDeltas(List<TextEditingDelta> textEditingDeltas) {
    if (!shouldCreateInputConnection || textEditingDeltas.isEmpty) return;

    for (final textEditingDelta in textEditingDeltas) {
      int start = 0, length = 0;
      String data = '';
      if (textEditingDelta is TextEditingDeltaInsertion) {
        start = textEditingDelta.insertionOffset;
        data = textEditingDelta.textInserted;
      } else if (textEditingDelta is TextEditingDeltaDeletion) {
        start = textEditingDelta.deletedRange.start;
        length = textEditingDelta.deletedRange.length;
      } else if (textEditingDelta is TextEditingDeltaReplacement) {
        start = textEditingDelta.replacedRange.start;
        length = textEditingDelta.replacedRange.length;
        data = textEditingDelta.replacementText;
      }
      _lastKnownRemoteTextEditingValue =
          textEditingDelta.apply(_lastKnownRemoteTextEditingValue!);
      widget.controller.replaceText(start, length, data,
          selection: textEditingDelta.selection);

      if (data.isNotEmpty) {
        hideToolbar(true);
      }
    }
  }

  @override
  void updateEditingValue(TextEditingValue value) {
    // no-op
  }

  @override
  void performAction(TextInputAction action) {
    // no-op
  }

  @override
  void performPrivateCommand(String action, Map<String, dynamic> data) {
    // no-op
  }

  // The time it takes for the floating cursor to snap to the text aligned
  // cursor position after the user has finished placing it.
  static const Duration _floatingCursorResetTime = Duration(milliseconds: 125);

  // The original position of the caret on FloatingCursorDragState.start.
  Rect? _startCaretRect;

  // The most recent text position as determined by the location of the floating
  // cursor.
  TextPosition? _lastTextPosition;

  // The offset of the floating cursor as determined from the start call.
  Offset? _pointOffsetOrigin;

  // The most recent position of the floating cursor.
  Offset? _lastBoundedOffset;

  // Because the center of the cursor is preferredLineHeight / 2 below the touch
  // origin, but the touch origin is used to determine which line the cursor is
  // on, we need this offset to correctly render and move the cursor.
  Offset _floatingCursorOffset(TextPosition textPosition) =>
      Offset(0, renderEditor.preferredLineHeight(textPosition) / 2);

  @override
  void updateFloatingCursor(RawFloatingCursorPoint point) {
    switch (point.state) {
      case FloatingCursorDragState.Start:
        if (floatingCursorResetController.isAnimating) {
          floatingCursorResetController.stop();
          onFloatingCursorResetTick();
        }
        // We want to send in points that are centered around a (0,0) origin, so
        // we cache the position.
        _pointOffsetOrigin = point.offset;

        final currentTextPosition =
            TextPosition(offset: renderEditor.selection.baseOffset);
        _startCaretRect =
            renderEditor.getLocalRectForCaret(currentTextPosition);

        _lastBoundedOffset = _startCaretRect!.center -
            _floatingCursorOffset(currentTextPosition);
        _lastTextPosition = currentTextPosition;
        renderEditor.setFloatingCursor(
            point.state, _lastBoundedOffset!, _lastTextPosition!);
        break;
      case FloatingCursorDragState.Update:
        assert(_lastTextPosition != null, 'Last text position was not set');
        final floatingCursorOffset = _floatingCursorOffset(_lastTextPosition!);
        final Offset centeredPoint = point.offset! - _pointOffsetOrigin!;
        final Offset rawCursorOffset =
            _startCaretRect!.center + centeredPoint - floatingCursorOffset;

        final preferredLineHeight =
            renderEditor.preferredLineHeight(_lastTextPosition!);
        _lastBoundedOffset = renderEditor.calculateBoundedFloatingCursorOffset(
          rawCursorOffset,
          preferredLineHeight,
        );
        _lastTextPosition = renderEditor.getPositionForOffset(renderEditor
            .localToGlobal(_lastBoundedOffset! + floatingCursorOffset));
        renderEditor.setFloatingCursor(
            point.state, _lastBoundedOffset!, _lastTextPosition!);
        final newSelection = TextSelection.collapsed(
            offset: _lastTextPosition!.offset,
            affinity: _lastTextPosition!.affinity);
        // Setting selection as floating cursor moves will have scroll view
        // bring background cursor into view
        renderEditor.onSelectionChanged!(
            newSelection, SelectionChangedCause.forcePress);
        break;
      case FloatingCursorDragState.End:
        // We skip animation if no update has happened.
        if (_lastTextPosition != null && _lastBoundedOffset != null) {
          floatingCursorResetController.value = 0.0;
          floatingCursorResetController.animateTo(1.0,
              duration: _floatingCursorResetTime, curve: Curves.decelerate);
        }
        break;
    }
  }

  /// Specifies the floating cursor dimensions and position based
  /// the animation controller value.
  /// The floating cursor is resized
  /// (see [RenderAbstractEditor.setFloatingCursor])
  /// and repositioned (linear interpolation between position of floating cursor
  /// and current position of background cursor)
  void onFloatingCursorResetTick() {
    final Offset finalPosition =
        renderEditor.getLocalRectForCaret(_lastTextPosition!).centerLeft -
            _floatingCursorOffset(_lastTextPosition!);
    if (floatingCursorResetController.isCompleted) {
      renderEditor.setFloatingCursor(
          FloatingCursorDragState.End, finalPosition, _lastTextPosition!);
      _startCaretRect = null;
      _lastTextPosition = null;
      _pointOffsetOrigin = null;
      _lastBoundedOffset = null;
    } else {
      final double lerpValue = floatingCursorResetController.value;
      final double lerpX =
          ui.lerpDouble(_lastBoundedOffset!.dx, finalPosition.dx, lerpValue)!;
      final double lerpY =
          ui.lerpDouble(_lastBoundedOffset!.dy, finalPosition.dy, lerpValue)!;

      renderEditor.setFloatingCursor(FloatingCursorDragState.Update,
          Offset(lerpX, lerpY), _lastTextPosition!,
          resetLerpValue: lerpValue);
    }
  }

  @override
  void showAutocorrectionPromptRect(int start, int end) {
    throw UnimplementedError();
  }

  @override
  void connectionClosed() {
    if (hasConnection) {
      _textInputConnection!.connectionClosedReceived();
      _textInputConnection = null;
      _lastKnownRemoteTextEditingValue = null;
    }
  }

  void _updateSizeAndTransform() {
    if (hasConnection) {
      // Asking for renderEditor.size here can cause errors if layout hasn't
      // occurred yet. So we schedule a post frame callback instead.
      SchedulerBinding.instance.addPostFrameCallback((Duration _) {
        if (!mounted) {
          return;
        }
        final size = renderEditor.size;
        final transform = renderEditor.getTransformTo(null);
        _textInputConnection?.setEditableSizeAndTransform(size, transform);
      });
    }
  }

  @override
  void insertContent(KeyboardInsertedContent content) {
    // TODO: implement insertContent
  }
}

extension on TextRange {
  int get length => end - start;
}
