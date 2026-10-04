//! The ad blocker behind Mizu: a small C surface over Brave's adblock-rust.
//!
//! WebKit does not let an app see or cancel a page's requests, so network
//! filters are translated into WebKit content rules (`mizu_content_rules`) and
//! WebKit does the blocking itself. Everything WebKit's rules cannot express
//! (element hiding by class and id, scriptlets) is answered by
//! an `Engine` kept in memory.
//!
//! Strings handed out are owned by the caller and go back through
//! `mizu_string_free`; byte buffers through `mizu_bytes_free`.

use adblock::content_blocking::CbType;
use adblock::lists::{FilterSet, ParseOptions, RuleTypes};
use adblock::resources::Resource;
use adblock::Engine;
use serde::Deserialize;
use std::collections::HashSet;
use std::ffi::{c_char, CStr, CString};
use std::{ptr, slice};

pub struct MizuEngine(Engine);

unsafe fn text<'a>(data: *const u8, len: usize) -> Option<&'a str> {
    if data.is_null() {
        return None;
    }
    std::str::from_utf8(slice::from_raw_parts(data, len)).ok()
}

unsafe fn cstr<'a>(s: *const c_char) -> Option<&'a str> {
    if s.is_null() {
        return None;
    }
    CStr::from_ptr(s).to_str().ok()
}

fn out(s: String) -> *mut c_char {
    CString::new(s).map(CString::into_raw).unwrap_or(ptr::null_mut())
}

/// Translates the network filters of a filter list into WebKit content rules.
///
/// WebKit caps the size of a rule list, so the rules come back in chunks of at
/// most `chunk` blocking rules: one JSON array per line. An
/// `ignore-previous-rules` exception only undoes rules of the list it is
/// compiled into, so every chunk ends with all of the exceptions.
/// Returns null on failure.
#[no_mangle]
pub unsafe extern "C" fn mizu_content_rules(filters: *const u8, len: usize, chunk: usize) -> *mut c_char {
    let Some(filters) = text(filters, len) else {
        return ptr::null_mut();
    };
    let mut set = FilterSet::new(true);
    set.add_filter_list(
        filters.to_string(),
        ParseOptions {
            rule_types: RuleTypes::NetworkOnly,
            ..ParseOptions::default()
        },
    );
    let Ok((converted, _)) = set.into_content_blocking() else {
        return ptr::null_mut();
    };
    let (mut rules, mut exceptions) = (Vec::new(), Vec::new());
    for rule in converted {
        let Ok(json) = serde_json::to_string(&rule) else {
            continue;
        };
        if matches!(rule.action.typ, CbType::IgnorePreviousRules) {
            exceptions.push(json);
        } else {
            rules.push(json);
        }
    }
    let exceptions = exceptions.join(",");
    let mut result = String::new();
    for part in rules.chunks(chunk.max(1)) {
        result.push('[');
        result.push_str(&part.join(","));
        if !exceptions.is_empty() {
            result.push(',');
            result.push_str(&exceptions);
        }
        result.push_str("]\n");
    }
    out(result)
}

/// Builds an engine from filter list text. It keeps only the cosmetic rules:
/// the network rules are WebKit's to enforce, and leaving them out makes the
/// engine a fraction of the size in memory.
#[no_mangle]
pub unsafe extern "C" fn mizu_engine_new(filters: *const u8, len: usize) -> *mut MizuEngine {
    let Some(filters) = text(filters, len) else {
        return ptr::null_mut();
    };
    let mut set = FilterSet::new(false);
    set.add_filter_list(
        filters.to_string(),
        ParseOptions {
            rule_types: RuleTypes::CosmeticOnly,
            ..ParseOptions::default()
        },
    );
    Box::into_raw(Box::new(MizuEngine(Engine::new_with_filter_set(set))))
}

/// Restores an engine saved with `mizu_engine_serialize`. Null when the data
/// is from another version of the format; build from the lists again then.
#[no_mangle]
pub unsafe extern "C" fn mizu_engine_load(data: *const u8, len: usize) -> *mut MizuEngine {
    if data.is_null() {
        return ptr::null_mut();
    }
    let mut engine = Engine::default();
    match engine.deserialize(slice::from_raw_parts(data, len)) {
        Ok(()) => Box::into_raw(Box::new(MizuEngine(engine))),
        Err(_) => ptr::null_mut(),
    }
}

#[no_mangle]
pub unsafe extern "C" fn mizu_engine_serialize(engine: *const MizuEngine, len: *mut usize) -> *mut u8 {
    let Some(engine) = engine.as_ref() else {
        return ptr::null_mut();
    };
    let mut bytes = engine.0.serialize().into_boxed_slice();
    *len = bytes.len();
    let data = bytes.as_mut_ptr();
    std::mem::forget(bytes);
    data
}

/// Gives the engine its scriptlets and redirect resources: the JSON array
/// published by brave/adblock-resources. Returns how many were loaded.
#[no_mangle]
pub unsafe extern "C" fn mizu_engine_use_resources(engine: *mut MizuEngine, json: *const u8, len: usize) -> usize {
    let (Some(engine), Some(json)) = (engine.as_mut(), text(json, len)) else {
        return 0;
    };
    let Ok(resources) = serde_json::from_str::<Vec<Resource>>(json) else {
        return 0;
    };
    let count = resources.len();
    engine.0.use_resources(resources);
    count
}

/// What to hide and inject on a page, as JSON: `hide_selectors`,
/// `procedural_actions`, `exceptions`, `injected_script`, `generichide`.
#[no_mangle]
pub unsafe extern "C" fn mizu_engine_cosmetics(engine: *const MizuEngine, url: *const c_char) -> *mut c_char {
    let (Some(engine), Some(url)) = (engine.as_ref(), cstr(url)) else {
        return ptr::null_mut();
    };
    serde_json::to_string(&engine.0.url_cosmetic_resources(url)).map(out).unwrap_or(ptr::null_mut())
}

#[derive(Deserialize)]
struct Seen {
    #[serde(default)]
    classes: Vec<String>,
    #[serde(default)]
    ids: Vec<String>,
    #[serde(default)]
    exceptions: HashSet<String>,
}

/// The generic hiding selectors that apply to the classes and ids a page has
/// reported. Takes JSON `{"classes": [], "ids": [], "exceptions": []}` and
/// returns a JSON array of selectors.
#[no_mangle]
pub unsafe extern "C" fn mizu_engine_hidden_selectors(engine: *const MizuEngine, seen: *const c_char) -> *mut c_char {
    let (Some(engine), Some(seen)) = (engine.as_ref(), cstr(seen)) else {
        return ptr::null_mut();
    };
    let Ok(seen) = serde_json::from_str::<Seen>(seen) else {
        return ptr::null_mut();
    };
    let selectors = engine.0.hidden_class_id_selectors(&seen.classes, &seen.ids, &seen.exceptions);
    serde_json::to_string(&selectors).map(out).unwrap_or(ptr::null_mut())
}

#[no_mangle]
pub unsafe extern "C" fn mizu_engine_free(engine: *mut MizuEngine) {
    if !engine.is_null() {
        drop(Box::from_raw(engine));
    }
}

#[no_mangle]
pub unsafe extern "C" fn mizu_string_free(s: *mut c_char) {
    if !s.is_null() {
        drop(CString::from_raw(s));
    }
}

#[no_mangle]
pub unsafe extern "C" fn mizu_bytes_free(data: *mut u8, len: usize) {
    if !data.is_null() {
        drop(Box::from_raw(ptr::slice_from_raw_parts_mut(data, len)));
    }
}
