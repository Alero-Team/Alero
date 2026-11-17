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
use super::gfx::{decode_image, Canvas};
use super::model::Media;
use super::ui::{Cmd, Drag, Island, LocalTime, CANVAS_H, CANVAS_W};

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
    /// Display scale, 1.0 = 96 dpi.
    fn dpi(&mut self) -> f32;
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
}

pub enum Msg {
    Event(Event),
    /// The computer's player, with its cover as the bytes of an image file. None: nothing is playing.
    Media(Option<(crate::sys::Media, Option<Vec<u8>>)>),
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

impl Handle {
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
                        Some((m, art.clone()))
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

    let wants = Arc::new(AtomicBool::new(false));
    let media = spawn_media(tx, wants.clone());

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
    let mut closed_since: Option<Instant> = Some(Instant::now());
    let mut full = false;
    let mut full_at: Option<Instant> = None;
    let mut time_at: Option<Instant> = None;
    let mut pending: Vec<HostEvent> = Vec::new();

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
                island.set_config(cfg.clone());
            }
        }
        // ------------------------------------------------------------------------------ engine and player
        let mut notices = Vec::new();
        while let Ok(m) = rx.try_recv() {
            match m {
                Msg::Event(e) => notices.extend(island.model.feed(&e)),
                Msg::Media(m) => {
                    island.model.pc_media = m.map(|(m, art)| Media {
                        title: m.title,
                        artist: m.artist,
                        app: m.app,
                        playing: m.playing,
                        position_ms: m.position_ms,
                        duration_ms: m.duration_ms,
                        speed: if m.speed > 0.0 { m.speed } else { 1.0 },
                        at: Some(Instant::now()),
                        art: art.and_then(|b| decode_image(&b)),
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
            host.pump(250);
            last_tick = Instant::now();
            continue;
        }
        let now = Instant::now();
        let dt = now.duration_since(last_tick).as_secs_f32().min(0.25);
        last_tick = now;

        // ------------------------------------------------------------------------------ pointer
        if monitors_at.map_or(true, |t| t.elapsed() > Duration::from_secs(3)) {
            monitors = host.monitors();
            monitors_at = Some(Instant::now());
            dpi = host.dpi();
            dpi_at = Some(Instant::now());
        }
        if dpi_at.map_or(true, |t| t.elapsed() > Duration::from_secs(10)) {
            dpi = host.dpi();
            dpi_at = Some(Instant::now());
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
        if cfg.hide_fullscreen && !island.is_open() {
            if full_at.map_or(true, |t| t.elapsed() > Duration::from_millis(400)) {
                full = mon.is_some_and(|m| host.fullscreen(m));
                full_at = Some(Instant::now());
            }
        } else {
            full = false;
            full_at = None;
        }
        let fullscreen = full;
        island.set_suppressed(fullscreen);
        if time_at.map_or(true, |t| t.elapsed() > Duration::from_secs(1)) {
            island.set_time(local_time());
            time_at = Some(Instant::now());
        }
        let dragging_window = btn && hot && host.moving_window();
        island.set_reduce_motion(host.reduce_motion());
        island.set_zone(hot && !fullscreen && !dragging_window, btn && !dragging_window, dt);

        // ------------------------------------------------------------------------------ geometry and input
        if let Some(m) = mon {
            let k = dpi * cfg.scale as f32 / 100.0;
            let w = (CANVAS_W * k).ceil() as i32;
            geom = Geometry { x: (m.0 + m.2) / 2 - w / 2 + (cfg.offset_x as f32 * dpi) as i32, y: m.1, k };
        }
        let pointer = cur.and_then(|(cx, cy, _)| {
            let (lx, ly) = ((cx - geom.x) as f32 / geom.k, (cy - geom.y) as f32 / geom.k);
            (island.visible() && lx >= 0.0 && ly >= 0.0 && lx < CANVAS_W && ly < CANVAS_H).then_some((lx, ly))
        });
        island.set_pointer(pointer);
        if island.visible() {
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

        // ------------------------------------------------------------------------------ commands
        let cmds = island.take_cmds();
        if !cmds.is_empty() {
            let ctx = Ctx { target: island.model.target_id(), call_peer: island.model.call().map(|(p, _)| p.clone()) };
            for c in cmds {
                match c {
                    Cmd::Beep => host.beep(),
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
            closed_since = None;
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
        } else if st.visible {
            pending.extend(host.pump(14));
        } else {
            pending.extend(host.pump(40));
        }
    }
}

/// The computer's clock, for the pill and the header's date.
#[cfg(target_os = "linux")]
fn local_time() -> LocalTime {
    // SAFETY: `localtime_r` fills the `tm` we own; `time` has no preconditions.
    unsafe {
        let now = libc::time(std::ptr::null_mut());
        let mut tm: libc::tm = std::mem::zeroed();
        if libc::localtime_r(&now, &mut tm).is_null() {
            return LocalTime::default();
        }
        LocalTime { hour: tm.tm_hour as u32, min: tm.tm_min as u32, wday: tm.tm_wday as u32, month: (tm.tm_mon + 1) as u32, day: tm.tm_mday as u32 }
    }
}

#[cfg(windows)]
fn local_time() -> LocalTime {
    use windows::Win32::System::SystemInformation::GetLocalTime;
    // SAFETY: no preconditions.
    let t = unsafe { GetLocalTime() };
    LocalTime { hour: t.wHour as u32, min: t.wMinute as u32, wday: t.wDayOfWeek as u32, month: t.wMonth as u32, day: t.wDay as u32 }
}

#[cfg(not(any(target_os = "linux", windows)))]
fn local_time() -> LocalTime {
    LocalTime::default()
}
