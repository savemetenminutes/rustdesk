import 'dart:convert';
import 'dart:ui';

import 'package:flutter_hbb/utils/display_windows.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a stored display window keeps its frame, screen, state, view and scroll', () {
    final state = DisplayWindowState(
        const Rect.fromLTWH(1912, -8, 1936, 1035),
        const Rect.fromLTRB(1920, 0, 3840, 1080),
        true,
        false,
        viewStyle: 'original',
        customScalePercent: 75,
        scrollX: 43.5,
        scrollY: 0);
    final restored =
        DisplayWindowState.fromJson(jsonDecode(jsonEncode(state.toJson())))!;
    expect(restored.frame, state.frame);
    expect(restored.screen, state.screen);
    expect(restored.isMaximized, isTrue);
    expect(restored.isFullscreen, isFalse);
    expect(restored.viewStyle, 'original');
    expect(restored.customScalePercent, 75);
    expect(restored.scrollX, 43.5);
    expect(restored.scrollY, 0);
  });

  test('a malformed stored entry is ignored', () {
    expect(DisplayWindowState.fromJson({'l': 'x'}), isNull);
  });
}
