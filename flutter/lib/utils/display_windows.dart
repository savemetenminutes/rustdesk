// Per-peer, per-display remote window memory.
//
// Peer flutter option `kPeerOptionDisplayWindows` holds a JSON object keyed by the remote display index
// (`kAllDisplayValue` included) with one `DisplayWindowState` per display that was ever shown in its own window.
// An entry is added or updated whenever a remote window showing that display moves, resizes, changes maximized or
// fullscreen state, switches display or closes; entries are never removed, so closing the windows one at a time keeps
// every display.
//
// Writes MUST go through the main window isolate (`kWindowEventSaveDisplayWindow`): every remote window is its own
// isolate, and the option is a read-modify-write of one string, so concurrent writers would drop each other's
// entries.

import 'dart:async';
import 'dart:convert';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/main.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:flutter_hbb/models/state_model.dart';
import 'package:window_size/window_size.dart' as window_size;

const String kPeerOptionDisplayWindows = 'display_windows';
const String kWindowEventSaveDisplayWindow = 'save_display_window';

/// Restore frame of a window whose target local screen no longer exists; the window is maximized on the primary
/// screen over it.
const Size kDisplayWindowFallbackSize = Size(600, 400);
const double kDisplayWindowFallbackOffset = 30;

class DisplayWindowState {
  /// Restore (non-maximized, non-fullscreen) frame.
  final Rect frame;

  /// Frame of the local screen that contained the center of `frame` when it was saved.
  final Rect? screen;
  final bool isMaximized;
  final bool isFullscreen;

  DisplayWindowState(
      this.frame, this.screen, this.isMaximized, this.isFullscreen);

  Map<String, dynamic> toJson() => {
        'l': frame.left,
        't': frame.top,
        'w': frame.width,
        'h': frame.height,
        if (screen != null)
          'screen': {
            'l': screen!.left,
            't': screen!.top,
            'r': screen!.right,
            'b': screen!.bottom,
          },
        'isMaximized': isMaximized,
        'isFullscreen': isFullscreen,
      };

  static DisplayWindowState? fromJson(dynamic m) {
    try {
      final s = m['screen'];
      return DisplayWindowState(
        Rect.fromLTWH((m['l'] as num).toDouble(), (m['t'] as num).toDouble(),
            (m['w'] as num).toDouble(), (m['h'] as num).toDouble()),
        s == null
            ? null
            : Rect.fromLTRB(
                (s['l'] as num).toDouble(),
                (s['t'] as num).toDouble(),
                (s['r'] as num).toDouble(),
                (s['b'] as num).toDouble()),
        m['isMaximized'] == true,
        m['isFullscreen'] == true,
      );
    } catch (e) {
      debugPrint('Failed to parse DisplayWindowState $m: $e');
      return null;
    }
  }
}

/// Returns the stored windows of `peerId`, keyed by remote display index.
Map<int, DisplayWindowState> loadDisplayWindows(String peerId) {
  final res = <int, DisplayWindowState>{};
  final raw =
      bind.mainGetPeerFlutterOptionSync(id: peerId, k: kPeerOptionDisplayWindows);
  if (raw.isEmpty) {
    return res;
  }
  try {
    final m = jsonDecode(raw) as Map<String, dynamic>;
    m.forEach((k, v) {
      final display = int.tryParse(k);
      final state = DisplayWindowState.fromJson(v);
      if (display != null && state != null) {
        res[display] = state;
      }
    });
  } catch (e) {
    debugPrint('Failed to parse $kPeerOptionDisplayWindows of $peerId: $e');
  }
  return res;
}

/// Main window isolate only: handler of `kWindowEventSaveDisplayWindow`.
void storeDisplayWindow(String arguments) {
  try {
    final args = jsonDecode(arguments);
    final peerId = args['peer_id'] as String;
    final display = args['display'] as int;
    final state = DisplayWindowState.fromJson(args['state']);
    if (state == null) {
      return;
    }
    final raw = bind.mainGetPeerFlutterOptionSync(
        id: peerId, k: kPeerOptionDisplayWindows);
    Map<String, dynamic> m = {};
    if (raw.isNotEmpty) {
      try {
        m = jsonDecode(raw) as Map<String, dynamic>;
      } catch (_) {}
    }
    m['$display'] = state.toJson();
    bind.mainSetPeerFlutterOptionSync(
        id: peerId, k: kPeerOptionDisplayWindows, v: jsonEncode(m));
  } catch (e) {
    debugPrint('Failed to store display window "$arguments": $e');
  }
}

/// Returns the frame of a screen in `screens` that equals `rect` within 1 px, else null.
Rect? _findScreen(List<window_size.Screen> screens, Rect rect) {
  for (final s in screens) {
    final f = s.frame;
    if ((f.left - rect.left).abs() <= 1 &&
        (f.top - rect.top).abs() <= 1 &&
        (f.right - rect.right).abs() <= 1 &&
        (f.bottom - rect.bottom).abs() <= 1) {
      return f;
    }
  }
  return null;
}

/// Primary screen: the screen whose frame starts at the virtual-screen origin (Windows), else the first one.
Rect? _primaryScreen(List<window_size.Screen> screens) {
  if (screens.isEmpty) {
    return null;
  }
  for (final s in screens) {
    if (s.frame.left == 0 && s.frame.top == 0) {
      return s.frame;
    }
  }
  return screens.first.frame;
}

Rect? _screenContaining(List<window_size.Screen> screens, Offset point) {
  for (final s in screens) {
    if (s.frame.contains(point)) {
      return s.frame;
    }
  }
  return null;
}

/// Restore frame of the current window isolate's window, tracked while the window is neither maximized nor
/// fullscreen.
Rect? _normalFrame;

/// Applies `state` to window `windowId`.
///
/// The target screen is `state.screen`; when no current local screen equals it, the window MUST open maximized on the
/// primary screen with the restore frame `kDisplayWindowFallbackSize` at `kDisplayWindowFallbackOffset`.
Future<void> applyDisplayWindowState(
    int windowId, DisplayWindowState state) async {
  var frame = state.frame;
  var isMaximized = state.isMaximized;
  var isFullscreen = state.isFullscreen;
  List<window_size.Screen> screens = [];
  try {
    screens = await window_size.getScreenList();
  } catch (e) {
    debugPrint('Failed to get the screen list: $e');
  }
  final targetExists = screens.isEmpty ||
      (state.screen != null && _findScreen(screens, state.screen!) != null);
  if (!targetExists) {
    final primary = _primaryScreen(screens)!;
    frame = Rect.fromLTWH(
        primary.left + kDisplayWindowFallbackOffset,
        primary.top + kDisplayWindowFallbackOffset,
        kDisplayWindowFallbackSize.width,
        kDisplayWindowFallbackSize.height);
    isMaximized = true;
    isFullscreen = false;
  }
  final wc = WindowController.fromWindowId(windowId);
  if (kWindowId == windowId) {
    _normalFrame = frame;
  }
  await wc.setFrame(frame);
  // A delay is needed, or the window is restored after maximize/fullscreen (same as `restoreWindowPosition()`).
  Future.delayed(const Duration(milliseconds: 300), () async {
    if (isFullscreen) {
      if (kWindowId == windowId) {
        stateGlobal.setFullscreen(true);
      } else {
        DesktopMultiWindow.invokeMethod(
            windowId, kWindowEventSetFullscreen, 'true');
      }
    } else if (isMaximized) {
      await wc.maximize();
    }
  });
}

/// Returns `(peerId, display)` of every remote session shown in the current window.
typedef DisplayWindowSessions = List<(String, int)> Function();

DisplayWindowSessions? _sessions;
bool _armed = false;
Timer? _reportTimer;

/// Registered by the remote window page of the current window isolate.
void registerDisplayWindowSessions(DisplayWindowSessions sessions) {
  _sessions = sessions;
}

/// Reports MUST start only after the window reached its restored frame and display: a report taken earlier would
/// store a transient frame under the display that is being replaced.
void armDisplayWindowReports() {
  if (_armed) {
    return;
  }
  Future.delayed(const Duration(milliseconds: 1500), () {
    _armed = true;
    reportDisplayWindowSoon();
  });
}

/// Debounced `reportDisplayWindowNow()`.
void reportDisplayWindowSoon() {
  if (!_armed) {
    return;
  }
  _reportTimer?.cancel();
  _reportTimer =
      Timer(const Duration(milliseconds: 500), () => reportDisplayWindowNow());
}

/// Sends the current window's state for every `(peerId, display)` it shows to the main window isolate.
Future<void> reportDisplayWindowNow() async {
  _reportTimer?.cancel();
  _reportTimer = null;
  final windowId = kWindowId;
  if (!_armed || _sessions == null || windowId == null) {
    return;
  }
  if (stateGlobal.isMinimized) {
    return;
  }
  final wc = WindowController.fromWindowId(windowId);
  final isFullscreen = stateGlobal.fullscreen.isTrue;
  Rect current;
  bool isMaximized;
  try {
    current = await wc.getFrame();
    isMaximized = !isFullscreen && await wc.isMaximized();
  } catch (e) {
    debugPrint('Failed to get the frame of window $windowId, it may be hidden');
    return;
  }
  // A minimized window on Windows reports an offset of -32000.
  if (current.left < -10000 || current.top < -10000) {
    return;
  }
  if (!isFullscreen && !isMaximized) {
    _normalFrame = current;
  }
  List<window_size.Screen> screens = [];
  try {
    screens = await window_size.getScreenList();
  } catch (e) {
    debugPrint('Failed to get the screen list: $e');
  }
  for (final (peerId, display) in _sessions!()) {
    final frame =
        _normalFrame ?? loadDisplayWindows(peerId)[display]?.frame ?? current;
    final screen = _screenContaining(screens, frame.center) ??
        _screenContaining(screens, current.center);
    final state =
        DisplayWindowState(frame, screen, isMaximized, isFullscreen);
    await DesktopMultiWindow.invokeMethod(
        kMainWindowId,
        kWindowEventSaveDisplayWindow,
        jsonEncode({
          'peer_id': peerId,
          'display': display,
          'state': state.toJson(),
        }));
  }
}
