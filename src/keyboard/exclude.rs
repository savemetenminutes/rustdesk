//! Per-peer keyboard shortcut exclude list.
//!
//! Peer option `KEYBOARD_EXCLUDE_SHORTCUTS_OPTION` holds a comma-separated list of chords (`Ctrl+Shift`, `Win+D`,
//! `Alt+Tab`, ...). While a session window grabs the keyboard, every key press goes to the remote PC; a chord on the
//! focused session's list goes to the local PC instead:
//!
//! - A chord with a main key (`Win+D`) is diverted on the press of the main key: the held modifiers are released on
//!   the remote PC, and the held modifiers plus the main key are re-injected locally with `rdev::simulate_code()`.
//!   Every press until all modifiers are released stays local.
//! - A modifier-only chord (`Alt+Shift`, `Win`) is diverted on the first modifier release, when no other key was pressed
//!   since the first modifier went down: the modifiers are pressed locally and the release is re-injected, so the
//!   local system sees the complete chord; the remote PC gets `MASK_KEY` before the releases, so its own action for the
//!   chord (input language switch, Start menu) does not fire.

use super::client;
use rdev::{Event, EventType, Key};
use std::{
    collections::{HashMap, VecDeque},
    sync::Mutex,
    time::SystemTime,
};

pub const KEYBOARD_EXCLUDE_SHORTCUTS_OPTION: &str = "keyboard-exclude-shortcuts";

const MOD_CTRL: u8 = 1;
const MOD_ALT: u8 = 2;
const MOD_SHIFT: u8 = 4;
const MOD_WIN: u8 = 8;

/// `F24`: VK `0x87`, set-1 scan code `0x76`.
const MASK_KEY: Key = Key::F24;
const MASK_VK: u32 = 0x87;
const MASK_SCAN: u32 = 0x76;

/// Scan code of the fake left `Ctrl` that Windows sends with `AltGr`.
const FAKE_CTRL_SCAN: u32 = 0x021D;

#[derive(Clone, Copy, PartialEq, Eq, Hash, Debug)]
pub struct Chord {
    mods: u8,
    key: Option<Key>,
}

/// Friendly name ⇄ `rdev::Key`. The first name of a key is its canonical name.
const KEY_NAMES: &[(&str, Key)] = &[
    ("A", Key::KeyA), ("B", Key::KeyB), ("C", Key::KeyC), ("D", Key::KeyD), ("E", Key::KeyE),
    ("F", Key::KeyF), ("G", Key::KeyG), ("H", Key::KeyH), ("I", Key::KeyI), ("J", Key::KeyJ),
    ("K", Key::KeyK), ("L", Key::KeyL), ("M", Key::KeyM), ("N", Key::KeyN), ("O", Key::KeyO),
    ("P", Key::KeyP), ("Q", Key::KeyQ), ("R", Key::KeyR), ("S", Key::KeyS), ("T", Key::KeyT),
    ("U", Key::KeyU), ("V", Key::KeyV), ("W", Key::KeyW), ("X", Key::KeyX), ("Y", Key::KeyY),
    ("Z", Key::KeyZ),
    ("0", Key::Num0), ("1", Key::Num1), ("2", Key::Num2), ("3", Key::Num3), ("4", Key::Num4),
    ("5", Key::Num5), ("6", Key::Num6), ("7", Key::Num7), ("8", Key::Num8), ("9", Key::Num9),
    ("F1", Key::F1), ("F2", Key::F2), ("F3", Key::F3), ("F4", Key::F4), ("F5", Key::F5),
    ("F6", Key::F6), ("F7", Key::F7), ("F8", Key::F8), ("F9", Key::F9), ("F10", Key::F10),
    ("F11", Key::F11), ("F12", Key::F12), ("F13", Key::F13), ("F14", Key::F14), ("F15", Key::F15),
    ("F16", Key::F16), ("F17", Key::F17), ("F18", Key::F18), ("F19", Key::F19), ("F20", Key::F20),
    ("F21", Key::F21), ("F22", Key::F22), ("F23", Key::F23),
    ("Esc", Key::Escape), ("Escape", Key::Escape),
    ("Tab", Key::Tab),
    ("Space", Key::Space),
    ("Enter", Key::Return), ("Return", Key::Return),
    ("Backspace", Key::Backspace),
    ("Delete", Key::Delete), ("Del", Key::Delete),
    ("Insert", Key::Insert), ("Ins", Key::Insert),
    ("Home", Key::Home), ("End", Key::End),
    ("PageUp", Key::PageUp), ("PgUp", Key::PageUp),
    ("PageDown", Key::PageDown), ("PgDn", Key::PageDown),
    ("Left", Key::LeftArrow), ("Right", Key::RightArrow), ("Up", Key::UpArrow), ("Down", Key::DownArrow),
    ("PrintScreen", Key::PrintScreen), ("PrtSc", Key::PrintScreen),
    ("Pause", Key::Pause), ("ScrollLock", Key::ScrollLock),
    ("Apps", Key::Apps), ("Menu", Key::Apps),
    ("`", Key::BackQuote), ("-", Key::Minus), ("=", Key::Equal),
    ("[", Key::LeftBracket), ("]", Key::RightBracket), ("\\", Key::BackSlash),
    (";", Key::SemiColon), ("'", Key::Quote), (",", Key::Comma), (".", Key::Dot), ("/", Key::Slash),
    ("Num0", Key::Kp0), ("Num1", Key::Kp1), ("Num2", Key::Kp2), ("Num3", Key::Kp3), ("Num4", Key::Kp4),
    ("Num5", Key::Kp5), ("Num6", Key::Kp6), ("Num7", Key::Kp7), ("Num8", Key::Kp8), ("Num9", Key::Kp9),
    ("Num+", Key::KpPlus), ("Num-", Key::KpMinus), ("Num*", Key::KpMultiply), ("Num/", Key::KpDivide),
    ("NumEnter", Key::KpReturn), ("NumDel", Key::KpDecimal),
    ("VolumeUp", Key::VolumeUp), ("VolumeDown", Key::VolumeDown), ("VolumeMute", Key::VolumeMute),
];

fn mod_bit(key: Key) -> u8 {
    match key {
        Key::ControlLeft | Key::ControlRight => MOD_CTRL,
        Key::Alt | Key::AltGr => MOD_ALT,
        Key::ShiftLeft | Key::ShiftRight => MOD_SHIFT,
        Key::MetaLeft | Key::MetaRight => MOD_WIN,
        _ => 0,
    }
}

impl Chord {
    /// Parses `Ctrl+Alt+Shift+Win+<key>` (any order, case-insensitive); returns `None` for an unknown token, a second
    /// main key or an empty chord.
    pub fn parse(s: &str) -> Option<Chord> {
        let mut mods = 0u8;
        let mut key = None;
        // `+` as a key name: "Ctrl++" splits into ["Ctrl", "", ""].
        let tokens: Vec<&str> = s.split('+').map(|t| t.trim()).collect();
        let mut i = 0;
        while i < tokens.len() {
            let t = tokens[i];
            let lower = t.to_lowercase();
            let bit = match lower.as_str() {
                "ctrl" | "control" => MOD_CTRL,
                "alt" => MOD_ALT,
                "shift" => MOD_SHIFT,
                "win" | "windows" | "meta" | "super" | "cmd" => MOD_WIN,
                _ => 0,
            };
            if bit != 0 {
                mods |= bit;
            } else if t.is_empty() {
                // A trailing "+" key.
                if i + 2 == tokens.len() && tokens[i + 1].is_empty() {
                    if key.is_some() {
                        return None;
                    }
                    key = Some(Key::Equal);
                    i += 1;
                } else {
                    return None;
                }
            } else {
                let k = KEY_NAMES
                    .iter()
                    .find(|(n, _)| n.eq_ignore_ascii_case(t))
                    .map(|(_, k)| *k)?;
                if key.is_some() {
                    return None;
                }
                key = Some(k);
            }
            i += 1;
        }
        if mods == 0 && key.is_none() {
            return None;
        }
        Some(Chord { mods, key })
    }

    /// Canonical `Ctrl+Alt+Shift+Win+<key>` form.
    pub fn to_canonical(&self) -> String {
        let mut parts: Vec<&str> = vec![];
        if self.mods & MOD_CTRL != 0 {
            parts.push("Ctrl");
        }
        if self.mods & MOD_ALT != 0 {
            parts.push("Alt");
        }
        if self.mods & MOD_SHIFT != 0 {
            parts.push("Shift");
        }
        if self.mods & MOD_WIN != 0 {
            parts.push("Win");
        }
        if let Some(k) = self.key {
            if let Some((n, _)) = KEY_NAMES.iter().find(|(_, kk)| *kk == k) {
                parts.push(n);
            }
        }
        parts.join("+")
    }
}

/// Returns the canonical form of chord `s`, or "" when `s` is not a valid chord.
pub fn normalize_chord(s: &str) -> String {
    Chord::parse(s).map(|c| c.to_canonical()).unwrap_or_default()
}

/// Parses a comma-separated chord list; invalid entries are dropped, duplicates are kept once.
pub fn parse_list(s: &str) -> Vec<Chord> {
    let mut res: Vec<Chord> = vec![];
    for c in s.split(',').filter_map(|t| Chord::parse(t)) {
        if !res.contains(&c) {
            res.push(c);
        }
    }
    res
}

fn list_to_string(list: &[Chord]) -> String {
    list.iter()
        .map(|c| c.to_canonical())
        .collect::<Vec<_>>()
        .join(",")
}

lazy_static::lazy_static! {
    /// Peer id → exclude list. Filled from the peer option on first use and by `set_exclude_list()`.
    static ref EXCLUDE_LISTS: Mutex<HashMap<String, Vec<Chord>>> = Mutex::new(HashMap::new());
    static ref STATE: Mutex<HookState> = Mutex::new(HookState::default());
}

/// Stores `value` as the exclude list of the peer of `session` (peer option and cache) and returns the canonical form.
#[cfg(feature = "flutter")]
pub fn set_exclude_list(session: &crate::flutter::FlutterSession, value: &str) -> String {
    let list = parse_list(value);
    let canonical = list_to_string(&list);
    session.set_option(
        KEYBOARD_EXCLUDE_SHORTCUTS_OPTION.to_owned(),
        canonical.clone(),
    );
    let peer_id = session.lc.read().unwrap().get_id().to_owned();
    EXCLUDE_LISTS.lock().unwrap().insert(peer_id, list);
    canonical
}

#[cfg(feature = "flutter")]
fn cur_exclude_list() -> Vec<Chord> {
    let Some(session) = crate::flutter::get_cur_session() else {
        return vec![];
    };
    if !session.is_default() {
        return vec![];
    }
    let peer_id = session.lc.read().unwrap().get_id().to_owned();
    let mut lists = EXCLUDE_LISTS.lock().unwrap();
    if let Some(list) = lists.get(&peer_id) {
        return list.clone();
    }
    let list = parse_list(&session.get_option(KEYBOARD_EXCLUDE_SHORTCUTS_OPTION.to_owned()));
    lists.insert(peer_id, list.clone());
    list
}

#[derive(Default)]
struct HookState {
    /// Physically held modifiers, with their press event.
    held: HashMap<Key, Event>,
    /// Modifiers pressed since all modifiers were up.
    seq_mods: u8,
    /// A non-modifier key was pressed since all modifiers were up.
    seq_other: bool,
    /// A modifier was released since all modifiers were up.
    seq_released: bool,
    /// A chord is diverted to the local PC until all modifiers are released.
    diverted: bool,
    /// Events re-injected by this module, expected back in the hook: `(position_code, is_press)`.
    expected: VecDeque<(u32, bool)>,
}

impl HookState {
    fn held_bits(&self) -> u8 {
        self.held.keys().fold(0, |b, k| b | mod_bit(*k))
    }
}

fn make_event(key: Key, platform_code: u32, position_code: u32, is_press: bool) -> Event {
    Event {
        time: SystemTime::now(),
        unicode: None,
        event_type: if is_press {
            EventType::KeyPress(key)
        } else {
            EventType::KeyRelease(key)
        },
        platform_code,
        position_code,
        usb_hid: 0,
        #[cfg(target_os = "windows")]
        extra_data: 0,
        #[cfg(target_os = "macos")]
        extra_data: 0,
    }
}

fn send_remote(mode: &str, event: &Event) {
    client::process_event(mode, event, None);
}

fn send_remote_mask(mode: &str) {
    send_remote(mode, &make_event(MASK_KEY, MASK_VK, MASK_SCAN, true));
    send_remote(mode, &make_event(MASK_KEY, MASK_VK, MASK_SCAN, false));
}

/// Releases every held modifier on the remote PC, masked when `Alt` or `Win` is among them.
fn release_remote_mods(mode: &str, state: &HookState) {
    if state.held_bits() & (MOD_ALT | MOD_WIN) != 0 {
        send_remote_mask(mode);
    }
    for ev in state.held.values() {
        let mut ev = ev.clone();
        if let EventType::KeyPress(k) = ev.event_type {
            ev.event_type = EventType::KeyRelease(k);
        }
        send_remote(mode, &ev);
    }
}

#[cfg(target_os = "windows")]
fn inject_local(state: &mut HookState, position_code: u32, is_press: bool) {
    state.expected.push_back((position_code, is_press));
    if rdev::simulate_code(None, Some(position_code), is_press).is_err() {
        state.expected.pop_back();
        hbb_common::log::error!(
            "keyboard exclude: failed to inject scan code 0x{:x}",
            position_code
        );
    }
}

/// Decides a keyboard hook event. Returns `Some(res)` when this module handled the event (`res` is the hook result:
/// `None` swallows it locally), `None` to leave it to the default path.
#[cfg(all(feature = "flutter", target_os = "windows"))]
pub fn on_hook_event(event: &Event, key: Key, is_press: bool, hooked: bool) -> Option<Option<Event>> {
    let mut state = STATE.lock().unwrap();
    if let Some(&(pos, press)) = state.expected.front() {
        if pos == event.position_code && press == is_press {
            state.expected.pop_front();
            return Some(Some(event.clone()));
        }
    }

    let bit = if event.position_code == FAKE_CTRL_SCAN {
        0
    } else {
        mod_bit(key)
    };
    let held_bits_before = state.held_bits();
    if is_press {
        if bit != 0 {
            if !state.held.contains_key(&key) {
                state.held.insert(key, event.clone());
            }
            state.seq_mods |= bit;
        } else {
            state.seq_other = true;
        }
    }
    let first_release = !is_press && bit != 0 && !state.seq_released;
    if !is_press && bit != 0 {
        state.held.remove(&key);
        state.seq_released = true;
    }
    let reset = |state: &mut HookState| {
        if state.held.is_empty() {
            state.seq_mods = 0;
            state.seq_other = false;
            state.seq_released = false;
            state.diverted = false;
        }
    };

    if !hooked {
        reset(&mut state);
        return None;
    }

    if state.diverted {
        if is_press {
            return Some(Some(event.clone()));
        }
        reset(&mut state);
        return None;
    }

    // Main-key chord: decided on the press of a non-modifier key.
    if is_press && bit == 0 {
        let chord = Chord {
            mods: held_bits_before,
            key: Some(key),
        };
        if !cur_exclude_list().contains(&chord) {
            return None;
        }
        let mode = super::get_keyboard_mode();
        release_remote_mods(&mode, &state);
        let held: Vec<u32> = state.held.values().map(|e| e.position_code).collect();
        for pos in held {
            inject_local(&mut state, pos, true);
        }
        inject_local(&mut state, event.position_code, true);
        state.diverted = true;
        return Some(None);
    }

    // Modifier-only chord: decided on the first modifier release of a sequence without another key.
    if first_release && !state.seq_other && held_bits_before == state.seq_mods {
        let chord = Chord {
            mods: state.seq_mods,
            key: None,
        };
        if !cur_exclude_list().contains(&chord) {
            reset(&mut state);
            return None;
        }
        let mode = super::get_keyboard_mode();
        send_remote_mask(&mode);
        send_remote(&mode, event);
        let held: Vec<u32> = state.held.values().map(|e| e.position_code).collect();
        for pos in held {
            inject_local(&mut state, pos, true);
        }
        inject_local(&mut state, event.position_code, true);
        inject_local(&mut state, event.position_code, false);
        state.diverted = true;
        reset(&mut state);
        return Some(None);
    }

    reset(&mut state);
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_and_normalize() {
        assert_eq!(normalize_chord("win+d"), "Win+D");
        assert_eq!(normalize_chord("Shift + Alt"), "Alt+Shift");
        assert_eq!(normalize_chord("ctrl+shift+esc"), "Ctrl+Shift+Esc");
        assert_eq!(normalize_chord("Win"), "Win");
        assert_eq!(normalize_chord("Ctrl++"), "Ctrl+=");
        assert_eq!(normalize_chord("Ctrl+Q+W"), "");
        assert_eq!(normalize_chord("Foo"), "");
        assert_eq!(normalize_chord(""), "");
        assert_eq!(
            list_to_string(&parse_list("Win+D, alt+shift,Win+D,bogus")),
            "Win+D,Alt+Shift"
        );
    }
}
