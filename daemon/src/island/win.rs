//! Alero Island's window on Windows: a layered, topmost, never-activated window with per-pixel alpha that exists
//! only while the island is on screen. It is fed finished frames (premultiplied pixels) and uses nothing but
//! documented user-mode APIs: `UpdateLayeredWindow` for the picture, `GetCursorPos` for the pointer, an OLE drop
//! target for files carried onto it, `SHQueryUserNotificationState` to stay away from games and presentations.

use std::ffi::c_void;
use std::mem::size_of;
use std::path::PathBuf;
use std::ptr;
use std::sync::Mutex;
use std::time::{Duration, Instant};

use windows::core::{implement, w, Ref, BOOL};
use windows::Win32::Foundation::{COLORREF, HINSTANCE, HWND, LPARAM, LRESULT, POINT, POINTL, SIZE, WPARAM};
use windows::Win32::Graphics::Dwm::DwmFlush;
use windows::Win32::Graphics::Gdi::{
    CreateCompatibleDC, CreateDIBSection, DeleteDC, DeleteObject, MonitorFromPoint, SelectObject, MONITOR_DEFAULTTONEAREST, BITMAPINFO, BITMAPINFOHEADER, BI_RGB, BLENDFUNCTION, DIB_RGB_COLORS, HBITMAP, HDC, HGDIOBJ,
};
use windows::Win32::System::Com::{IDataObject, DVASPECT_CONTENT, FORMATETC, TYMED_HGLOBAL};
use windows::Win32::System::Diagnostics::Debug::MessageBeep;
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::System::Ole::{IDropTarget, IDropTarget_Impl, OleInitialize, RegisterDragDrop, ReleaseStgMedium, CF_HDROP, DROPEFFECT, DROPEFFECT_COPY, DROPEFFECT_NONE};
use windows::Win32::System::SystemServices::MODIFIERKEYS_FLAGS;
use windows::Win32::UI::HiDpi::{GetDpiForMonitor, GetDpiForSystem, SetThreadDpiAwarenessContext, DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2, MDT_EFFECTIVE_DPI};
use windows::Win32::UI::Input::KeyboardAndMouse::{GetAsyncKeyState, RegisterHotKey, UnregisterHotKey, HOT_KEY_MODIFIERS, MOD_ALT, MOD_CONTROL, MOD_NOREPEAT, MOD_SHIFT, MOD_WIN, VK_LBUTTON};
use windows::Win32::UI::Shell::{DragQueryFileW, SHQueryUserNotificationState, HDROP, QUNS_BUSY, QUNS_PRESENTATION_MODE, QUNS_RUNNING_D3D_FULL_SCREEN};
use windows::Win32::UI::WindowsAndMessaging::{
    CreateWindowExW, DefWindowProcW, DispatchMessageW, GetCursorPos, GetForegroundWindow, GetGUIThreadInfo, GetWindowThreadProcessId, MsgWaitForMultipleObjects, PeekMessageW,
    RegisterClassW, SetWindowPos, ShowWindow, SystemParametersInfoW, TranslateMessage, UpdateLayeredWindow, GUITHREADINFO, GUI_INMOVESIZE, HWND_TOPMOST, MB_ICONASTERISK, MSG, PM_REMOVE,
    QS_ALLINPUT, SPI_GETCLIENTAREAANIMATION, SWP_NOACTIVATE, SWP_NOMOVE, SWP_NOSIZE, SW_HIDE, SW_SHOWNOACTIVATE, SYSTEM_PARAMETERS_INFO_UPDATE_FLAGS, ULW_ALPHA, WM_HOTKEY,
    WM_MOUSEACTIVATE, WM_MOUSEWHEEL, WNDCLASSW, WS_EX_LAYERED, WS_EX_NOACTIVATE, WS_EX_TOOLWINDOW, WS_EX_TOPMOST, WS_EX_TRANSPARENT, WS_POPUP,
    GetWindowLongW, SetWindowLongW, GWL_EXSTYLE,
};

use super::run::{Host, HostEvent, Rect};
use super::ui::Drag;

/// Events from the window procedure and the drop target, collected for `pump`.
static QUEUE: Mutex<Vec<HostEvent>> = Mutex::new(Vec::new());

fn push(e: HostEvent) {
    if let Ok(mut q) = QUEUE.lock() {
        q.push(e);
    }
}

unsafe extern "system" fn wndproc(hwnd: HWND, msg: u32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
    match msg {
        WM_MOUSEWHEEL => {
            let delta = ((wparam.0 >> 16) & 0xffff) as u16 as i16;
            push(HostEvent::Wheel(delta as f32 / 120.0));
            LRESULT(0)
        }
        WM_HOTKEY => {
            push(HostEvent::Hotkey);
            LRESULT(0)
        }
        // Clicking the island must never take the focus from what the user is working in.
        WM_MOUSEACTIVATE => LRESULT(3),
        _ => unsafe { DefWindowProcW(hwnd, msg, wparam, lparam) },
    }
}

/// Does the dragged data carry files?
fn carries_files(data: &IDataObject) -> bool {
    let fmt = FORMATETC { cfFormat: CF_HDROP.0, ptd: ptr::null_mut(), dwAspect: DVASPECT_CONTENT.0, lindex: -1, tymed: TYMED_HGLOBAL.0 as u32 };
    unsafe { data.QueryGetData(&fmt).is_ok() }
}

fn files_of(data: &IDataObject) -> Vec<PathBuf> {
    let fmt = FORMATETC { cfFormat: CF_HDROP.0, ptd: ptr::null_mut(), dwAspect: DVASPECT_CONTENT.0, lindex: -1, tymed: TYMED_HGLOBAL.0 as u32 };
    let mut out = Vec::new();
    unsafe {
        let Ok(mut medium) = data.GetData(&fmt) else { return out };
        let drop = HDROP(medium.u.hGlobal.0);
        let n = DragQueryFileW(drop, 0xFFFF_FFFF, None);
        for i in 0..n {
            let len = DragQueryFileW(drop, i, None) as usize;
            let mut buf = vec![0u16; len + 1];
            let got = DragQueryFileW(drop, i, Some(&mut buf)) as usize;
            out.push(PathBuf::from(String::from_utf16_lossy(&buf[..got.min(len)])));
        }
        ReleaseStgMedium(&mut medium);
    }
    out
}

#[implement(IDropTarget)]
struct Target;

#[allow(non_snake_case)]
impl IDropTarget_Impl for Target_Impl {
    fn DragEnter(&self, pdataobj: Ref<IDataObject>, _keys: MODIFIERKEYS_FLAGS, _pt: &POINTL, effect: *mut DROPEFFECT) -> windows::core::Result<()> {
        let ok = pdataobj.as_ref().is_some_and(carries_files);
        unsafe {
            if !effect.is_null() {
                *effect = if ok { DROPEFFECT_COPY } else { DROPEFFECT_NONE };
            }
        }
        if ok {
            push(HostEvent::Drag(Drag::Enter));
        }
        Ok(())
    }

    fn DragOver(&self, _keys: MODIFIERKEYS_FLAGS, _pt: &POINTL, effect: *mut DROPEFFECT) -> windows::core::Result<()> {
        unsafe {
            if !effect.is_null() {
                *effect = DROPEFFECT_COPY;
            }
        }
        push(HostEvent::Drag(Drag::Over));
        Ok(())
    }

    fn DragLeave(&self) -> windows::core::Result<()> {
        push(HostEvent::Drag(Drag::Leave));
        Ok(())
    }

    fn Drop(&self, pdataobj: Ref<IDataObject>, _keys: MODIFIERKEYS_FLAGS, _pt: &POINTL, effect: *mut DROPEFFECT) -> windows::core::Result<()> {
        let files = pdataobj.as_ref().map(files_of).unwrap_or_default();
        unsafe {
            if !effect.is_null() {
                *effect = if files.is_empty() { DROPEFFECT_NONE } else { DROPEFFECT_COPY };
            }
        }
        push(HostEvent::Drag(Drag::Leave));
        if !files.is_empty() {
            push(HostEvent::Drop(files));
        }
        Ok(())
    }
}

pub struct WinHost {
    hwnd: HWND,
    dc: HDC,
    bitmap: HBITMAP,
    bits: *mut c_void,
    size: (i32, i32),
    shown: bool,
    topmost_at: Instant,
    _target: IDropTarget,
    hotkey: bool,
    /// The window takes the mouse (otherwise every click goes through it to what is below).
    input: bool,
}

impl WinHost {
    pub fn new() -> Option<Self> {
        unsafe {
            // Real pixels and each monitor's own scale on this thread only (the rest of the daemon stays system-aware).
            let _ = SetThreadDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
            // The drop target needs a single-threaded apartment of its own on this thread.
            let _ = OleInitialize(None);
            let hinst: HINSTANCE = GetModuleHandleW(None).ok()?.into();
            let class = w!("AleroIslandWindow");
            let wc = WNDCLASSW { lpfnWndProc: Some(wndproc), hInstance: hinst, lpszClassName: class, ..Default::default() };
            RegisterClassW(&wc);
            // Starts click-through: the resting notch and the shadow must never cover the window below.
            let hwnd = CreateWindowExW(WS_EX_LAYERED | WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE | WS_EX_TRANSPARENT, class, w!("Alero Island"), WS_POPUP, 0, 0, 1, 1, None, None, Some(hinst), None).ok()?;
            let target: IDropTarget = Target.into();
            let _ = RegisterDragDrop(hwnd, &target);
            let dc = CreateCompatibleDC(None);
            Some(Self { hwnd, dc, bitmap: HBITMAP::default(), bits: ptr::null_mut(), size: (0, 0), shown: false, topmost_at: Instant::now(), _target: target, hotkey: false, input: false })
        }
    }

    /// A top-down 32-bit surface of this size, ready to hold the frame.
    fn surface(&mut self, w: i32, h: i32) -> bool {
        if self.size == (w, h) && !self.bits.is_null() {
            return true;
        }
        unsafe {
            let info = BITMAPINFO {
                bmiHeader: BITMAPINFOHEADER { biSize: size_of::<BITMAPINFOHEADER>() as u32, biWidth: w, biHeight: -h, biPlanes: 1, biBitCount: 32, biCompression: BI_RGB.0, ..Default::default() },
                ..Default::default()
            };
            let mut bits: *mut c_void = ptr::null_mut();
            let Ok(bmp) = CreateDIBSection(Some(self.dc), &info, DIB_RGB_COLORS, &mut bits, None, 0) else { return false };
            if bits.is_null() {
                let _ = DeleteObject(HGDIOBJ(bmp.0));
                return false;
            }
            let old = SelectObject(self.dc, HGDIOBJ(bmp.0));
            let _ = old;
            if !self.bitmap.is_invalid() {
                let _ = DeleteObject(HGDIOBJ(self.bitmap.0));
            }
            self.bitmap = bmp;
            self.bits = bits;
            self.size = (w, h);
        }
        true
    }
}

impl Drop for WinHost {
    fn drop(&mut self) {
        unsafe {
            if !self.bitmap.is_invalid() {
                let _ = DeleteObject(HGDIOBJ(self.bitmap.0));
            }
            let _ = DeleteDC(self.dc);
        }
    }
}

/// "ctrl+alt+i", "win+shift+f9": modifiers and one key.
fn parse_hotkey(spec: &str) -> Option<(HOT_KEY_MODIFIERS, u32)> {
    let mut mods = HOT_KEY_MODIFIERS(0);
    let mut key = None;
    for part in spec.split('+').map(|p| p.trim().to_ascii_lowercase()) {
        match part.as_str() {
            "ctrl" | "control" => mods |= MOD_CONTROL,
            "alt" => mods |= MOD_ALT,
            "shift" => mods |= MOD_SHIFT,
            "win" | "meta" | "super" => mods |= MOD_WIN,
            "space" => key = Some(0x20),
            p if p.len() == 1 && p.as_bytes()[0].is_ascii_alphanumeric() => key = Some(p.as_bytes()[0].to_ascii_uppercase() as u32),
            p if p.starts_with('f') && p[1..].parse::<u32>().is_ok_and(|n| (1..=12).contains(&n)) => key = Some(0x70 + p[1..].parse::<u32>().unwrap() - 1),
            _ => return None,
        }
    }
    // A bare key would swallow it for every program: at least one modifier.
    (mods.0 != 0).then_some(())?;
    key.map(|k| (mods, k))
}

impl Host for WinHost {
    fn monitors(&mut self) -> Vec<Rect> {
        crate::sys::monitors()
    }

    fn cursor(&mut self) -> Option<(i32, i32, bool)> {
        unsafe {
            let mut p = POINT::default();
            GetCursorPos(&mut p).ok()?;
            let down = (GetAsyncKeyState(VK_LBUTTON.0 as i32) as u16) & 0x8000 != 0;
            Some((p.x, p.y, down))
        }
    }

    fn dpi(&mut self, mon: Rect) -> f32 {
        let centre = POINT { x: (mon.0 + mon.2) / 2, y: (mon.1 + mon.3) / 2 };
        let (mut dx, mut dy) = (0u32, 0u32);
        let ok = unsafe { GetDpiForMonitor(MonitorFromPoint(centre, MONITOR_DEFAULTTONEAREST), MDT_EFFECTIVE_DPI, &mut dx, &mut dy) }.is_ok();
        let d = if ok && dx > 0 { dx } else { unsafe { GetDpiForSystem() } };
        if d == 0 { 1.0 } else { (d as f32 / 96.0).clamp(0.75, 4.0) }
    }

    fn fullscreen(&mut self, _mon: Rect) -> bool {
        // The shell's own answer: a game in exclusive or borderless full screen, a presentation, a "busy" app.
        unsafe { SHQueryUserNotificationState().is_ok_and(|s| s == QUNS_BUSY || s == QUNS_RUNNING_D3D_FULL_SCREEN || s == QUNS_PRESENTATION_MODE) }
    }

    fn moving_window(&mut self) -> bool {
        unsafe {
            let fg = GetForegroundWindow();
            if fg.0.is_null() {
                return false;
            }
            let tid = GetWindowThreadProcessId(fg, None);
            let mut info = GUITHREADINFO { cbSize: size_of::<GUITHREADINFO>() as u32, ..Default::default() };
            GetGUIThreadInfo(tid, &mut info).is_ok() && info.flags.contains(GUI_INMOVESIZE)
        }
    }

    fn reduce_motion(&mut self) -> bool {
        let mut on = BOOL(1);
        unsafe {
            if SystemParametersInfoW(SPI_GETCLIENTAREAANIMATION, 0, Some(&mut on as *mut BOOL as *mut c_void), SYSTEM_PARAMETERS_INFO_UPDATE_FLAGS(0)).is_ok() {
                return !on.as_bool();
            }
        }
        false
    }

    fn hotkey(&mut self, spec: &str) {
        unsafe {
            if self.hotkey {
                let _ = UnregisterHotKey(Some(self.hwnd), 1);
                self.hotkey = false;
            }
            if let Some((mods, vk)) = parse_hotkey(spec) {
                self.hotkey = RegisterHotKey(Some(self.hwnd), 1, mods | MOD_NOREPEAT, vk).is_ok();
            }
        }
    }

    fn present(&mut self, frame: Option<(&[u8], u32, u32, i32, i32)>) {
        unsafe {
            let Some((rgba, w, h, x, y)) = frame else {
                if self.shown {
                    let _ = ShowWindow(self.hwnd, SW_HIDE);
                    self.shown = false;
                }
                return;
            };
            if !self.surface(w as i32, h as i32) {
                return;
            }
            // RGBA to the BGRA the surface wants (both premultiplied).
            let dst = std::slice::from_raw_parts_mut(self.bits as *mut u8, (w * h * 4) as usize);
            // Whole pixels as u32 (the compiler vectorizes this): swap the red and blue bytes.
            for (d, s) in dst.chunks_exact_mut(4).zip(rgba.chunks_exact(4)) {
                let v = u32::from_le_bytes([s[0], s[1], s[2], s[3]]);
                let v = (v & 0xFF00_FF00) | ((v & 0xFF) << 16) | ((v >> 16) & 0xFF);
                d.copy_from_slice(&v.to_le_bytes());
            }
            let at = POINT { x, y };
            let size = SIZE { cx: w as i32, cy: h as i32 };
            let src = POINT { x: 0, y: 0 };
            let blend = BLENDFUNCTION { BlendOp: 0, BlendFlags: 0, SourceConstantAlpha: 255, AlphaFormat: 1 };
            let _ = UpdateLayeredWindow(self.hwnd, None, Some(ptr::from_ref(&at)), Some(ptr::from_ref(&size)), Some(self.dc), Some(ptr::from_ref(&src)), COLORREF(0), Some(ptr::from_ref(&blend)), ULW_ALPHA);
            if !self.shown {
                let _ = ShowWindow(self.hwnd, SW_SHOWNOACTIVATE);
                self.shown = true;
                self.topmost_at = Instant::now() - Duration::from_secs(1);
            }
            // Full-screen-ish windows and the taskbar may take the top of the stack: take it back now and then.
            if self.topmost_at.elapsed() > Duration::from_millis(500) {
                let _ = SetWindowPos(self.hwnd, Some(HWND_TOPMOST), 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
                self.topmost_at = Instant::now();
            }
        }
    }

    fn pump(&mut self, ms: u32) -> Vec<HostEvent> {
        unsafe {
            if ms > 0 {
                MsgWaitForMultipleObjects(None, false, ms, QS_ALLINPUT);
            }
            let mut msg = MSG::default();
            while PeekMessageW(&mut msg, None, 0, 0, PM_REMOVE).as_bool() {
                let _ = TranslateMessage(&msg);
                DispatchMessageW(&msg);
            }
        }
        QUEUE.lock().map(|mut q| std::mem::take(&mut *q)).unwrap_or_default()
    }

    fn vsync(&mut self) {
        // Paced by the compositor; where it is off, a short sleep keeps the loop from spinning.
        if unsafe { DwmFlush() }.is_err() {
            std::thread::sleep(Duration::from_millis(8));
        }
    }

    fn beep(&mut self) {
        let _ = unsafe { MessageBeep(MB_ICONASTERISK) };
    }

    fn set_input(&mut self, on: bool) {
        if self.input == on {
            return;
        }
        self.input = on;
        unsafe {
            let ex = GetWindowLongW(self.hwnd, GWL_EXSTYLE) as u32;
            let ex = if on { ex & !WS_EX_TRANSPARENT.0 } else { ex | WS_EX_TRANSPARENT.0 };
            SetWindowLongW(self.hwnd, GWL_EXSTYLE, ex as i32);
        }
    }

    fn keep_on_top(&mut self) {
        if self.shown {
            let _ = unsafe { SetWindowPos(self.hwnd, Some(HWND_TOPMOST), 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE) };
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hotkeys_parse_and_bare_keys_are_refused() {
        let (m, k) = parse_hotkey("Ctrl+Alt+I").unwrap();
        assert_eq!((m.0, k), (MOD_CONTROL.0 | MOD_ALT.0, b'I' as u32));
        assert_eq!(parse_hotkey("win+shift+f9").map(|(m, k)| (m.0, k)), Some((MOD_WIN.0 | MOD_SHIFT.0, 0x78)));
        assert!(parse_hotkey("i").is_none());
        assert!(parse_hotkey("ctrl+").is_none());
        assert!(parse_hotkey("").is_none());
        assert!(parse_hotkey("ctrl+nope").is_none());
    }
}

/// The real window on this desktop: hover, click-through, no focus stolen, an OLE drop and the hotkey. It moves the
/// pointer and presses Ctrl+Alt+Shift+F9, so it is manual: `cargo test -p pb-daemon -- --ignored --test-threads=1 island_live`.
#[cfg(test)]
mod live {
    use std::sync::atomic::{AtomicU32, Ordering};
    use std::sync::{Arc, Mutex};
    use std::time::Duration;

    use pb_core::engine::{Event, PeerState, PeerView};
    use serde_json::json;
    use windows::core::{implement, w, HRESULT, HSTRING, PCWSTR};
    use windows::Win32::Foundation::{HWND, LPARAM, POINT, WPARAM};
    use windows::Win32::System::Threading::GetCurrentThreadId;
    use windows::Win32::System::Com::IDataObject;
    use windows::Win32::System::Ole::{DoDragDrop, IDropSource, IDropSource_Impl, OleInitialize, DROPEFFECT, DROPEFFECT_COPY};
    use windows::Win32::System::SystemServices::MODIFIERKEYS_FLAGS;
    use windows::Win32::UI::Input::KeyboardAndMouse::{SendInput, INPUT, INPUT_0, INPUT_KEYBOARD, KEYBDINPUT, KEYEVENTF_KEYUP, VK_CONTROL, VK_F9, VK_MENU, VK_SHIFT};
    use windows::Win32::UI::Shell::{BHID_DataObject, IShellItem, SHCreateItemFromParsingName};
    use windows::Win32::UI::WindowsAndMessaging::{
        FindWindowExW, GetCursorPos, GetForegroundWindow, GetWindowLongW, GetWindowThreadProcessId, IsWindowVisible, PostThreadMessageW, SetCursorPos, WindowFromPoint, GWL_EXSTYLE, WM_MOUSEMOVE, WS_EX_LAYERED,
        WS_EX_NOACTIVATE, WS_EX_TOOLWINDOW, WS_EX_TOPMOST,
    };

    use super::super::run::{self, Ctx, Exec, Msg};
    use super::super::ui::{Cmd, CANVAS_W};
    use super::WinHost;

    const DRAGDROP_S_DROP: HRESULT = HRESULT(0x0004_0100);
    const DRAGDROP_S_USEDEFAULTCURSORS: HRESULT = HRESULT(0x0004_0102);

    struct Fake(Arc<Mutex<Vec<String>>>);

    impl Exec for Fake {
        fn peers(&self) -> Vec<PeerView> {
            Vec::new()
        }
        fn run(&self, cmd: Cmd, _ctx: &Ctx) -> Option<(bool, String, String)> {
            self.0.lock().unwrap().push(format!("{cmd:?}"));
            None
        }
    }

    #[implement(IDropSource)]
    struct Source(Mutex<u32>);

    #[allow(non_snake_case)]
    impl IDropSource_Impl for Source_Impl {
        fn QueryContinueDrag(&self, _esc: windows::core::BOOL, _keys: MODIFIERKEYS_FLAGS) -> HRESULT {
            let mut n = self.0.lock().unwrap();
            *n += 1;
            if *n > 6 { DRAGDROP_S_DROP } else { HRESULT(0) }
        }
        fn GiveFeedback(&self, _effect: DROPEFFECT) -> HRESULT {
            DRAGDROP_S_USEDEFAULTCURSORS
        }
    }

    fn ours() -> Option<HWND> {
        let me = std::process::id();
        let mut after: Option<HWND> = None;
        loop {
            let h = unsafe { FindWindowExW(None, after, w!("AleroIslandWindow"), PCWSTR::null()) }.ok()?;
            let mut pid = 0;
            unsafe { GetWindowThreadProcessId(h, Some(&mut pid)) };
            if pid == me {
                return Some(h);
            }
            after = Some(h);
        }
    }

    fn visible() -> bool {
        ours().is_some_and(|h| unsafe { IsWindowVisible(h) }.as_bool())
    }

    fn at(x: i32, y: i32) {
        unsafe { SetCursorPos(x, y) }.unwrap();
    }

    fn wait() {
        std::thread::sleep(Duration::from_millis(900));
    }

    fn keys(up: bool) {
        let mut list = vec![VK_CONTROL, VK_MENU, VK_SHIFT, VK_F9];
        if up {
            list.reverse();
        }
        let inputs: Vec<INPUT> = list
            .into_iter()
            .map(|k| INPUT {
                r#type: INPUT_KEYBOARD,
                Anonymous: INPUT_0 { ki: KEYBDINPUT { wVk: k, dwFlags: if up { KEYEVENTF_KEYUP } else { Default::default() }, ..Default::default() } },
            })
            .collect();
        unsafe { SendInput(&inputs, std::mem::size_of::<INPUT>() as i32) };
    }

    fn hotkey() {
        keys(false);
        keys(true);
    }

    #[test]
    #[ignore]
    fn island_live() {
        crate::sys::init();
        let dir = std::env::temp_dir().join(format!("alero-island-live-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("island.json"), r#"{"monitor":0,"open_delay_ms":0,"hide_fullscreen":false,"hotkey":"ctrl+alt+shift+f9"}"#).unwrap();
        let file = dir.join("prueba isla.txt");
        std::fs::write(&file, "hola").unwrap();

        let log = Arc::new(Mutex::new(Vec::new()));
        let (_handle, rx, tx) = run::channel();
        let peer = PeerView { id: "p".into(), name: "Pixel".into(), addr: String::new(), state: PeerState::Connected, trusted: true, detail: String::new() };
        tx.send(Msg::Event(Event::PeerChanged { peer })).unwrap();
        tx.send(Msg::Event(Event::Message { peer_id: "p".into(), kind: "pb.x.info".into(), body: json!({"kind":"phone","battery":{"level":80,"charging":false}}) })).unwrap();
        let (exec, data) = (Box::new(Fake(log.clone())), dir.clone());
        std::thread::spawn(move || run::run(Box::new(WinHost::new().expect("window")), rx, tx, data, exec));

        let mut back = POINT::default();
        unsafe { GetCursorPos(&mut back) }.unwrap();
        let fg = unsafe { GetForegroundWindow() };
        let m = crate::sys::monitors()[0];
        let (cx, mid) = ((m.0 + m.2) / 2, (m.1 + m.3) / 2);
        let k = unsafe { windows::Win32::UI::HiDpi::GetDpiForSystem() } as f32 / 96.0;
        // 1. Hover on the top edge opens it, as a layered, topmost, non-activating tool window.
        at(cx, mid);
        std::thread::sleep(Duration::from_millis(500));
        assert!(!visible(), "closed at rest");
        at(cx, m.1 + 1);
        wait();
        assert!(visible(), "hover opens it");
        let h = ours().unwrap();
        let ex = unsafe { GetWindowLongW(h, GWL_EXSTYLE) } as u32;
        for f in [WS_EX_LAYERED, WS_EX_TOPMOST, WS_EX_NOACTIVATE, WS_EX_TOOLWINDOW] {
            assert!(ex & f.0 != 0, "style {:#x}", f.0);
        }
        assert_eq!(unsafe { GetForegroundWindow() }, fg, "it never takes the focus");
        // 2. On the island it stays; its drawn pixels take the pointer and the transparent corner lets it through.
        let on = POINT { x: cx, y: m.1 + (40.0 * k) as i32 };
        at(on.x, on.y);
        std::thread::sleep(Duration::from_millis(400));
        assert!(visible(), "stays while the pointer is on it");
        assert_eq!(unsafe { WindowFromPoint(on) }, h, "drawn pixels are hit");
        let corner = POINT { x: cx - (CANVAS_W * k / 2.0) as i32 + 2, y: m.1 + 2 };
        assert_ne!(unsafe { WindowFromPoint(corner) }, h, "transparent pixels are click-through");
        // 3. A file carried onto it by OLE drag and drop becomes a send command.
        let path = file.clone();
        let tid = Arc::new(AtomicU32::new(0));
        let drag_tid = tid.clone();
        let dragged = std::thread::spawn(move || unsafe {
            drag_tid.store(GetCurrentThreadId(), Ordering::SeqCst);
            let _ = OleInitialize(None);
            let item: IShellItem = SHCreateItemFromParsingName(&HSTRING::from(path.as_os_str()), None).unwrap();
            let data: IDataObject = item.BindToHandler(None, &BHID_DataObject).unwrap();
            let source: IDropSource = Source(Mutex::new(0)).into();
            let mut effect = DROPEFFECT(0);
            let hr = DoDragDrop(&data, &source, DROPEFFECT_COPY, &mut effect);
            (hr, effect)
        });
        // The drag loop only advances on input its thread receives, and a test thread gets none: post it mouse moves
        // while the pointer stays on the island.
        for _ in 0..60 {
            if dragged.is_finished() {
                break;
            }
            unsafe { PostThreadMessageW(tid.load(Ordering::SeqCst), WM_MOUSEMOVE, WPARAM(0), LPARAM(0)) }.ok();
            std::thread::sleep(Duration::from_millis(40));
        }
        assert!(dragged.is_finished(), "the drag loop ended");
        let (hr, effect) = dragged.join().unwrap();
        assert_eq!((hr, effect), (DRAGDROP_S_DROP, DROPEFFECT_COPY), "the island accepted the drop");
        std::thread::sleep(Duration::from_millis(300));
        let sent = log.lock().unwrap().iter().any(|c| c.starts_with("SendFiles") && c.contains("prueba isla.txt"));
        assert!(sent, "drop sends the file: {:?}", log.lock().unwrap());
        // 4. Leaving closes it; the hotkey opens it anywhere and closes it again.
        at(cx, mid);
        std::thread::sleep(Duration::from_millis(2500));
        assert!(!visible(), "closes after the pointer leaves");
        hotkey();
        wait();
        assert!(visible(), "the hotkey opens it");
        hotkey();
        std::thread::sleep(Duration::from_millis(1500));
        assert!(!visible(), "the hotkey closes it");

        at(back.x, back.y);
        let _ = std::fs::remove_dir_all(&dir);
    }

}
