// Chord routing of a session: each keyboard chord goes to exactly one place.
//
// - "Send to the remote PC": the default of every chord.
// - "Run on this PC": the peer's exclude list (peer option `keyboard-exclude-shortcuts`, Rust `src/keyboard/exclude.rs`),
//   saved per device. The keyboard hook diverts such a chord before the shortcut matcher sees it.
// - "RustDesk action": a keyboard-shortcut binding (local option `keyboard-shortcuts`, Rust
//   `src/keyboard/shortcuts.rs`), global; bound and edited on the keyboard shortcuts page.
//
// A chord on the exclude list that is also bound to an action is shown as a conflict: it runs on this PC. Choosing a
// route here removes the chord from the other place.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/common/widgets/keyboard_shortcuts/shortcut_actions.dart';
import 'package:flutter_hbb/common/widgets/keyboard_shortcuts/shortcut_constants.dart';
import 'package:flutter_hbb/models/model.dart';
import 'package:flutter_hbb/models/platform_model.dart';

const String kOptionKeyboardExcludeShortcuts = 'keyboard-exclude-shortcuts';

/// Canonical chords (`Ctrl+Alt+Shift+Win+<key>`) always listed.
const List<String> kKeyboardShortcutPresets = [
  'Win',
  'Alt+Shift',
  'Ctrl+Shift',
  'Alt+Tab',
  'Alt+Esc',
  'Alt+F4',
  'Ctrl+Esc',
  'Ctrl+Shift+Esc',
  'Win+D',
  'Win+E',
  'Win+R',
  'Win+V',
  'Win+Tab',
  'Win+Space',
  'Shift+Win+S',
  'Win+Left',
  'Win+Right',
  'Win+Up',
  'Win+Down',
  'Ctrl+Win+Left',
  'Ctrl+Win+Right',
  'Ctrl+Win+D',
  'PrintScreen',
];

const String _kRouteRemote = 'remote';
const String _kRouteLocal = 'local';
const String _kRouteAction = 'action';

List<String> _parseList(String raw) => raw
    .split(',')
    .map((e) => bind.mainNormalizeKeyboardShortcut(chord: e))
    .where((e) => e.isNotEmpty)
    .toSet()
    .toList();

/// Chord → the shortcut bindings (`{action, mods, key}`) bound to it (`main_keyboard_shortcut_chords()`).
Map<String, List<Map<String, dynamic>>> _actionChords() {
  final res = <String, List<Map<String, dynamic>>>{};
  try {
    for (final e in jsonDecode(bind.mainKeyboardShortcutChords()) as List) {
      final chord = e['chord'] as String;
      res.putIfAbsent(chord, () => []).add(Map<String, dynamic>.from(e['binding'] as Map));
    }
  } catch (_) {}
  return res;
}

String _actionLabel(String actionId) {
  for (final entry in allActionEntries(kKeyboardShortcutActionGroups)) {
    if (entry.id == actionId) return translate(entry.labelKey);
  }
  return actionId;
}

bool _sameBinding(Map a, Map b) {
  final ma = ((a['mods'] as List?) ?? []).map((e) => '$e').toSet();
  final mb = ((b['mods'] as List?) ?? []).map((e) => '$e').toSet();
  return a['action'] == b['action'] && a['key'] == b['key'] && ma.length == mb.length && ma.containsAll(mb);
}

/// Removes `remove` from the stored keyboard-shortcut bindings and reloads the matcher.
Future<void> _removeBindings(List<Map<String, dynamic>> remove) async {
  if (remove.isEmpty) return;
  final raw = bind.mainGetLocalOption(key: kShortcutLocalConfigKey);
  Map<String, dynamic> json;
  try {
    json = raw.isEmpty ? <String, dynamic>{} : Map<String, dynamic>.from(jsonDecode(raw) as Map);
  } catch (_) {
    return;
  }
  final list = ((json['bindings'] as List?) ?? []).whereType<Map>().toList();
  json['bindings'] = list.where((b) => !remove.any((r) => _sameBinding(b, r))).toList();
  await bind.mainSetLocalOption(key: kShortcutLocalConfigKey, value: jsonEncode(json));
  bind.mainReloadKeyboardShortcuts();
}

void keyboardExcludeShortcutsDialog(FFI ffi) async {
  final sessionId = ffi.sessionId;
  final raw = await bind.sessionGetPeerOption(
      sessionId: sessionId, name: kOptionKeyboardExcludeShortcuts);
  final excluded = _parseList(raw);
  final actions = _actionChords();
  // Chord → route chosen in this dialog; absent = unchanged.
  final chosen = <String, String>{};
  final chords = <String>[
    ...kKeyboardShortcutPresets,
    ...excluded.where((e) => !kKeyboardShortcutPresets.contains(e)),
    ...actions.keys.where((e) => !kKeyboardShortcutPresets.contains(e) && !excluded.contains(e)),
  ];
  var recording = false;
  Timer? poll;
  DateTime? recordingSince;

  String routeOf(String chord) {
    final c = chosen[chord];
    if (c != null) return c;
    if (excluded.contains(chord)) return _kRouteLocal;
    if (actions.containsKey(chord)) return _kRouteAction;
    return _kRouteRemote;
  }

  void stopRecording() {
    poll?.cancel();
    poll = null;
    if (recording) {
      bind.mainStopKeyboardShortcutRecording();
    }
    recording = false;
  }

  await ffi.dialogManager.show((setState, close, context) {
    void add(String chord) {
      if (chord.isEmpty) return;
      if (!chords.contains(chord)) chords.add(chord);
      chosen[chord] = _kRouteLocal;
    }

    // The keyboard hook records the next chord exclusively: no key event reaches another keyboard hook
    // (e.g. AutoHotkey) or this dialog until a chord is complete.
    void startRecording() {
      bind.mainStartKeyboardShortcutRecording();
      recordingSince = DateTime.now();
      setState(() => recording = true);
      poll = Timer.periodic(const Duration(milliseconds: 50), (_) {
        final chord = bind.mainTakeRecordedKeyboardShortcut();
        final timedOut =
            DateTime.now().difference(recordingSince!).inSeconds >= 15;
        if (chord.isEmpty && !timedOut) return;
        stopRecording();
        try {
          setState(() => add(chord));
        } catch (_) {
          // The dialog was dismissed by `dialogManager`.
        }
      });
    }

    void onClose() {
      stopRecording();
      close();
    }

    Future<void> submit() async {
      final local = <String>[];
      final unbind = <Map<String, dynamic>>[];
      for (final chord in chords) {
        final route = routeOf(chord);
        if (route == _kRouteLocal) local.add(chord);
        if (route != _kRouteAction && chosen.containsKey(chord)) {
          unbind.addAll(actions[chord] ?? const []);
        }
      }
      await bind.sessionSetKeyboardExcludeShortcuts(
          sessionId: sessionId, value: local.join(','));
      await _removeBindings(unbind);
      onClose();
    }

    Widget row(String chord) {
      final bound = actions[chord];
      final conflict = bound != null && routeOf(chord) == _kRouteLocal;
      final items = <DropdownMenuItem<String>>[
        DropdownMenuItem(value: _kRouteRemote, child: Text(translate('Send to the remote PC'))),
        DropdownMenuItem(
            value: _kRouteLocal,
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Text(translate('Run on this PC')),
              const SizedBox(width: 4),
              const Icon(Icons.save_outlined, size: 14),
            ])),
        if (bound != null)
          DropdownMenuItem(
              value: _kRouteAction,
              child: Text(
                  '${translate('RustDesk action')}: ${bound.map((b) => _actionLabel('${b['action']}')).join(', ')}',
                  overflow: TextOverflow.ellipsis)),
      ];
      return Row(children: [
        Expanded(child: Text(chord)),
        if (conflict)
          Tooltip(
            message: translate('chord-conflict-tip'),
            child: const Icon(Icons.warning_amber_rounded, size: 18, color: Colors.orange),
          ),
        SizedBox(
          width: 260,
          child: DropdownButton<String>(
            isExpanded: true,
            value: routeOf(chord),
            items: items,
            onChanged: (v) {
              if (v != null) setState(() => chosen[chord] = v);
            },
          ),
        ),
      ]);
    }

    return CustomAlertDialog(
      title: Text(translate('Keyboard chord routing')),
      content: SizedBox(
        width: 560,
        height: 520,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(translate('chord-routing-tip')),
            const SizedBox(height: 8),
            Expanded(child: ListView(children: chords.map(row).toList())),
            Row(
              children: [
                Expanded(
                  child: Text(translate(recording
                      ? 'Press the shortcut to keep on this PC'
                      : 'Add a shortcut to keep on this PC')),
                ),
                dialogButton(recording ? 'Cancel' : 'Record',
                    icon: Icon(recording
                        ? Icons.stop_rounded
                        : Icons.fiber_manual_record),
                    onPressed: recording
                        ? () => setState(() => stopRecording())
                        : startRecording,
                    isOutline: true),
              ],
            ),
          ],
        ),
      ),
      actions: [
        dialogButton('Cancel',
            icon: const Icon(Icons.close_rounded),
            onPressed: onClose,
            isOutline: true),
        dialogButton('OK',
            icon: const Icon(Icons.done_rounded), onPressed: submit),
      ],
      onSubmit: recording ? null : submit,
      onCancel: recording ? null : onClose,
    );
  });
  stopRecording();
}
