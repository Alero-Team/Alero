//! Linux implementation of what the phone can do to this computer (see `sys.rs`). No root and no new crates:
//! - input: `/dev/uinput` (works on X11 and Wayland); XTest on X11 when uinput is not writable.
//! - screen: Xlib (`XGetImage`, loaded at run time with x11-dl) on X11; on Wayland the compositor's own
//!   screenshot tool (spectacle, grim or gnome-screenshot).
//! - media: MPRIS over the session bus. Power and volume: loginctl, systemctl and pactl.
//! - battery: /sys/class/power_supply.
//! `CAPS` is measured at run time, so the phone never shows a control that would do nothing here.

use std::ffi::c_ulong;
use std::fs::{File, OpenOptions};
use std::io::Write;
use std::os::fd::AsRawFd;
use std::os::raw::{c_int, c_uint};
use std::os::unix::fs::OpenOptionsExt;
use std::path::Path;
use std::process::{Command, Stdio};
use std::sync::{LazyLock, Mutex};
use std::time::Duration;

use dbus::arg::{prop_cast, PropMap, RefArg};
use dbus::blocking::stdintf::org_freedesktop_dbus::Properties;
use dbus::blocking::Connection;
use x11_dl::xlib::{Display, Xlib};
use x11_dl::xrandr::Xrandr;
use x11_dl::xtest::Xf86vmode as XTest;

use super::{Caps, Media};
use crate::linux::{is_wayland, set_clipboard, which};

// --- capabilities ----------------------------------------------------------------------------------------

pub static CAPS: LazyLock<Caps> = LazyLock::new(|| Caps {
    input: OpenOptions::new().write(true).open("/dev/uinput").is_ok() || (!is_wayland() && x11().as_ref().is_some_and(|x| x.xtest.is_some())),
    screen: if is_wayland() { shot_tool().is_some() } else { x11().is_some() },
    media: Connection::new_session().is_ok(),
    power: which("systemctl").is_some(),
});

pub fn init() {
    LazyLock::force(&CAPS);
}

pub fn keep_com_alive() {}

pub fn secure_desktop() -> bool {
    false
}

// --- X11 -------------------------------------------------------------------------------------------------

struct X {
    xlib: Xlib,
    xtest: Option<XTest>,
    xrandr: Option<Xrandr>,
    dpy: *mut Display,
    root: c_ulong,
}

// Every use goes through the `X11` mutex, one call at a time.
unsafe impl Send for X {}

static X11: LazyLock<Mutex<Option<X>>> = LazyLock::new(|| Mutex::new(open_x11()));

fn x11() -> std::sync::MutexGuard<'static, Option<X>> {
    X11.lock().unwrap_or_else(|e| e.into_inner())
}

fn open_x11() -> Option<X> {
    let xlib = Xlib::open().ok()?;
    unsafe {
        let dpy = (xlib.XOpenDisplay)(std::ptr::null());
        if dpy.is_null() {
            return None;
        }
        let root = (xlib.XDefaultRootWindow)(dpy);
        let xtest = XTest::open().ok().filter(|t| {
            let (mut a, mut b, mut c, mut d) = (0, 0, 0, 0);
            (t.XTestQueryExtension)(dpy, &mut a, &mut b, &mut c, &mut d) != 0
        });
        Some(X { xlib, xtest, xrandr: Xrandr::open().ok(), dpy, root })
    }
}

// --- input -----------------------------------------------------------------------------------------------

const EV_SYN: u16 = 0;
const EV_KEY: u16 = 1;
const EV_REL: u16 = 2;
const REL_X: u16 = 0;
const REL_Y: u16 = 1;
const REL_HWHEEL: u16 = 6;
const REL_WHEEL: u16 = 8;
const REL_HWHEEL_HI_RES: u16 = 0x0c;
const REL_WHEEL_HI_RES: u16 = 0x0b;
const BTN_LEFT: u16 = 0x110;
const BTN_RIGHT: u16 = 0x111;
const BTN_MIDDLE: u16 = 0x112;
const KEY_LEFTCTRL: u16 = 29;
const KEY_LEFTSHIFT: u16 = 42;
const KEY_LEFTALT: u16 = 56;
const KEY_LEFTMETA: u16 = 125;

// linux/uinput.h
const UI_DEV_CREATE: u64 = 0x5501;
const UI_DEV_SETUP: u64 = 0x405c5503;
const UI_SET_EVBIT: u64 = 0x40045564;
const UI_SET_KEYBIT: u64 = 0x40045565;
const UI_SET_RELBIT: u64 = 0x40045566;

#[repr(C)]
struct UinputSetup {
    bustype: u16,
    vendor: u16,
    product: u16,
    version: u16,
    name: [u8; 80],
    ff_effects_max: u32,
}

enum Backend {
    Uinput(File),
    XTest,
}

/// Chosen on the first input and kept: a virtual device lives as long as its file stays open.
static INPUT: LazyLock<Mutex<Option<Backend>>> = LazyLock::new(|| Mutex::new(open_backend()));

fn open_backend() -> Option<Backend> {
    if let Some(f) = create_uinput() {
        return Some(Backend::Uinput(f));
    }
    (!is_wayland() && x11().as_ref().is_some_and(|x| x.xtest.is_some())).then_some(Backend::XTest)
}

fn create_uinput() -> Option<File> {
    let f = OpenOptions::new().write(true).custom_flags(libc::O_NONBLOCK).open("/dev/uinput").ok()?;
    let fd = f.as_raw_fd();
    let ctl = |req: u64, arg: usize| unsafe { libc::ioctl(fd, req as _, arg) } >= 0;
    let mut ok = ctl(UI_SET_EVBIT, EV_KEY as usize) && ctl(UI_SET_EVBIT, EV_REL as usize) && ctl(UI_SET_EVBIT, EV_SYN as usize);
    for key in (1..=248u16).chain([BTN_LEFT, BTN_RIGHT, BTN_MIDDLE]) {
        ok &= ctl(UI_SET_KEYBIT, key as usize);
    }
    for rel in [REL_X, REL_Y, REL_HWHEEL, REL_WHEEL, REL_WHEEL_HI_RES, REL_HWHEEL_HI_RES] {
        ok &= ctl(UI_SET_RELBIT, rel as usize);
    }
    let mut setup = UinputSetup { bustype: 0x06, vendor: 0x1209, product: 0xa1e0, version: 1, name: [0; 80], ff_effects_max: 0 };
    let name = b"Alero remote input";
    setup.name[..name.len()].copy_from_slice(name);
    ok &= unsafe { libc::ioctl(fd, UI_DEV_SETUP as _, &setup as *const UinputSetup) } >= 0;
    ok &= ctl(UI_DEV_CREATE, 0);
    // shortcut: fixed wait for the compositor to notice the new device (events sent before are lost), react to the
    // udev "add" event instead if some desktop needs longer.
    if ok {
        std::thread::sleep(Duration::from_millis(300));
    }
    ok.then_some(f)
}

/// Sends `(type, code, value)` events as one report. Unknown backends (no uinput, Wayland) drop them silently.
fn send(events: &[(u16, u16, i32)]) {
    let mut input = INPUT.lock().unwrap_or_else(|e| e.into_inner());
    match input.as_mut() {
        Some(Backend::Uinput(f)) => {
            let mut buf: Vec<libc::input_event> = events
                .iter()
                .map(|&(type_, code, value)| libc::input_event { time: libc::timeval { tv_sec: 0, tv_usec: 0 }, type_, code, value })
                .collect();
            buf.push(libc::input_event { time: libc::timeval { tv_sec: 0, tv_usec: 0 }, type_: EV_SYN, code: 0, value: 0 });
            // SAFETY: input_event is plain old data with no padding invariants for the kernel.
            let bytes = unsafe { std::slice::from_raw_parts(buf.as_ptr().cast::<u8>(), std::mem::size_of_val(buf.as_slice())) };
            let _ = f.write_all(bytes);
        }
        Some(Backend::XTest) => {
            let guard = x11();
            let Some(x) = guard.as_ref() else { return };
            let Some(t) = &x.xtest else { return };
            let (mut dx, mut dy) = (0, 0);
            unsafe {
                for &(type_, code, value) in events {
                    match (type_, code) {
                        (EV_KEY, BTN_LEFT | BTN_MIDDLE | BTN_RIGHT) => {
                            let n = match code { BTN_LEFT => 1, BTN_MIDDLE => 2, _ => 3 };
                            (t.XTestFakeButtonEvent)(x.dpy, n, (value != 0) as c_int, 0);
                        }
                        // X keycodes are evdev codes + 8 on every current server.
                        (EV_KEY, _) => {
                            (t.XTestFakeKeyEvent)(x.dpy, code as c_uint + 8, (value != 0) as c_int, 0);
                        }
                        (EV_REL, REL_X) => dx += value,
                        (EV_REL, REL_Y) => dy += value,
                        // Buttons 4-7 are the wheel; hi-res events are ignored, the whole notches come in REL_WHEEL.
                        (EV_REL, REL_WHEEL | REL_HWHEEL) => {
                            let n = match (code, value > 0) { (REL_WHEEL, true) => 4, (REL_WHEEL, false) => 5, (_, true) => 7, _ => 6 };
                            for _ in 0..value.unsigned_abs().min(50) {
                                (t.XTestFakeButtonEvent)(x.dpy, n, 1, 0);
                                (t.XTestFakeButtonEvent)(x.dpy, n, 0, 0);
                            }
                        }
                        _ => {}
                    }
                }
                if dx != 0 || dy != 0 {
                    // x11-dl declares this function with the arguments of XTestFakeMotionEvent (dpy, screen, x, y, delay);
                    // the real one is (dpy, dx, dy, delay): the extra zero lands in the unused register.
                    (t.XTestFakeRelativeMotionEvent)(x.dpy, dx, dy, 0, 0);
                }
                (x.xlib.XFlush)(x.dpy);
            }
        }
        None => {}
    }
}

/// Relative pointer movement, in the same units a mouse reports.
pub fn move_by(dx: i32, dy: i32) {
    send(&[(EV_REL, REL_X, dx), (EV_REL, REL_Y, dy)]);
    if is_wayland() {
        let (w, h) = wayland_logical();
        let mut p = VIRTUAL_POINTER.lock().unwrap_or_else(|e| e.into_inner());
        let (x, y) = p.unwrap_or((w / 2.0, h / 2.0));
        *p = Some(((x + dx as f64).clamp(0.0, w - 1.0), (y + dy as f64).clamp(0.0, h - 1.0)));
    }
}

/// Where the pointer is on Wayland, in logical pixels, from the movements this daemon injected (a client cannot
/// ask the compositor). None until the first one. shortcut: ignores the compositor's pointer acceleration and
/// moves made with the real mouse; pushing into a corner resyncs it. Replace with the RemoteDesktop portal.
static VIRTUAL_POINTER: Mutex<Option<(f64, f64)>> = Mutex::new(None);

/// Size of the first screen in the pixels the pointer moves in (physical size divided by the scale): KDE's
/// `kscreen-doctor -j` knows it, else the kernel's mode with no scaling.
fn wayland_logical() -> (f64, f64) {
    static SIZE: LazyLock<(f64, f64)> = LazyLock::new(|| {
        let from_kde = which("kscreen-doctor")
            .and_then(|p| Command::new(p).arg("-j").stdin(Stdio::null()).stderr(Stdio::null()).output().ok())
            .and_then(|o| serde_json::from_slice::<serde_json::Value>(&o.stdout).ok())
            .and_then(|v| {
                let o = v["outputs"].as_array()?.iter().find(|o| o["enabled"] == true)?;
                let scale = o["scale"].as_f64().filter(|s| *s > 0.0).unwrap_or(1.0);
                Some((o["size"]["width"].as_f64()? / scale, o["size"]["height"].as_f64()? / scale))
            });
        from_kde.unwrap_or_else(|| {
            let (l, t, r, b) = drm_monitors().first().copied().unwrap_or((0, 0, 1920, 1080));
            ((r - l) as f64, (b - t) as f64)
        })
    });
    *SIZE
}

pub fn button(name: &str, down: bool) {
    let code = match name {
        "right" => BTN_RIGHT,
        "middle" => BTN_MIDDLE,
        _ => BTN_LEFT,
    };
    send(&[(EV_KEY, code, down as i32)]);
}

/// `dy`/`dx` in wheel notches (positive: up / right), fractions allowed (smooth scrolling).
pub fn scroll(dy: f64, dx: f64) {
    // The kernel wants whole notches in REL_WHEEL next to the fine 1/120 steps: carry the remainder over.
    static REST: Mutex<(f64, f64)> = Mutex::new((0.0, 0.0));
    let mut guard = REST.lock().unwrap_or_else(|e| e.into_inner());
    let (rest_y, rest_x) = &mut *guard;
    let mut events = Vec::new();
    for (amount, rest, whole, fine) in [(dy, rest_y, REL_WHEEL, REL_WHEEL_HI_RES), (dx, rest_x, REL_HWHEEL, REL_HWHEEL_HI_RES)] {
        if amount == 0.0 {
            continue;
        }
        let steps = (amount * 120.0).round() as i32;
        *rest += steps as f64 / 120.0;
        let notches = rest.trunc();
        *rest -= notches;
        events.push((EV_REL, fine, steps));
        if notches != 0.0 {
            events.push((EV_REL, whole, notches as i32));
        }
    }
    send(&events);
}

/// evdev key code of a key name (the same names the phone sends on Windows). Layout-independent codes, like
/// pressing the key at that position on a US keyboard.
fn key_code(name: &str) -> Option<u16> {
    const LETTERS: &[u8; 26] = &[30, 48, 46, 32, 18, 33, 34, 35, 23, 36, 37, 38, 50, 49, 24, 25, 16, 19, 31, 20, 22, 47, 17, 45, 21, 44];
    let n = name.to_lowercase();
    Some(match n.as_str() {
        "enter" => 28,
        "backspace" => 14,
        "tab" => 15,
        "esc" | "escape" => 1,
        "space" => 57,
        "delete" => 111,
        "insert" => 110,
        "home" => 102,
        "end" => 107,
        "pageup" => 104,
        "pagedown" => 109,
        "left" => 105,
        "right" => 106,
        "up" => 103,
        "down" => 108,
        "win" => KEY_LEFTMETA,
        f if f.starts_with('f') && f[1..].parse::<u16>().is_ok_and(|k| (1..=12).contains(&k)) => {
            let k = f[1..].parse::<u16>().unwrap();
            if k <= 10 { 58 + k } else { 87 + k - 11 }
        }
        c if c.len() == 1 && c.as_bytes()[0].is_ascii_lowercase() => LETTERS[(c.as_bytes()[0] - b'a') as usize] as u16,
        c if c.len() == 1 && c.as_bytes()[0].is_ascii_digit() => match c.as_bytes()[0] {
            b'0' => 11,
            d => (d - b'1') as u16 + 2,
        },
        _ => return None,
    })
}

/// A key press (down and up) with optional ctrl/alt/shift/win held around it.
pub fn key(name: &str, mods: &[String]) -> bool {
    let Some(code) = key_code(name) else { return false };
    let held: Vec<u16> = mods
        .iter()
        .filter_map(|m| match m.as_str() {
            "ctrl" => Some(KEY_LEFTCTRL),
            "alt" => Some(KEY_LEFTALT),
            "shift" => Some(KEY_LEFTSHIFT),
            "win" => Some(KEY_LEFTMETA),
            _ => None,
        })
        .collect();
    let mut seq: Vec<(u16, u16, i32)> = held.iter().map(|&m| (EV_KEY, m, 1)).collect();
    seq.extend([(EV_KEY, code, 1), (EV_KEY, code, 0)]);
    seq.extend(held.iter().rev().map(|&m| (EV_KEY, m, 0)));
    send(&seq);
    true
}

/// Types text. X11 with xdotool types it for real (any character, any layout). Everywhere else the text goes to the
/// clipboard and Ctrl+V pastes it. Capped: a phone is not a macro engine.
/// shortcut: the paste overwrites the clipboard and does nothing in terminals (they paste with Ctrl+Shift+V);
/// replace it with the libei/RemoteDesktop portal once the target desktops ship it.
pub fn text(s: &str) {
    let s: String = s.chars().take(2000).collect();
    if s.is_empty() {
        return;
    }
    if !is_wayland() {
        if let Some(xdotool) = which("xdotool") {
            let ok = Command::new(xdotool).args(["type", "--delay", "0", "--", &s]).stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null()).status();
            if ok.is_ok_and(|st| st.success()) {
                return;
            }
        }
    }
    set_clipboard(&s);
    std::thread::sleep(Duration::from_millis(120));
    key("v", &["ctrl".into()]);
}

// --- media and power -------------------------------------------------------------------------------------

fn run(cmd: &str, args: &[&str]) -> bool {
    which(cmd).is_some_and(|p| Command::new(p).args(args).stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null()).status().is_ok_and(|s| s.success()))
}

/// Volume goes to the sound server (PulseAudio or PipeWire's pulse layer); transport goes to the active MPRIS player.
pub fn media_key(action: &str) -> bool {
    match action {
        "volume_up" => run("pactl", &["set-sink-volume", "@DEFAULT_SINK@", "+5%"]),
        "volume_down" => run("pactl", &["set-sink-volume", "@DEFAULT_SINK@", "-5%"]),
        "mute" => run("pactl", &["set-sink-mute", "@DEFAULT_SINK@", "toggle"]),
        "toggle" | "next" | "prev" | "stop" => {
            let method = match action {
                "toggle" => "PlayPause",
                "next" => "Next",
                "prev" => "Previous",
                _ => "Stop",
            };
            let Ok(conn) = Connection::new_session() else { return false };
            let Some((name, _)) = current_player(&conn) else { return false };
            conn.with_proxy(name, "/org/mpris/MediaPlayer2", Duration::from_secs(2)).method_call::<(), _, _, _>(PLAYER, method, ()).is_ok()
        }
        _ => false,
    }
}

/// "lock" or "sleep". Never shutdown from a phone message: too destructive for one tap.
pub fn power(action: &str) -> bool {
    match action {
        "lock" => run("loginctl", &["lock-session"]),
        "sleep" => run("systemctl", &["suspend"]),
        _ => false,
    }
}

/// (percent, plugged in); None on a desktop PC.
pub fn battery() -> Option<(u8, bool)> {
    let read = |dir: &Path, f: &str| std::fs::read_to_string(dir.join(f)).ok().map(|s| s.trim().to_string());
    for entry in std::fs::read_dir("/sys/class/power_supply").ok()?.flatten() {
        let dir = entry.path();
        // "Device" scope is a mouse or a headset, not this computer.
        if read(&dir, "type").as_deref() != Some("Battery") || read(&dir, "scope").as_deref() == Some("Device") {
            continue;
        }
        let level = read(&dir, "capacity")?.parse::<u8>().ok().filter(|&l| l <= 100)?;
        let plugged = matches!(read(&dir, "status").as_deref(), Some("Charging" | "Full" | "Not charging"));
        return Some((level, plugged));
    }
    None
}

const PLAYER: &str = "org.mpris.MediaPlayer2.Player";

/// The player that is playing, else the first one. Name on the bus and its Player properties.
fn current_player(conn: &Connection) -> Option<(String, PropMap)> {
    let (names,): (Vec<String>,) = conn
        .with_proxy("org.freedesktop.DBus", "/org/freedesktop/DBus", Duration::from_secs(2))
        .method_call("org.freedesktop.DBus", "ListNames", ())
        .ok()?;
    let mut first = None;
    for name in names.into_iter().filter(|n| n.starts_with("org.mpris.MediaPlayer2.")) {
        let Ok(props) = conn.with_proxy(name.as_str(), "/org/mpris/MediaPlayer2", Duration::from_secs(2)).get_all(PLAYER) else { continue };
        if prop_cast::<String>(&props, "PlaybackStatus").is_some_and(|s| s == "Playing") {
            return Some((name, props));
        }
        first.get_or_insert((name, props));
    }
    first
}

/// What the active MPRIS player (Spotify, Firefox, VLC, Elisa…) reports. None when nothing is open.
pub fn media_state() -> Option<Media> {
    let conn = Connection::new_session().ok()?;
    let (name, props) = current_player(&conn)?;
    let meta = prop_cast::<PropMap>(&props, "Metadata");
    let text = |k: &str| meta.and_then(|m| m.get(k)).and_then(|v| v.0.as_str()).unwrap_or("").to_string();
    let artist = meta
        .and_then(|m| m.get("xesam:artist"))
        .and_then(|v| v.0.as_iter())
        .map(|it| it.filter_map(|a| a.as_str().map(String::from)).collect::<Vec<_>>().join(", "))
        .unwrap_or_default();
    let micros = |v: Option<&dbus::arg::Variant<Box<dyn RefArg>>>| v.and_then(|v| v.0.as_i64()).unwrap_or(0) / 1000;
    let flag = |k: &str, bit: u64| if prop_cast::<bool>(&props, k) == Some(&true) { bit } else { 0 };
    let app = conn
        .with_proxy(name.as_str(), "/org/mpris/MediaPlayer2", Duration::from_secs(2))
        .get::<String>("org.mpris.MediaPlayer2", "Identity")
        .unwrap_or_else(|_| name.trim_start_matches("org.mpris.MediaPlayer2.").to_string());
    Some(Media {
        app,
        title: text("xesam:title"),
        artist,
        playing: prop_cast::<String>(&props, "PlaybackStatus").is_some_and(|s| s == "Playing"),
        position_ms: micros(props.get("Position")),
        duration_ms: micros(meta.and_then(|m| m.get("mpris:length"))),
        actions: flag("CanGoPrevious", 16) | flag("CanGoNext", 32) | flag("CanPlay", 4) | flag("CanPause", 2) | 512,
        speed: prop_cast::<f64>(&props, "Rate").copied().unwrap_or(1.0),
    })
}

/// Cover of the current player: a `file://` image, or an http(s) one fetched with curl. Covers over 150 KB are
/// dropped. shortcut: no resizing (Windows shrinks big covers); add it with the png/jpeg crates if players that
/// hand over huge images turn out to be common.
pub fn media_art() -> Option<Vec<u8>> {
    let conn = Connection::new_session().ok()?;
    let (_, props) = current_player(&conn)?;
    let url = prop_cast::<PropMap>(&props, "Metadata")?.get("mpris:artUrl")?.0.as_str()?.to_string();
    let bytes = if let Some(path) = url.strip_prefix("file://") {
        std::fs::read(percent_decode(path)).ok()?
    } else if url.starts_with("https://") || url.starts_with("http://") {
        let out = Command::new(which("curl")?)
            .args(["-sfL", "--max-time", "3", "--max-filesize", "150000", "--", &url])
            .stdin(Stdio::null())
            .stderr(Stdio::null())
            .output()
            .ok()?;
        out.status.success().then_some(out.stdout)?
    } else {
        return None;
    };
    (!bytes.is_empty() && bytes.len() <= 150_000).then_some(bytes)
}

fn percent_decode(s: &str) -> String {
    let b = s.as_bytes();
    let mut out = Vec::with_capacity(b.len());
    let mut i = 0;
    while i < b.len() {
        match (b[i], b.get(i + 1..i + 3).and_then(|h| std::str::from_utf8(h).ok()).and_then(|h| u8::from_str_radix(h, 16).ok())) {
            (b'%', Some(v)) => {
                out.push(v);
                i += 3;
            }
            (c, _) => {
                out.push(c);
                i += 1;
            }
        }
    }
    String::from_utf8_lossy(&out).into_owned()
}

// --- screen ----------------------------------------------------------------------------------------------

/// Monitors as (left, top, right, bottom), primary first. X11: XRandR. Elsewhere: the connected outputs the kernel
/// reports, laid out left to right. shortcut: on Wayland the real positions and scale are unknown to a client
/// without a portal; add them if the compositor's protocol is ever queried.
pub fn monitors() -> Vec<(i32, i32, i32, i32)> {
    if !is_wayland() {
        if let Some(found) = x11_monitors().filter(|m| !m.is_empty()) {
            return found;
        }
    }
    drm_monitors()
}

fn x11_monitors() -> Option<Vec<(i32, i32, i32, i32)>> {
    let guard = x11();
    let x = guard.as_ref()?;
    unsafe {
        let mut out = Vec::new();
        if let Some(xr) = &x.xrandr {
            let mut n = 0;
            let list = (xr.XRRGetMonitors)(x.dpy, x.root, 1, &mut n);
            if !list.is_null() {
                for m in std::slice::from_raw_parts(list, n.max(0) as usize) {
                    if m.width > 0 && m.height > 0 {
                        out.push((m.primary != 0, m.x, m.y, m.x + m.width, m.y + m.height));
                    }
                }
                (xr.XRRFreeMonitors)(list);
            }
        }
        if out.is_empty() {
            let screen = (x.xlib.XDefaultScreen)(x.dpy);
            out.push((true, 0, 0, (x.xlib.XDisplayWidth)(x.dpy, screen), (x.xlib.XDisplayHeight)(x.dpy, screen)));
        }
        out.sort_by_key(|m| (!m.0, m.2, m.1));
        Some(out.into_iter().map(|(_, l, t, r, b)| (l, t, r, b)).collect())
    }
}

fn drm_monitors() -> Vec<(i32, i32, i32, i32)> {
    let mut cards: Vec<_> = std::fs::read_dir("/sys/class/drm").into_iter().flatten().flatten().map(|e| e.path()).collect();
    cards.sort();
    let mut left = 0;
    let mut out = Vec::new();
    for dir in cards {
        let read = |f: &str| std::fs::read_to_string(dir.join(f)).unwrap_or_default();
        // Connectors are "card0-HDMI-A-1"; "enabled" is absent on some drivers, "disabled" means no picture.
        if !dir.file_name().is_some_and(|n| n.to_string_lossy().contains('-')) || read("status").trim() != "connected" || read("enabled").trim() == "disabled" {
            continue;
        }
        let modes = read("modes");
        if let Some((w, h)) = modes.lines().next().and_then(|l| l.split_once('x')).and_then(|(w, h)| Some((w.parse::<i32>().ok()?, h.trim().parse::<i32>().ok()?))) {
            out.push((left, 0, left + w, h));
            left += w;
        }
    }
    out
}

/// Monitor index 0 is the primary screen.
pub fn capture(width: u32) -> Option<(u32, u32, Vec<u8>)> {
    capture_monitor(width, 0, true)
}

/// Where the pointer is on a monitor, as fractions of its width and height. On Wayland a client cannot ask for
/// it: the position follows the movements this daemon injects (`VIRTUAL_POINTER`). None while it is on another monitor.
pub fn cursor_at(monitor: usize) -> Option<(f64, f64)> {
    if is_wayland() {
        let (w, h) = wayland_logical();
        let (x, y) = (*VIRTUAL_POINTER.lock().unwrap_or_else(|e| e.into_inner()))?;
        return (monitor == 0).then_some((x / w, y / h));
    }
    let (left, top, right, bottom) = *monitors().get(monitor)?;
    let guard = x11();
    let x = guard.as_ref()?;
    let (mut root_ret, mut child, mut rx, mut ry, mut wx, mut wy, mut mask) = (0, 0, 0, 0, 0, 0, 0);
    let ok = unsafe { (x.xlib.XQueryPointer)(x.dpy, x.root, &mut root_ret, &mut child, &mut rx, &mut ry, &mut wx, &mut wy, &mut mask) };
    (ok != 0 && rx >= left && rx < right && ry >= top && ry < bottom)
        .then(|| ((rx - left) as f64 / (right - left) as f64, (ry - top) as f64 / (bottom - top) as f64))
}

/// Pixels come back as BGRA rows, top first (what the JPEG encoder takes as it is). The pointer is not drawn into
/// the picture unless `cursor` (the viewer does not draw its own): then spectacle and grim are asked for it. shortcut:
/// X11 has no cursor in XGetImage (needs XFixes); the phone draws its own from `cursor_at` there.
pub fn capture_monitor(width: u32, monitor: usize, cursor: bool) -> Option<(u32, u32, Vec<u8>)> {
    let (src_w, src_h, bgra) = if is_wayland() {
        // shortcut: the screenshot tool captures every screen as one picture and costs a process per frame
        // (a frame or two per second); only monitor 0 is offered. Move to the ScreenCast portal + PipeWire.
        if monitor != 0 {
            return None;
        }
        capture_wayland(cursor)?
    } else {
        let (left, top, right, bottom) = *monitors().get(monitor)?;
        capture_x11(left, top, (right - left) as u32, (bottom - top) as u32)?
    };
    let dw = width.min(src_w).max(16);
    let dh = ((src_h as u64 * dw as u64) / src_w as u64).max(1) as u32;
    let pixels = if dw == src_w { bgra } else { shrink(&bgra, src_w as usize, src_h as usize, dw as usize, dh as usize) };
    Some((dw, dh, pixels))
}

fn capture_x11(left: i32, top: i32, w: u32, h: u32) -> Option<(u32, u32, Vec<u8>)> {
    if w == 0 || h == 0 {
        return None;
    }
    let guard = x11();
    let x = guard.as_ref()?;
    unsafe {
        let img = (x.xlib.XGetImage)(x.dpy, x.root, left, top, w, h, !0, 2 /* ZPixmap */);
        if img.is_null() {
            return None;
        }
        let i = &*img;
        let mut out = None;
        // A 32-bit ZPixmap is B, G, R, unused per pixel on the little-endian machines this targets.
        if i.bits_per_pixel == 32 && i.byte_order == 0 && !i.data.is_null() && i.bytes_per_line >= (w * 4) as i32 {
            let src = std::slice::from_raw_parts(i.data.cast::<u8>(), i.bytes_per_line as usize * h as usize);
            let mut bgra = Vec::with_capacity((w * h * 4) as usize);
            for row in src.chunks_exact(i.bytes_per_line as usize) {
                bgra.extend_from_slice(&row[..(w * 4) as usize]);
            }
            bgra.iter_mut().skip(3).step_by(4).for_each(|a| *a = 255);
            out = Some((w, h, bgra));
        }
        (x.xlib.XDestroyImage)(img);
        out
    }
}

/// The compositor's own screenshot tool: spectacle (KDE), grim (wlroots), gnome-screenshot (GNOME).
fn shot_tool() -> Option<(&'static str, std::path::PathBuf)> {
    ["spectacle", "grim", "gnome-screenshot"].into_iter().find_map(|t| which(t).map(|p| (t, p)))
}

fn capture_wayland(cursor: bool) -> Option<(u32, u32, Vec<u8>)> {
    let (tool, path) = shot_tool()?;
    let dir = std::env::var_os("XDG_RUNTIME_DIR").map(std::path::PathBuf::from).unwrap_or_else(std::env::temp_dir);
    let file = dir.join(format!("alero-shot-{}.png", std::process::id()));
    let mut args: Vec<&std::ffi::OsStr> = match tool {
        "spectacle" => vec!["-b".as_ref(), "-n".as_ref(), "-f".as_ref(), "-o".as_ref(), file.as_os_str()],
        "gnome-screenshot" => vec!["-f".as_ref(), file.as_os_str()],
        _ => vec![file.as_os_str()],
    };
    match (tool, cursor) {
        ("spectacle", true) => args.insert(0, "-p".as_ref()),
        ("grim", true) => args.insert(0, "-c".as_ref()),
        ("gnome-screenshot", true) => args.insert(0, "-p".as_ref()),
        _ => {}
    }
    let ok = Command::new(path).args(args).stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null()).status().is_ok_and(|s| s.success());
    let decoded = ok.then(|| decode_png(&file)).flatten();
    let _ = std::fs::remove_file(&file);
    decoded
}

/// 8-bit RGB or RGBA PNG as BGRA.
fn decode_png(path: &Path) -> Option<(u32, u32, Vec<u8>)> {
    let mut decoder = png::Decoder::new(std::io::BufReader::new(File::open(path).ok()?));
    decoder.set_transformations(png::Transformations::normalize_to_color8());
    let mut reader = decoder.read_info().ok()?;
    let mut buf = vec![0; reader.output_buffer_size()?];
    let info = reader.next_frame(&mut buf).ok()?;
    let channels = match info.color_type {
        png::ColorType::Rgb => 3,
        png::ColorType::Rgba => 4,
        _ => return None,
    };
    let mut bgra = Vec::with_capacity(info.width as usize * info.height as usize * 4);
    for px in buf[..info.buffer_size()].chunks_exact(channels) {
        bgra.extend_from_slice(&[px[2], px[1], px[0], 255]);
    }
    Some((info.width, info.height, bgra))
}

/// Box filter: every output pixel is the average of the source block it covers (sharper text than nearest).
fn shrink(src: &[u8], sw: usize, sh: usize, dw: usize, dh: usize) -> Vec<u8> {
    let mut out = vec![255u8; dw * dh * 4];
    for dy in 0..dh {
        let (y0, y1) = (dy * sh / dh, ((dy + 1) * sh / dh).clamp(dy * sh / dh + 1, sh));
        for dx in 0..dw {
            let (x0, x1) = (dx * sw / dw, ((dx + 1) * sw / dw).clamp(dx * sw / dw + 1, sw));
            let mut sum = [0u32; 3];
            for y in y0..y1 {
                for px in src[(y * sw + x0) * 4..(y * sw + x1) * 4].chunks_exact(4) {
                    sum[0] += px[0] as u32;
                    sum[1] += px[1] as u32;
                    sum[2] += px[2] as u32;
                }
            }
            let n = ((y1 - y0) * (x1 - x0)) as u32;
            let o = (dy * dw + dx) * 4;
            out[o..o + 3].copy_from_slice(&[(sum[0] / n) as u8, (sum[1] / n) as u8, (sum[2] / n) as u8]);
        }
    }
    out
}

// --- identity --------------------------------------------------------------------------------------------

/// Hardware identity from the firmware tables the kernel exposes (no wallpaper: the phone keeps its stock picture).
pub fn device_metadata() -> serde_json::Value {
    let dmi = |f: &str| std::fs::read_to_string(format!("/sys/class/dmi/id/{f}")).unwrap_or_default().trim().to_string();
    identity(&dmi("sys_vendor"), &dmi("product_name"), &dmi("product_version"), &dmi("product_family"))
}

/// Firmware often leaves placeholders ("Default string", "To be filled by O.E.M.") or a legal name in the DMI fields.
/// Model: a real version (ThinkPads keep their name there), else the product name, else the family ("APL" is a platform).
fn identity(vendor: &str, name: &str, version: &str, family: &str) -> serde_json::Value {
    let clean = |s: &str| {
        let l = s.to_lowercase();
        let junk = ["default string", "to be filled", "system product", "system manufacturer", "not specified", "none", "unknown", "o.e.m"];
        if s.is_empty() || junk.iter().any(|j| l.contains(j)) { String::new() } else { s.to_string() }
    };
    let words: Vec<&str> = vendor.split_whitespace().collect();
    // "CHUWI Innovation And Technology(ShenZhen)co.,Ltd" -> "CHUWI".
    let vendor = if words.len() > 2 { words[0].to_string() } else { vendor.to_string() };
    let model = [Some(clean(version)).filter(|s| s.len() > 4), Some(clean(name)), Some(clean(family))].into_iter().flatten().find(|s| !s.is_empty()).unwrap_or_default();
    serde_json::json!({"manufacturer": clean(&vendor), "model": model, "product": clean(name), "stockJpeg": ""})
}

/// Why the screen cannot be shared here, for the phone to show; empty when it can.
pub fn screen_note() -> &'static str {
    if CAPS.screen {
        ""
    } else if is_wayland() {
        "En Wayland hace falta spectacle, grim o gnome-screenshot para capturar la pantalla."
    } else {
        "No se pudo abrir la pantalla (servidor X)."
    }
}

pub fn screen_size() -> (i32, i32) {
    monitors().first().map(|&(l, t, r, b)| (r - l, b - t)).unwrap_or((0, 0))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn keys_map_to_evdev_codes() {
        assert_eq!(key_code("Enter"), Some(28));
        assert_eq!((key_code("a"), key_code("z"), key_code("q")), (Some(30), Some(44), Some(16)));
        assert_eq!((key_code("1"), key_code("0")), (Some(2), Some(11)));
        assert_eq!((key_code("f1"), key_code("F10"), key_code("f11"), key_code("f12")), (Some(59), Some(68), Some(87), Some(88)));
        assert_eq!((key_code("f13"), key_code("ñ"), key_code("ctrl+c"), key_code("")), (None, None, None, None));
    }

    #[test]
    fn shrink_averages_blocks() {
        // 2x2 BGRA pixels with blue 0, 100, 100, 200 -> one pixel with blue 100.
        let src = [0, 0, 0, 255, 100, 0, 0, 255, 100, 0, 0, 255, 200, 0, 0, 255];
        assert_eq!(shrink(&src, 2, 2, 1, 1), vec![100, 0, 0, 255]);
    }

    #[test]
    fn art_urls_are_decoded() {
        assert_eq!(percent_decode("/home/n/M%C3%BAsica/a%20b.jpg"), "/home/n/Música/a b.jpg");
        assert_eq!(percent_decode("100%"), "100%");
    }

    #[test]
    fn identity_drops_placeholders() {
        let v = identity("CHUWI Innovation And Technology(ShenZhen)co.,Ltd", "HeroBook Pro+", "Default string", "APL");
        assert_eq!((v["manufacturer"].as_str(), v["model"].as_str()), (Some("CHUWI"), Some("HeroBook Pro+")));
        let t = identity("LENOVO", "20XW", "ThinkPad X1", "ThinkPad X1 Carbon");
        assert_eq!(t["model"], "ThinkPad X1");
        assert_eq!(identity("To be filled by O.E.M.", "", "", "")["model"], "");
    }

    #[test]
    fn dmi_never_panics() {
        assert!(device_metadata().is_object());
    }
}
