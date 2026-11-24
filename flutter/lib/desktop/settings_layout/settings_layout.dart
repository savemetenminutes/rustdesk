// Settings layout: the settings screen's categories and the remote toolbar's settings dropdowns are rendered from
// one JSON document, `settings_layout.json` (bundled in `assets/`, overridden by the file of that name in the config
// directory, `main_settings_layout()`). `SettingsLayout.reload()` re-reads it in this isolate;
// `SettingsLayout.reloadEverywhere()` makes every window do so (`kWindowActionReloadSettingsLayout`).
//
// Document: {"categories": [{"id", "label", "icon", "condition", "items": [item]}]}
// item: {"type": "section" | "bool" | "radio" | "number" | "widget" | "page" | "note",
//        "label", "tooltip", "platforms": ["windows" | "macos" | "linux"],
//        "condition": "<rhai expression>",                    (shown only while it evaluates to true)
//        "options": [option] | "<rhai expression>",           (radio; an expression evaluates to the option list)
//        "widget": "<id>",                                    (widget: `settingsWidgetBuilders[id]`)
//        "page": "<id>",                                      (page: `settingsPageBuilders[id]`, a whole page)
//        "default": store, "peer": store, "screen": {"field"}, (columns; a bool/radio/number needs at least one)
//        "session": "<id>",                                   (in a session the peer column is this widget)
//        "after": "<id>",                                     (`settingsAfterHooks[id]` runs after every write)
//        "enabledBy": store,                                  (editable only while that bool store is true)
//        "offClears": [store]}                                (turning this bool off also turns these off)
// option: {"value", "label", "tooltip"} | "<value = label>" | ["<value>", "<label>"(, "<tooltip>")]
// store: {"kind": "server" | "local" | "default" | "peer", "key", "invert": bool, "live": "<id>", "toggle": "<name>",
//         "options": [option] | "<rhai expression>"}         (radio options of this column only)
//   server  = `Config` option (this PC's service), local = `LocalConfig` option (this PC's client),
//   default = the default of every new session (`UserDefaultConfig`), peer = stored per device (`PeerConfig`).
//   A peer store edits the open session through its own setter (`toggle` = session toggle option name, `live` = a
//   named session setter), otherwise the peer file (`main_set_peer_setting`).
// screen: {"field": "viewStyle" | "customScalePercent"} — the fork's per remote screen window state
//   (`display_windows`, keyed by the remote display index).
// Expressions run in the Rust `rhai` engine (`main_eval_settings_expr`, scope and functions in
// `src/settings_expr.rs`); their errors are listed in the UI category's reload row.

import 'dart:convert';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/common/shared_state.dart';
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/models/model.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:flutter_hbb/models/state_model.dart';
import 'package:flutter_hbb/utils/scale.dart';
import 'package:get/get.dart';

const kPeerOptionDisplayWindowsKey = 'display_windows';

/// Errors of the layout's expressions since the last reload: expression → message. Written while pages build, so
/// the reload row follows `settingsExprErrorRevision`, bumped after the frame.
final Map<String, String> settingsExprErrors = {};
final RxInt settingsExprErrorRevision = 0.obs;
bool _exprErrorBumpScheduled = false;

void _exprError(String expr, String message) {
  if (settingsExprErrors[expr] == message) return;
  settingsExprErrors[expr] = message;
  if (_exprErrorBumpScheduled) return;
  _exprErrorBumpScheduled = true;
  WidgetsBinding.instance.addPostFrameCallback((_) {
    _exprErrorBumpScheduled = false;
    settingsExprErrorRevision.value++;
  });
}

/// Evaluates `rhai` expression `expr` in the scope of `target` and `value`; null (and an entry in
/// `settingsExprErrors`) when it fails.
dynamic settingsEval(String expr, {SettingsTarget? target, String value = ''}) {
  try {
    final r = jsonDecode(bind.mainEvalSettingsExpr(
        expr: expr,
        ctxJson: jsonEncode({
          'peer': target?.peerId ?? '',
          'in_session': target?.inSession ?? false,
          'display': target?.display ?? -1,
          'value': value,
        }))) as Map;
    if (r.containsKey('error')) {
      _exprError(expr, '${r['error']}');
      return null;
    }
    return r['ok'];
  } catch (e) {
    _exprError(expr, '$e');
    return null;
  }
}

/// A condition: true while expression `c` evaluates to true; a failing or non-bool result shows the item.
bool _conditionHolds(String? c) {
  if (c == null || c.trim().isEmpty) return true;
  final v = settingsEval(c);
  if (v is bool) return v;
  if (v != null) _exprError(c, 'not a bool: $v');
  return true;
}

SettingsOption? _optionFrom(dynamic o) {
  if (o is Map) return SettingsOption('${o['value'] ?? ''}', '${o['label'] ?? o['value'] ?? ''}', o['tooltip']);
  if (o is List && o.isNotEmpty) {
    return SettingsOption('${o[0]}', o.length > 1 ? '${o[1]}' : '${o[0]}', o.length > 2 ? '${o[2]}' : null);
  }
  if (o is String || o is num || o is bool) return SettingsOption('$o', '$o', null);
  return null;
}

/// "options" of an item or a store: a fixed list, or an expression (kept as `expr`) evaluated at render time.
class SettingsOptions {
  final List<SettingsOption> fixed;
  final String? expr;
  SettingsOptions(this.fixed, this.expr);

  static SettingsOptions? fromJson(dynamic j) {
    if (j is String) return SettingsOptions(const [], j);
    if (j is List) return SettingsOptions(j.map(_optionFrom).whereType<SettingsOption>().toList(), null);
    return null;
  }

  List<SettingsOption> resolve(SettingsTarget target, String current) {
    final e = expr;
    if (e == null) return fixed;
    final v = settingsEval(e, target: target, value: current);
    if (v is! List) {
      if (v != null) _exprError(e, 'not a list: $v');
      return const [];
    }
    return v.map(_optionFrom).whereType<SettingsOption>().toList();
  }
}

class SettingsStore {
  final String kind;
  final String key;
  final bool invert;
  final String? live;
  final String? toggle;
  final SettingsOptions? options;
  SettingsStore(this.kind, this.key, {this.invert = false, this.live, this.toggle, this.options});

  static SettingsStore? fromJson(dynamic j) => j is Map
      ? SettingsStore(j['kind'] ?? 'local', j['key'] ?? '',
          invert: j['invert'] == true,
          live: j['live'],
          toggle: j['toggle'],
          options: SettingsOptions.fromJson(j['options']))
      : null;
}

class SettingsOption {
  final String value;
  final String label;
  final String? tooltip;
  SettingsOption(this.value, this.label, this.tooltip);
}

class SettingsItem {
  final String type;
  final String label;
  final String? tooltip;
  final String? widget;
  final String? page;
  final String? session;
  final String? condition;
  final String? after;
  final List<String>? platforms;
  final SettingsOptions options;
  final SettingsStore? defaultStore;
  final SettingsStore? peerStore;
  final SettingsStore? enabledBy;
  final List<SettingsStore> offClears;
  final String? screenField;

  SettingsItem.fromJson(Map<String, dynamic> j)
      : type = j['type'] ?? 'bool',
        label = j['label'] ?? '',
        tooltip = j['tooltip'],
        widget = j['widget'],
        page = j['page'],
        session = j['session'],
        condition = j['condition'],
        after = j['after'],
        platforms = (j['platforms'] as List?)?.cast<String>(),
        options = SettingsOptions.fromJson(j['options']) ?? SettingsOptions(const [], null),
        defaultStore = SettingsStore.fromJson(j['default']),
        peerStore = SettingsStore.fromJson(j['peer']),
        enabledBy = SettingsStore.fromJson(j['enabledBy']),
        offClears = ((j['offClears'] as List?) ?? [])
            .map((e) => SettingsStore.fromJson(e))
            .whereType<SettingsStore>()
            .toList(),
        screenField = (j['screen'] as Map?)?['field'];

  bool get visibleOnThisPlatform {
    if (platforms == null) return true;
    final p = isWindows
        ? 'windows'
        : isMacOS
            ? 'macos'
            : isLinux
                ? 'linux'
                : 'other';
    return platforms!.contains(p);
  }

  bool get visible => visibleOnThisPlatform && _conditionHolds(condition);

  bool get hasColumns => peerStore != null || screenField != null || session != null;

  /// Options of column `store` (its own "options", else the item's) for `current` value.
  List<SettingsOption> optionsFor(SettingsStore? store, SettingsTarget target, String current) =>
      (store?.options ?? options).resolve(target, current);
}

class SettingsCategory {
  final String id;
  final String label;
  final String icon;
  final String? condition;
  final List<SettingsItem> _items;
  SettingsCategory.fromJson(Map<String, dynamic> j)
      : id = j['id'],
        label = j['label'] ?? j['id'],
        icon = j['icon'] ?? 'settings',
        condition = j['condition'],
        _items = ((j['items'] as List?) ?? [])
            .map((e) => SettingsItem.fromJson(e as Map<String, dynamic>))
            .toList();

  /// Items shown on this PC now (platform and condition evaluated at each call).
  List<SettingsItem> get items => _items.where((e) => e.visible).toList();

  bool get visible => _conditionHolds(condition);

  IconData get iconData => kSettingsIcons[icon] ?? Icons.settings;
  bool get hasColumns => items.any((e) => e.hasColumns);

  /// The category is one whole page (Security, Network, ...): rendered as that page, without the rows' list.
  SettingsItem? get wholePage {
    final i = items;
    return i.length == 1 && i.first.type == 'page' ? i.first : null;
  }
}

const kSettingsIcons = <String, IconData>{
  'settings': Icons.settings,
  'palette': Icons.palette,
  'videocam': Icons.videocam,
  'link': Icons.link,
  'volume_up': Icons.volume_up,
  'keyboard': Icons.keyboard,
  'desktop_windows': Icons.desktop_windows,
  'computer': Icons.computer,
  'swap_horiz': Icons.swap_horiz,
  'security': Icons.enhanced_encryption,
  'person': Icons.person,
  'print': Icons.print,
  'info': Icons.info,
};

const kWindowActionReloadSettingsLayout = 'reload_settings_layout';

class SettingsLayout {
  final List<SettingsCategory> _categories;
  SettingsLayout(this._categories);

  static SettingsLayout _current = SettingsLayout([]);
  static SettingsLayout get current => _current;

  /// Incremented by every `reload()`; pages and toolbars observe it and rebuild.
  static final RxInt revision = 0.obs;

  /// Where the layout came from, for the settings screen's reload row.
  static String source = '';

  /// Categories shown on this PC now.
  List<SettingsCategory> get categories => _categories.where((c) => c.visible).toList();

  static Future<void> reload() async {
    String text = '';
    try {
      text = bind.mainSettingsLayout();
    } catch (_) {}
    source = text.isNotEmpty ? bind.mainSettingsLayoutPath() : 'assets/settings_layout.json';
    settingsExprErrors.clear();
    if (text.isEmpty) {
      text = await rootBundle.loadString('assets/settings_layout.json');
    }
    try {
      final j = jsonDecode(text) as Map<String, dynamic>;
      _current = SettingsLayout(((j['categories'] as List?) ?? [])
          .map((e) => SettingsCategory.fromJson(e as Map<String, dynamic>))
          .toList());
    } catch (e) {
      debugPrint('settings layout: $e');
      source = '$source (invalid JSON: $e)';
    }
    revision.value++;
  }

  /// Re-reads the layout in this window and in every other window of the app (main window included).
  static Future<void> reloadEverywhere() async {
    await reload();
    if (isWeb) return;
    try {
      final ids = await DesktopMultiWindow.getAllSubWindowIds();
      for (final id in ids) {
        if (id == stateGlobal.windowId) continue;
        DesktopMultiWindow.invokeMethod(id, kWindowActionReloadSettingsLayout).catchError((_) => null);
      }
      if (stateGlobal.windowId != kMainWindowId) {
        DesktopMultiWindow.invokeMethod(kMainWindowId, kWindowActionReloadSettingsLayout)
            .catchError((_) => null);
      }
    } catch (e) {
      debugPrint('settings layout broadcast: $e');
    }
  }

  SettingsCategory? category(String id) {
    for (final c in _categories) {
      if (c.id == id) return c;
    }
    return null;
  }
}

/// What a page renders against: the open session (toolbar dropdown) or none (settings screen), the peer and remote
/// screen the per-device / per-screen columns edit.
class SettingsTarget {
  final FFI? ffi;
  String? peerId;
  int? display;
  SettingsTarget({this.ffi, this.peerId, this.display});
  bool get inSession => ffi != null;
}

typedef SettingsWidgetBuilder = Widget? Function(
    String id, BuildContext context, SettingsTarget target);

/// Builders of the "widget" items and of the "session" cells, registered by the settings screen and the remote
/// toolbar. A builder returns null where its widget does not apply (e.g. a session widget outside a session).
final Map<String, SettingsWidgetBuilder> settingsWidgetBuilders = {};

/// Builders of the "page" items: a whole page of the settings screen.
final Map<String, Widget Function()> settingsPageBuilders = {};


/// "after" ids: run after every write of the item, with the written value.
final Map<String, Future<void> Function(String value, SettingsTarget target)> settingsAfterHooks = {};

// ---- stores -------------------------------------------------------------------------------------------------

String _readStore(SettingsStore s, SettingsTarget t) {
  switch (s.kind) {
    case 'server':
      return bind.mainGetOptionSync(key: s.key);
    case 'local':
      return bind.mainGetLocalOption(key: s.key);
    case 'default':
      return bind.mainGetUserDefaultOption(key: s.key);
    case 'peer':
      final ffi = t.ffi;
      if (ffi != null && s.toggle != null) {
        return bind.sessionGetToggleOptionSync(sessionId: ffi.sessionId, arg: s.toggle!) ? 'Y' : 'N';
      }
      if (t.peerId == null || t.peerId!.isEmpty) return '';
      return bind.mainGetPeerSetting(id: t.peerId!, key: s.key);
  }
  return '';
}

/// Side effects of a session toggle, the same as the toolbar's toggle builders run (`toolbarCursor()`,
/// `toolbarDisplayToggle()`, view-only and show-my-cursor in `ShortcutModel`): the session's models follow the stored
/// option.
Future<void> _afterSessionToggle(FFI ffi, String toggle) async {
  final sid = ffi.sessionId;
  final id = ffi.id;
  bool now(String opt) => bind.sessionGetToggleOptionSync(sessionId: sid, arg: opt);
  switch (toggle) {
    case 'show-quality-monitor':
      ffi.qualityMonitorModel.checkShowQualityMonitor(sid);
      return;
    case 'i444':
      bind.sessionChangePreferCodec(sessionId: sid);
      return;
    case 'show-remote-cursor':
      try {
        ShowRemoteCursorState.find(id).value = now('show-remote-cursor');
      } catch (_) {}
      return;
    case 'follow-remote-cursor':
      try {
        final follow = now('follow-remote-cursor');
        ShowRemoteCursorLockState.find(id).value = follow;
        if (follow && !now('show-remote-cursor')) {
          await bind.sessionToggleOption(sessionId: sid, value: 'show-remote-cursor');
          ShowRemoteCursorState.find(id).value = now('show-remote-cursor');
        }
      } catch (_) {}
      return;
    case 'zoom-cursor':
      try {
        PeerBoolOption.find(id, 'zoom-cursor').value = now('zoom-cursor');
      } catch (_) {}
      return;
    case kOptionToggleViewOnly:
      ffi.ffiModel.setViewOnly(id, now(kOptionToggleViewOnly));
      ffi.ffiModel.setShowMyCursor(now(kOptionToggleShowMyCursor));
      return;
    case kOptionToggleShowMyCursor:
      final show = now(kOptionToggleShowMyCursor);
      ffi.ffiModel.setShowMyCursor(show);
      if (show && !ffi.ffiModel.viewOnly) {
        await bind.sessionToggleOption(sessionId: sid, value: kOptionToggleViewOnly);
        ffi.ffiModel.setViewOnly(id, now(kOptionToggleViewOnly));
      }
      return;
  }
}

Future<void> _writeStore(SettingsStore s, SettingsTarget t, String v) async {
  switch (s.kind) {
    case 'server':
      await bind.mainSetOption(key: s.key, value: v);
      return;
    case 'local':
      final ffi = t.ffi;
      if (s.live == 'inputSource' && ffi != null) {
        await stateGlobal.setInputSource(ffi.sessionId, v);
        if (isMacOS) ffi.inputModel.enterOrLeave(false);
        await ffi.ffiModel.checkDesktopKeyboardMode();
        await ffi.inputModel.updateKeyboardMode();
        return;
      }
      await bind.mainSetLocalOption(key: s.key, value: v);
      return;
    case 'default':
      await bind.mainSetUserDefaultOption(key: s.key, value: v);
      return;
    case 'peer':
      final ffi = t.ffi;
      if (ffi != null) {
        final sid = ffi.sessionId;
        if (s.toggle != null) {
          final cur = bind.sessionGetToggleOptionSync(sessionId: sid, arg: s.toggle!);
          if (cur != (v == 'Y')) {
            await bind.sessionToggleOption(sessionId: sid, value: s.toggle!);
            await _afterSessionToggle(ffi, s.toggle!);
          }
          return;
        }
        switch (s.live) {
          case 'viewStyle':
            await setSessionViewStyle(sid, v);
            await ffi.canvasModel.updateViewStyle();
            return;
          case 'imageQuality':
            await bind.sessionSetImageQuality(sessionId: sid, value: v);
            return;
          case 'scrollStyle':
            await bind.sessionSetScrollStyle(sessionId: sid, value: v);
            await ffi.canvasModel.updateScrollStyle();
            return;
          case 'keyboardMode':
            await bind.sessionSetKeyboardMode(sessionId: sid, value: v);
            await ffi.inputModel.updateKeyboardMode();
            return;
          case 'edgeThickness':
            final n = int.tryParse(v);
            if (n == null) return;
            await bind.sessionSetEdgeScrollEdgeThickness(sessionId: sid, value: n);
            ffi.canvasModel.updateEdgeScrollEdgeThickness(n);
            return;
          case 'reverseWheel':
            await bind.sessionSetReverseMouseWheel(sessionId: sid, value: v);
            return;
          case 'codec':
            await bind.sessionPeerOption(sessionId: sid, name: s.key, value: v);
            bind.sessionChangePreferCodec(sessionId: sid);
            return;
          case 'peerOption':
            await bind.sessionPeerOption(sessionId: sid, name: s.key, value: v);
            return;
        }
      }
      if (t.peerId == null || t.peerId!.isEmpty) return;
      bind.mainSetPeerSetting(id: t.peerId!, key: s.key, value: v);
      return;
  }
}

bool _asBool(SettingsStore s, String v) {
  final b = s.kind == 'server' || s.kind == 'local' ? option2bool(s.key, v) : v == 'Y';
  return s.invert ? !b : b;
}

String _fromBool(SettingsStore s, bool b) {
  final on = s.invert ? !b : b;
  if (s.kind == 'server' || s.kind == 'local') return bool2option(s.key, on);
  return on ? 'Y' : 'N';
}

// ---- per remote screen state (`display_windows`) ---------------------------------------------------------------

Map<String, dynamic> _screens(String peerId) {
  try {
    final raw = bind.mainGetPeerFlutterOptionSync(id: peerId, k: kPeerOptionDisplayWindowsKey);
    return raw.isEmpty ? {} : jsonDecode(raw) as Map<String, dynamic>;
  } catch (_) {
    return {};
  }
}

String _readScreen(SettingsTarget t, String field) {
  if (t.peerId == null || t.display == null) return '';
  final m = _screens(t.peerId!)['${t.display}'];
  return m is Map && m[field] != null ? '${m[field]}' : '';
}

Future<void> _writeScreen(SettingsTarget t, String field, String v) async {
  if (t.peerId == null || t.display == null) return;
  final all = _screens(t.peerId!);
  final m = Map<String, dynamic>.from((all['${t.display}'] as Map?) ?? {});
  m[field] = field == 'customScalePercent' ? int.tryParse(v) : v;
  all['${t.display}'] = m;
  bind.mainSetPeerFlutterOptionSync(
      id: t.peerId!, k: kPeerOptionDisplayWindowsKey, v: jsonEncode(all));
  final ffi = t.ffi;
  if (ffi != null && field == 'viewStyle' && ffi.ffiModel.pi.currentDisplay == t.display) {
    await setSessionViewStyle(ffi.sessionId, v);
    await ffi.canvasModel.updateViewStyle();
  }
}

// ---- rendering ----------------------------------------------------------------------------------------------

/// The setting column keeps at least this width; a narrower page scrolls the table sideways.
const double _kSettingColumnMinWidth = 240;

/// The settings screen's "Reload settings layout" row: the file in use and the button that re-reads it everywhere.
class SettingsLayoutReloadRow extends StatelessWidget {
  const SettingsLayoutReloadRow({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      SettingsLayout.revision.value;
      settingsExprErrorRevision.value;
      final errors = settingsExprErrors.entries.map((e) => '${e.key}\n  → ${e.value}').join('\n\n');
      return Row(children: [
        Expanded(
          child: Tooltip(
            message: '${translate('settings-layout-tip')}\n${bind.mainSettingsLayoutPath()}',
            child: Text(SettingsLayout.source,
                overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.bodySmall),
          ),
        ),
        if (settingsExprErrors.isNotEmpty)
          Tooltip(
            message: errors,
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.error_outline, size: 16, color: Colors.red),
              const SizedBox(width: 4),
              Text('${settingsExprErrors.length} ${translate('expression errors')}',
                  style: const TextStyle(color: Colors.red)),
            ]),
          ),
        IconButton(
          tooltip: translate('Reload settings layout'),
          icon: const Icon(Icons.refresh),
          onPressed: () => SettingsLayout.reloadEverywhere(),
        ),
      ]);
    });
  }
}

/// A category page: its items in order; rows with several scopes get the columns Default | Saved session-specific
/// (floppy) | Saved per screen, headed by the peer and screen selectors. A category of one "page" item is that page.
class SettingsCategoryPage extends StatefulWidget {
  final String categoryId;
  final FFI? ffi;
  const SettingsCategoryPage({Key? key, required this.categoryId, this.ffi}) : super(key: key);

  @override
  State<SettingsCategoryPage> createState() => _SettingsCategoryPageState();
}

class _SettingsCategoryPageState extends State<SettingsCategoryPage> {
  late SettingsTarget target;
  List<Map<String, dynamic>> peers = [];

  @override
  void initState() {
    super.initState();
    final ffi = widget.ffi;
    target = SettingsTarget(
        ffi: ffi,
        peerId: ffi?.id,
        // In a toolbar dropdown: this window's session and the remote screen it shows (none while it shows all).
        display: ffi == null || ffi.ffiModel.pi.currentDisplay == kAllDisplayValue
            ? null
            : ffi.ffiModel.pi.currentDisplay);
    if (ffi == null) {
      try {
        peers = (jsonDecode(bind.mainListPeers()) as List).cast<Map<String, dynamic>>();
      } catch (_) {}
      if (peers.isNotEmpty) target.peerId = peers.first['id'];
      final screens = target.peerId == null ? <String>[] : (_screens(target.peerId!).keys.toList()..sort());
      if (screens.isNotEmpty) target.display = int.tryParse(screens.first);
    }
  }

  void refresh() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      SettingsLayout.revision.value;
      final cat = SettingsLayout.current.category(widget.categoryId);
      if (cat == null) return Center(child: Text(translate('Not found')));
      final page = cat.wholePage;
      if (page != null) {
        final b = settingsPageBuilders[page.page];
        return b == null ? const SizedBox.shrink() : b();
      }
      final items = cat.items;
      final table = items.any((e) => e.hasColumns);
      final screenColumn = items.any((e) => e.screenField != null);
      _widths = table ? _measureColumns(context, items, screenColumn) : const [0, 0, 0, 0];
      final rows = items.map((i) => _row(context, i, table, screenColumn)).toList();
      // The column header stays on top; only the rows scroll under it.
      Widget body(double? width) => SizedBox(
            width: width,
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              if (table) _columnsHeader(context, screenColumn),
              Expanded(child: ListView(children: rows)),
            ]),
          );
      return Padding(
        padding: const EdgeInsets.all(12),
        child: LayoutBuilder(builder: (context, constraints) {
          // A table wider than the page scrolls sideways; the value columns are never narrowed.
          final needed = _kSettingColumnMinWidth + _widths[1] + _widths[2] + (screenColumn ? _widths[3] : 0);
          if (!table || constraints.maxWidth >= needed) return body(null);
          return SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SizedBox(height: constraints.maxHeight, child: body(needed)));
        }),
      );
    });
  }

  String _peerLabel(Map<String, dynamic> p) {
    final alias = (p['alias'] ?? '') as String;
    final host = (p['hostname'] ?? '') as String;
    return [p['id'], if (alias.isNotEmpty) alias else if (host.isNotEmpty) host].join(' — ');
  }

  // ---- table cells: column 0 = setting, 1 = Default, 2 = Saved session-specific, 3 = Saved per screen ----

  /// Widths of columns 1–3 for the category being rendered (`_measureColumns()`); column 0 takes the rest.
  List<double> _widths = const [0, 0, 0, 0];

  double _textWidth(BuildContext context, String text, {TextStyle? style}) {
    final tp = TextPainter(
      text: TextSpan(text: text, style: style ?? Theme.of(context).textTheme.titleMedium),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    return tp.width;
  }

  /// Width of a dropdown of item `i` showing every option of column `s` in full: the longest option + the arrow.
  double _radioWidth(BuildContext context, SettingsItem i, SettingsStore? s, String value) =>
      i.optionsFor(s, target, value).map((o) => _textWidth(context, translate(o.label))).fold<double>(
          _textWidth(context, value.isEmpty ? '—' : value), (a, b) => a > b ? a : b) +
      36;

  /// Width of each value column = its widest content: the longest option of every dropdown in it (a dropdown is
  /// `isExpanded` in its cell, so the column width is the dropdown width), the header text and selectors, and a floor
  /// for checkboxes, number fields and session widgets. 2 px padding on each side of a cell and the 1 px line are
  /// included.
  List<double> _measureColumns(BuildContext context, List<SettingsItem> items, bool screenColumn) {
    const dropdownChrome = 24.0 + 12.0; // arrow icon + its gap
    const cellChrome = 4.0 + 1.0; // 2 px padding each side + the column line
    final bold = (Theme.of(context).textTheme.titleMedium ?? const TextStyle())
        .copyWith(fontWeight: FontWeight.bold);
    final w = <double>[0, 90, 90, 90];
    void fit(int col, double width) {
      if (width + cellChrome > w[col]) w[col] = width + cellChrome;
    }

    double radioWidth(SettingsItem i, SettingsStore? s, String value) => _radioWidth(context, i, s, value);

    double valueWidth(SettingsItem i, SettingsStore s) {
      switch (i.type) {
        case 'radio':
          return radioWidth(i, s, _readStore(s, target));
        case 'number':
          return 90;
        default:
          return 48;
      }
    }

    for (final i in items) {
      if (i.defaultStore != null) fit(1, valueWidth(i, i.defaultStore!));
      if (target.inSession && i.session != null) {
        fit(2, 200);
      } else if (i.peerStore != null) {
        fit(2, valueWidth(i, i.peerStore!));
      }
      if (i.screenField != null) {
        fit(3, i.screenField == 'customScalePercent' ? 90 : radioWidth(i, null, _readScreen(target, i.screenField!)));
      }
    }
    fit(1, _textWidth(context, translate('Default'), style: bold));
    fit(2, _textWidth(context, translate('Saved session-specific'), style: bold) + 18);
    final peerTexts = target.inSession ? [target.peerId ?? ''] : peers.map(_peerLabel);
    for (final t in peerTexts) {
      fit(2, _textWidth(context, t) + (target.inSession ? 0 : dropdownChrome));
    }
    if (screenColumn) {
      fit(3, _textWidth(context, translate('Saved per screen'), style: bold));
      fit(3, _textWidth(context, '${translate('Screen')} 99') + dropdownChrome);
    }
    return w;
  }

  Color get _borderColor => Theme.of(context).dividerColor;

  /// Background of column `col`: the page color, the two right-hand columns 2 % and 4 % lighter.
  Color _columnColor(int col) {
    final base = Theme.of(context).scaffoldBackgroundColor;
    if (col < 2) return base;
    return Color.lerp(base, Colors.white, col == 2 ? 0.02 : 0.04)!;
  }

  Widget _tableCell(int col, Widget child, {bool header = false}) {
    final box = Container(
      width: col == 0 ? null : _widths[col],
      alignment: header ? Alignment.bottomLeft : Alignment.centerLeft,
      padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
      decoration: BoxDecoration(
        color: _columnColor(col),
        border: col == 0 ? null : Border(left: BorderSide(color: _borderColor, width: 1)),
      ),
      child: child,
    );
    return col == 0 ? Expanded(child: box) : box;
  }

  /// A table row: the cells side by side, as tall as the tallest, with a thin line under it.
  Widget _tableRow(List<Widget> cells, {double bottomBorder = 1}) {
    return Container(
      decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: _borderColor, width: bottomBorder))),
      child: IntrinsicHeight(
          child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: cells)),
    );
  }

  Widget _columnsHeader(BuildContext context, bool screenColumn) {
    final screens = target.peerId == null ? <String>[] : (_screens(target.peerId!).keys.toList()..sort());
    // This window's screen is listed before its window state is first stored.
    if (target.display != null && !screens.contains('${target.display}')) {
      screens
        ..add('${target.display}')
        ..sort();
    }
    final peerSelector = target.inSession
        ? Text(target.peerId ?? '', overflow: TextOverflow.ellipsis)
        : DropdownButton<String>(
            isExpanded: true,
            value: peers.any((p) => p['id'] == target.peerId) ? target.peerId : null,
            items: peers
                .map((p) => DropdownMenuItem<String>(
                    value: p['id'], child: Text(_peerLabel(p), overflow: TextOverflow.ellipsis)))
                .toList(),
            onChanged: (v) => setState(() {
                  target.peerId = v;
                  final s = v == null ? <String>[] : (_screens(v).keys.toList()..sort());
                  target.display = s.isEmpty ? null : int.tryParse(s.first);
                }));
    final screenSelector = DropdownButton<int>(
        isExpanded: true,
        value: screens.contains('${target.display}') ? target.display : null,
        items: screens
            .map((s) => DropdownMenuItem<int>(
                value: int.parse(s), child: Text('${translate('Screen')} ${int.parse(s) + 1}')))
            .toList(),
        onChanged: (v) => setState(() => target.display = v));
    const bold = TextStyle(fontWeight: FontWeight.bold);
    return _tableRow([
      _tableCell(0, Text(translate('Setting'), style: bold), header: true),
      _tableCell(1, Text(translate('Default'), style: bold), header: true),
      _tableCell(
          2,
          Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Flexible(child: Text(translate('Saved session-specific'), style: bold)),
              const SizedBox(width: 4),
              const Icon(Icons.save_outlined, size: 14),
            ]),
            peerSelector,
          ]),
          header: true),
      if (screenColumn)
        _tableCell(
            3,
            Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(translate('Saved per screen'), style: bold),
              screenSelector,
            ]),
            header: true),
    ], bottomBorder: 2);
  }

  Widget _label(SettingsItem i, {TextStyle? style}) {
    final text = Text(translate(i.label), style: style);
    if (i.tooltip == null || i.tooltip!.isEmpty) return text;
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Flexible(child: text),
      const SizedBox(width: 4),
      Tooltip(
        message: translate(i.tooltip!),
        child: const Icon(Icons.help_outline, size: 15),
      ),
    ]);
  }

  /// One item. In a category with columns (`table`) every row is a table row: a setting's value cells sit in their
  /// columns; a section, note or widget spans the row.
  Widget _row(BuildContext context, SettingsItem i, bool table, bool screenColumn) {
    Widget spanning(Widget child, {EdgeInsets padding = const EdgeInsets.symmetric(vertical: 4)}) {
      final inner = Padding(padding: padding.add(const EdgeInsets.symmetric(horizontal: 2)), child: child);
      if (!table) return inner;
      // One cell across the row, without `IntrinsicHeight`: an embedded page section may hold a `LayoutBuilder`,
      // which does not report intrinsic dimensions.
      return Container(
        decoration: BoxDecoration(
          color: _columnColor(0),
          border: Border(bottom: BorderSide(color: _borderColor, width: 1)),
        ),
        child: inner,
      );
    }

    switch (i.type) {
      case 'section':
        return spanning(_label(i, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
            padding: const EdgeInsets.only(top: 14, bottom: 6));
      case 'note':
        return spanning(_label(i));
      case 'page':
        final b = settingsPageBuilders[i.page];
        if (b == null) return const SizedBox.shrink();
        final height = (MediaQuery.of(context).size.height * 0.7).clamp(240.0, 900.0);
        return SizedBox(height: height, child: b());
      case 'widget':
        final b = settingsWidgetBuilders[i.widget];
        final w = b == null ? null : b(i.widget!, context, target);
        if (w == null) return const SizedBox.shrink();
        if (i.label.isEmpty) return spanning(w);
        return spanning(Row(children: [Expanded(child: _label(i)), Flexible(child: w)]));
    }
    final sessionCell = (target.inSession && i.session != null) ? _sessionCell(context, i) : null;
    final peerCell = sessionCell ?? (i.peerStore != null ? _cell(i, i.peerStore!) : null);
    final defaultCell = i.defaultStore != null ? _cell(i, i.defaultStore!) : null;
    final screenCell = i.screenField != null ? _screenCell(i) : null;
    if (!table) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 3, horizontal: 2),
        child: Row(children: [
          Expanded(child: _label(i)),
          if (defaultCell != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: SizedBox(
                  width: i.type == 'bool'
                      ? null
                      : i.type == 'radio'
                          ? _radioWidth(context, i, i.defaultStore, _readStore(i.defaultStore!, target))
                          : 90,
                  child: defaultCell),
            ),
        ]),
      );
    }
    return _tableRow([
      _tableCell(0, _label(i)),
      _tableCell(1, defaultCell ?? const SizedBox()),
      _tableCell(2, peerCell ?? const SizedBox()),
      if (screenColumn) _tableCell(3, screenCell ?? const SizedBox()),
    ]);
  }

  Widget? _sessionCell(BuildContext context, SettingsItem i) {
    final b = settingsWidgetBuilders[i.session];
    return b == null ? null : b(i.session!, context, target);
  }

  bool _editable(SettingsItem i, SettingsStore s) {
    if (s.kind == 'peer' && !target.inSession && target.peerId == null) return false;
    final dep = i.enabledBy;
    if (dep != null && !_asBool(dep, _readStore(dep, target))) return false;
    if (s.kind == 'default' && isOptionFixed(s.key)) return false;
    return true;
  }

  Future<void> _write(SettingsItem i, SettingsStore s, String v) async {
    await _writeStore(s, target, v);
    if (i.type == 'bool' && !_asBool(s, v)) {
      for (final c in i.offClears) {
        await _writeStore(c, target, _fromBool(c, false));
      }
    }
    final hook = i.after == null ? null : settingsAfterHooks[i.after!];
    if (hook != null) await hook(v, target);
    refresh();
  }

  Widget _cell(SettingsItem i, SettingsStore s) {
    final editable = _editable(i, s);
    final value = _readStore(s, target);
    switch (i.type) {
      case 'bool':
        return Align(
          alignment: Alignment.centerLeft,
          child: Checkbox(
            value: _asBool(s, value),
            onChanged: editable ? (b) => _write(i, s, _fromBool(s, b == true)) : null,
          ),
        );
      case 'radio':
        final options = i.optionsFor(s, target, value);
        return DropdownButton<String>(
          isExpanded: true,
          value: options.any((o) => o.value == value) ? value : null,
          hint: Text(value.isEmpty ? '—' : value),
          items: options
              .map((o) => DropdownMenuItem<String>(
                  value: o.value,
                  child: o.tooltip == null
                      ? Text(translate(o.label), overflow: TextOverflow.ellipsis)
                      : Tooltip(
                          message: translate(o.tooltip!),
                          child: Text(translate(o.label), overflow: TextOverflow.ellipsis))))
              .toList(),
          onChanged: editable
              ? (v) {
                  if (v != null) _write(i, s, v);
                }
              : null,
        );
      case 'number':
        final c = TextEditingController(text: value);
        return TextField(
          controller: c,
          enabled: editable,
          keyboardType: TextInputType.number,
          onSubmitted: (v) => _write(i, s, v.trim()),
        );
    }
    return const SizedBox();
  }

  Widget _screenCell(SettingsItem i) {
    final field = i.screenField!;
    final value = _readScreen(target, field);
    final enabled = target.peerId != null && target.display != null;
    if (field == 'customScalePercent') {
      final c = TextEditingController(text: value);
      return TextField(
        controller: c,
        enabled: enabled,
        keyboardType: TextInputType.number,
        decoration: const InputDecoration(suffixText: '%'),
        onSubmitted: (v) async {
          await _writeScreen(target, field, v.trim());
          refresh();
        },
      );
    }
    final options = i.optionsFor(null, target, value);
    return DropdownButton<String>(
      isExpanded: true,
      value: options.any((o) => o.value == value) ? value : null,
      hint: Text(value.isEmpty ? '—' : value),
      items: options
          .map((o) => DropdownMenuItem<String>(value: o.value, child: Text(translate(o.label))))
          .toList(),
      onChanged: !enabled
          ? null
          : (v) async {
              if (v == null) return;
              await _writeScreen(target, field, v);
              refresh();
            },
    );
  }
}
