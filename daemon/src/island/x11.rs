//! Alero Island's window on X11 (and XWayland sessions that report an X display): an override-redirect ARGB window
//! that is shown only while the island is, the pointer read with `XQueryPointer`, files dropped on it received
//! with the XDND protocol. Pure Wayland sessions have no way to know where the pointer is, so there is no island.

use std::os::raw::{c_int, c_long, c_uchar, c_ulong};
use std::path::PathBuf;
use std::ptr;
use std::time::{Duration, Instant};

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
    buf: Vec<u8>,
    raised: Instant,
    dpi: f32,
    dpi_at: Option<Instant>,
    atoms: Atoms,
    dnd: Option<Dnd>,
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
            Some(Self { x, dpy, root, win, gc, visual: vi.visual, mapped: false, geom: (0, 0, 0, 0), buf: Vec::new(), raised: Instant::now(), dpi: 1.0, dpi_at: None, atoms, dnd: None })
        }
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
            if let Ok(v) = u8::from_str_radix(&s[i + 1..i + 3], 16) {
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

    fn dpi(&mut self) -> f32 {
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
            let Some((rgba, w, h, x, y)) = frame else {
                if self.mapped {
                    (self.x.XUnmapWindow)(self.dpy, self.win);
                    (self.x.XFlush)(self.dpy);
                    self.mapped = false;
                }
                return;
            };
            // Only the part that is not transparent: the window is as small as the island, so everything around it
            // stays clickable.
            let (mut x0, mut y0, mut x1, mut y1) = (w, h, 0u32, 0u32);
            for row in 0..h {
                let line = &rgba[(row * w * 4) as usize..((row + 1) * w * 4) as usize];
                let first = line.chunks_exact(4).position(|p| p[3] != 0);
                if let Some(f) = first {
                    let last = line.chunks_exact(4).rposition(|p| p[3] != 0).unwrap_or(f);
                    x0 = x0.min(f as u32);
                    x1 = x1.max(last as u32 + 1);
                    y0 = y0.min(row);
                    y1 = y1.max(row + 1);
                }
            }
            if x1 <= x0 || y1 <= y0 {
                if self.mapped {
                    (self.x.XUnmapWindow)(self.dpy, self.win);
                    self.mapped = false;
                }
                return;
            }
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
            let geom = (x + x0 as i32, y + y0 as i32, cw, ch);
            if geom != self.geom || !self.mapped {
                (self.x.XMoveResizeWindow)(self.dpy, self.win, geom.0, geom.1, cw, ch);
                self.geom = geom;
            }
            if !self.mapped {
                (self.x.XMapWindow)(self.dpy, self.win);
                self.mapped = true;
                self.raised = Instant::now();
            } else if self.raised.elapsed() > Duration::from_millis(500) {
                (self.x.XRaiseWindow)(self.dpy, self.win);
                self.raised = Instant::now();
            }
            let img = (self.x.XCreateImage)(self.dpy, self.visual, 32, xlib::ZPixmap, 0, self.buf.as_mut_ptr() as *mut _, cw, ch, 32, 0);
            if !img.is_null() {
                (self.x.XPutImage)(self.dpy, self.win, self.gc, img, 0, 0, 0, 0, cw, ch);
                // The pixels are ours: let the library free only the structure.
                (*img).data = ptr::null_mut();
                (self.x.XDestroyImage)(img);
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
            std::thread::sleep(Duration::from_millis(left.min(if ms >= 30 { 20 } else { 4 })));
        }
        out
    }

    fn vsync(&mut self) {
        std::thread::sleep(Duration::from_millis(8));
    }

    fn beep(&mut self) {}
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn uri_lists_become_paths() {
        let t = "# a comment\r\nfile:///home/nico/Mi%20foto.jpg\r\nfile://localhost/tmp/a%23b.txt\r\nhttps://example.com/x\r\n";
        assert_eq!(parse_uri_list(t), vec![PathBuf::from("/home/nico/Mi foto.jpg"), PathBuf::from("/tmp/a#b.txt")]);
        assert_eq!(percent_decode("100%"), "100%");
        assert_eq!(percent_decode("%zz"), "%zz");
    }
}
