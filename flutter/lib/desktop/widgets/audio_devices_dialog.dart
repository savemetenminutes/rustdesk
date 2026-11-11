// Audio dialog of a remote desktop session (Rust: `src/client/audio_devices.rs`, `src/client/audio_volume.rs`,
// `src/server/virtual_microphone.rs`). Groups, each with the volume (and boost) of its selected device right below it:
//
// - Output on this PC: "Windows default" follows the current Windows default output device; a named device that is
//   not present plays on the Windows default until it is present again.
// - Microphone of the remote PC: the remote PC's recording devices, its virtual microphone included; the selection
//   is the remote PC's default recording device. Without a virtual microphone, an option installs VB-CABLE there.
// - Microphone of this PC: one of this PC's input devices plays into the remote PC's virtual microphone; selectable
//   only while that virtual microphone is the remote PC's selected recording device.
// - Sound you hear from the remote PC: what the remote PC captures and sends to this PC.

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

/// Peer option: this PC's input device played into the remote PC's virtual microphone (Rust
/// `audio_devices::OPTION_AUDIO_HOST_INPUT_DEVICE`); "" = none.
const String kOptionAudioHostInputDevice = 'audio-host-input-device';

/// What the remote PC reports (`AudioInputs`).
class _RemoteInputs {
  /// Capture devices (what this PC hears).
  final List<String> devices;
  final String ownSetting;
  final bool systemSound;

  /// Recording device name of the remote PC's virtual microphone; "" when none is installed.
  final String virtualMicrophone;

  /// Outcome of the last driver install request: "", "installing", "installed", "failed: <reason>".
  final String install;

  /// Recording devices and the default one with its endpoint volume (-1 unknown) and Microphone Boost.
  final List<String> recordingDevices;
  final String defaultRecording;
  final int defaultRecordingVolume;
  final Map<String, dynamic>? defaultRecordingBoost;

  _RemoteInputs(
      this.devices,
      this.ownSetting,
      this.systemSound,
      this.virtualMicrophone,
      this.install,
      this.recordingDevices,
      this.defaultRecording,
      this.defaultRecordingVolume,
      this.defaultRecordingBoost);
}

_RemoteInputs? _parseRemoteInputs(String raw) {
  if (raw.isEmpty) return null;
  try {
    final m = jsonDecode(raw);
    final boost = (m['default_recording_boost'] ?? '') as String;
    return _RemoteInputs(
        (m['devices'] as List).cast<String>(),
        m['own_setting'] as String,
        m['system_sound'] == true,
        (m['virtual_microphone'] ?? '') as String,
        (m['virtual_microphone_install'] ?? '') as String,
        ((m['recording_devices'] ?? []) as List).cast<String>(),
        (m['default_recording'] ?? '') as String,
        ((m['default_recording_volume'] ?? -1) as num).toInt(),
        boost.isEmpty ? null : jsonDecode(boost) as Map<String, dynamic>);
  } catch (e) {
    debugPrint('Failed to parse remote audio inputs "$raw": $e');
    return null;
  }
}

Future<_RemoteInputs?> _fetchRemoteInputs(FFI ffi) async {
  bind.sessionRequestRemoteAudioInputs(sessionId: ffi.sessionId);
  for (var i = 0; i < 30; i++) {
    await Future.delayed(const Duration(milliseconds: 100));
    final raw = bind.sessionGetRemoteAudioInputs(sessionId: ffi.sessionId);
    if (raw.isNotEmpty) return _parseRemoteInputs(raw);
  }
  return null;
}

void audioDevicesDialog(FFI ffi) async {
  final sessionId = ffi.sessionId;
  var output = await bind.sessionGetPeerOption(
      sessionId: sessionId, name: kOptionAudioOutputDevice);
  var input = await bind.sessionGetPeerOption(
      sessionId: sessionId, name: kOptionAudioInputDevice);
  var hostInput = await bind.sessionGetPeerOption(
      sessionId: sessionId, name: kOptionAudioHostInputDevice);
  List<String> parseList(String raw) {
    try {
      return (jsonDecode(raw) as List).cast<String>();
    } catch (e) {
      return [];
    }
  }

  final outputs = parseList(bind.mainGetAudioOutputDevices());
  final hostInputs = parseList(bind.mainGetAudioInputDevices());

  // Stored volumes (percent) per device and the output device that plays (Rust `audio_volume`).
  Map<String, dynamic> volumes = {};
  try {
    volumes = jsonDecode(bind.sessionGetAudioVolumes(sessionId: sessionId))
        as Map<String, dynamic>;
  } catch (e) {
    volumes = {};
  }

  // Microphone Boost (dB) of an input device of this PC: {"min", "max", "step", "current"}, or null when it has none.
  Map<String, dynamic>? localBoostOf(String device) {
    if (device.isEmpty) return null;
    try {
      final raw = bind.mainGetMicrophoneBoost(device: device);
      return raw.isEmpty ? null : jsonDecode(raw) as Map<String, dynamic>;
    } catch (e) {
      return null;
    }
  }

  var hostBoost = localBoostOf(hostInput);
  var muted = bind.sessionGetToggleOptionSync(
      sessionId: sessionId, arg: kOptionToggleDisableAudio);
  var muteSaved = await bind.sessionGetPeerOption(
      sessionId: sessionId, name: kOptionAudioMuteSaved);
  _RemoteInputs? remote;
  var fetchStarted = false;
  var fetchDone = false;
  var closed = false;
  // Slider values while dragging, keyed by group and device.
  final dragging = <String, double>{};

  ffi.dialogManager.show((setState, close, context) {
    void setRemote(_RemoteInputs? r) {
      if (closed) return;
      try {
        setState(() {
          remote = r;
          fetchDone = true;
        });
      } catch (e) {
        // The dialog was dismissed by `dialogManager`.
      }
    }

    if (!fetchStarted) {
      fetchStarted = true;
      _fetchRemoteInputs(ffi).then(setRemote);
    }

    // Follows the `AudioInputs` the remote PC sends after a change, for up to `seconds`.
    void followRemote(int seconds, bool Function(_RemoteInputs r) done) {
      Timer.periodic(const Duration(milliseconds: 500), (t) {
        if (closed || t.tick > seconds * 2) {
          t.cancel();
          return;
        }
        final r = _parseRemoteInputs(
            bind.sessionGetRemoteAudioInputs(sessionId: sessionId));
        if (r == null) return;
        setRemote(r);
        if (done(r)) t.cancel();
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

    void setHostInput(String v) {
      bind.sessionSetHostMicrophone(sessionId: sessionId, device: v);
      setState(() {
        hostInput = v;
        hostBoost = localBoostOf(v);
      });
    }

    void controlRecording(String device,
        {bool setDefault = false, int volume = -1, double? boost}) {
      bind.sessionControlRemoteRecordingDevice(
          sessionId: sessionId,
          device: device,
          setDefault: setDefault,
          volume: volume,
          setBoost: boost != null,
          boostDb: boost ?? 0);
      followRemote(5, (r) => !setDefault || r.defaultRecording == device);
    }

    void installVirtualMicrophone() {
      bind.sessionInstallRemoteVirtualMicrophone(
          sessionId: sessionId, driver: 'vb-cable');
      followRemote(
          900, (r) => r.install == 'installed' || r.install.startsWith('failed'));
    }

    // Slider row; `value` is the current value, `onEnd` stores and applies the final one.
    Widget slider(String key, String label, double min, double max,
        double value, String Function(double) text, void Function(double) onEnd,
        {int? divisions}) {
      final v = (dragging[key] ?? value).clamp(min, max).toDouble();
      return Padding(
        padding: const EdgeInsets.only(left: 48, right: 8),
        child: Row(
          children: [
            SizedBox(width: 110, child: Text(label)),
            Expanded(
              child: Slider(
                min: min,
                max: max,
                divisions: divisions,
                value: v,
                label: text(v),
                onChanged: (x) => setState(() => dragging[key] = x),
                onChangeEnd: (x) {
                  onEnd(x);
                  setState(() => dragging.remove(key));
                },
              ),
            ),
            SizedBox(width: 64, child: Text(text(v))),
          ],
        ),
      );
    }

    int storedVolume(String kind, String device) {
      final m = volumes[kind];
      if (m is Map && m[device] is num) return (m[device] as num).toInt();
      return 100;
    }

    // Software volume (0..200 %) of this PC, stored per peer and per device.
    Widget volumeSlider(String kind, String device) => slider(
            '$kind/$device',
            'Volume',
            0,
            200,
            storedVolume(kind, device).toDouble(),
            (x) => '${x.round()} %', (x) {
          final m = Map<String, dynamic>.from(
              (volumes[kind] as Map?) ?? <String, dynamic>{});
          m[device] = x.round();
          volumes[kind] = m;
          bind.sessionSetAudioVolume(
              sessionId: sessionId,
              kind: kind,
              device: device,
              percent: x.round());
        }, divisions: 40);

    Widget boostSlider(String key, Map<String, dynamic> b,
        void Function(double) onEnd) {
      final min = (b['min'] as num).toDouble();
      final max = (b['max'] as num).toDouble();
      final step = (b['step'] as num).toDouble();
      return slider(key, 'Microphone boost', min, max,
          (b['current'] as num).toDouble(), (x) => '${x.toStringAsFixed(1)} dB',
          (x) {
        b['current'] = x;
        onEnd(x);
      },
          divisions:
              step > 0 ? ((max - min) / step).round().clamp(1, 100) : null);
    }

    Widget radio(String label, String value, String group,
            void Function(String)? onChanged,
            {List<Widget> whenSelected = const []}) =>
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            RadioListTile<String>(
              dense: true,
              title: Text(label),
              value: value,
              groupValue: group,
              onChanged: onChanged == null ? null : (v) => onChanged(v ?? ''),
            ),
            if (value == group) ...whenSelected,
          ],
        );

    Widget note(String text) => Padding(
          padding: const EdgeInsets.only(left: 16, right: 8, bottom: 4),
          child: Text(text,
              style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).textTheme.bodySmall?.color)),
        );

    Widget heading(String text) => Padding(
          padding: const EdgeInsets.only(top: 8, bottom: 4),
          child: Text(text, style: TextStyle(fontWeight: FontWeight.bold)),
        );

    // Output on this PC. The volume belongs to the device that plays ("Windows default" resolves to one).
    final playingOutput = (volumes['playing_output'] as String?) ?? '';
    final outputGroup = <Widget>[
      heading('Output on this PC'),
      radio('Windows default (follows changes)', '', output, setOutput,
          whenSelected: [
            if (playingOutput.isNotEmpty) note('Playing on "$playingOutput"'),
            volumeSlider('output', playingOutput),
          ]),
      ...outputs.map((d) => radio(d, d, output, setOutput,
          whenSelected: [volumeSlider('output', playingOutput.isEmpty ? d : playingOutput)])),
      if (output.isNotEmpty && !outputs.contains(output))
        radio('$output (not present, Windows default is used)', output,
            output, setOutput,
            whenSelected: [volumeSlider('output', playingOutput)]),
    ];

    // Microphone of the remote PC: its recording devices; the selection is its default recording device.
    final r = remote;
    final virtualMic = r?.virtualMicrophone ?? '';
    final List<Widget> remoteMicGroup = [heading('Microphone of the remote PC')];
    if (r == null) {
      remoteMicGroup.add(note(fetchDone
          ? 'The remote PC did not list its devices (it needs this build)'
          : "Loading the remote PC's devices..."));
    } else {
      List<Widget> recordingControls(String device) => [
            if (r.defaultRecordingVolume >= 0)
              slider(
                  'remote_recording/$device',
                  'Volume',
                  0,
                  100,
                  r.defaultRecordingVolume.toDouble(),
                  (x) => '${x.round()} %',
                  (x) => controlRecording(device, volume: x.round()),
                  divisions: 50),
            if (r.defaultRecordingBoost != null)
              boostSlider('remote_boost/$device', r.defaultRecordingBoost!,
                  (x) => controlRecording(device, boost: x)),
          ];
      for (final d in r.recordingDevices) {
        remoteMicGroup.add(radio(
            d == virtualMic ? '$d (virtual microphone, fed from this PC)' : d,
            d,
            r.defaultRecording,
            (v) => controlRecording(v, setDefault: true),
            whenSelected: recordingControls(d)));
      }
      if (virtualMic.isEmpty && r.install != 'installing') {
        remoteMicGroup.add(radio(
            'Select this option to install "VB-CABLE Virtual Audio Device" (https://vb-audio.com/Cable/)',
            'install:vb-cable',
            r.defaultRecording,
            (_) => installVirtualMicrophone()));
      }
      if (r.install == 'installing') {
        remoteMicGroup.add(note(
            'Installing VB-CABLE on the remote PC: allow the Windows driver prompt on its screen'));
      } else if (r.install.startsWith('failed')) {
        remoteMicGroup.add(note('VB-CABLE install ${r.install}'));
      }
    }

    // Microphone of this PC, played into the remote PC's virtual microphone.
    final hostEnabled = virtualMic.isNotEmpty && r?.defaultRecording == virtualMic;
    final hostGroup = <Widget>[
      heading('Microphone of this PC (sent to the remote PC)'),
      if (!hostEnabled)
        note(
            'The remote PC must have the virtual microphone installed and selected under "Microphone of the remote PC" to send a microphone of this PC'),
      radio('None', '', hostInput, hostEnabled ? setHostInput : null),
      ...hostInputs.map((d) => radio(
              d, d, hostInput, hostEnabled ? setHostInput : null,
              whenSelected: [
                volumeSlider('host_input', d),
                if (hostBoost != null)
                  boostSlider('host_boost/$d', hostBoost!, (x) {
                    bind.sessionSetMicrophoneBoost(
                        sessionId: sessionId, device: d, db: x);
                  }),
              ])),
      if (hostInput.isNotEmpty && !hostInputs.contains(hostInput))
        radio('$hostInput (not present, default input device is used)',
            hostInput, hostInput, hostEnabled ? setHostInput : null,
            whenSelected: [volumeSlider('host_input', hostInput)]),
    ];

    // Sound you hear from the remote PC: what the remote PC captures and sends to this PC.
    final List<Widget> hearGroup = [
      heading('Sound you hear from the remote PC (captured there)')
    ];
    if (r == null) {
      hearGroup.add(radio("Remote PC's own setting", '', input, setInput,
          whenSelected: [volumeSlider('remote_input', '')]));
    } else {
      final defaultLabel =
          r.systemSound ? 'System Sound' : 'Default input device';
      final ownLabel = r.ownSetting.isEmpty ? defaultLabel : r.ownSetting;
      final selected = input.startsWith(kAudioInputOverridePrefix)
          ? input.substring(kAudioInputOverridePrefix.length)
          : null;
      hearGroup.addAll([
        radio("Remote PC's own setting ($ownLabel)", '', input, setInput,
            whenSelected: [volumeSlider('remote_input', '')]),
        radio(defaultLabel, kAudioInputOverridePrefix, input, setInput,
            whenSelected: [
              volumeSlider('remote_input', kAudioInputOverridePrefix)
            ]),
        ...r.devices.map((d) => radio(
                d, '$kAudioInputOverridePrefix$d', input, setInput,
                whenSelected: [
                  volumeSlider('remote_input', '$kAudioInputOverridePrefix$d')
                ])),
        if (selected != null &&
            selected.isNotEmpty &&
            !r.devices.contains(selected))
          radio('$selected (not present, default input device is used)',
              input, input, setInput,
              whenSelected: [volumeSlider('remote_input', input)]),
      ]);
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

    void onClose() {
      closed = true;
      close();
    }

    return CustomAlertDialog(
      title: Text('Audio devices'),
      content: SizedBox(
        width: 560,
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
            ...outputGroup,
            const Divider(),
            ...remoteMicGroup,
            const Divider(),
            ...hostGroup,
            const Divider(),
            ...hearGroup,
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
