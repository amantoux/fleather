import 'dart:math';

import 'package:fleather/util.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/rendering.dart';

import 'editor.dart';

mixin RawEditorStateSelectionDelegateMixin on EditorState
    implements TextSelectionDelegate {
  @override
  TextEditingValue get textEditingValue {
    return widget.controller.plainTextEditingValue;
  }

  @override
  void userUpdateTextEditingValue(
      TextEditingValue value, SelectionChangedCause cause) {
    final cursorPosition = value.selection.extentOffset;
    final oldText = widget.controller.document.toPlainText();
    final newText = value.text;
    final diff = fastDiff(oldText, newText, cursorPosition);
    widget.controller.replaceText(
        diff.start, diff.deleted.length, diff.inserted,
        selection: value.selection);
  }

  @override
  void bringIntoView(TextPosition position) {
    final localRect = renderEditor.getLocalRectForCaret(position);
    final targetOffset = _getOffsetToRevealCaret(localRect, position);

    scrollController.jumpTo(targetOffset.offset);
    renderEditor.showOnScreen(rect: targetOffset.rect);
  }

  // Finds the closest scroll offset to the current scroll offset that fully
  // reveals the given caret rect. If the given rect's main axis extent is too
  // large to be fully revealed in `renderEditable`, it will be centered along
  // the main axis.
  //
  // If this is a multiline EditableText (which means the Editable can only
  // scroll vertically), the given rect's height will first be extended to match
  // `renderEditable.preferredLineHeight`, before the target scroll offset is
  // calculated.
  RevealedOffset _getOffsetToRevealCaret(Rect rect, TextPosition position) {
    if (!scrollController.position.allowImplicitScrolling) {
      return RevealedOffset(offset: scrollController.offset, rect: rect);
    }

    final editableSize = renderEditor.size;
    final double additionalOffset;
    final Offset unitOffset;

    // The caret is vertically centered within the line. Expand the caret's
    // height so that it spans the line because we're going to ensure that the
    // entire expanded caret is scrolled into view.
    final expandedRect = Rect.fromCenter(
      center: rect.center,
      width: rect.width,
      height: max(rect.height, renderEditor.preferredLineHeight(position)),
    );

    additionalOffset = expandedRect.height >= editableSize.height
        ? editableSize.height / 2 - expandedRect.center.dy
        : 0.0
            .clamp(expandedRect.bottom - editableSize.height, expandedRect.top);
    unitOffset = const Offset(0, 1);

    // No overscrolling when encountering tall fonts/scripts that extend past
    // the ascent.
    final targetOffset = (additionalOffset + scrollController.offset).clamp(
      scrollController.position.minScrollExtent,
      scrollController.position.maxScrollExtent,
    );

    final offsetDelta = scrollController.offset - targetOffset;
    return RevealedOffset(
        rect: rect.shift(unitOffset * offsetDelta), offset: targetOffset);
  }

  @override
  void hideToolbar([bool hideHandles = true]) {
    if (hideHandles) {
      selectionOverlay?.hide();
    } else if (selectionOverlay?.toolbarIsVisible ?? false) {
      selectionOverlay?.hideToolbar();
    }
  }

  @override
  bool get cutEnabled =>
      !widget.readOnly && !textEditingValue.selection.isCollapsed;

  @override
  bool get copyEnabled => !textEditingValue.selection.isCollapsed;

  @override
  bool get pasteEnabled =>
      !widget.readOnly &&
      (clipboardStatus == null ||
          clipboardStatus?.value == ClipboardStatus.pasteable);

  @override
  bool get selectAllEnabled => widget.enableInteractiveSelection;
}
