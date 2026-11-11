//! What the phone can do to this computer, one small function per capability. Windows implements them with
//! documented user-mode APIs (`SendInput`, GDI, `GetSystemPowerStatus`, the media-session WinRT API). Other
//! systems report "not supported" so the phone never shows a control that would do nothing (Linux would need
//! uinput/evdev and a Wayland portal: documented as pending).

/// Which groups of controls this build can actually carry out.
pub struct Caps {
    pub input: bool,
    pub screen: bool,
    pub media: bool,
    pub power: bool,
}

pub struct Media {
    pub app: String,
    pub title: String,
    pub artist: String,
    pub playing: bool,
    pub position_ms: i64,
    pub duration_ms: i64,
    pub actions: u64,
    pub speed: f64,
}

/// Size and hotspot of the pointer drawn into a shared frame: 82% of the real pointer (which already follows the
/// system DPI and the accessibility pointer size), never under 12 px. The hotspot shrinks with it, so the drawn tip
/// stays exactly where the click lands. Only the picture changes; the Windows pointer itself is never touched.
pub fn stream_pointer(native: i32, hot_x: i32, hot_y: i32) -> (i32, i32, i32) {
    let px = ((native.max(1) as f64 * 0.82).round() as i32).max(12);
    let k = px as f64 / native.max(1) as f64;
    (px, (hot_x as f64 * k).round() as i32, (hot_y as f64 * k).round() as i32)
}

#[cfg(windows)]
pub use win::*;
#[cfg(not(windows))]
pub use other::*;

#[cfg(not(windows))]
mod other {
    use super::*;
    pub const CAPS: Caps = Caps { input: false, screen: false, media: false, power: false };
    pub fn init() {}
    pub fn move_by(_: i32, _: i32) {}
    pub fn button(_: &str, _: bool) {}
    pub fn scroll(_: f64, _: f64) {}
    pub fn key(_: &str, _: &[String]) -> bool {
        false
    }
    pub fn text(_: &str) {}
    pub fn media_key(_: &str) -> bool {
        false
    }
    pub fn power(_: &str) -> bool {
        false
    }
    pub fn battery() -> Option<(u8, bool)> {
        None
    }
    pub fn capture(_: u32) -> Option<(u32, u32, Vec<u8>)> { None }
    pub fn capture_monitor(_: u32, _: usize, _: bool) -> Option<(u32, u32, Vec<u8>)> { None }
    pub fn cursor_at(_: usize) -> Option<(f64, f64)> { None }
    pub fn monitors() -> Vec<(i32, i32, i32, i32)> { Vec::new() }
    pub fn media_state() -> Option<Media> {
        None
    }

    pub fn media_art() -> Option<Vec<u8>> {
        None
    }
    pub fn keep_com_alive() {}
    pub fn secure_desktop() -> bool {
        false
    }
}

#[cfg(windows)]
mod win {
    use std::mem::size_of;
    use windows::core::BOOL;
    use windows::Win32::Foundation::{LPARAM, RECT};

    use windows::Win32::Graphics::Gdi::{
        BitBlt, CreateCompatibleBitmap, CreateCompatibleDC, DeleteDC, DeleteObject, EnumDisplayMonitors, GetMonitorInfoW,
        GetDC, GetDIBits, GetObjectW, ReleaseDC, SelectObject, BITMAP, HDC, HMONITOR, MONITORINFO,
        SetStretchBltMode, StretchBlt, BITMAPINFO, BITMAPINFOHEADER, BI_RGB, CAPTUREBLT, DIB_RGB_COLORS, HALFTONE, SRCCOPY,
    };
    use windows::Win32::System::Com::{CoInitializeEx, COINIT_MULTITHREADED};
    use windows::Win32::System::Power::{GetSystemPowerStatus, SetSuspendState, SYSTEM_POWER_STATUS};
    use windows::Win32::System::Shutdown::LockWorkStation;
    use windows::Win32::UI::Input::KeyboardAndMouse::*;
    use windows::Win32::UI::WindowsAndMessaging::{
        DrawIconEx, GetCursorInfo, GetIconInfo, GetSystemMetrics, SetProcessDPIAware, CURSORINFO, CURSOR_SHOWING, DI_NORMAL,
        HICON, ICONINFO, SM_CXCURSOR, SM_CXSCREEN, SM_CYSCREEN,
    };
    use windows::Media::Control::{GlobalSystemMediaTransportControlsSessionManager, GlobalSystemMediaTransportControlsSessionPlaybackStatus};

    use super::{Caps, Media};

    pub const CAPS: Caps = Caps { input: true, screen: true, media: true, power: true };

    /// Per-process setup: report real pixels (not DPI-scaled ones) so capture and the cursor line up.
    pub fn init() {
        unsafe {
            let _ = SetProcessDPIAware();
        }
    }

    fn send(inputs: &[INPUT]) {
        unsafe {
            SendInput(inputs, size_of::<INPUT>() as i32);
        }
    }

    fn mouse(flags: MOUSE_EVENT_FLAGS, dx: i32, dy: i32, data: i32) -> INPUT {
        INPUT {
            r#type: INPUT_MOUSE,
            Anonymous: INPUT_0 { mi: MOUSEINPUT { dx, dy, mouseData: data as u32, dwFlags: flags, time: 0, dwExtraInfo: 0 } },
        }
    }

    fn keyboard(vk: u16, scan: u16, flags: KEYBD_EVENT_FLAGS) -> INPUT {
        INPUT {
            r#type: INPUT_KEYBOARD,
            Anonymous: INPUT_0 { ki: KEYBDINPUT { wVk: VIRTUAL_KEY(vk), wScan: scan, dwFlags: flags, time: 0, dwExtraInfo: 0 } },
        }
    }

    /// Relative pointer movement, in the same units a mouse reports.
    pub fn move_by(dx: i32, dy: i32) {
        send(&[mouse(MOUSEEVENTF_MOVE, dx, dy, 0)]);
    }

    pub fn button(name: &str, down: bool) {
        let f = match (name, down) {
            ("right", true) => MOUSEEVENTF_RIGHTDOWN,
            ("right", false) => MOUSEEVENTF_RIGHTUP,
            ("middle", true) => MOUSEEVENTF_MIDDLEDOWN,
            ("middle", false) => MOUSEEVENTF_MIDDLEUP,
            (_, true) => MOUSEEVENTF_LEFTDOWN,
            (_, false) => MOUSEEVENTF_LEFTUP,
        };
        send(&[mouse(f, 0, 0, 0)]);
    }

    /// `dy`/`dx` in wheel notches (positive: up / right), fractions allowed (smooth scrolling).
    pub fn scroll(dy: f64, dx: f64) {
        if dy != 0.0 {
            send(&[mouse(MOUSEEVENTF_WHEEL, 0, 0, (dy * 120.0) as i32)]);
        }
        if dx != 0.0 {
            send(&[mouse(MOUSEEVENTF_HWHEEL, 0, 0, (dx * 120.0) as i32)]);
        }
    }

    fn vk_of(name: &str) -> Option<(u16, bool)> {
        // (virtual key, extended key)
        let n = name.to_lowercase();
        Some(match n.as_str() {
            "enter" => (VK_RETURN.0, false),
            "backspace" => (VK_BACK.0, false),
            "tab" => (VK_TAB.0, false),
            "esc" | "escape" => (VK_ESCAPE.0, false),
            "space" => (VK_SPACE.0, false),
            "delete" => (VK_DELETE.0, true),
            "insert" => (VK_INSERT.0, true),
            "home" => (VK_HOME.0, true),
            "end" => (VK_END.0, true),
            "pageup" => (VK_PRIOR.0, true),
            "pagedown" => (VK_NEXT.0, true),
            "left" => (VK_LEFT.0, true),
            "right" => (VK_RIGHT.0, true),
            "up" => (VK_UP.0, true),
            "down" => (VK_DOWN.0, true),
            "win" => (VK_LWIN.0, true),
            f if f.starts_with('f') && f[1..].parse::<u16>().is_ok_and(|k| (1..=12).contains(&k)) => {
                (VK_F1.0 + f[1..].parse::<u16>().unwrap() - 1, false)
            }
            c if c.len() == 1 && c.as_bytes()[0].is_ascii_alphanumeric() => (c.as_bytes()[0].to_ascii_uppercase() as u16, false),
            _ => return None,
        })
    }

    /// A key press (down and up) with optional ctrl/alt/shift/win held around it.
    pub fn key(name: &str, mods: &[String]) -> bool {
        let Some((vk, ext)) = vk_of(name) else { return false };
        let held: Vec<u16> = mods
            .iter()
            .filter_map(|m| match m.as_str() {
                "ctrl" => Some(VK_CONTROL.0),
                "alt" => Some(VK_MENU.0),
                "shift" => Some(VK_SHIFT.0),
                "win" => Some(VK_LWIN.0),
                _ => None,
            })
            .collect();
        let e = if ext { KEYEVENTF_EXTENDEDKEY } else { KEYBD_EVENT_FLAGS(0) };
        let mut seq = Vec::new();
        for m in &held {
            seq.push(keyboard(*m, 0, KEYBD_EVENT_FLAGS(0)));
        }
        seq.push(keyboard(vk, 0, e));
        seq.push(keyboard(vk, 0, e | KEYEVENTF_KEYUP));
        for m in held.iter().rev() {
            seq.push(keyboard(*m, 0, KEYEVENTF_KEYUP));
        }
        send(&seq);
        true
    }

    /// Types text as Unicode, so any layout and any character works. Capped: a phone is not a macro engine.
    pub fn text(s: &str) {
        let mut seq = Vec::new();
        for u in s.chars().take(2000).collect::<String>().encode_utf16() {
            if u == b'\n' as u16 {
                seq.push(keyboard(VK_RETURN.0, 0, KEYBD_EVENT_FLAGS(0)));
                seq.push(keyboard(VK_RETURN.0, 0, KEYEVENTF_KEYUP));
            } else {
                seq.push(keyboard(0, u, KEYEVENTF_UNICODE));
                seq.push(keyboard(0, u, KEYEVENTF_UNICODE | KEYEVENTF_KEYUP));
            }
        }
        send(&seq);
    }

    /// Volume and transport keys: they go to whatever the system treats as the active player.
    pub fn media_key(action: &str) -> bool {
        let vk = match action {
            "volume_up" => VK_VOLUME_UP,
            "volume_down" => VK_VOLUME_DOWN,
            "mute" => VK_VOLUME_MUTE,
            "toggle" => VK_MEDIA_PLAY_PAUSE,
            "next" => VK_MEDIA_NEXT_TRACK,
            "prev" => VK_MEDIA_PREV_TRACK,
            "stop" => VK_MEDIA_STOP,
            _ => return false,
        };
        send(&[keyboard(vk.0, 0, KEYEVENTF_EXTENDEDKEY), keyboard(vk.0, 0, KEYEVENTF_EXTENDEDKEY | KEYEVENTF_KEYUP)]);
        true
    }

    /// "lock" or "sleep". Never shutdown or sign-out from a phone message: too destructive for one tap.
    pub fn power(action: &str) -> bool {
        unsafe {
            match action {
                "lock" => LockWorkStation().is_ok(),
                "sleep" => SetSuspendState(false, false, false),
                _ => false,
            }
        }
    }

    /// (percent, plugged in); None on a desktop PC or when Windows does not know.
    pub fn battery() -> Option<(u8, bool)> {
        let mut s = SYSTEM_POWER_STATUS::default();
        unsafe { GetSystemPowerStatus(&mut s).ok()? };
        if s.BatteryFlag & 128 != 0 || s.BatteryFlag == 255 || s.BatteryLifePercent > 100 {
            return None;
        }
        Some((s.BatteryLifePercent, s.ACLineStatus == 1))
    }

    /// Actual Windows desktop monitors, primary first.
    pub fn monitors() -> Vec<(i32, i32, i32, i32)> {
        unsafe extern "system" fn add(
            monitor: HMONITOR, _: HDC, _: *mut RECT, context: LPARAM,
        ) -> BOOL {
            let result = &mut *(context.0 as *mut Vec<(bool, i32, i32, i32, i32)>);
            let mut info = MONITORINFO { cbSize: size_of::<MONITORINFO>() as u32, ..Default::default() };
            if GetMonitorInfoW(monitor, &mut info).as_bool() {
                let r = info.rcMonitor;
                if r.right > r.left && r.bottom > r.top {
                    result.push((info.dwFlags & 1 != 0, r.left, r.top, r.right, r.bottom));
                }
            }
            BOOL(1)
        }
        let mut out: Vec<(bool, i32, i32, i32, i32)> = Vec::new();
        unsafe {
            EnumDisplayMonitors(
                None, None, Some(add),
                LPARAM((&mut out as *mut Vec<(bool, i32, i32, i32, i32)>) as isize),
            );
        }
        out.sort_by_key(|item| (!item.0, item.2, item.1));
        out.into_iter().map(|(_, x, y, right, bottom)| (x, y, right, bottom)).collect()
    }

    /// Monitor index 0 is the primary screen.
    pub fn capture(width: u32) -> Option<(u32, u32, Vec<u8>)> {
        capture_monitor(width, 0, true)
    }

    /// Where the pointer is on a monitor, as fractions of its width and height. None while it is hidden or on
    /// another monitor. Costs one system call, so a stream can report it far more often than it sends pictures.
    pub fn cursor_at(monitor: usize) -> Option<(f64, f64)> {
        let (left, top, right, bottom) = *monitors().get(monitor)?;
        let mut ci = CURSORINFO { cbSize: size_of::<CURSORINFO>() as u32, ..Default::default() };
        unsafe { GetCursorInfo(&mut ci).ok()? };
        let (x, y) = (ci.ptScreenPos.x, ci.ptScreenPos.y);
        ((ci.flags.0 & CURSOR_SHOWING.0) != 0 && x >= left && x < right && y >= top && y < bottom)
            .then(|| ((x - left) as f64 / (right - left) as f64, (y - top) as f64 / (bottom - top) as f64))
    }

    /// Pixels come back as BGRA rows, top first (what GDI hands over and the JPEG encoder takes as it is).
    /// `cursor` draws the pointer into the picture; a stream whose viewer draws its own leaves it out.
    pub fn capture_monitor(width: u32, monitor: usize, cursor: bool) -> Option<(u32, u32, Vec<u8>)> {
        let (left, top, right, bottom) = *monitors().get(monitor)?;

        unsafe {
            let (sw, sh) = (right - left, bottom - top);
            if sw <= 0 || sh <= 0 {
                return None;
            }
            let dw = (width.min(sw as u32) as i32).max(16);
            let dh = ((sh as i64 * dw as i64) / sw as i64).max(1) as i32;
            let screen = GetDC(None);
            let mem = CreateCompatibleDC(Some(screen));
            let bmp = CreateCompatibleBitmap(screen, dw, dh);
            let old = SelectObject(mem, bmp.into());
            let ok = if dw == sw {
                BitBlt(mem, 0, 0, sw, sh, Some(screen), left, top, SRCCOPY | CAPTUREBLT).is_ok()
            } else {
                SetStretchBltMode(mem, HALFTONE);
                StretchBlt(mem, 0, 0, dw, dh, Some(screen), left, top, sw, sh, SRCCOPY | CAPTUREBLT).as_bool()
            };
            let mut out = None;
            if ok {
                let mut ci = CURSORINFO { cbSize: size_of::<CURSORINFO>() as u32, ..Default::default() };
                if cursor && GetCursorInfo(&mut ci).is_ok() && (ci.flags.0 & CURSOR_SHOWING.0) != 0 {
                    let (x, y) = (((ci.ptScreenPos.x - left) as i64 * dw as i64 / sw as i64) as i32, ((ci.ptScreenPos.y - top) as i64 * dh as i64 / sh as i64) as i32);
                    let icon = HICON(ci.hCursor.0);
                    let (mut native, mut hx, mut hy) = (GetSystemMetrics(SM_CXCURSOR), 0, 0);
                    let mut ii = ICONINFO::default();
                    if GetIconInfo(icon, &mut ii).is_ok() {
                        (hx, hy) = (ii.xHotspot as i32, ii.yHotspot as i32);
                        // Real pointer width (a monochrome cursor's mask is twice as tall, never wider).
                        let b = if ii.hbmColor.is_invalid() { ii.hbmMask } else { ii.hbmColor };
                        let mut bm = BITMAP::default();
                        if GetObjectW(b.into(), size_of::<BITMAP>() as i32, Some((&mut bm as *mut BITMAP).cast())) != 0 && bm.bmWidth > 0 {
                            native = bm.bmWidth;
                        }
                        for h in [ii.hbmColor, ii.hbmMask] {
                            if !h.is_invalid() {
                                let _ = DeleteObject(h.into());
                            }
                        }
                    }
                    let (px, ox, oy) = super::stream_pointer(native, hx, hy);
                    let _ = DrawIconEx(mem, x - ox, y - oy, icon, px, px, 0, None, DI_NORMAL);
                }
                let mut bi = BITMAPINFO {
                    bmiHeader: BITMAPINFOHEADER {
                        biSize: size_of::<BITMAPINFOHEADER>() as u32,
                        biWidth: dw,
                        biHeight: -dh, // negative: top-down rows
                        biPlanes: 1,
                        biBitCount: 32,
                        biCompression: BI_RGB.0,
                        ..Default::default()
                    },
                    ..Default::default()
                };
                let mut bgra = vec![0u8; dw as usize * dh as usize * 4];
                if GetDIBits(mem, bmp, 0, dh as u32, Some(bgra.as_mut_ptr().cast()), &mut bi, DIB_RGB_COLORS) != 0 {
                    out = Some((dw as u32, dh as u32, bgra));
                }
            }
            SelectObject(mem, old);
            let _ = DeleteObject(bmp.into());
            let _ = DeleteDC(mem);
            ReleaseDC(None, screen);
            out
        }
    }

    /// True while Windows shows the secure desktop (UAC prompt, Ctrl+Alt+Del, lock screen). Nothing a normal user
    /// process does reaches it: capture sees nothing and input is dropped until it closes.
    pub fn secure_desktop() -> bool {
        use windows::Win32::System::StationsAndDesktops::{
            CloseDesktop, GetUserObjectInformationW, OpenInputDesktop, DESKTOP_CONTROL_FLAGS, DESKTOP_READOBJECTS, UOI_NAME,
        };
        unsafe {
            let Ok(desk) = OpenInputDesktop(DESKTOP_CONTROL_FLAGS(0), false, DESKTOP_READOBJECTS) else { return true };
            let mut name = [0u16; 64];
            let ok = GetUserObjectInformationW(windows::Win32::Foundation::HANDLE(desk.0), UOI_NAME, Some(name.as_mut_ptr().cast()), (name.len() * 2) as u32, None).is_ok();
            let _ = CloseDesktop(desk);
            let len = name.iter().position(|&c| c == 0).unwrap_or(name.len());
            ok && !String::from_utf16_lossy(&name[..len]).eq_ignore_ascii_case("Default")
        }
    }

    /// Keeps the process-wide COM multithreaded apartment alive. windows-rs caches WinRT factories, and the
    /// media watcher thread (the only one that initialised COM) exits when nobody watches: the apartment was then
    /// torn down under the cached factory and the next `media_state` crashed the daemon (0xc0000005).
    pub fn keep_com_alive() {
        let _ = std::thread::Builder::new().name("com-mta".into()).spawn(|| {
            unsafe {
                let _ = CoInitializeEx(None, COINIT_MULTITHREADED);
            }
            loop {
                std::thread::park();
            }
        });
    }

    /// What the system's current media session (any player) reports. None when nothing is open.
    pub fn media_state() -> Option<Media> {
        unsafe {
            let _ = CoInitializeEx(None, COINIT_MULTITHREADED);
        }
        let mgr = GlobalSystemMediaTransportControlsSessionManager::RequestAsync().ok()?.join().ok()?;
        let s = mgr.GetCurrentSession().ok()?;
        let props = s.TryGetMediaPropertiesAsync().ok()?.join().ok()?;
        let playback = s.GetPlaybackInfo().ok()?;
        let playing = playback.PlaybackStatus().ok()? == GlobalSystemMediaTransportControlsSessionPlaybackStatus::Playing;
        let controls = playback.Controls().ok()?;
        let actions = (if controls.IsPreviousEnabled().unwrap_or(false) { 16 } else { 0 })
            | (if controls.IsNextEnabled().unwrap_or(false) { 32 } else { 0 })
            | (if controls.IsPlayEnabled().unwrap_or(false) { 4 } else { 0 })
            | (if controls.IsPauseEnabled().unwrap_or(false) { 2 } else { 0 })
            | (if controls.IsPlayPauseToggleEnabled().unwrap_or(false) { 512 } else { 0 });
        let (position_ms, duration_ms) = s
            .GetTimelineProperties()
            .ok()
            .map(|t| {
                let ms = |d: windows::Foundation::TimeSpan| d.Duration / 10_000;
                let (pos, end) = (t.Position().map(ms).unwrap_or(0), t.EndTime().map(ms).unwrap_or(0));
                // Players report the position only now and then (Spotify every few seconds or on seek): add the
                // time since that report, or the phone's bar jumps back on every update.
                let since = t.LastUpdatedTime().ok().map(|u| now_ticks() - u.UniversalTime).filter(|&d| d > 0).unwrap_or(0);
                let pos = if playing { pos + since / 10_000 } else { pos };
                (if end > 0 { pos.min(end) } else { pos }, end)
            })
            .unwrap_or((0, 0));
        Some(Media {
            app: s.SourceAppUserModelId().map(|h| h.to_string()).unwrap_or_default(),
            title: props.Title().map(|h| h.to_string()).unwrap_or_default(),
            artist: props.Artist().map(|h| h.to_string()).unwrap_or_default(),
            playing,
            position_ms,
            duration_ms,
            actions,
            speed: playback.PlaybackRate().ok().and_then(|rate| rate.Value().ok()).unwrap_or(1.0),
        })
    }

    /// Now as a Windows `DateTime` (100 ns ticks since 1601-01-01 UTC), like the timeline's update time.
    fn now_ticks() -> i64 {
        let unix = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_nanos() as i64 / 100).unwrap_or(0);
        unix + 116_444_736_000_000_000
    }

    /// Cover of the current session (JPEG or PNG). Covers over 150 KB are shrunk to a 400 px JPEG instead of
    /// dropped: many players hand over a full-size image, which left the phone without a cover.
    pub fn media_art() -> Option<Vec<u8>> {
        cover(150_000)
    }

    /// The cover as is when it weighs at most `limit` bytes, else shrunk.
    pub(crate) fn cover(limit: u64) -> Option<Vec<u8>> {
        use windows::core::Interface;
        let mgr = GlobalSystemMediaTransportControlsSessionManager::RequestAsync().ok()?.join().ok()?;
        let props = mgr.GetCurrentSession().ok()?.TryGetMediaPropertiesAsync().ok()?.join().ok()?;
        let stream = props.Thumbnail().ok()?.OpenReadAsync().ok()?.join().ok()?;
        let size = stream.Size().ok().filter(|&n| n > 0)?;
        if size <= limit {
            return read_stream(&stream.cast().ok()?, size as u32);
        }
        shrink_cover(&stream.cast().ok()?, 400)
    }

    fn read_stream(stream: &windows::Storage::Streams::IRandomAccessStream, size: u32) -> Option<Vec<u8>> {
        use windows::Storage::Streams::DataReader;
        let reader = DataReader::CreateDataReader(&stream.GetInputStreamAt(0).ok()?).ok()?;
        let got = reader.LoadAsync(size).ok()?.join().ok()?;
        let mut buf = vec![0u8; got as usize];
        reader.ReadBytes(&mut buf).ok()?;
        Some(buf)
    }

    /// Decodes any cover Windows can read and re-encodes it as a JPEG whose longest side is `max` pixels.
    fn shrink_cover(stream: &windows::Storage::Streams::IRandomAccessStream, max: u32) -> Option<Vec<u8>> {
        use windows::Graphics::Imaging::{BitmapAlphaMode, BitmapDecoder, BitmapEncoder, BitmapInterpolationMode, BitmapPixelFormat};
        use windows::Storage::Streams::InMemoryRandomAccessStream;
        let decoder = BitmapDecoder::CreateAsync(stream).ok()?.join().ok()?;
        let (w, h) = (decoder.PixelWidth().ok()?, decoder.PixelHeight().ok()?);
        if w == 0 || h == 0 {
            return None;
        }
        let scale = (max as f64 / w.max(h) as f64).min(1.0);
        let bitmap = decoder
            .GetSoftwareBitmapConvertedAsync(BitmapPixelFormat::Bgra8, BitmapAlphaMode::Ignore)
            .ok()?
            .join()
            .ok()?;
        let out = InMemoryRandomAccessStream::new().ok()?;
        let encoder = BitmapEncoder::CreateAsync(BitmapEncoder::JpegEncoderId().ok()?, &out).ok()?.join().ok()?;
        encoder.SetSoftwareBitmap(&bitmap).ok()?;
        let t = encoder.BitmapTransform().ok()?;
        t.SetScaledWidth(((w as f64 * scale).round() as u32).max(1)).ok()?;
        t.SetScaledHeight(((h as f64 * scale).round() as u32).max(1)).ok()?;
        t.SetInterpolationMode(BitmapInterpolationMode::Fant).ok()?;
        encoder.FlushAsync().ok()?.join().ok()?;
        use windows::core::Interface;
        let size = out.Size().ok()? as u32;
        let jpeg = read_stream(&out.cast().ok()?, size)?;
        (jpeg.len() <= 150_000).then_some(jpeg)
    }
}

/// The system's own hardware identity and built-in wallpaper, sampled once at startup.
pub fn device_metadata() -> serde_json::Value {
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        let script = r#"
Add-Type -AssemblyName System.Drawing
$bios = Get-ItemProperty 'HKLM:\HARDWARE\DESCRIPTION\System\BIOS'
$image = $null
$small = $null
$stream = $null
$graphics = $null
$jpeg = ''
try {
  $path = Join-Path $env:WINDIR 'Web\Wallpaper\Windows\img0.jpg'
  $image = [Drawing.Image]::FromFile($path)
  $small = [Drawing.Bitmap]::new(480, [Math]::Max(1, [int](480 * $image.Height / $image.Width)))
  $graphics = [Drawing.Graphics]::FromImage($small)
  $graphics.DrawImage($image, 0, 0, $small.Width, $small.Height)
  $stream = [IO.MemoryStream]::new()
  $small.Save($stream, [Drawing.Imaging.ImageFormat]::Jpeg)
  $jpeg = [Convert]::ToBase64String($stream.ToArray())
} catch {} finally {
  if ($graphics) { $graphics.Dispose() }
  if ($image) { $image.Dispose() }
  if ($small) { $small.Dispose() }
  if ($stream) { $stream.Dispose() }
}
@{manufacturer=$bios.SystemManufacturer; model=$bios.SystemFamily; product=$bios.SystemProductName; stockJpeg=$jpeg} | ConvertTo-Json -Compress
"#;
        if let Ok(out) = std::process::Command::new("powershell.exe")
            .args(["-NoProfile", "-NonInteractive", "-Command", script]).creation_flags(0x08000000).output() {
            if let Ok(value) = serde_json::from_slice(&out.stdout) { return value; }
        }
    }
    serde_json::json!({})
}

pub fn screen_size() -> (i32, i32) {
    #[cfg(windows)]
    unsafe {
        use windows::Win32::UI::WindowsAndMessaging::{GetSystemMetrics, SM_CXSCREEN, SM_CYSCREEN};
        return (GetSystemMetrics(SM_CXSCREEN), GetSystemMetrics(SM_CYSCREEN));
    }
    #[cfg(not(windows))]
    (0, 0)
}

#[cfg(test)]
mod pointer_tests {
    use super::stream_pointer;

    #[test]
    fn stream_pointer_is_smaller_and_keeps_the_tip() {
        // 100% (32 px), 150% (48 px) and 200% (64 px) pointers: 15-20% smaller.
        for n in [32, 48, 64] {
            let (px, _, _) = stream_pointer(n, 0, 0);
            let r = px as f64 / n as f64;
            assert!((0.80..=0.85).contains(&r), "{n} -> {px}");
        }
        // The I-beam/hand hotspot scales with the picture, so the click point does not drift.
        assert_eq!(stream_pointer(48, 24, 24), (39, 20, 20));
        assert_eq!(stream_pointer(4, 2, 2).0, 12);
    }
}

#[cfg(all(test, windows))]
mod tests {
    use super::*;

    fn churn() {
        for _ in 0..6 {
            std::thread::spawn(|| {
                let _ = media_state();
            })
            .join()
            .unwrap();
        }
    }

    /// On the normal desktop input must not be reported as blocked (that would nag the phone on every move).
    #[test]
    fn normal_desktop_is_not_secure() {
        assert!(!secure_desktop());
    }

    /// The media watcher thread exits when nobody watches; the next one must not hit a dead factory.
    #[test]
    fn media_state_survives_its_thread_exiting() {
        keep_com_alive();
        churn();
    }
}

/// Manual check with something playing: `cargo test -p pb-daemon -- --ignored cover`.
#[cfg(all(test, windows))]
mod live {
    #[test]
    #[ignore]
    fn cover_is_sent_and_fits() {
        let art = super::media_art().expect("play something with a cover first");
        assert!(art.len() <= 150_000);
        println!("cover: {} bytes, starts {:02x?}", art.len(), &art[..4]);
        // Force the shrinking path on the same cover: a 400 px JPEG.
        let small = super::win::cover(1).expect("shrunk cover");
        assert_eq!(&small[..2], &[0xff, 0xd8]);
        println!("shrunk: {} bytes", small.len());
    }

    #[test]
    #[ignore]
    fn position_moves_between_player_reports() {
        let a = super::media_state().expect("play something first");
        std::thread::sleep(std::time::Duration::from_secs(2));
        let b = super::media_state().unwrap();
        println!("playing={} {} -> {} ms", a.playing, a.position_ms, b.position_ms);
        if a.playing && b.playing && a.title == b.title {
            assert!((1500..2600).contains(&(b.position_ms - a.position_ms)));
        }
    }
}
