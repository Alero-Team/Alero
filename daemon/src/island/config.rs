//! Alero Island settings. The Flutter window writes `island.json` in the data dir; the daemon re-reads it when the
//! file changes, so a switch in Ajustes takes effect at once without restarting anything.

use std::path::{Path, PathBuf};
use std::time::SystemTime;

use serde::{Deserialize, Serialize};

pub const FILE: &str = "island.json";

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
#[serde(default)]
pub struct Modules {
    pub player: bool,
    pub send: bool,
    pub incoming: bool,
    pub notifications: bool,
    pub call: bool,
    pub clipboard: bool,
    pub controls: bool,
    pub status: bool,
}

impl Default for Modules {
    fn default() -> Self {
        Self { player: true, send: true, incoming: true, notifications: true, call: true, clipboard: true, controls: true, status: true }
    }
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
#[serde(default)]
pub struct IslandConfig {
    pub enabled: bool,
    /// -1: the monitor under the pointer, 0: the primary one, n: the n-th monitor of the system's list.
    pub monitor: i32,
    pub hide_fullscreen: bool,
    /// Width of the trigger zone on the top edge, in px (100..400).
    pub zone_width: u32,
    pub open_delay_ms: u32,
    pub close_delay_ms: u32,
    /// Horizontal shift from the centre of the monitor, in px (-300..300).
    pub offset_x: i32,
    /// "ctrl+alt+i": opens the island without the mouse (Windows). Empty: none.
    pub hotkey: String,
    /// Size of everything, in percent (75..150).
    pub scale: u32,
    pub top_margin: u32,
    /// "normal" (iPhone-like spring with a little bounce), "soft" (less bounce) or "off".
    pub animation: String,
    pub respect_reduce_motion: bool,
    /// Background, "#RRGGBB". Pure black (OLED) by default.
    pub color: String,
    /// Progress bars, active toggles and badges, "#RRGGBB".
    pub accent: String,
    pub modules: Modules,
    pub auto_expand: bool,
    pub event_secs: u32,
    pub sound: bool,
}

impl Default for IslandConfig {
    fn default() -> Self {
        Self {
            enabled: true,
            monitor: -1,
            hide_fullscreen: true,
            zone_width: 220,
            open_delay_ms: 120,
            close_delay_ms: 450,
            offset_x: 0,
            hotkey: String::new(),
            scale: 100,
            top_margin: 8,
            animation: "normal".into(),
            respect_reduce_motion: true,
            color: "#000000".into(),
            accent: "#8AB4F8".into(),
            modules: Modules::default(),
            auto_expand: true,
            event_secs: 6,
            sound: false,
        }
    }
}

impl IslandConfig {
    /// Brings every field inside the range the UI offers, so a hand-edited file cannot break the layout.
    pub fn clamped(mut self) -> Self {
        self.zone_width = self.zone_width.clamp(100, 400);
        self.open_delay_ms = self.open_delay_ms.min(500);
        self.close_delay_ms = self.close_delay_ms.min(1000);
        self.offset_x = self.offset_x.clamp(-300, 300);
        self.scale = self.scale.clamp(75, 150);
        self.top_margin = self.top_margin.min(40);
        self.event_secs = self.event_secs.clamp(3, 15);
        if !matches!(self.animation.as_str(), "normal" | "soft" | "off") {
            self.animation = "normal".into();
        }
        if parse_hex(&self.color).is_none() {
            self.color = "#000000".into();
        }
        if parse_hex(&self.accent).is_none() {
            self.accent = "#8AB4F8".into();
        }
        self
    }

    pub fn background(&self) -> [u8; 3] {
        parse_hex(&self.color).unwrap_or([0, 0, 0])
    }

    pub fn accent_rgb(&self) -> [u8; 3] {
        parse_hex(&self.accent).unwrap_or([0x8A, 0xB4, 0xF8])
    }
}

/// "#RRGGBB" (the "#" is optional).
pub fn parse_hex(s: &str) -> Option<[u8; 3]> {
    let h = s.trim().trim_start_matches('#');
    if h.len() != 6 || !h.is_ascii() {
        return None;
    }
    let v = u32::from_str_radix(h, 16).ok()?;
    Some([(v >> 16) as u8, (v >> 8) as u8, v as u8])
}

/// Relative luminance in 0..1 (sRGB, no gamma: enough to pick light or dark text).
pub fn luma(c: [u8; 3]) -> f32 {
    (0.2126 * c[0] as f32 + 0.7152 * c[1] as f32 + 0.0722 * c[2] as f32) / 255.0
}

/// The settings file, re-read only when it changed.
pub struct Watcher {
    path: PathBuf,
    seen: Option<SystemTime>,
    pub current: IslandConfig,
}

impl Watcher {
    pub fn new(data: &Path) -> Self {
        let mut w = Self { path: data.join(FILE), seen: None, current: IslandConfig::default() };
        w.poll();
        w
    }

    /// True when the settings changed.
    pub fn poll(&mut self) -> bool {
        let mtime = std::fs::metadata(&self.path).and_then(|m| m.modified()).ok();
        if mtime == self.seen {
            return false;
        }
        self.seen = mtime;
        let next = match mtime {
            // The file was deleted: back to the defaults.
            None => IslandConfig::default(),
            Some(_) => match std::fs::read_to_string(&self.path).ok().and_then(|t| serde_json::from_str::<IslandConfig>(&t).ok()) {
                Some(c) => c.clamped(),
                // Half-written or invalid: keep what we had and look again at the next change.
                None => return false,
            },
        };
        let changed = next != self.current;
        self.current = next;
        changed
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_empty_file_gives_the_defaults() {
        let c: IslandConfig = serde_json::from_str("{}").unwrap();
        assert_eq!(c, IslandConfig::default());
        assert_eq!(c.background(), [0, 0, 0]);
    }

    #[test]
    fn partial_files_keep_the_other_defaults() {
        let c: IslandConfig = serde_json::from_str(r##"{"scale":120,"modules":{"clipboard":false},"color":"#101820"}"##).unwrap();
        assert_eq!(c.scale, 120);
        assert!(!c.modules.clipboard && c.modules.player);
        assert_eq!(c.background(), [0x10, 0x18, 0x20]);
    }

    #[test]
    fn out_of_range_values_are_pulled_back() {
        let c: IslandConfig = serde_json::from_str(r##"{"scale":900,"zone_width":1,"animation":"wild","color":"nope","event_secs":0}"##).unwrap();
        let c = c.clamped();
        assert_eq!((c.scale, c.zone_width, c.event_secs), (150, 100, 3));
        assert_eq!(c.animation, "normal");
        assert_eq!(c.color, "#000000");
    }

    #[test]
    fn hex_parsing() {
        assert_eq!(parse_hex("#FF8000"), Some([255, 128, 0]));
        assert_eq!(parse_hex("ff8000"), Some([255, 128, 0]));
        assert_eq!(parse_hex("#fff"), None);
        assert_eq!(parse_hex("#ggggggg"), None);
    }

    #[test]
    fn watcher_reloads_only_on_change() {
        let dir = std::env::temp_dir().join(format!("alero-island-cfg-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let _ = std::fs::remove_file(dir.join(FILE));
        let mut w = Watcher::new(&dir);
        assert!(w.current.enabled);
        assert!(!w.poll());
        std::fs::write(dir.join(FILE), r#"{"enabled":false}"#).unwrap();
        assert!(w.poll());
        assert!(!w.current.enabled);
        assert!(!w.poll());
        let _ = std::fs::remove_dir_all(&dir);
    }
}
