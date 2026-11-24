//! Expressions of `settings_layout.json`, evaluated with the embedded `rhai` engine.
//!
//! The layout's `condition` (show the item or category while true) and `options` (a radio's options, when written as
//! a string) are `rhai` expressions, so a change to them needs no build: the settings screen's Reload re-reads the
//! file and the next render evaluates the new text.
//!
//! Scope of every evaluation, from the caller's context JSON: `platform` ("windows" | "macos" | "linux"), `peer`
//! (peer id of the column, "" for none), `in_session` (bool), `display` (remote display index, -1 for none), `value`
//! (current value of the column's store, "" for none).
//!
//! Functions: `option(key)` (`Config`), `local_option(key)` (`LocalConfig`), `default_option(key)`
//! (`UserDefaultConfig`), `builtin_option(key)`, `peer_setting(id, key)` (`main_get_peer_setting`),
//! `is_incoming_only()`, `is_outgoing_only()`, `is_custom_client()`, `is_installed()`, `is_installed_daemon()`,
//! `is_disable_settings()`, `is_disable_account()`, `has_hwcodec()`, `has_vram()`, `hw_decodings()` (map `h264`,
//! `h265`), `audio_inputs()` (array), `audio_loopback()`, `input_sources()` (array of `[id, label key]`),
//! `privacy_mode_impls()` (array of `[id, label key]`).
//!
//! The engine is sandboxed: no file, network or process access; `set_max_operations` bounds a runaway expression.
//! Compiled expressions are cached by their text.

use hbb_common::config::{Config, LocalConfig, UserDefaultConfig};
use rhai::{Array, Dynamic, Engine, Map, Scope, AST};
use std::{collections::HashMap, sync::Mutex};

lazy_static::lazy_static! {
    static ref ENGINE: Engine = new_engine();
    static ref AST_CACHE: Mutex<HashMap<String, AST>> = Mutex::new(HashMap::new());
}

fn pairs(v: Vec<(String, String)>) -> Array {
    v.into_iter()
        .map(|(a, b)| Dynamic::from_array(vec![a.into(), b.into()]))
        .collect()
}

fn new_engine() -> Engine {
    let mut e = Engine::new();
    e.set_max_operations(200_000);
    e.set_max_expr_depths(64, 32);
    e.register_fn("option", |k: &str| Config::get_option(k));
    e.register_fn("local_option", |k: &str| LocalConfig::get_option(k));
    e.register_fn("default_option", |k: &str| UserDefaultConfig::load().get(k));
    e.register_fn("builtin_option", |k: &str| {
        crate::flutter_ffi::main_get_buildin_option(k.to_owned()).0
    });
    e.register_fn("peer_setting", |id: &str, k: &str| {
        crate::flutter_ffi::main_get_peer_setting(id.to_owned(), k.to_owned()).0
    });
    e.register_fn("is_incoming_only", || hbb_common::config::is_incoming_only());
    e.register_fn("is_outgoing_only", || hbb_common::config::is_outgoing_only());
    e.register_fn("is_custom_client", || crate::common::is_custom_client());
    e.register_fn("is_installed", || crate::flutter_ffi::main_is_installed().0);
    e.register_fn("is_installed_daemon", || {
        crate::flutter_ffi::main_is_installed_daemon(false).0
    });
    e.register_fn("is_disable_settings", || hbb_common::config::is_disable_settings());
    e.register_fn("is_disable_account", || hbb_common::config::is_disable_account());
    e.register_fn("has_hwcodec", || crate::flutter_ffi::main_has_hwcodec().0);
    e.register_fn("has_vram", || crate::flutter_ffi::main_has_vram().0);
    e.register_fn("hw_decodings", || {
        let s = crate::flutter_ffi::main_supported_hwdecodings().0;
        let v: HashMap<String, bool> = serde_json::from_str(&s).unwrap_or_default();
        let mut m = Map::new();
        m.insert("h264".into(), (*v.get("h264").unwrap_or(&false)).into());
        m.insert("h265".into(), (*v.get("h265").unwrap_or(&false)).into());
        m
    });
    e.register_fn("audio_inputs", || -> Array {
        crate::flutter_ffi::main_get_sound_inputs()
            .into_iter()
            .map(Dynamic::from)
            .collect()
    });
    e.register_fn("audio_loopback", || {
        crate::flutter_ffi::main_audio_support_loopback().0
    });
    e.register_fn("input_sources", || -> Array {
        #[cfg(not(any(target_os = "android", target_os = "ios")))]
        return pairs(crate::keyboard::input_source::get_supported_input_source());
        #[cfg(any(target_os = "android", target_os = "ios"))]
        return Array::new();
    });
    e.register_fn("privacy_mode_impls", || -> Array {
        pairs(
            crate::privacy_mode::get_supported_privacy_mode_impl()
                .into_iter()
                .map(|(a, b)| (a.to_owned(), b.to_owned()))
                .collect(),
        )
    });
    e
}

fn platform() -> &'static str {
    if cfg!(target_os = "windows") {
        "windows"
    } else if cfg!(target_os = "macos") {
        "macos"
    } else if cfg!(target_os = "linux") {
        "linux"
    } else {
        "other"
    }
}

/// Evaluates `expr` with the scope of `ctx_json` (see the module doc). Returns `{"ok": <value>}` or
/// `{"error": "<message>"}`.
pub fn eval(expr: &str, ctx_json: &str) -> String {
    let ctx: serde_json::Value = serde_json::from_str(ctx_json).unwrap_or(serde_json::Value::Null);
    let s = |k: &str| ctx.get(k).and_then(|v| v.as_str()).unwrap_or("").to_owned();
    let mut scope = Scope::new();
    scope.push_constant("platform", platform().to_owned());
    scope.push_constant("peer", s("peer"));
    scope.push_constant("value", s("value"));
    scope.push_constant(
        "in_session",
        ctx.get("in_session").and_then(|v| v.as_bool()).unwrap_or(false),
    );
    scope.push_constant(
        "display",
        ctx.get("display").and_then(|v| v.as_i64()).unwrap_or(-1),
    );
    let ast = {
        let mut cache = AST_CACHE.lock().unwrap();
        match cache.get(expr) {
            Some(a) => a.clone(),
            // Compiled without the scope: the cached program must read `value`, `peer`, ... at each evaluation, and
            // compiling with the scope would let the optimizer inline the first evaluation's constants.
            None => match ENGINE.compile(expr) {
                Ok(a) => {
                    cache.insert(expr.to_owned(), a.clone());
                    a
                }
                Err(e) => return serde_json::json!({ "error": e.to_string() }).to_string(),
            },
        }
    };
    match ENGINE.eval_ast_with_scope::<Dynamic>(&mut scope, &ast) {
        Ok(v) => match rhai::serde::from_dynamic::<serde_json::Value>(&v) {
            Ok(j) => serde_json::json!({ "ok": j }).to_string(),
            Err(e) => serde_json::json!({ "error": e.to_string() }).to_string(),
        },
        Err(e) => serde_json::json!({ "error": e.to_string() }).to_string(),
    }
}
