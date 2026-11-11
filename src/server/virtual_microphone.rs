//! The controlled side's virtual microphone: a virtual audio cable whose playback endpoint carries the controller's
//! microphone stream and whose recording endpoint the controlled side's applications record from.
//!
//! - `detect()` returns the first installed pair of `PAIRS` (active endpoints, matched by friendly name).
//! - `activate(conn_id)` makes the pair's recording endpoint the Windows default recording device for every role
//!   (`eConsole`, `eMultimedia`, `eCommunications`) and returns the playback endpoint's name, which the connection's
//!   audio playback thread opens. The defaults in place before the first activation are restored by
//!   `deactivate(conn_id)` of the last active connection.
//!
//! Windows has no public API to change a default endpoint; `IPolicyConfig::SetDefaultEndpoint` (the interface the
//! Sound control panel uses) is called through its vtable. All calls run on `crate::audio_device_thread`.

use hbb_common::log;
use std::{collections::HashSet, ffi::c_void, sync::Mutex};
use windows::{
    core::{Interface, GUID, HRESULT, IUnknown, PCWSTR},
    Win32::{
        Devices::FunctionDiscovery::PKEY_Device_FriendlyName,
        Media::Audio::{
            eCapture, eCommunications, eConsole, eMultimedia, eRender, EDataFlow, IMMDevice,
            IMMDeviceEnumerator, MMDeviceEnumerator, DEVICE_STATE_ACTIVE,
        },
        System::Com::{
            CoCreateInstance, CoInitializeEx, CoTaskMemFree, CLSCTX_ALL, COINIT_MULTITHREADED,
            STGM_READ,
        },
    },
};

/// `(driver, playback endpoint name pattern, recording endpoint name pattern)`; a pattern matches a friendly name that
/// contains it. VB-CABLE: "CABLE Input (VB-Audio Virtual Cable)" → "CABLE Output (VB-Audio Virtual Cable)".
/// Virtual Audio Driver (VirtualDrivers): "Virtual Audio Driver" speaker → "Virtual Mic Driver" microphone.
const PAIRS: &[(&str, &str, &str)] = &[
    ("VB-CABLE", "CABLE Input", "CABLE Output"),
    ("Virtual Audio Driver", "Virtual Audio Driver", "Virtual Mic Driver"),
];

const CLSID_POLICY_CONFIG_CLIENT: GUID = GUID::from_u128(0x870af99c_171d_4f9e_af0d_e63df40c2bc9);
const IID_IPOLICY_CONFIG: GUID = GUID::from_u128(0xf8679f50_850a_41cf_9c72_430f290290c8);
/// `IPolicyConfig::SetDefaultEndpoint`: IUnknown (3) + GetMixFormat, GetDeviceFormat, ResetDeviceFormat,
/// SetDeviceFormat, GetProcessingPeriod, SetProcessingPeriod, GetShareMode, SetShareMode, GetPropertyValue,
/// SetPropertyValue (10).
const SET_DEFAULT_ENDPOINT_SLOT: usize = 13;

#[derive(Clone, Debug)]
pub struct Pair {
    pub driver: String,
    pub playback_name: String,
    pub recording_name: String,
    recording_id: String,
}

struct State {
    /// Connections with an active controller microphone.
    active: HashSet<i32>,
    /// Default recording endpoint ids per role (`eConsole`, `eMultimedia`, `eCommunications`) before activation.
    previous: Option<[Option<String>; 3]>,
}

lazy_static::lazy_static! {
    static ref STATE: Mutex<State> = Mutex::new(State { active: HashSet::new(), previous: None });
}

struct Endpoint {
    id: String,
    name: String,
}

unsafe fn enumerator() -> windows::core::Result<IMMDeviceEnumerator> {
    // The audio-device-query thread lives as long as the process; COM stays initialized on it. An STA set up there
    // by CPAL earlier answers RPC_E_CHANGED_MODE, which is fine.
    let _ = CoInitializeEx(None, COINIT_MULTITHREADED);
    CoCreateInstance(&MMDeviceEnumerator, None, CLSCTX_ALL)
}

unsafe fn device_id(device: &IMMDevice) -> windows::core::Result<String> {
    let id = device.GetId()?;
    let s = id.to_string().unwrap_or_default();
    CoTaskMemFree(Some(id.0 as *const c_void));
    Ok(s)
}

unsafe fn endpoints(flow: EDataFlow) -> windows::core::Result<Vec<Endpoint>> {
    let collection = enumerator()?.EnumAudioEndpoints(flow, DEVICE_STATE_ACTIVE)?;
    let mut out = Vec::new();
    for i in 0..collection.GetCount()? {
        let device = collection.Item(i)?;
        let store = device.OpenPropertyStore(STGM_READ)?;
        let name = store.GetValue(&PKEY_Device_FriendlyName)?.to_string();
        out.push(Endpoint {
            id: device_id(&device)?,
            name,
        });
    }
    Ok(out)
}

unsafe fn detect_inner() -> windows::core::Result<Option<Pair>> {
    let playback = endpoints(eRender)?;
    let recording = endpoints(eCapture)?;
    for (driver, play_pattern, rec_pattern) in PAIRS {
        let p = playback.iter().find(|e| e.name.contains(play_pattern));
        let r = recording.iter().find(|e| e.name.contains(rec_pattern));
        if let (Some(p), Some(r)) = (p, r) {
            return Ok(Some(Pair {
                driver: driver.to_string(),
                playback_name: p.name.clone(),
                recording_name: r.name.clone(),
                recording_id: r.id.clone(),
            }));
        }
    }
    Ok(None)
}

/// The first installed virtual microphone of `PAIRS`.
pub fn detect() -> Option<Pair> {
    crate::audio_device_thread::run(|| match unsafe { detect_inner() } {
        Ok(pair) => pair,
        Err(e) => {
            log::error!("Virtual microphone detection failed: {e}");
            None
        }
    })
    .flatten()
}

unsafe fn default_recording_ids() -> windows::core::Result<[Option<String>; 3]> {
    let e = enumerator()?;
    let mut out: [Option<String>; 3] = Default::default();
    for (i, role) in [eConsole, eMultimedia, eCommunications].into_iter().enumerate() {
        out[i] = match e.GetDefaultAudioEndpoint(eCapture, role) {
            Ok(d) => Some(device_id(&d)?),
            Err(_) => None,
        };
    }
    Ok(out)
}

unsafe fn set_default_recording(ids: &[Option<String>; 3]) -> windows::core::Result<()> {
    let _ = CoInitializeEx(None, COINIT_MULTITHREADED);
    let unknown: IUnknown = CoCreateInstance(&CLSID_POLICY_CONFIG_CLIENT, None, CLSCTX_ALL)?;
    let mut raw: *mut c_void = std::ptr::null_mut();
    unknown.query(&IID_IPOLICY_CONFIG, &mut raw).ok()?;
    let policy = IUnknown::from_raw(raw);
    type SetDefaultEndpoint = unsafe extern "system" fn(*mut c_void, PCWSTR, i32) -> HRESULT;
    let vtable = *(policy.as_raw() as *const *const usize);
    let set: SetDefaultEndpoint = std::mem::transmute(*vtable.add(SET_DEFAULT_ENDPOINT_SLOT));
    for (i, role) in [eConsole, eMultimedia, eCommunications].into_iter().enumerate() {
        if let Some(id) = &ids[i] {
            let wide: Vec<u16> = id.encode_utf16().chain(std::iter::once(0)).collect();
            set(policy.as_raw(), PCWSTR(wide.as_ptr()), role.0).ok()?;
        }
    }
    Ok(())
}

/// Download of VB-CABLE (https://vb-audio.com/Cable/): driver pack with `VBCABLE_Setup_x64.exe`.
pub const VB_CABLE_PACK_URL: &str = "https://download.vb-audio.com/Download_CABLE/VBCABLE_Driver_Pack45.zip";

/// Installs virtual microphone driver `driver` ("vb-cable"): downloads the driver pack into the temp directory,
/// extracts it with `Expand-Archive` and runs `VBCABLE_Setup_x64.exe -i -h`. Windows asks the user of this side to
/// allow the signed driver. Blocking; returns once the installer exits.
pub fn install(driver: &str) -> hbb_common::ResultType<()> {
    use hbb_common::anyhow::{anyhow, bail};
    if driver != "vb-cable" {
        bail!("unknown virtual microphone driver {driver:?}");
    }
    let dir = std::env::temp_dir().join("rustdesk-virtual-microphone");
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir)?;
    let zip = dir.join("VBCABLE_Driver_Pack.zip");
    log::info!("Downloading {VB_CABLE_PACK_URL}");
    let bytes = crate::hbbs_http::create_http_client_with_url(VB_CABLE_PACK_URL)
        .get(VB_CABLE_PACK_URL)
        .send()?
        .error_for_status()?
        .bytes()?;
    std::fs::write(&zip, &bytes)?;
    let status = std::process::Command::new("powershell.exe")
        .args([
            "-NoProfile",
            "-NonInteractive",
            "-Command",
            &format!(
                "Expand-Archive -Force -LiteralPath '{}' -DestinationPath '{}'",
                zip.display(),
                dir.display()
            ),
        ])
        .status()?;
    if !status.success() {
        bail!("Expand-Archive exited with {status}");
    }
    let setup = dir.join("VBCABLE_Setup_x64.exe");
    log::info!("Running {} -i -h", setup.display());
    let status = std::process::Command::new(&setup).args(["-i", "-h"]).status()?;
    log::info!("VB-CABLE setup exited with {status}");
    if detect().is_none() {
        return Err(anyhow!("the installer exited ({status}) and no virtual microphone is present"));
    }
    Ok(())
}

/// Makes the virtual microphone the default recording device for connection `conn_id`; returns the pair, whose
/// `playback_name` the connection's playback thread MUST open. `None` when no virtual microphone is installed.
pub fn activate(conn_id: i32) -> Option<Pair> {
    let pair = detect()?;
    let recording_id = pair.recording_id.clone();
    let ok = crate::audio_device_thread::run(move || unsafe {
        let mut state = STATE.lock().unwrap();
        if state.previous.is_none() {
            state.previous = Some(default_recording_ids()?);
        }
        let target = [Some(recording_id.clone()), Some(recording_id.clone()), Some(recording_id)];
        set_default_recording(&target)?;
        state.active.insert(conn_id);
        windows::core::Result::Ok(())
    });
    match ok {
        Some(Ok(())) => {
            log::info!(
                "Virtual microphone active for connection {conn_id}: {} plays into {} ({})",
                pair.playback_name,
                pair.recording_name,
                pair.driver
            );
            Some(pair)
        }
        Some(Err(e)) => {
            log::error!("Failed to make {} the default recording device: {e}", pair.recording_name);
            None
        }
        None => None,
    }
}

/// Ends the virtual microphone of connection `conn_id`; the last active connection restores the previous default
/// recording devices.
pub fn deactivate(conn_id: i32) {
    crate::audio_device_thread::run(move || unsafe {
        let mut state = STATE.lock().unwrap();
        if !state.active.remove(&conn_id) || !state.active.is_empty() {
            return;
        }
        if let Some(previous) = state.previous.take() {
            match set_default_recording(&previous) {
                Ok(()) => log::info!("Virtual microphone inactive; default recording devices restored"),
                Err(e) => log::error!("Failed to restore the default recording devices: {e}"),
            }
        }
    });
}
