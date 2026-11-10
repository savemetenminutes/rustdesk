// Per-peer audio device selection (Rust: `src/client/audio_devices.rs`).
//
// Output: "Windows default" follows the current Windows default output device; a named device that is not present
// plays on the Windows default until it is present again.
// Input: the remote PC's capture device for this connection; "Remote PC's own setting" leaves it to the remote PC.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/models/model.dart';
import 'package:flutter_hbb/models/platform_model.dart';

const String kOptionAudioOutputDevice = 'audio-output-device';
const String kOptionAudioInputDevice = 'audio-input-device';

/// Prefix of a peer `kOptionAudioInputDevice` value that selects a device; the prefix alone is System Sound / the
/// default input device of the remote PC.
const String kAudioInputOverridePrefix = '=';

class _RemoteInputs {
  final List<String> devices;
  final String ownSetting;
  final bool systemSound;
  _RemoteInputs(this.devices, this.ownSetting, this.systemSound);
}

Future<_RemoteInputs?> _fetchRemoteInputs(FFI ffi) async {
  bind.sessionRequestRemoteAudioInputs(sessionId: ffi.sessionId);
  for (var i = 0; i < 30; i++) {
    await Future.delayed(const Duration(milliseconds: 100));
    final raw = bind.sessionGetRemoteAudioInputs(sessionId: ffi.sessionId);
    if (raw.isNotEmpty) {
      try {
        final m = jsonDecode(raw);
        return _RemoteInputs((m['devices'] as List).cast<String>(),
            m['own_setting'] as String, m['system_sound'] == true);
      } catch (e) {
        debugPrint('Failed to parse remote audio inputs "$raw": $e');
        return null;
      }
    }
  }
  return null;
}

void audioDevicesDialog(FFI ffi) async {
  final sessionId = ffi.sessionId;
  var output = await bind.sessionGetPeerOption(
      sessionId: sessionId, name: kOptionAudioOutputDevice);
  var input = await bind.sessionGetPeerOption(
      sessionId: sessionId, name: kOptionAudioInputDevice);
  List<String> outputs = [];
  try {
    outputs = (jsonDecode(bind.mainGetAudioOutputDevices()) as List)
        .cast<String>();
  } catch (e) {
    debugPrint('Failed to parse output devices: $e');
  }
  _RemoteInputs? remote;
  var fetchStarted = false;
  var fetchDone = false;
  var closed = false;

  ffi.dialogManager.show((setState, close, context) {
    if (!fetchStarted) {
      fetchStarted = true;
      _fetchRemoteInputs(ffi).then((r) {
        if (!closed) {
          try {
            setState(() {
              remote = r;
              fetchDone = true;
            });
          } catch (e) {
            // The dialog was dismissed by `dialogManager`.
          }
        }
      });
    }

    void setOutput(String v) {
      bind.sessionSetAudioOutputDevice(sessionId: sessionId, device: v);
      setState(() => output = v);
    }

    void setInput(String v) {
      bind.sessionSetRemoteAudioInput(sessionId: sessionId, value: v);
      setState(() => input = v);
    }

    Widget radio(String label, String value, String group,
            void Function(String) onChanged) =>
        RadioListTile<String>(
          dense: true,
          title: Text(label),
          value: value,
          groupValue: group,
          onChanged: (v) => onChanged(v ?? ''),
        );

    final outputItems = <Widget>[
      radio('Windows default (follows changes)', '', output, setOutput),
      ...outputs.map((d) => radio(d, d, output, setOutput)),
      if (output.isNotEmpty && !outputs.contains(output))
        radio('$output (not present, Windows default is used)', output,
            output, setOutput),
    ];

    final List<Widget> inputItems;
    final r = remote;
    if (r == null) {
      inputItems = [
        ListTile(
          dense: true,
          title: Text(fetchDone
              ? 'The remote PC did not list its devices (it needs this build)'
              : "Loading the remote PC's devices..."),
        ),
        radio("Remote PC's own setting", '', input, setInput),
      ];
    } else {
      final defaultLabel =
          r.systemSound ? 'System Sound' : 'Default input device';
      final ownLabel = r.ownSetting.isEmpty ? defaultLabel : r.ownSetting;
      final selected = input.startsWith(kAudioInputOverridePrefix)
          ? input.substring(kAudioInputOverridePrefix.length)
          : null;
      inputItems = [
        radio("Remote PC's own setting ($ownLabel)", '', input, setInput),
        radio(defaultLabel, kAudioInputOverridePrefix, input, setInput),
        ...r.devices.map((d) =>
            radio(d, '$kAudioInputOverridePrefix$d', input, setInput)),
        if (selected != null &&
            selected.isNotEmpty &&
            !r.devices.contains(selected))
          radio('$selected (not present, default input device is used)',
              input, input, setInput),
      ];
    }

    void onClose() {
      closed = true;
      close();
    }

    return CustomAlertDialog(
      title: Text('Audio devices'),
      content: SizedBox(
        width: 460,
        height: 480,
        child: ListView(
          children: [
            Text('Output on this PC',
                style: TextStyle(fontWeight: FontWeight.bold)),
            ...outputItems,
            const Divider(),
            Text('Input on the remote PC',
                style: TextStyle(fontWeight: FontWeight.bold)),
            ...inputItems,
          ],
        ),
      ),
      actions: [
        dialogButton('Close',
            icon: const Icon(Icons.close_rounded), onPressed: onClose),
      ],
      onCancel: onClose,
      onSubmit: onClose,
    );
  });
}
