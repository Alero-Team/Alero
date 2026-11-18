//! The loop that ties the island to its host (the platform's window) and to the engine.
//!
//! Idle cost: while the island is off, the thread wakes four times a second to look at its settings file. While
//! it is on and closed, it reads the pointer every 40 ms and nothing else. Frames are drawn only while something
//! moves or changes, paced by the display.

use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{Receiver, Sender};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use pb_core::engine::Event;

use super::config::{IslandConfig, Watcher};
use super::gfx::{decode_image, Canvas, Image};
use super::model::Media;
use super::ui::{Cmd, Drag, Island, CANVAS_H, CANVAS_W};

pub type Rect = (i32, i32, i32, i32);

/// What the platform window reports besides the pointer.
#[allow(dead_code)]
pub enum HostEvent {
    Wheel(f32),
    Drag(Drag),
    Drop(Vec<PathBuf>),
    Hotkey,
}

pub trait Host {
    /// Monitors as (left, top, right, bottom), primary first.
    fn monitors(&mut self) -> Vec<Rect>;
    /// Pointer in screen pixels and whether the left button is down. None when it cannot be read.
    fn cursor(&mut self) -> Option<(i32, i32, bool)>;
    /// Scale of this monitor, 1.0 = 96 dpi.
    fn dpi(&mut self, mon: Rect) -> f32;
    /// Is an application covering the whole of this monitor (a game, a video, a presentation)?
    fn fullscreen(&mut self, mon: Rect) -> bool;
    /// Is the user dragging or resizing a window right now (so a button held at the top edge is not a file)?
    fn moving_window(&mut self) -> bool;
    /// Does the system ask for less animation?
    fn reduce_motion(&mut self) -> bool;
    /// Registers the global hotkey ("ctrl+alt+i"); an empty string removes it.
    fn hotkey(&mut self, spec: &str);
    /// Shows `frame` (premultiplied RGBA, `w * h * 4` bytes) with its top-left corner at (x, y), or hides the window.
    fn present(&mut self, frame: Option<(&[u8], u32, u32, i32, i32)>);
    /// Handles the system's pending messages, waiting up to `ms` for them.
    fn pump(&mut self, ms: u32) -> Vec<HostEvent>;
    /// Waits for the next display refresh (or a short sleep where there is no way to know it).
    fn vsync(&mut self);
    fn beep(&mut self);
    /// Puts the shown window back on top of other always-on-top windows (a video player, the taskbar).
    fn keep_on_top(&mut self) {}
    /// Whether the window takes the mouse. Off, clicks fall through to the windows below (the island reads the
    /// pointer by polling, so it only needs the mouse while the pointer is on it: to keep clicks, the wheel and drops).
    fn set_input(&mut self, _on: bool) {}
}

pub enum Msg {
    Event(Event),
    /// The computer's player, with its cover as the bytes of an image file. None: nothing is playing.
    Media(Option<(crate::sys::Media, Option<Vec<u8>>, Option<Image>)>),
    /// A phone's state over adb (peer id); None: no adb for it now.
    Adb(String, Option<super::adb::Radios>),
}

/// What the executor needs to know to address a command.
pub struct Ctx {
    pub target: Option<String>,
    pub call_peer: Option<String>,
}

pub trait Exec {
    fn peers(&self) -> Vec<pb_core::engine::PeerView>;
    /// Carries out one command. A line of feedback, if any: (good, title, text).
    fn run(&self, cmd: Cmd, ctx: &Ctx) -> Option<(bool, String, String)>;
}

#[derive(Clone)]
pub struct Handle(Arc<Mutex<Sender<Msg>>>);

/// The island is on screen and opens by itself for a file offer, so it can be answered there without the window.
static SHOWS_OFFERS: AtomicBool = AtomicBool::new(false);

impl Handle {
    pub fn shows_offers(&self) -> bool {
        SHOWS_OFFERS.load(Ordering::Relaxed)
    }

    pub fn feed(&self, e: Event) {
        let _ = self.0.lock().unwrap().send(Msg::Event(e));
    }
}

pub fn channel() -> (Handle, Receiver<Msg>, Sender<Msg>) {
    let (tx, rx) = std::sync::mpsc::channel();
    (Handle(Arc::new(Mutex::new(tx.clone()))), rx, tx)
}

/// Polls the computer's player while the island wants it, in its own thread (the system call can take a while).
fn spawn_media(tx: Sender<Msg>, wants: Arc<AtomicBool>) -> std::thread::Thread {
    let t = std::thread::Builder::new()
        .name("island-media".into())
        .spawn(move || {
            let mut last = String::new();
            let mut art: Option<Vec<u8>> = None;
            let mut icon: (String, Option<Image>) = (String::new(), None);
            loop {
                if !wants.load(Ordering::Relaxed) {
                    std::thread::park_timeout(Duration::from_secs(3));
                    continue;
                }
                let state = crate::sys::media_state();
                let msg = match state {
                    Some(m) if !(m.title.is_empty() && m.artist.is_empty()) => {
                        let key = format!("{}\u{1}{}\u{1}{}", m.app, m.title, m.artist);
                        if key != last {
                            last = key;
                            art = crate::sys::media_art();
                        }
                        if icon.0 != m.app {
                            let img = crate::sys::app_icon(&m.app).and_then(|(w, h, px)| Image::from_rgba(w, h, px));
                            icon = (m.app.clone(), img);
                        }
                        Some((m, art.clone(), icon.1.clone()))
                    }
                    _ => {
                        last.clear();
                        art = None;
                        None
                    }
                };
                if tx.send(Msg::Media(msg)).is_err() {
                    return;
                }
                std::thread::park_timeout(Duration::from_millis(1000));
            }
        })
        .expect("media thread");
    t.thread().clone()
}

fn contains(r: Rect, x: i32, y: i32) -> bool {
    x >= r.0 && x < r.2 && y >= r.1 && y < r.3
}

struct Geometry {
    x: i32,
    y: i32,
    k: f32,
}

pub fn run(mut host: Box<dyn Host>, rx: Receiver<Msg>, tx: Sender<Msg>, data: PathBuf, exec: Box<dyn Exec>) {
    let mut watcher = Watcher::new(&data);
    let mut cfg: IslandConfig = watcher.current.clone();
    let mut island = Island::new(cfg.clone());
    island.model.set_peers(exec.peers());
    host.hotkey(&cfg.hotkey);
    SHOWS_OFFERS.store(cfg.enabled && cfg.auto_expand && cfg.modules.incoming, Ordering::Relaxed);

    let wants = Arc::new(AtomicBool::new(false));
    let media = spawn_media(tx.clone(), wants.clone());

    let mut canvas: Option<Canvas> = None;
    let mut canvas_key = (0u32, 0u32);
    let mut geom = Geometry { x: 0, y: 0, k: 1.0 };
    let mut shown = false;
    let mut monitors: Vec<Rect> = Vec::new();
    let mut monitors_at: Option<Instant> = None;
    let mut mon: Option<Rect> = None;
    let mut prev_btn = false;
    let mut last_tick = Instant::now();
    let mut last_cfg_check = Instant::now();
    let mut dpi = 1.0f32;
    let mut dpi_at: Option<Instant> = None;
    let mut dpi_mon: Option<Rect> = None;
    let mut full_at: Option<Instant> = None;
    let mut full = false;
    let mut reduce = false;
    let mut last_art: Option<Vec<u8>> = None;
    let mut closed_since: Option<Instant> = Some(Instant::now());
    let mut pending: Vec<HostEvent> = Vec::new();
    let devices_file = data.join("island-devices.json");
    let (adb_tx, adb_rx) = std::sync::mpsc::channel::<super::adb::Req>();
    super::adb::spawn(adb_rx, tx.clone());
    let mut adb_at: Option<Instant> = None;
    let mut devices_seen: Option<std::time::SystemTime> = None;

    loop {
        // ------------------------------------------------------------------------------ settings
        if last_cfg_check.elapsed() >= Duration::from_millis(400) {
            last_cfg_check = Instant::now();
            if watcher.poll() {
                let next = watcher.current.clone();
                if next.hotkey != cfg.hotkey {
                    host.hotkey(&next.hotkey);
                }
                cfg = next;
                SHOWS_OFFERS.store(cfg.enabled && cfg.auto_expand && cfg.modules.incoming, Ordering::Relaxed);
                island.set_config(cfg.clone());
            }
            // The phones' pictures: read again only when the app rewrote the list.
            let seen = std::fs::metadata(&devices_file).and_then(|m| m.modified()).ok();
            if seen != devices_seen {
                devices_seen = seen;
                island.model.devices = std::fs::read_to_string(&devices_file).map(|j| super::model::load_devices(&j)).unwrap_or_default();
                island.mark_dirty();
            }
        }
        // ------------------------------------------------------------------------------ engine and player
        let mut notices = Vec::new();
        while let Ok(m) = rx.try_recv() {
            match m {
                Msg::Event(e) => notices.extend(island.model.feed(&e)),
                Msg::Adb(peer, radios) => {
                    match radios {
                        Some(r) => island.model.adb.insert(peer, r),
                        None => island.model.adb.remove(&peer),
                    };
                    island.mark_dirty();
                }
                Msg::Media(m) => {
                    // The player thread repeats the same cover every second: decode it only when it changes.
                    let same_art = m.as_ref().map(|(_, a, _)| a) == Some(&last_art);
                    let old_art = island.model.pc_media.as_mut().and_then(|p| p.art.take());
                    if let Some((_, a, _)) = &m {
                        last_art.clone_from(a);
                    } else {
                        last_art = None;
                    }
                    island.model.pc_media = m.map(|(m, art, icon)| Media {
                        icon,
                        title: m.title,
                        artist: m.artist,
                        app: m.app,
                        playing: m.playing,
                        position_ms: m.position_ms,
                        duration_ms: m.duration_ms,
                        speed: if m.speed > 0.0 { m.speed } else { 1.0 },
                        at: Some(Instant::now()),
                        art: if same_art { old_art } else { art.and_then(|b| decode_image(&b)) },
                    });
                    island.mark_dirty();
                }
            }
        }
        if !notices.is_empty() {
            island.notices(notices);
        }
        if !cfg.enabled {
            // Off: look at the settings now and then, nothing else.
            if shown {
                host.present(None);
                shown = false;
            }
            canvas = None;
            wants.store(false, Ordering::Relaxed);
            host.pump(250);
            last_tick = Instant::now();
            continue;
        }
        let now = Instant::now();
        let dt = now.duration_since(last_tick).as_secs_f32().min(0.25);
        last_tick = now;

        // ------------------------------------------------------------------------------ pointer
        if monitors_at.is_none_or(|t| t.elapsed() > Duration::from_secs(3)) {
            monitors = host.monitors();
            monitors_at = Some(Instant::now());
            reduce = host.reduce_motion();
        }
        let cur = host.cursor();
        let (btn, hot) = match cur {
            Some((cx, cy, btn)) => {
                // The monitor the island belongs to: the chosen one, or the one the pointer is on (kept while open).
                if !island.is_open() || mon.is_none() {
                    mon = match cfg.monitor {
                        m if m >= 0 => monitors.get(m as usize).or(monitors.first()).copied(),
                        _ => monitors.iter().find(|r| contains(**r, cx, cy)).copied().or(monitors.first().copied()),
                    };
                }
                // Each monitor has its own scale: read it when the island moves to another one, and now and then.
                if mon != dpi_mon || dpi_at.is_none_or(|t| t.elapsed() > Duration::from_secs(10)) {
                    if let Some(m) = mon {
                        dpi = host.dpi(m);
                    }
                    dpi_mon = mon;
                    dpi_at = Some(Instant::now());
                }
                let hot = mon.is_some_and(|m| {
                    let edge = (3.0 * dpi).round().max(2.0) as i32;
                    let centre = (m.0 + m.2) / 2 + (cfg.offset_x as f32 * dpi) as i32;
                    let half = (cfg.zone_width as f32 * dpi / 2.0) as i32;
                    cy >= m.1 && cy < m.1 + edge && contains((m.0, m.1, m.2, m.3), cx, cy) && (cx - centre).abs() <= half
                });
                (btn, hot)
            }
            None => (false, false),
        };
        // Only asked when the pointer is in the zone: nothing else depends on it.
        let fullscreen = hot && cfg.hide_fullscreen && !island.is_open() && mon.is_some_and(|m| host.fullscreen(m));
        // The resting notch steps aside for games and videos; asked once a second, it is not free.
        if full_at.is_none_or(|t| t.elapsed() > Duration::from_secs(1)) {
            full = cfg.hide_fullscreen && !island.is_open() && mon.is_some_and(|m| host.fullscreen(m));
            full_at = Some(Instant::now());
            if shown && !island.is_open() {
                host.keep_on_top();
            }
        }
        island.set_rest(!full);
        let dragging_window = btn && hot && host.moving_window();
        island.set_reduce_motion(reduce);
        island.set_zone(hot && !fullscreen && !dragging_window, btn && !dragging_window, dt);

        // ------------------------------------------------------------------------------ geometry and input
        if let Some(m) = mon {
            // Text that reads well on a laptop is tiny on a big desktop screen: grow a little with the screen's
            // height in logical pixels (950 and under: 1.0, a 1080p screen at 100 %: 1.14), up to 1.2.
            let fit = ((m.3 - m.1) as f32 / dpi / 950.0).clamp(1.0, 1.2);
            let k = dpi * fit * cfg.scale as f32 / 100.0;
            let w = (CANVAS_W * k).ceil() as i32;
            let g = Geometry { x: (m.0 + m.2) / 2 - w / 2 + (cfg.offset_x as f32 * dpi) as i32, y: m.1, k };
            // The resting notch follows the pointer to another monitor: draw it there.
            if (g.x, g.y, g.k) != (geom.x, geom.y, geom.k) {
                island.mark_dirty();
            }
            geom = g;
        }
        let pointer = cur.and_then(|(cx, cy, _)| {
            let (lx, ly) = ((cx - geom.x) as f32 / geom.k, (cy - geom.y) as f32 / geom.k);
            (island.is_open() && lx >= 0.0 && ly >= 0.0 && lx < CANVAS_W && ly < CANVAS_H).then_some((lx, ly))
        });
        island.set_pointer(pointer);
        host.set_input(island.wants_input());
        if island.is_open() {
            if btn && !prev_btn {
                island.press();
            } else if btn && prev_btn {
                island.moved();
            } else if !btn && prev_btn {
                island.release();
            }
        }
        prev_btn = btn;

        pending.extend(host.pump(0));
        for ev in pending.drain(..) {
            match ev {
                HostEvent::Wheel(n) => island.wheel(n),
                HostEvent::Drag(d) => island.drag(d),
                HostEvent::Drop(files) => island.dropped(files),
                HostEvent::Hotkey => island.hotkey(),
            }
        }

        // ------------------------------------------------------------------------------ adb
        // Asked only while the controls are on screen, every 5 s (the app's own rhythm).
        let adb_peer = island.model.target().map(|p| (p.id.clone(), p.addr.rsplit_once(':').map_or(String::new(), |(ip, _)| ip.to_string())));
        if island.wants_adb() {
            if let Some((peer, ip)) = &adb_peer {
                if adb_at.is_none_or(|t| t.elapsed() > Duration::from_secs(5)) {
                    adb_at = Some(Instant::now());
                    let _ = adb_tx.send(super::adb::Req { peer: peer.clone(), ip: ip.clone(), act: None });
                }
            }
        } else {
            adb_at = None;
        }

        // ------------------------------------------------------------------------------ commands
        let cmds = island.take_cmds();
        if !cmds.is_empty() {
            let ctx = Ctx { target: island.model.target_id(), call_peer: island.model.call().map(|(p, _)| p.clone()) };
            for c in cmds {
                match c {
                    Cmd::Beep => host.beep(),
                    Cmd::Adb { what, on } => {
                        if let Some((peer, ip)) = &adb_peer {
                            let _ = adb_tx.send(super::adb::Req { peer: peer.clone(), ip: ip.clone(), act: Some((what, on)) });
                        }
                    }
                    Cmd::PcMedia(k) => {
                        exec.run(Cmd::PcMedia(k), &ctx);
                        if let Some(m) = island.model.pc_media.as_mut() {
                            if k == "toggle" {
                                m.position_ms = m.position_now();
                                m.at = Some(Instant::now());
                                m.playing = !m.playing;
                            }
                        }
                        media.unpark();
                    }
                    c => {
                        if let Some((good, title, text)) = exec.run(c, &ctx) {
                            island.flash(good, title, text);
                        }
                    }
                }
            }
        }

        // ------------------------------------------------------------------------------ time and drawing
        let st = island.update(dt);
        let want = island.wants_media();
        if want && !wants.swap(true, Ordering::Relaxed) {
            media.unpark();
        } else if !want {
            wants.store(false, Ordering::Relaxed);
        }
        if st.visible {
            if island.is_open() {
                closed_since = None;
            } else if closed_since.get_or_insert_with(Instant::now).elapsed() > Duration::from_secs(5) && !st.animating {
                // Only the resting notch for a while: the next frame makes a new canvas if it needs one.
                canvas = None;
                island.release_buffers();
            }
            if st.animating {
                island.take_dirty();
                let size = ((CANVAS_W * geom.k).ceil() as u32, (CANVAS_H * geom.k).ceil() as u32);
                if canvas.is_none() || canvas_key != size || canvas.as_ref().is_some_and(|c| (c.k - geom.k).abs() > 1e-3) {
                    canvas = Some(Canvas::new(CANVAS_W, CANVAS_H, geom.k));
                    canvas_key = size;
                }
                if let Some(cv) = canvas.as_mut() {
                    island.render(cv);
                    host.present(Some((cv.pm.data(), cv.width_px(), cv.height_px(), geom.x, geom.y)));
                    shown = true;
                }
            }
        } else {
            if shown {
                host.present(None);
                shown = false;
            }
            closed_since.get_or_insert_with(Instant::now);
            // Closed for a while: give the frame buffers back.
            if closed_since.is_some_and(|t| t.elapsed() > Duration::from_secs(5)) {
                canvas = None;
                island.release_buffers();
            }
        }

        // ------------------------------------------------------------------------------ pacing
        if st.visible && st.animating {
            host.vsync();
        } else if st.visible && island.is_open() {
            pending.extend(host.pump(14));
        } else {
            pending.extend(host.pump(40));
        }
    }
}
