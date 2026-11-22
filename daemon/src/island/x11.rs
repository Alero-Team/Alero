//! Alero Island's window on X11 (and XWayland sessions that report an X display): an override-redirect ARGB window
//! that is shown only while the island is, the pointer read with `XQueryPointer`, files dropped on it received
//! with the XDND protocol. Pure Wayland sessions have no way to know where the pointer is, so there is no island.

use std::os::raw::{c_int, c_long, c_uchar, c_ulong};
use std::path::PathBuf;
use std::ptr;
use std::time::{Duration, Instant};

use x11_dl::xfixes::{self, XserverRegion};
use x11_dl::xlib::{self, Atom, Display, Window, Xlib};

use super::run::{Host, HostEvent, Rect};
use super::ui::Drag;

pub struct X11Host {
    x: Xlib,
    dpy: *mut Display,
    root: Window,
    win: Window,
    gc: xlib::GC,
    visual: *mut xlib::Visual,
    mapped: bool,
    geom: (i32, i32, u32, u32),
    /// Opaque part of the last frame sent, in window pixels: the next frame resends it too, so what turned
    /// transparent is cleared.
    drawn: Option<Bounds>,
    /// XFixes input shapes; None on a server without them (the window then keeps the mouse, as before 1.4.7).
    fixes: Option<xfixes::Xlib>,
    input: bool,
    /// The input region last set: Some(None) = click-through, Some(Some(b)) = only `b` takes the mouse.
    shape: Option<Option<Bounds>>,
    buf: Vec<u8>,
    raised: Instant,
    dpi: f32,
    dpi_at: Option<Instant>,
    atoms: Atoms,
    dnd: Option<Dnd>,
    /// The window holds the keyboard (a reply is being written); the one that had it before.
    keys: bool,
    prev_focus: Option<Window>,
}

#[derive(Clone, Copy)]
struct Atoms {
    aware: Atom,
    enter: Atom,
    position: Atom,
    status: Atom,
    leave: Atom,
    drop: Atom,
    finished: Atom,
    selection: Atom,
    type_list: Atom,
    uri_list: Atom,
    copy: Atom,
    prop: Atom,
    active: Atom,
    wm_state: Atom,
    fullscreen: Atom,
}

/// (x0, y0, x1, y1), end exclusive.
type Bounds = (u32, u32, u32, u32);

/// The rectangle holding every pixel that is not fully transparent.
fn opaque_bounds(rgba: &[u8], w: u32, h: u32) -> Option<Bounds> {
    let (mut x0, mut y0, mut x1, mut y1) = (w, h, 0u32, 0u32);
    for row in 0..h {
        let line = &rgba[(row * w * 4) as usize..((row + 1) * w * 4) as usize];
        if let Some(f) = line.chunks_exact(4).position(|p| p[3] != 0) {
            let last = line.chunks_exact(4).rposition(|p| p[3] != 0).unwrap_or(f);
            x0 = x0.min(f as u32);
            x1 = x1.max(last as u32 + 1);
            y0 = y0.min(row);
            y1 = y1.max(row + 1);
        }
    }
    (x1 > x0 && y1 > y0).then_some((x0, y0, x1, y1))
}

fn union(a: Bounds, b: Bounds) -> Bounds {
    (a.0.min(b.0), a.1.min(b.1), a.2.max(b.2), a.3.max(b.3))
}

struct Dnd {
    source: Window,
    accepts: bool,
}

fn atom(x: &Xlib, dpy: *mut Display, name: &str) -> Atom {
    let c = std::ffi::CString::new(name).unwrap();
    unsafe { (x.XInternAtom)(dpy, c.as_ptr(), 0) }
}

impl X11Host {
    pub fn new() -> Option<Self> {
        if crate::linux::is_wayland() && std::env::var_os("DISPLAY").is_none() {
            return None;
        }
        let x = Xlib::open().ok()?;
        unsafe {
            let dpy = (x.XOpenDisplay)(ptr::null());
            if dpy.is_null() {
                return None;
            }
            let screen = (x.XDefaultScreen)(dpy);
            let root = (x.XRootWindow)(dpy, screen);
            let mut vi: xlib::XVisualInfo = std::mem::zeroed();
            if (x.XMatchVisualInfo)(dpy, screen, 32, xlib::TrueColor, &mut vi) == 0 {
                return None;
            }
            let cmap = (x.XCreateColormap)(dpy, root, vi.visual, xlib::AllocNone);
            let mut attrs: xlib::XSetWindowAttributes = std::mem::zeroed();
            attrs.override_redirect = 1;
            attrs.colormap = cmap;
            attrs.border_pixel = 0;
            attrs.background_pixel = 0;
            attrs.event_mask = xlib::ExposureMask;
            let win = (x.XCreateWindow)(
                dpy,
                root,
                0,
                0,
                16,
                16,
                0,
                32,
                xlib::InputOutput as u32,
                vi.visual,
                xlib::CWOverrideRedirect | xlib::CWColormap | xlib::CWBorderPixel | xlib::CWBackPixel | xlib::CWEventMask,
                &mut attrs,
            );
            if win == 0 {
                return None;
            }
            let gc = (x.XCreateGC)(dpy, win, 0, ptr::null_mut());
            let atoms = Atoms {
                aware: atom(&x, dpy, "XdndAware"),
                enter: atom(&x, dpy, "XdndEnter"),
                position: atom(&x, dpy, "XdndPosition"),
                status: atom(&x, dpy, "XdndStatus"),
                leave: atom(&x, dpy, "XdndLeave"),
                drop: atom(&x, dpy, "XdndDrop"),
                finished: atom(&x, dpy, "XdndFinished"),
                selection: atom(&x, dpy, "XdndSelection"),
                type_list: atom(&x, dpy, "XdndTypeList"),
                uri_list: atom(&x, dpy, "text/uri-list"),
                copy: atom(&x, dpy, "XdndActionCopy"),
                prop: atom(&x, dpy, "ALERO_ISLAND_DROP"),
                active: atom(&x, dpy, "_NET_ACTIVE_WINDOW"),
                wm_state: atom(&x, dpy, "_NET_WM_STATE"),
                fullscreen: atom(&x, dpy, "_NET_WM_STATE_FULLSCREEN"),
            };
            // XdndAware: protocol version 5.
            let version: c_long = 5;
            (x.XChangeProperty)(dpy, win, atoms.aware, xlib::XA_ATOM, 32, xlib::PropModeReplace, &version as *const c_long as *const c_uchar, 1);
            // Window shapes need XFixes 2; the version query is also the handshake the extension requires.
            let fixes = xfixes::Xlib::open().ok().filter(|f| {
                let (mut ev, mut err, mut major, minor) = (0, 0, 5, 0);
                (f.XFixesQueryExtension)(dpy, &mut ev, &mut err) != 0 && (f.XFixesQueryVersion)(dpy, &mut major, &minor) != 0 && major >= 2
            });
            let mut host = Self {
                x, dpy, root, win, gc, visual: vi.visual, mapped: false, geom: (0, 0, 0, 0), drawn: None, fixes, input: false, shape: None,
                buf: Vec::new(), raised: Instant::now(), dpi: 1.0, dpi_at: None, atoms, dnd: None, keys: false, prev_focus: None,
            };
            // Starts click-through: the resting notch and the shadow must never cover the window below.
            host.apply_input();
            Some(host)
        }
    }

    /// Sets the input region: nothing while the island does not want the mouse, otherwise its drawn part.
    fn apply_input(&mut self) {
        let want = if self.input { self.drawn } else { None };
        if self.shape == Some(want) {
            return;
        }
        let Some(f) = &self.fixes else { return };
        unsafe {
            let mut r = want.map(|(x0, y0, x1, y1)| xlib::XRectangle { x: x0 as i16, y: y0 as i16, width: (x1 - x0) as u16, height: (y1 - y0) as u16 });
            let region: XserverRegion = match r.as_mut() {
                Some(r) => (f.XFixesCreateRegion)(self.dpy, r, 1),
                None => (f.XFixesCreateRegion)(self.dpy, ptr::null_mut(), 0),
            };
            // 2 = ShapeInput: only the mouse is shaped, the picture stays whole.
            (f.XFixesSetWindowShapeRegion)(self.dpy, self.win, 2, 0, 0, region);
            (f.XFixesDestroyRegion)(self.dpy, region);
        }
        self.shape = Some(want);
    }

    fn send_client(&self, to: Window, kind: Atom, data: [c_long; 5]) {
        unsafe {
            let mut ev: xlib::XClientMessageEvent = std::mem::zeroed();
            ev.type_ = xlib::ClientMessage;
            ev.display = self.dpy;
            ev.window = to;
            ev.message_type = kind;
            ev.format = 32;
            ev.data.as_longs_mut().copy_from_slice(&data);
            let mut e = xlib::XEvent::from(ev);
            (self.x.XSendEvent)(self.dpy, to, 0, xlib::NoEventMask, &mut e);
        }
    }

    /// Does the source offer a list of files? (Up to three types come in the message, more in a property.)
    fn offers_files(&self, source: Window, data: &[c_long]) -> bool {
        let a = &self.atoms;
        if (data[1] & 1) == 0 {
            return data[2..5].contains(&(a.uri_list as c_long));
        }
        unsafe {
            let (mut ty, mut fmt, mut n, mut after): (Atom, c_int, c_ulong, c_ulong) = (0, 0, 0, 0);
            let mut p: *mut c_uchar = ptr::null_mut();
            let ok = (self.x.XGetWindowProperty)(self.dpy, source, a.type_list, 0, 256, 0, xlib::XA_ATOM, &mut ty, &mut fmt, &mut n, &mut after, &mut p);
            let mut found = false;
            if ok == 0 && !p.is_null() && fmt == 32 {
                let list = std::slice::from_raw_parts(p as *const c_long, n as usize);
                found = list.contains(&(a.uri_list as c_long));
            }
            if !p.is_null() {
                (self.x.XFree)(p as *mut _);
            }
            found
        }
    }

    fn handle(&mut self, ev: &mut xlib::XEvent, out: &mut Vec<HostEvent>) {
        let a = self.atoms;
        unsafe {
            match ev.get_type() {
                xlib::KeyPress if self.keys => {
                    use super::ui::Key;
                    let mut buf = [0u8; 32];
                    let mut sym: xlib::KeySym = 0;
                    let n = (self.x.XLookupString)(&mut ev.key, buf.as_mut_ptr() as *mut std::os::raw::c_char, buf.len() as i32, &mut sym, ptr::null_mut());
                    match sym {
                        0xff08 => out.push(HostEvent::Key(Key::Back)),
                        0xff0d | 0xff8d => out.push(HostEvent::Key(Key::Enter)),
                        0xff1b => out.push(HostEvent::Key(Key::Escape)),
                        // Latin-1, which covers every accent of Spanish and the other western languages.
                        _ if n > 0 => {
                            let s: String = buf[..n as usize].iter().map(|&b| b as char).filter(|c| !c.is_control()).collect();
                            if !s.is_empty() {
                                out.push(HostEvent::Text(s));
                            }
                        }
                        _ => {}
                    }
                }
                xlib::FocusOut if self.keys => out.push(HostEvent::Key(super::ui::Key::Escape)),
                xlib::ClientMessage => {
                    let m = ev.client_message;
                    let d = m.data.as_longs().to_vec();
                    let source = d[0] as Window;
                    if m.message_type == a.enter {
                        let accepts = self.offers_files(source, &d);
                        self.dnd = Some(Dnd { source, accepts });
                        if accepts {
                            out.push(HostEvent::Drag(Drag::Enter));
                        }
                    } else if m.message_type == a.position {
                        let accepts = self.dnd.as_ref().is_some_and(|x| x.accepts);
                        self.send_client(source, a.status, [self.win as c_long, accepts as c_long, 0, 0, if accepts { a.copy as c_long } else { 0 }]);
                        if accepts {
                            out.push(HostEvent::Drag(Drag::Over));
                        }
                    } else if m.message_type == a.leave {
                        if self.dnd.take().is_some_and(|x| x.accepts) {
                            out.push(HostEvent::Drag(Drag::Leave));
                        }
                    } else if m.message_type == a.drop {
                        match &self.dnd {
                            Some(Dnd { accepts: true, .. }) => {
                                (self.x.XConvertSelection)(self.dpy, a.selection, a.uri_list, a.prop, self.win, d[2] as c_ulong);
                            }
                            _ => {
                                self.send_client(source, a.finished, [self.win as c_long, 0, 0, 0, 0]);
                                self.dnd = None;
                            }
                        }
                    }
                }
                xlib::SelectionNotify => {
                    let s = ev.selection;
                    let source = self.dnd.take().map(|d| d.source);
                    let mut files = Vec::new();
                    if s.property != 0 {
                        let (mut ty, mut fmt, mut n, mut after): (Atom, c_int, c_ulong, c_ulong) = (0, 0, 0, 0);
                        let mut p: *mut c_uchar = ptr::null_mut();
                        let ok = (self.x.XGetWindowProperty)(self.dpy, self.win, a.prop, 0, 1 << 16, 1, xlib::AnyPropertyType as c_ulong, &mut ty, &mut fmt, &mut n, &mut after, &mut p);
                        if ok == 0 && !p.is_null() && fmt == 8 {
                            let text = String::from_utf8_lossy(std::slice::from_raw_parts(p, n as usize)).into_owned();
                            files = parse_uri_list(&text);
                        }
                        if !p.is_null() {
                            (self.x.XFree)(p as *mut _);
                        }
                    }
                    if let Some(src) = source {
                        self.send_client(src, a.finished, [self.win as c_long, !files.is_empty() as c_long, if files.is_empty() { 0 } else { a.copy as c_long }, 0, 0]);
                    }
                    out.push(HostEvent::Drag(Drag::Leave));
                    if !files.is_empty() {
                        out.push(HostEvent::Drop(files));
                    }
                }
                _ => {}
            }
        }
    }
}

fn percent_decode(s: &str) -> String {
    let b = s.as_bytes();
    let mut out = Vec::with_capacity(b.len());
    let mut i = 0;
    while i < b.len() {
        if b[i] == b'%' && i + 2 < b.len() {
            // Bytes, not &s[..]: a raw UTF-8 name after the "%" would split a character and panic.
            if let Some(v) = std::str::from_utf8(&b[i + 1..i + 3]).ok().and_then(|h| u8::from_str_radix(h, 16).ok()) {
                out.push(v);
                i += 3;
                continue;
            }
        }
        out.push(b[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

/// "file:///home/a/b%20c.txt" lines (comments start with #) into paths.
fn parse_uri_list(text: &str) -> Vec<PathBuf> {
    text.lines()
        .map(str::trim)
        .filter(|l| !l.is_empty() && !l.starts_with('#'))
        .filter_map(|l| l.strip_prefix("file://"))
        .map(|rest| {
            // Optional host before the first slash ("file://localhost/...").
            let path = rest.find('/').map_or(rest, |i| &rest[i..]);
            PathBuf::from(percent_decode(path))
        })
        .collect()
}

impl Host for X11Host {
    fn monitors(&mut self) -> Vec<Rect> {
        crate::sys::monitors()
    }

    fn cursor(&mut self) -> Option<(i32, i32, bool)> {
        unsafe {
            let (mut rr, mut cr): (Window, Window) = (0, 0);
            let (mut rx, mut ry, mut wx, mut wy): (c_int, c_int, c_int, c_int) = (0, 0, 0, 0);
            let mut mask: u32 = 0;
            let ok = (self.x.XQueryPointer)(self.dpy, self.root, &mut rr, &mut cr, &mut rx, &mut ry, &mut wx, &mut wy, &mut mask);
            (ok != 0).then_some((rx, ry, mask & xlib::Button1Mask != 0))
        }
    }

    // shortcut: X11 has one Xft.dpi for every monitor; per-monitor scale needs XRandR, upgrade if mixed-DPI X11 setups appear.
    fn dpi(&mut self, _mon: Rect) -> f32 {
        if self.dpi_at.map_or(true, |t| t.elapsed() > Duration::from_secs(30)) {
            self.dpi_at = Some(Instant::now());
            unsafe {
                let s = (self.x.XResourceManagerString)(self.dpy);
                if !s.is_null() {
                    let text = std::ffi::CStr::from_ptr(s).to_string_lossy().into_owned();
                    if let Some(v) = text.lines().find_map(|l| l.strip_prefix("Xft.dpi:")).and_then(|v| v.trim().parse::<f32>().ok()) {
                        self.dpi = (v / 96.0).clamp(0.75, 4.0);
                    }
                }
            }
        }
        self.dpi
    }

    fn fullscreen(&mut self, _mon: Rect) -> bool {
        let a = &self.atoms;
        unsafe {
            let (mut ty, mut fmt, mut n, mut after): (Atom, c_int, c_ulong, c_ulong) = (0, 0, 0, 0);
            let mut p: *mut c_uchar = ptr::null_mut();
            if (self.x.XGetWindowProperty)(self.dpy, self.root, a.active, 0, 1, 0, xlib::AnyPropertyType as c_ulong, &mut ty, &mut fmt, &mut n, &mut after, &mut p) != 0 || p.is_null() {
                return false;
            }
            let active = if n > 0 && fmt == 32 { *(p as *const c_long) as Window } else { 0 };
            (self.x.XFree)(p as *mut _);
            if active == 0 || active == self.win {
                return false;
            }
            let mut p: *mut c_uchar = ptr::null_mut();
            if (self.x.XGetWindowProperty)(self.dpy, active, a.wm_state, 0, 32, 0, xlib::XA_ATOM, &mut ty, &mut fmt, &mut n, &mut after, &mut p) != 0 || p.is_null() {
                return false;
            }
            let mut found = false;
            if ty == xlib::XA_ATOM && fmt == 32 {
                // Xlib hands back format-32 items as C longs; read them one by one instead of building a slice.
                for i in 0..(n as usize).min(32) {
                    if ptr::read_unaligned((p as *const c_long).add(i)) == a.fullscreen as c_long {
                        found = true;
                        break;
                    }
                }
            }
            (self.x.XFree)(p as *mut _);
            found
        }
    }

    /// A drag-and-drop in progress always has an owner of `XdndSelection`; a window being moved does not.
    fn moving_window(&mut self) -> bool {
        unsafe { (self.x.XGetSelectionOwner)(self.dpy, self.atoms.selection) == 0 }
    }

    fn reduce_motion(&mut self) -> bool {
        false
    }

    fn hotkey(&mut self, _spec: &str) {
        // Global hotkeys on X11 need a key grab on the root window and a layout-aware keycode lookup; the pointer is
        // the way in on Linux for now.
    }

    fn present(&mut self, frame: Option<(&[u8], u32, u32, i32, i32)>) {
        unsafe {
            let Some(((rgba, w, h, x, y), now)) = frame.and_then(|f| opaque_bounds(f.0, f.1, f.2).map(|b| (f, b))) else {
                if self.mapped {
                    (self.x.XUnmapWindow)(self.dpy, self.win);
                    (self.x.XFlush)(self.dpy);
                    self.mapped = false;
                }
                self.drawn = None;
                return;
            };
            // The window keeps the canvas size: resizing it on every frame of an animation made the server clear it
            // before the new picture arrived, and the island flickered while opening. Clicks go through the empty
            // part thanks to the input shape.
            let geom = (x, y, w, h);
            if geom != self.geom {
                (self.x.XMoveResizeWindow)(self.dpy, self.win, x, y, w, h);
                self.geom = geom;
                self.drawn = None;
            }
            // Only the part that changed can be non-transparent: this frame's pixels and the last frame's.
            let (x0, y0, x1, y1) = match self.drawn {
                Some(prev) if self.mapped => union(prev, now),
                _ => now,
            };
            let (cw, ch) = (x1 - x0, y1 - y0);
            self.buf.clear();
            self.buf.reserve((cw * ch * 4) as usize);
            for row in y0..y1 {
                let line = &rgba[((row * w + x0) * 4) as usize..((row * w + x1) * 4) as usize];
                for p in line.chunks_exact(4) {
                    // RGBA (premultiplied) to the server's BGRA.
                    self.buf.extend_from_slice(&[p[2], p[1], p[0], p[3]]);
                }
            }
            let img = (self.x.XCreateImage)(self.dpy, self.visual, 32, xlib::ZPixmap, 0, self.buf.as_mut_ptr() as *mut _, cw, ch, 32, 0);
            if !img.is_null() {
                (self.x.XPutImage)(self.dpy, self.win, self.gc, img, 0, 0, x0 as i32, y0 as i32, cw, ch);
                // The pixels are ours: let the library free only the structure.
                (*img).data = ptr::null_mut();
                (self.x.XDestroyImage)(img);
            }
            self.drawn = Some(now);
            self.apply_input();
            if !self.mapped {
                (self.x.XMapWindow)(self.dpy, self.win);
                self.mapped = true;
                self.raised = Instant::now();
            } else if self.raised.elapsed() > Duration::from_millis(500) {
                (self.x.XRaiseWindow)(self.dpy, self.win);
                self.raised = Instant::now();
            }
            (self.x.XFlush)(self.dpy);
        }
    }

    fn pump(&mut self, ms: u32) -> Vec<HostEvent> {
        let mut out = Vec::new();
        let start = Instant::now();
        loop {
            unsafe {
                while (self.x.XPending)(self.dpy) > 0 {
                    let mut ev: xlib::XEvent = std::mem::zeroed();
                    (self.x.XNextEvent)(self.dpy, &mut ev);
                    self.handle(&mut ev, &mut out);
                }
            }
            let left = (ms as u64).saturating_sub(start.elapsed().as_millis() as u64);
            if left == 0 || !out.is_empty() {
                break;
            }
            // Sleep until the X server has something for us (or the time is up), instead of waking every 20 ms
            // to look.
            let mut fd = libc::pollfd { fd: unsafe { (self.x.XConnectionNumber)(self.dpy) }, events: libc::POLLIN, revents: 0 };
            let n = unsafe { libc::poll(&mut fd, 1, left.min(i32::MAX as u64) as i32) };
            if n < 0 {
                std::thread::sleep(Duration::from_millis(left.min(20)));
            }
        }
        out
    }

    fn vsync(&mut self) {
        std::thread::sleep(Duration::from_millis(8));
    }

    fn beep(&mut self) {}

    fn keep_on_top(&mut self) {
        if self.mapped {
            unsafe {
                (self.x.XRaiseWindow)(self.dpy, self.win);
                (self.x.XFlush)(self.dpy);
            }
        }
    }

    fn set_input(&mut self, on: bool) {
        self.input = on;
        self.apply_input();
    }

    fn set_keyboard(&mut self, on: bool) {
        if self.keys == on {
            return;
        }
        self.keys = on;
        unsafe {
            if on {
                let (mut prev, mut revert) = (0 as Window, 0);
                (self.x.XGetInputFocus)(self.dpy, &mut prev, &mut revert);
                self.prev_focus = (prev > 1 && prev != self.win).then_some(prev);
                (self.x.XSelectInput)(self.dpy, self.win, xlib::ExposureMask | xlib::KeyPressMask | xlib::FocusChangeMask);
                (self.x.XSetInputFocus)(self.dpy, self.win, xlib::RevertToParent, xlib::CurrentTime);
            } else {
                (self.x.XSelectInput)(self.dpy, self.win, xlib::ExposureMask);
                if let Some(prev) = self.prev_focus.take() {
                    (self.x.XSetInputFocus)(self.dpy, prev, xlib::RevertToParent, xlib::CurrentTime);
                }
            }
            (self.x.XFlush)(self.dpy);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bounds_cover_opaque_pixels_and_union_keeps_the_old_ones() {
        let (w, h) = (4u32, 3u32);
        let mut px = vec![0u8; (w * h * 4) as usize];
        assert_eq!(opaque_bounds(&px, w, h), None);
        px[((w + 2) * 4 + 3) as usize] = 9; // (2, 1)
        px[((2 * w + 1) * 4 + 3) as usize] = 1; // (1, 2)
        assert_eq!(opaque_bounds(&px, w, h), Some((1, 1, 3, 3)));
        assert_eq!(union((1, 1, 3, 3), (0, 0, 2, 2)), (0, 0, 3, 3));
    }

    #[test]
    fn uri_lists_become_paths() {
        let t = "# a comment\r\nfile:///home/nico/Mi%20foto.jpg\r\nfile://localhost/tmp/a%23b.txt\r\nhttps://example.com/x\r\n";
        assert_eq!(parse_uri_list(t), vec![PathBuf::from("/home/nico/Mi foto.jpg"), PathBuf::from("/tmp/a#b.txt")]);
        assert_eq!(percent_decode("100%"), "100%");
        assert_eq!(percent_decode("%zz"), "%zz");
        assert_eq!(percent_decode("/a%aé.txt"), "/a%aé.txt");
    }
}
