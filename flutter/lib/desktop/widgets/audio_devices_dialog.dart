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

/// Session toggle option behind "Mute" (`toolbarDisplayToggle()`).
const String kOptionToggleDisableAudio = 'disable-audio';

/// Peer option with the saved mute state (Rust `audio_devices::OPTION_AUDIO_MUTE_SAVED`): "Y" / "N"; "" starts muted.
const String kOptionAudioMuteSaved = 'audio-mute-saved';

/// Peer option: this PC's input device streamed into the remote PC's virtual microphone (Rust
/// `audio_devices::OPTION_AUDIO_HOST_INPUT_DEVICE`); "" = the remote PC records from its own input as configured there.
const String kOptionAudioHostInputDevice = 'audio-host-input-device';

class _RemoteInputs {
  final List<String> devices;
  final String ownSetting;
  final bool systemSound;
  // Recording device name of the remote PC's virtual microphone; "" when none is installed.
  final String virtualMicrophone;
  _RemoteInputs(
      this.devices, this.ownSetting, this.systemSound, this.virtualMicrophone);
}

Future<_RemoteInputs?> _fetchRemoteInputs(FFI ffi) async {
  bind.sessionRequestRemoteAudioInputs(sessionId: ffi.sessionId);
  for (var i = 0; i < 30; i++) {
    await Future.delayed(const Duration(milliseconds: 100));
    final raw = bind.sessionGetRemoteAudioInputs(sessionId: ffi.sessionId);
    if (raw.isNotEmpty) {
      try {
        final m = jsonDecode(raw);
        return _RemoteInputs(
            (m['devices'] as List).cast<String>(),
            m['own_setting'] as String,
            m['system_sound'] == true,
            (m['virtual_microphone'] ?? '') as String);
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
  var hostInput = await bind.sessionGetPeerOption(
      sessionId: sessionId, name: kOptionAudioHostInputDevice);
  List<String> hostInputs = [];
  try {
    hostInputs = (jsonDecode(bind.mainGetAudioInputDevices()) as List)
        .cast<String>();
  } catch (e) {
    debugPrint('Failed to parse input devices: $e');
  }
  // Stored volumes (percent) per device and the output device that plays (Rust `audio_volume`).
  Map<String, dynamic> volumes = {};
  void loadVolumes() {
    try {
      volumes = jsonDecode(bind.sessionGetAudioVolumes(sessionId: sessionId))
          as Map<String, dynamic>;
    } catch (e) {
      volumes = {};
    }
  }

  loadVolumes();
  // Microphone Boost (dB) of `hostInput`: {"min", "max", "step", "current"}, or null when the device has none.
  Map<String, dynamic>? boostOf(String device) {
    if (device.isEmpty) return null;
    try {
      final raw = bind.mainGetMicrophoneBoost(device: device);
      return raw.isEmpty ? null : jsonDecode(raw) as Map<String, dynamic>;
    } catch (e) {
      return null;
    }
  }

  var boost = boostOf(hostInput);
  var muted = bind.sessionGetToggleOptionSync(
      sessionId: sessionId, arg: kOptionToggleDisableAudio);
  var muteSaved = await bind.sessionGetPeerOption(
      sessionId: sessionId, name: kOptionAudioMuteSaved);
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

    // Mutes or unmutes the running session (`disable-audio` toggle); the saved state changes only through Save/Clear.
    Future<void> setMuted(bool v) async {
      if (v != muted) {
        await bind.sessionToggleOption(
            sessionId: sessionId, value: kOptionToggleDisableAudio);
      }
      setState(() => muted = bind.sessionGetToggleOptionSync(
          sessionId: sessionId, arg: kOptionToggleDisableAudio));
    }

    void setHostInput(String v) {
      bind.sessionSetHostMicrophone(sessionId: sessionId, device: v);
      setState(() {
        hostInput = v;
        boost = boostOf(v);
      });
    }

    int volumeOf(String kind, String device) {
      final m = volumes[kind];
      if (m is Map && m[device] is num) return (m[device] as num).toInt();
      return 100;
    }

    // A volume slider (0..200 %) stored per peer and per `device`.
    Widget volumeSlider(String label, String kind, String device) => Row(
          children: [
            SizedBox(width: 150, child: Text(label)),
            Expanded(
              child: Slider(
                min: 0,
                max: 200,
                divisions: 40,
                value: volumeOf(kind, device).toDouble(),
                label: '${volumeOf(kind, device)} %',
                onChanged: (v) {
                  final m = Map<String, dynamic>.from(
                      (volumes[kind] as Map?) ?? <String, dynamic>{});
                  m[device] = v.round();
                  setState(() => volumes[kind] = m);
                },
                onChangeEnd: (v) => bind.sessionSetAudioVolume(
                    sessionId: sessionId,
                    kind: kind,
                    device: device,
                    percent: v.round()),
              ),
            ),
            SizedBox(width: 48, child: Text('${volumeOf(kind, device)} %')),
          ],
        );

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

    final r = remote;
    final virtualMic = r?.virtualMicrophone ?? '';
    final playingOutput = (volumes['playing_output'] as String?) ?? '';
    final b = boost;
    final microphoneItems = <Widget>[
      radio("Remote PC's own input, as configured there", '', hostInput,
          setHostInput),
      ...hostInputs.map((d) => radio(d, d, hostInput, setHostInput)),
      if (hostInput.isNotEmpty && !hostInputs.contains(hostInput))
        radio('$hostInput (not present, default input device is used)',
            hostInput, hostInput, setHostInput),
      if (hostInput.isNotEmpty)
        volumeSlider('Volume', 'host_input', hostInput),
      if (hostInput.isNotEmpty && b != null)
        Row(
          children: [
            SizedBox(width: 150, child: Text('Microphone boost')),
            Expanded(
              child: Slider(
                min: (b['min'] as num).toDouble(),
                max: (b['max'] as num).toDouble(),
                divisions: ((b['step'] as num) > 0)
                    ? (((b['max'] as num) - (b['min'] as num)) /
                            (b['step'] as num))
                        .round()
                        .clamp(1, 100)
                    : null,
                value: (b['current'] as num)
                    .toDouble()
                    .clamp((b['min'] as num).toDouble(),
                        (b['max'] as num).toDouble()),
                label: '${(b['current'] as num).toStringAsFixed(1)} dB',
                onChanged: (v) => setState(() => boost = {...b, 'current': v}),
                onChangeEnd: (v) {
                  final m = Map<String, dynamic>.from(
                      (volumes['boost'] as Map?) ?? <String, dynamic>{});
                  m[hostInput] = v;
                  volumes['boost'] = m;
                  bind.sessionSetMicrophoneBoost(
                      sessionId: sessionId, device: hostInput, db: v);
                },
              ),
            ),
            SizedBox(
                width: 48,
                child: Text('${(b['current'] as num).toStringAsFixed(1)} dB')),
          ],
        ),
      ListTile(
        dense: true,
        title: Text(r == null
            ? "Checking the remote PC's virtual microphone..."
            : virtualMic.isEmpty
                ? 'The remote PC has no virtual microphone: install VB-CABLE or Virtual Audio Driver there'
                : 'A device of this PC plays into "$virtualMic", which is then the remote PC\'s default recording device'),
      ),
    ];

    final List<Widget> inputItems;
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
        height: 720,
        child: ListView(
          children: [
            Row(
              children: [
                Expanded(
                  child: CheckboxListTile(
                    dense: true,
                    title: Text(translate('Mute')),
                    subtitle: Text(muteSaved.isEmpty
                        ? 'Not saved: sessions start muted'
                        : 'Saved: sessions start ${muteSaved == 'N' ? 'unmuted' : 'muted'}'),
                    value: muted,
                    onChanged: (v) async {
                      if (v == null || v == muted) return;
                      await setMuted(v);
                    },
                  ),
                ),
                dialogButton('Save', onPressed: () async {
                  await bind.sessionPeerOption(
                      sessionId: sessionId,
                      name: kOptionAudioMuteSaved,
                      value: muted ? 'Y' : 'N');
                  setState(() => muteSaved = muted ? 'Y' : 'N');
                }),
                const SizedBox(width: 8),
                dialogButton('Clear', isOutline: true, onPressed: () async {
                  await bind.sessionPeerOption(
                      sessionId: sessionId,
                      name: kOptionAudioMuteSaved,
                      value: '');
                  setState(() => muteSaved = '');
                  await setMuted(true);
                }),
              ],
            ),
            const Divider(),
            Text('Output on this PC',
                style: TextStyle(fontWeight: FontWeight.bold)),
            ...outputItems,
            volumeSlider(
                playingOutput.isEmpty
                    ? 'Volume'
                    : 'Volume of "$playingOutput"',
                'output',
                playingOutput),
            const Divider(),
            Text('Microphone of the remote PC',
                style: TextStyle(fontWeight: FontWeight.bold)),
            ...microphoneItems,
            const Divider(),
            Text('Sound you hear from the remote PC (captured there)',
                style: TextStyle(fontWeight: FontWeight.bold)),
            ...inputItems,
            volumeSlider('Volume', 'remote_input', input),
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
