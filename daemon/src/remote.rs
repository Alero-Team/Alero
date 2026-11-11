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
    monitor: usize,
    /// The viewer draws the pointer itself from `pb.x.screen.cursor`, so pictures go without it.
    cursor: bool,
    last_keepalive: Instant,
    inflight: u32,
    last_ack: Instant,
    gen: u64,
}

pub struct Remote {
    data: PathBuf,
    device: Value,
    allowed: Mutex<(Option<SystemTime>, bool)>,
    noticed: Mutex<HashMap<String, Instant>>,
    denied: Mutex<HashMap<String, Instant>>,
    screen: Mutex<Option<Screen>>,
    watchers: Mutex<HashMap<String, Instant>>,
    watching: Mutex<bool>,
    pushed: Mutex<HashMap<String, Value>>,
    next_gen: Mutex<u64>,
    held: Mutex<HashMap<(String, String), Instant>>,
}

fn jpeg(w: u32, h: u32, bgra: &[u8], quality: u8) -> Option<Vec<u8>> {
    let mut out = Vec::new();
    jpeg_encoder::Encoder::new(&mut out, quality).encode(bgra, w as u16, h as u16, jpeg_encoder::ColorType::Bgra).ok()?;
    Some(out)
}

/// Cheap fingerprint of a frame (a sample of its bytes), to skip sending a picture that did not change.
fn fingerprint(rgb: &[u8]) -> u64 {
    let mut h: u64 = 0xcbf29ce484222325;
    for b in rgb.iter().step_by(83) {
        h = (h ^ *b as u64).wrapping_mul(0x100000001b3);
    }
    h
}

impl Remote {
    pub fn new(data: PathBuf) -> Arc<Self> {
        sys::init();
        Arc::new(Self {
            data,
            device: sys::device_metadata(),
            allowed: Mutex::new((None, false)),
            noticed: Mutex::new(HashMap::new()),
            denied: Mutex::new(HashMap::new()),
            screen: Mutex::new(None),
            watchers: Mutex::new(HashMap::new()),
            watching: Mutex::new(false),
            pushed: Mutex::new(HashMap::new()),
            next_gen: Mutex::new(0),
            held: Mutex::new(HashMap::new()),
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
        let (w, h) = sys::screen_size();
        let name = engine.name();
        let mut v = json!({
            "kind": "desktop",
            "model": self.device["model"].as_str().filter(|m| !m.is_empty()).unwrap_or(name.as_str()),
            "manufacturer": self.device["manufacturer"],
            "product": self.device["product"],
            "screen": {"w": w, "h": h},
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
        if self.device["product"] == "83FS" {
            v["screen"]["bodyWidthMm"] = json!(359.2);
            v["screen"]["bodyHeightMm"] = json!(235.8);
            v["screen"]["depthMm"] = json!(19.9);
        }
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

    fn deny(&self, engine: &Engine, peer: &str, reason: &str) {
        let mut d = self.denied.lock().unwrap();
        let key = format!("{peer}/{reason}");
        // A UAC prompt or a locked screen can last minutes: remind rarely.
        let every = Duration::from_secs(if reason == "secure_desktop" { 20 } else { 5 });
        if d.get(&key).is_some_and(|t| t.elapsed() < every) {
            return;
        }
        d.insert(key, Instant::now());
        let _ = engine.send_message(peer, "pb.x.remote.denied", json!({"reason": reason}));
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
                if let Some(jpeg) = self.device["stockJpeg"].as_str().filter(|s| !s.is_empty()) {
                    let _ = engine.send_message(&p.id, "pb.x.wallpaper", json!({"jpeg": jpeg}));
                }
                pushed.insert(p.id, info.clone());
            }
        }
    }

    /// Every 30 s: battery and the switch may have changed. Cheap (one power query).
    pub fn spawn_status(self: &Arc<Self>, engine: Arc<Engine>) {
        let guard = self.clone();
        let owner = engine.clone();
        thread::spawn(move || loop {
            thread::sleep(Duration::from_secs(1));
            let online: Vec<_> = owner.peers().into_iter().filter(|p| p.trusted && p.state == PeerState::Connected).map(|p| p.id).collect();
            let allowed = guard.allowed();
            guard.held.lock().unwrap().retain(|(peer, button), at| {
                let keep = allowed && online.contains(peer) && at.elapsed() < Duration::from_secs(8);
                if !keep { sys::button(button, false); }
                keep
            });
        });
        let me = self.clone();
        thread::spawn(move || loop {
            thread::sleep(Duration::from_secs(30));
            me.push_info(&engine, None);
        });
    }

    /// Returns true when the message was ours (it is then not forwarded to the window).
    pub fn handle(self: &Arc<Self>, engine: &Arc<Engine>, peer: &str, kind: &str, b: &Value) -> bool {
        if kind.starts_with("pb.x.pcfs.") {
            return crate::pc_files::handle(engine, peer, kind, b, &self.data);
        }
        if kind == "pb.x.info.request" {
            self.pushed.lock().unwrap().remove(peer);
            self.push_info(engine, Some(peer));
            return true;
        }
        if kind == "pb.x.pcmedia.unwatch" {
            self.watchers.lock().unwrap().remove(peer);
            return true;
        }
        let ours = kind.starts_with("pb.x.remote.")
            || kind.starts_with("pb.x.screen.")
            || kind == "pb.x.shot.request"
            || kind == "pb.x.pcmedia.watch";
        if !ours {
            return false;
        }
        // As pc_files: input and the screen only for a phone that is paired and connected right now.
        if !engine.peers().iter().any(|p| p.id == peer && p.trusted && p.state == PeerState::Connected) {
            return true;
        }
        if !self.allowed() {
            self.deny(engine, peer, "not_allowed");
            return true;
        }
        if kind.starts_with("pb.x.remote.") && kind != "pb.x.remote.keepalive" && sys::secure_desktop() {
            // A UAC prompt: Windows drops our input until the user answers it on the computer. Say so.
            self.deny(engine, peer, "secure_desktop");
        }
        let f = |k: &str| b[k].as_f64().unwrap_or(0.0);
        let s = |k: &str| b[k].as_str().unwrap_or("");
        match kind {
            "pb.x.remote.move" => {
                self.notice(engine, peer, "controla este equipo");
                sys::move_by(f("dx").round().clamp(-3000.0, 3000.0) as i32, f("dy").round().clamp(-3000.0, 3000.0) as i32)
            }
            "pb.x.remote.keepalive" => {
                for ((id, _), at) in self.held.lock().unwrap().iter_mut() {
                    if id == peer { *at = Instant::now(); }
                }
            }
            "pb.x.remote.button" => {
                let button = s("button");
                if matches!(button, "left" | "right" | "middle") {
                    let down = b["down"] == true;
                    let key = (peer.to_owned(), button.to_owned());
                    let mut held = self.held.lock().unwrap();
                    if down { held.insert(key, Instant::now()); } else { held.remove(&key); }
                    sys::button(button, down);
                }
            },
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
            fps: b["fps"].as_u64().unwrap_or(8).clamp(1, 30) as u32,
            monitor: b["monitor"].as_u64().unwrap_or(0).min(16) as usize,
            cursor: b["cursor"] == true,
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
        let mut pointer: Option<Option<(f64, f64)>> = None;
        loop {
            let (peer, width, fps, monitor, own_cursor, busy) = {
                let mut g = self.screen.lock().unwrap();
                match g.as_mut() {
                    Some(sc) if sc.gen == gen && sc.last_keepalive.elapsed() < SESSION_IDLE => {
                        // A lost ack must not stall the stream forever.
                        if sc.inflight > 0 && sc.last_ack.elapsed() > Duration::from_secs(3) {
                            sc.inflight = 0;
                        }
                        (sc.peer.clone(), sc.width, sc.fps, sc.monitor, sc.cursor, sc.inflight >= 2)
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
            if sys::secure_desktop() {
                // Nothing to capture until the prompt closes; the phone keeps the last picture and is told why.
                self.deny(engine, &peer, "secure_desktop");
                thread::sleep(Duration::from_millis(500));
                continue;
            }
            // While the phone still holds two pictures no new one goes out, but the pointer keeps moving below.
            if !busy {
                if let Some((w, h, pixels)) = sys::capture_monitor(width, monitor, !own_cursor) {
                    let print = fingerprint(&pixels);
                    // Unchanged picture: send nothing (the phone keeps showing the last one), except a refresh now and then.
                    if print != last_print || last_sent.elapsed() > Duration::from_secs(2) {
                        let mut q = 60u8;
                        let data = loop {
                            match jpeg(w, h, &pixels, q) {
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
            }
            // Until the next picture is due, the pointer alone travels at up to 60 times a second: a few bytes
            // each, so it follows the finger even when the pictures are slow.
            let frame = Duration::from_millis(if busy { 25 } else { 1000 / fps as u64 });
            loop {
                if own_cursor {
                    let now = sys::cursor_at(monitor);
                    if pointer != Some(now) {
                        pointer = Some(now);
                        let body = match now {
                            Some((x, y)) => json!({"x": x, "y": y}),
                            None => json!({"hidden": true}),
                        };
                        let _ = engine.send_message(&peer, "pb.x.screen.cursor", body);
                    }
                }
                let left = frame.saturating_sub(started.elapsed());
                if left.is_zero() {
                    break;
                }
                thread::sleep(left.min(Duration::from_millis(16)));
            }
        }
    }

    /// A full-resolution screenshot, sent as an ordinary file transfer (so it is resumable, listed in the
    /// history and saved by the phone like any other received file).
    fn shot(&self, engine: &Engine, peer: &str) {
        self.notice(engine, peer, "pidió una captura de pantalla");
        let Some((w, h, pixels)) = sys::capture(u32::MAX) else {
            let _ = engine.send_message(peer, "pb.x.remote.denied", json!({"reason": "unsupported"}));
            return;
        };
        let Some(data) = jpeg(w, h, &pixels, 85) else { return };
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
            // The cover is read again only when the song changes (or is still missing), not every poll.
            let (mut art_of, mut art) = (String::new(), String::new());
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
                    Some(m) => {
                        let song = format!("{}|{}|{}", m.app, m.title, m.artist);
                        // Players often set the cover a moment after the title: retry while there is none.
                        if song != art_of || art.is_empty() {
                            art = sys::media_art().map(|b| STANDARD.encode(b)).unwrap_or_default();
                            art_of = song;
                        }
                        json!({"active": true, "art": art, "app": m.app, "title": m.title, "artist": m.artist, "playing": m.playing,
                        "position": m.position_ms, "duration": m.duration_ms, "actions": m.actions, "speed": m.speed, "at": SystemTime::now().duration_since(SystemTime::UNIX_EPOCH).map(|d| d.as_millis() as u64).unwrap_or(0)})
                    }
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

#[cfg(all(test, windows))]
mod stream_tests {
    /// The capture is BGRA and the encoder is told so: a wrong pairing fails here, not as blue faces on a phone.
    #[test]
    fn a_captured_frame_encodes_and_the_pointer_is_inside_it() {
        crate::sys::init();
        if let Some((w, h, pixels)) = crate::sys::capture_monitor(320, 0, false) {
            assert_eq!(pixels.len(), (w * h * 4) as usize);
            assert!(super::jpeg(w, h, &pixels, 60).is_some_and(|d| d.starts_with(&[0xFF, 0xD8])));
        }
        if let Some((x, y)) = crate::sys::cursor_at(0) {
            assert!((0.0..1.0).contains(&x) && (0.0..1.0).contains(&y));
        }
    }
}
