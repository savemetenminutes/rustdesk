// Settings layout: the settings screen's categories and the remote toolbar's settings dropdowns are rendered from
// one JSON document, `settings_layout.json` (bundled in `assets/`, overridden by the file of that name in the config
// directory, `main_settings_layout()`). `SettingsLayout.reload()` re-reads it in this isolate;
// `SettingsLayout.reloadEverywhere()` makes every window do so (`kWindowActionReloadSettingsLayout`).
//
// Document: {"categories": [{"id", "label", "icon", "condition", "items": [item]}]}
// item: {"type": "section" | "bool" | "radio" | "number" | "widget" | "page" | "note",
//        "label", "tooltip", "platforms": ["windows" | "macos" | "linux"],
//        "condition": "<id>",                                 (shown only while `settingsConditions[id]()` is true)
//        "options": [{"value", "label", "tooltip"}],          (radio)
//        "optionsFrom": "<id>",                               (radio: `settingsOptionSources[id]()` replaces options)
//        "widget": "<id>",                                    (widget: `settingsWidgetBuilders[id]`)
//        "page": "<id>",                                      (page: `settingsPageBuilders[id]`, a whole page)
//        "default": store, "peer": store, "screen": {"field"}, (columns; a bool/radio/number needs at least one)
//        "session": "<id>",                                   (in a session the peer column is this widget)
//        "after": "<id>",                                     (`settingsAfterHooks[id]` runs after every write)
//        "enabledBy": store,                                  (editable only while that bool store is true)
//        "offClears": [store]}                                (turning this bool off also turns these off)
// store: {"kind": "server" | "local" | "default" | "peer", "key", "invert": bool, "live": "<id>", "toggle": "<name>",
//         "optionsFrom": "<id>"}                              (radio options of this column only)
//   server  = `Config` option (this PC's service), local = `LocalConfig` option (this PC's client),
//   default = the default of every new session (`UserDefaultConfig`), peer = stored per device (`PeerConfig`).
//   A peer store edits the open session through its own setter (`toggle` = session toggle option name, `live` = a
//   named session setter), otherwise the peer file (`main_set_peer_setting`).
// screen: {"field": "viewStyle" | "customScalePercent"} — the fork's per remote screen window state
//   (`display_windows`, keyed by the remote display index).

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

class SettingsStore {
  final String kind;
  final String key;
  final bool invert;
  final String? live;
  final String? toggle;
  final String? optionsFrom;
  SettingsStore(this.kind, this.key, {this.invert = false, this.live, this.toggle, this.optionsFrom});

  static SettingsStore? fromJson(dynamic j) => j is Map
      ? SettingsStore(j['kind'] ?? 'local', j['key'] ?? '',
          invert: j['invert'] == true, live: j['live'], toggle: j['toggle'], optionsFrom: j['optionsFrom'])
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
  final String? optionsFrom;
  final String? after;
  final List<String>? platforms;
  final List<SettingsOption> options;
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
        optionsFrom = j['optionsFrom'],
        after = j['after'],
        platforms = (j['platforms'] as List?)?.cast<String>(),
        options = ((j['options'] as List?) ?? [])
            .map((o) => SettingsOption('${o['value']}', o['label'] ?? '', o['tooltip']))
            .toList(),
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

  bool get visible {
    if (!visibleOnThisPlatform) return false;
    final c = condition;
    if (c == null) return true;
    final f = settingsConditions[c];
    return f == null ? true : f();
  }

  bool get hasColumns => peerStore != null || screenField != null || session != null;

  /// Options of column `store` (its own "optionsFrom", else the item's, else "options") for `current` value.
  List<SettingsOption> optionsFor(SettingsStore? store, SettingsTarget target, String current) {
    final id = store?.optionsFrom ?? optionsFrom;
    final src = id == null ? null : settingsOptionSources[id];
    return src == null ? options : src(target, current);
  }
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

  bool get visible {
    final c = condition;
    if (c == null) return true;
    final f = settingsConditions[c];
    return f == null ? true : f();
  }

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

/// "condition" ids: an item or category is shown only while its condition is true.
final Map<String, bool Function()> settingsConditions = {};

/// "optionsFrom" ids: options of a radio computed at render time (e.g. the audio devices present), for the column's
/// target and current value.
final Map<String, List<SettingsOption> Function(SettingsTarget target, String current)> settingsOptionSources = {};

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

const double _kColumnWidth = 170;

/// The settings screen's "Reload settings layout" row: the file in use and the button that re-reads it everywhere.
class SettingsLayoutReloadRow extends StatelessWidget {
  const SettingsLayoutReloadRow({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      SettingsLayout.revision.value;
      return Row(children: [
        Expanded(
          child: Tooltip(
            message: '${translate('settings-layout-tip')}\n${bind.mainSettingsLayoutPath()}',
            child: Text(SettingsLayout.source,
                overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.bodySmall),
          ),
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
      final rows = <Widget>[
        if (items.any((e) => e.hasColumns)) _columnsHeader(context, items),
        ...items.map((i) => _row(context, i)),
      ];
      return ListView(padding: const EdgeInsets.all(12), children: rows);
    });
  }

  String _peerLabel(Map<String, dynamic> p) {
    final alias = (p['alias'] ?? '') as String;
    final host = (p['hostname'] ?? '') as String;
    return [p['id'], if (alias.isNotEmpty) alias else if (host.isNotEmpty) host].join(' — ');
  }

  Widget _columnsHeader(BuildContext context, List<SettingsItem> items) {
    final hasScreen = items.any((e) => e.screenField != null);
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
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
        const Expanded(child: SizedBox()),
        SizedBox(
            width: _kColumnWidth,
            child: Text(translate('Default'), style: const TextStyle(fontWeight: FontWeight.bold))),
        SizedBox(
            width: _kColumnWidth,
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Flexible(
                    child: Text(translate('Saved session-specific'),
                        style: const TextStyle(fontWeight: FontWeight.bold))),
                const SizedBox(width: 4),
                const Icon(Icons.save_outlined, size: 14),
              ]),
              peerSelector,
            ])),
        if (hasScreen)
          SizedBox(
              width: _kColumnWidth,
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(translate('Saved per screen'), style: const TextStyle(fontWeight: FontWeight.bold)),
                screenSelector,
              ])),
      ]),
    );
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

  Widget _row(BuildContext context, SettingsItem i) {
    switch (i.type) {
      case 'section':
        return Padding(
          padding: const EdgeInsets.only(top: 14, bottom: 6),
          child: _label(i, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
        );
      case 'note':
        return Padding(padding: const EdgeInsets.symmetric(vertical: 4), child: _label(i));
      case 'page':
        final b = settingsPageBuilders[i.page];
        if (b == null) return const SizedBox.shrink();
        final height = (MediaQuery.of(context).size.height * 0.7).clamp(240.0, 900.0);
        return SizedBox(height: height, child: b());
      case 'widget':
        final b = settingsWidgetBuilders[i.widget];
        final w = b == null ? null : b(i.widget!, context, target);
        if (w == null) return const SizedBox.shrink();
        if (i.label.isEmpty) {
          return Padding(padding: const EdgeInsets.symmetric(vertical: 4), child: w);
        }
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(children: [Expanded(child: _label(i)), Flexible(child: w)]),
        );
    }
    final sessionCell = (target.inSession && i.session != null) ? _sessionCell(context, i) : null;
    final peerCell = sessionCell ?? (i.peerStore != null ? _cell(i, i.peerStore!) : null);
    final defaultCell = i.defaultStore != null ? _cell(i, i.defaultStore!) : null;
    final screenCell = i.screenField != null ? _screenCell(i) : null;
    if (!i.hasColumns) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(children: [
          Expanded(child: _label(i)),
          if (defaultCell != null) SizedBox(width: i.type == 'bool' ? null : _kColumnWidth, child: defaultCell),
        ]),
      );
    }
    final anyScreen = SettingsLayout.current
            .category(widget.categoryId)
            ?.items
            .any((e) => e.screenField != null) ??
        false;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
        Expanded(child: _label(i)),
        SizedBox(width: _kColumnWidth, child: defaultCell ?? const SizedBox()),
        SizedBox(width: _kColumnWidth, child: peerCell ?? const SizedBox()),
        if (anyScreen) SizedBox(width: _kColumnWidth, child: screenCell ?? const SizedBox()),
      ]),
    );
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
