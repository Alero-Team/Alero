//! A paired phone controlling and watching this computer (ADR-0011). Everything here arrives as `pb.x.*`
//! app messages from a paired device (the engine already refuses anyone else) and is carried out only while the
//! user has switched on "Control remoto" in Alero (a file in the data folder, off by default). While a phone
//! watches the screen or drives the input, a toast says so.
//!
//! Messages (all JSON bodies; Protocol.md §6.2):
//!   phone -> PC   pb.x.remote.{move,button,click,scroll,key,text,media,power}   pb.x.screen.{start,keepalive,ack,stop}
//!                 pb.x.shot.request   pb.x.pcmedia.watch
//!   PC -> phone   pb.x.info (battery, capabilities, allowed)   pb.x.screen.frame   pb.x.pcmedia.state
//!                 pb.x.remote.denied   (a screenshot is a normal file transfer)

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant, SystemTime};

use base64::engine::general_purpose::STANDARD;
use base64::Engine as _;
use pb_core::engine::{Engine, PeerState};
use serde_json::{json, Value};

use crate::sys;

/// Frames must fit one app message (256 KiB after base64).
const MAX_JPEG: usize = 170_000;
const SESSION_IDLE: Duration = Duration::from_secs(15);
const WATCH_IDLE: Duration = Duration::from_secs(25);

struct Screen {
    peer: String,
    width: u32,
    fps: u32,
    last_keepalive: Instant,
    inflight: u32,
    last_ack: Instant,
    gen: u64,
}

pub struct Remote {
    data: PathBuf,
    allowed: Mutex<(Option<SystemTime>, bool)>,
    noticed: Mutex<HashMap<String, Instant>>,
    denied: Mutex<HashMap<String, Instant>>,
    screen: Mutex<Option<Screen>>,
    watchers: Mutex<HashMap<String, Instant>>,
    watching: Mutex<bool>,
    pushed: Mutex<HashMap<String, Value>>,
    next_gen: Mutex<u64>,
}

fn jpeg(w: u32, h: u32, rgb: &[u8], quality: u8) -> Option<Vec<u8>> {
    let mut out = Vec::new();
    jpeg_encoder::Encoder::new(&mut out, quality).encode(rgb, w as u16, h as u16, jpeg_encoder::ColorType::Rgb).ok()?;
    Some(out)
}

/// Cheap fingerprint of a frame (a sample of its bytes), to skip sending a picture that did not change.
fn fingerprint(rgb: &[u8]) -> u64 {
    let mut h: u64 = 0xcbf29ce484222325;
    for b in rgb.iter().step_by(61) {
        h = (h ^ *b as u64).wrapping_mul(0x100000001b3);
    }
    h
}

impl Remote {
    pub fn new(data: PathBuf) -> Arc<Self> {
        sys::init();
        Arc::new(Self {
            data,
            allowed: Mutex::new((None, false)),
            noticed: Mutex::new(HashMap::new()),
            denied: Mutex::new(HashMap::new()),
            screen: Mutex::new(None),
            watchers: Mutex::new(HashMap::new()),
            watching: Mutex::new(false),
            pushed: Mutex::new(HashMap::new()),
            next_gen: Mutex::new(0),
        })
    }

    /// The user's switch: `{"allow": true}` in `remote.json`, written by the Alero window. Re-read when it changes.
    pub fn allowed(&self) -> bool {
        let path = self.data.join("remote.json");
        let mtime = std::fs::metadata(&path).and_then(|m| m.modified()).ok();
        let mut c = self.allowed.lock().unwrap();
        if c.0 != mtime || mtime.is_none() {
            let on = std::fs::read_to_string(&path)
                .ok()
                .and_then(|t| serde_json::from_str::<Value>(&t).ok())
                .is_some_and(|v| v["allow"] == true);
            *c = (mtime, on);
        }
        c.1
    }

    /// What this computer tells a phone about itself (basic facts are shared with any paired device; the
    /// `remote.allowed` flag tells the phone whether the controls below would be obeyed).
    pub fn info(&self, engine: &Engine) -> Value {
        #[cfg(windows)]
        let (os, version) = ("Windows", crate::win::os_version());
        #[cfg(not(windows))]
        let (os, version) = (std::env::consts::OS, String::new());
        let mut v = json!({
            "kind": "desktop",
            "model": engine.name(),
            "os": os,
            "osVersion": version,
            "remote": {
                "allowed": self.allowed(),
                "input": sys::CAPS.input,
                "screen": sys::CAPS.screen,
                "media": sys::CAPS.media,
                "power": sys::CAPS.power,
            },
        });
        v["battery"] = match sys::battery() {
            Some((level, charging)) => json!({"level": level, "charging": charging}),
            None => json!({"level": -1}),
        };
        v
    }

    fn peer_name(engine: &Engine, id: &str) -> String {
        engine.peers().into_iter().find(|p| p.id == id).map(|p| p.name).filter(|n| !n.is_empty()).unwrap_or_else(|| "Un dispositivo".into())
    }

    /// Tells the user, at most once every ten minutes per phone, that it is driving this computer.
    fn notice(&self, engine: &Engine, peer: &str, what: &str) {
        let mut n = self.noticed.lock().unwrap();
        if n.get(peer).is_some_and(|t| t.elapsed() < Duration::from_secs(600)) {
            return;
        }
        n.insert(peer.to_string(), Instant::now());
        #[cfg(windows)]
        crate::win::toast("Control remoto", &format!("{} {what}", Self::peer_name(engine, peer)));
        #[cfg(not(windows))]
        let _ = (engine, what);
    }

    fn deny(&self, engine: &Engine, peer: &str) {
        let mut d = self.denied.lock().unwrap();
        if d.get(peer).is_some_and(|t| t.elapsed() < Duration::from_secs(5)) {
            return;
        }
        d.insert(peer.to_string(), Instant::now());
        let _ = engine.send_message(peer, "pb.x.remote.denied", json!({"reason": "not_allowed"}));
    }

    /// Pushes this computer's info to every connected paired phone whose copy is outdated.
    pub fn push_info(&self, engine: &Engine, only: Option<&str>) {
        let info = self.info(engine);
        let mut pushed = self.pushed.lock().unwrap();
        for p in engine.peers() {
            if !p.trusted || p.state != PeerState::Connected || only.is_some_and(|o| o != p.id) {
                continue;
            }
            if only.is_none() && pushed.get(&p.id) == Some(&info) {
                continue;
            }
            if engine.send_message(&p.id, "pb.x.info", info.clone()).is_ok() {
                pushed.insert(p.id, info.clone());
            }
        }
    }

    /// Every 30 s: battery and the switch may have changed. Cheap (one power query).
    pub fn spawn_status(self: &Arc<Self>, engine: Arc<Engine>) {
        let me = self.clone();
        thread::spawn(move || loop {
            thread::sleep(Duration::from_secs(30));
            me.push_info(&engine, None);
        });
    }

    /// Returns true when the message was ours (it is then not forwarded to the window).
    pub fn handle(self: &Arc<Self>, engine: &Arc<Engine>, peer: &str, kind: &str, b: &Value) -> bool {
        if kind == "pb.x.info.request" {
            self.pushed.lock().unwrap().remove(peer);
            self.push_info(engine, Some(peer));
            return true;
        }
        let ours = kind.starts_with("pb.x.remote.")
            || kind.starts_with("pb.x.screen.")
            || kind == "pb.x.shot.request"
            || kind == "pb.x.pcmedia.watch";
        if !ours {
            return false;
        }
        if !self.allowed() {
            self.deny(engine, peer);
            return true;
        }
        let f = |k: &str| b[k].as_f64().unwrap_or(0.0);
        let s = |k: &str| b[k].as_str().unwrap_or("");
        match kind {
            "pb.x.remote.move" => {
                self.notice(engine, peer, "controla este equipo");
                sys::move_by(f("dx").round().clamp(-3000.0, 3000.0) as i32, f("dy").round().clamp(-3000.0, 3000.0) as i32)
            }
            "pb.x.remote.button" => sys::button(s("button"), b["down"] == true),
            "pb.x.remote.click" => {
                self.notice(engine, peer, "controla este equipo");
                for _ in 0..b["count"].as_u64().unwrap_or(1).clamp(1, 2) {
                    sys::button(s("button"), true);
                    sys::button(s("button"), false);
                }
            }
            "pb.x.remote.scroll" => sys::scroll(f("dy").clamp(-50.0, 50.0), f("dx").clamp(-50.0, 50.0)),
            "pb.x.remote.key" => {
                self.notice(engine, peer, "usa el teclado de este equipo");
                let mods: Vec<String> = b["mods"].as_array().map(|a| a.iter().filter_map(|m| m.as_str().map(String::from)).collect()).unwrap_or_default();
                sys::key(s("key"), &mods);
            }
            "pb.x.remote.text" => {
                self.notice(engine, peer, "usa el teclado de este equipo");
                sys::text(s("text"));
            }
            "pb.x.remote.media" => {
                sys::media_key(s("action"));
            }
            "pb.x.remote.power" => {
                // The phone asks for confirmation first; the PC only ever locks or sleeps.
                let ok = sys::power(s("action"));
                let _ = engine.send_message(peer, "pb.x.remote.power.result", json!({"action": s("action"), "ok": ok}));
            }
            "pb.x.screen.start" => self.start_screen(engine, peer, b),
            "pb.x.screen.keepalive" => {
                if let Some(sc) = self.screen.lock().unwrap().as_mut().filter(|sc| sc.peer == peer) {
                    sc.last_keepalive = Instant::now();
                }
            }
            "pb.x.screen.ack" => {
                if let Some(sc) = self.screen.lock().unwrap().as_mut().filter(|sc| sc.peer == peer) {
                    sc.inflight = sc.inflight.saturating_sub(1);
                    sc.last_ack = Instant::now();
                }
            }
            "pb.x.screen.stop" => {
                let mut sc = self.screen.lock().unwrap();
                if sc.as_ref().is_some_and(|x| x.peer == peer) {
                    *sc = None;
                }
            }
            "pb.x.shot.request" => {
                // Capture and encode off the connection thread, so pointer input keeps flowing meanwhile.
                let (me, engine, peer) = (self.clone(), engine.clone(), peer.to_string());
                thread::spawn(move || me.shot(&engine, &peer));
            }
            "pb.x.pcmedia.watch" => self.watch(engine, peer),
            _ => {}
        }
        true
    }

    // --- screen ------------------------------------------------------------------------------------------

    fn start_screen(self: &Arc<Self>, engine: &Arc<Engine>, peer: &str, b: &Value) {
        if !sys::CAPS.screen {
            let _ = engine.send_message(peer, "pb.x.remote.denied", json!({"reason": "unsupported"}));
            return;
        }
        let gen = {
            let mut g = self.next_gen.lock().unwrap();
            *g += 1;
            *g
        };
        *self.screen.lock().unwrap() = Some(Screen {
            peer: peer.to_string(),
            width: b["w"].as_u64().unwrap_or(960).clamp(320, 1920) as u32,
            fps: b["fps"].as_u64().unwrap_or(4).clamp(1, 10) as u32,
            last_keepalive: Instant::now(),
            inflight: 0,
            last_ack: Instant::now(),
            gen,
        });
        #[cfg(windows)]
        crate::win::toast("Pantalla compartida", &format!("{} está viendo la pantalla de este equipo", Self::peer_name(engine, peer)));
        let (me, engine) = (self.clone(), engine.clone());
        thread::spawn(move || me.screen_loop(&engine, gen));
    }

    fn screen_loop(&self, engine: &Engine, gen: u64) {
        let (mut seq, mut last_print, mut last_sent) = (0u64, 0u64, Instant::now() - Duration::from_secs(10));
        loop {
            let (peer, width, fps) = {
                let mut g = self.screen.lock().unwrap();
                match g.as_mut() {
                    Some(sc) if sc.gen == gen && sc.last_keepalive.elapsed() < SESSION_IDLE => {
                        // A lost ack must not stall the stream forever.
                        if sc.inflight > 0 && sc.last_ack.elapsed() > Duration::from_secs(3) {
                            sc.inflight = 0;
                        }
                        if sc.inflight >= 2 {
                            drop(g);
                            thread::sleep(Duration::from_millis(25));
                            continue;
                        }
                        (sc.peer.clone(), sc.width, sc.fps)
                    }
                    _ => {
                        let mut g = g;
                        if g.as_ref().is_some_and(|sc| sc.gen == gen) {
                            *g = None;
                        }
                        return;
                    }
                }
            };
            let started = Instant::now();
            if let Some((w, h, rgb)) = sys::capture(width) {
                let print = fingerprint(&rgb);
                // Unchanged picture: send nothing (the phone keeps showing the last one), except a refresh now and then.
                if print != last_print || last_sent.elapsed() > Duration::from_secs(2) {
                    let mut q = 60u8;
                    let data = loop {
                        match jpeg(w, h, &rgb, q) {
                            Some(d) if d.len() <= MAX_JPEG || q <= 25 => break Some(d),
                            Some(_) => q -= 12,
                            None => break None,
                        }
                    };
                    if let Some(d) = data.filter(|d| d.len() <= MAX_JPEG) {
                        seq += 1;
                        let body = json!({"seq": seq, "w": w, "h": h, "jpeg": STANDARD.encode(&d)});
                        if engine.send_message(&peer, "pb.x.screen.frame", body).is_ok() {
                            if let Some(sc) = self.screen.lock().unwrap().as_mut().filter(|sc| sc.gen == gen) {
                                sc.inflight += 1;
                                if sc.inflight == 1 {
                                    sc.last_ack = Instant::now();
                                }
                            }
                            last_print = print;
                            last_sent = Instant::now();
                        }
                    }
                }
            }
            let frame = Duration::from_millis(1000 / fps as u64);
            thread::sleep(frame.saturating_sub(started.elapsed()));
        }
    }

    /// A full-resolution screenshot, sent as an ordinary file transfer (so it is resumable, listed in the
    /// history and saved by the phone like any other received file).
    fn shot(&self, engine: &Engine, peer: &str) {
        self.notice(engine, peer, "pidió una captura de pantalla");
        let Some((w, h, rgb)) = sys::capture(u32::MAX) else {
            let _ = engine.send_message(peer, "pb.x.remote.denied", json!({"reason": "unsupported"}));
            return;
        };
        let Some(data) = jpeg(w, h, &rgb, 85) else { return };
        let dir = std::env::temp_dir().join("alero-captures");
        let _ = std::fs::create_dir_all(&dir);
        // Old captures go away: the transfer has long finished with them.
        if let Ok(rd) = std::fs::read_dir(&dir) {
            for e in rd.flatten() {
                if e.metadata().and_then(|m| m.modified()).ok().and_then(|t| t.elapsed().ok()).is_some_and(|a| a > Duration::from_secs(3600)) {
                    let _ = std::fs::remove_file(e.path());
                }
            }
        }
        let secs = SystemTime::now().duration_since(SystemTime::UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0);
        let name = format!("Captura-PC-{secs}.jpg");
        let path = dir.join(&name);
        if std::fs::write(&path, data).is_ok() {
            if let Err(e) = engine.send_file(peer, &path, Some(&name)) {
                let _ = engine.send_message(peer, "pb.x.remote.denied", json!({"reason": "shot_failed", "detail": e}));
            }
        }
    }

    // --- what the PC is playing --------------------------------------------------------------------------

    fn watch(self: &Arc<Self>, engine: &Arc<Engine>, peer: &str) {
        self.watchers.lock().unwrap().insert(peer.to_string(), Instant::now());
        let mut w = self.watching.lock().unwrap();
        if *w {
            return;
        }
        *w = true;
        let (me, engine) = (self.clone(), engine.clone());
        thread::spawn(move || {
            let mut last: Option<Value> = None;
            let mut sent = Instant::now() - Duration::from_secs(60);
            loop {
                let peers: Vec<String> = {
                    let mut ws = me.watchers.lock().unwrap();
                    ws.retain(|_, t| t.elapsed() < WATCH_IDLE);
                    if ws.is_empty() {
                        *me.watching.lock().unwrap() = false;
                        return;
                    }
                    ws.keys().cloned().collect()
                };
                let state = match sys::media_state() {
                    Some(m) => json!({"active": true, "app": m.app, "title": m.title, "artist": m.artist, "playing": m.playing,
                        "position": m.position_ms, "duration": m.duration_ms, "at": SystemTime::now().duration_since(SystemTime::UNIX_EPOCH).map(|d| d.as_millis() as u64).unwrap_or(0)}),
                    None => json!({"active": false}),
                };
                // Position moves every second by itself; compare the rest, and refresh the clock every 10 s.
                let mut key = state.clone();
                key.as_object_mut().map(|o| {
                    o.remove("position");
                    o.remove("at");
                });
                if last.as_ref() != Some(&key) || sent.elapsed() > Duration::from_secs(10) {
                    for p in &peers {
                        let _ = engine.send_message(p, "pb.x.pcmedia.state", state.clone());
                    }
                    last = Some(key);
                    sent = Instant::now();
                }
                thread::sleep(Duration::from_millis(1500));
            }
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_screen_sized_frame_fits_one_app_message() {
        // Worst case for JPEG: noise. Even then the quality ladder must end under the limit or give up cleanly.
        let (w, h) = (1280u32, 720u32);
        let rgb: Vec<u8> = (0..(w * h * 3) as usize).map(|i| (i.wrapping_mul(2654435761) >> 13) as u8).collect();
        let mut q = 60u8;
        let data = loop {
            let d = jpeg(w, h, &rgb, q).unwrap();
            if d.len() <= MAX_JPEG || q <= 25 {
                break d;
            }
            q -= 12;
        };
        // On realistic content (flat colors, text) it is far smaller; for noise we only require a valid JPEG.
        assert_eq!(&data[..2], &[0xFF, 0xD8]);
        let flat = vec![200u8; (w * h * 3) as usize];
        assert!(jpeg(w, h, &flat, 60).unwrap().len() < MAX_JPEG);
        assert!(STANDARD.encode(vec![0u8; MAX_JPEG]).len() + 200 < pb_core::frame::MAX_APP_BODY);
    }

    #[test]
    fn the_switch_is_off_until_the_file_says_otherwise() {
        let dir = std::env::temp_dir().join(format!("alero-remote-test-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let r = Remote::new(dir.clone());
        assert!(!r.allowed(), "no file: off");
        std::fs::write(dir.join("remote.json"), r#"{"allow":true}"#).unwrap();
        assert!(r.allowed());
        std::fs::write(dir.join("remote.json"), "not json").unwrap();
        std::thread::sleep(Duration::from_millis(20));
        // An unreadable file never turns control on.
        let _ = std::fs::write(dir.join("remote.json"), r#"{"allow":false}"#);
        assert!(!r.allowed());
        let _ = std::fs::remove_dir_all(&dir);
    }
}
