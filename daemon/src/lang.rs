//! Spanish or English wording for what the daemon shows by itself (toasts, tray menu).
//!
//! The Alero window writes the language it resolved ("es" or "en") as `lang` in `remote.json`; it is re-read when
//! that file changes. Without it (no window ever opened) the system language decides, and Spanish stays the default.

use std::path::PathBuf;
use std::sync::{Mutex, OnceLock};
use std::time::SystemTime;

static DATA: OnceLock<PathBuf> = OnceLock::new();
static CACHE: Mutex<(Option<SystemTime>, Option<bool>)> = Mutex::new((None, None));

/// Remembers where `remote.json` lives. Call once at start-up.
pub fn init(data: &std::path::Path) {
    let _ = DATA.set(data.to_path_buf());
}

fn from_file() -> Option<bool> {
    let path = DATA.get()?.join("remote.json");
    let mtime = std::fs::metadata(&path).and_then(|m| m.modified()).ok();
    let mut c = CACHE.lock().unwrap_or_else(|e| e.into_inner());
    if c.0 != mtime || mtime.is_none() {
        *c = (mtime, read_choice(&path));
    }
    c.1
}

/// The language written in `remote.json`: Some(true) for "es", Some(false) for "en".
fn read_choice(path: &std::path::Path) -> Option<bool> {
    std::fs::read_to_string(path)
        .ok()
        .and_then(|t| serde_json::from_str::<serde_json::Value>(&t).ok())
        .and_then(|v| match v["lang"].as_str() {
            Some("es") => Some(true),
            Some("en") => Some(false),
            _ => None,
        })
}

#[cfg(all(not(test), windows))]
/// Windows keeps no language in the environment: the user's display language decides. In a LANGID the low ten
/// bits are the primary language, and 0x0A is Spanish (any country).
fn from_system() -> Option<bool> {
    // SAFETY: no arguments, no pointers; it only reads the user's settings.
    let id = unsafe { windows::Win32::Globalization::GetUserDefaultUILanguage() };
    Some(id & 0x3ff == 0x0a)
}

#[cfg(all(not(test), not(windows)))]
/// `LANGUAGE`, `LC_ALL`, `LC_MESSAGES` and `LANG`, the first that is set: "es_PE.UTF-8" (or "es:en") is Spanish,
/// "C" and the rest are not.
fn from_system() -> Option<bool> {
    ["LANGUAGE", "LC_ALL", "LC_MESSAGES", "LANG"]
        .iter()
        .filter_map(|k| std::env::var(k).ok())
        .find(|v| !v.is_empty())
        .map(|v| v.to_ascii_lowercase().starts_with("es"))
}

pub fn spanish() -> bool {
    // Tests must not depend on the machine that runs them.
    #[cfg(test)]
    let system = None;
    #[cfg(not(test))]
    let system = from_system();
    from_file().or(system).unwrap_or(true)
}

pub fn t(es: &'static str, en: &'static str) -> &'static str {
    if spanish() { es } else { en }
}

#[cfg(test)]
mod tests {
    use super::*;

    // No init() here: DATA is process-wide, and pointing it at an English file flipped the wording of every
    // test rendering in parallel (a pixel comparison in the island saw Spanish before and English after).
    #[test]
    fn the_window_choice_is_read_from_remote_json() {
        let dir = std::env::temp_dir().join(format!("alero-lang-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("remote.json");
        std::fs::write(&path, r#"{"lang":"en"}"#).unwrap();
        assert_eq!(read_choice(&path), Some(false));
        std::fs::write(&path, r#"{"lang":"es"}"#).unwrap();
        assert_eq!(read_choice(&path), Some(true));
        std::fs::write(&path, r#"{"lang":"fr"}"#).unwrap();
        assert_eq!(read_choice(&path), None);
        let _ = std::fs::remove_dir_all(&dir);
        assert_eq!(read_choice(&path), None);
        assert!(spanish(), "tests never see a window choice nor the system language");
    }
}
