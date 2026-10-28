//! Windows-only helpers for when no window is open: system toasts and the clipboard.
//! Toasts need an AppUserModelID; an unpackaged app registers one under HKCU (documented by Microsoft for
//! "other types of unpackaged apps"), so the toast shows "Alero" instead of an unknown app.

use windows::core::{HSTRING, PCWSTR};
use windows::Data::Xml::Dom::XmlDocument;
use windows::UI::Notifications::{ToastNotification, ToastNotificationManager};
use windows::Win32::Foundation::HANDLE;
use windows::Win32::System::DataExchange::{CloseClipboard, EmptyClipboard, OpenClipboard, SetClipboardData};
use windows::Win32::System::Memory::{GlobalAlloc, GlobalLock, GlobalUnlock, GMEM_MOVEABLE};
use windows::Win32::System::Registry::{RegSetKeyValueW, HKEY_CURRENT_USER, REG_SZ};

const AUMID: &str = "Alero.Desktop";
const CF_UNICODETEXT: u32 = 13;

fn wide(s: &str) -> Vec<u16> {
    s.encode_utf16().chain(Some(0)).collect()
}

/// Idempotent; called once at start.
pub fn register_app() {
    let key = wide(&format!("Software\\Classes\\AppUserModelId\\{AUMID}"));
    let name = wide("DisplayName");
    let value = wide("Alero");
    unsafe {
        let _ = RegSetKeyValueW(
            HKEY_CURRENT_USER,
            PCWSTR(key.as_ptr()),
            PCWSTR(name.as_ptr()),
            REG_SZ.0,
            Some(value.as_ptr().cast()),
            (value.len() * 2) as u32,
        );
    }
}

fn esc(s: &str) -> String {
    s.chars().take(300).map(|c| match c {
        '&' => "&amp;".to_string(),
        '<' => "&lt;".to_string(),
        '>' => "&gt;".to_string(),
        '"' => "&quot;".to_string(),
        '\'' => "&apos;".to_string(),
        c if c.is_control() && c != '\n' => " ".to_string(),
        c => c.to_string(),
    }).collect()
}

pub fn toast(title: &str, body: &str) {
    toast_icon(title, body, "", "");
}

/// Writes the phone app's icon (base64 PNG) to the temp folder and returns its `file:///` URI, or "" if it has none.
fn icon_uri(pkg: &str, b64: &str) -> String {
    use base64::Engine;
    let name: String = pkg.chars().filter(|c| c.is_ascii_alphanumeric() || *c == '.' || *c == '_').collect();
    if name.is_empty() || b64.is_empty() {
        return String::new();
    }
    let Ok(png) = base64::engine::general_purpose::STANDARD.decode(b64) else { return String::new() };
    let dir = std::env::temp_dir().join("alero-icons");
    let path = dir.join(format!("{name}.png"));
    if std::fs::create_dir_all(&dir).and_then(|_| std::fs::write(&path, png)).is_err() {
        return String::new();
    }
    format!("file:///{}", path.to_string_lossy().replace('\\', "/"))
}

/// Toast with the icon of the phone app it comes from; without one the toast keeps the default look.
pub fn toast_icon(title: &str, body: &str, pkg: &str, icon_b64: &str) {
    let uri = icon_uri(pkg, icon_b64);
    let image = if uri.is_empty() { String::new() } else { format!("<image placement=\"appLogoOverride\" src=\"{}\"/>", esc(&uri)) };
    let r = (|| -> windows::core::Result<()> {
        let xml = XmlDocument::new()?;
        xml.LoadXml(&HSTRING::from(format!(
            "<toast><visual><binding template=\"ToastGeneric\">{image}<text>{}</text><text>{}</text></binding></visual></toast>",
            esc(title),
            esc(body)
        )))?;
        let n = ToastNotification::CreateToastNotification(&xml)?;
        ToastNotificationManager::CreateToastNotifierWithId(&HSTRING::from(AUMID))?.Show(&n)
    })();
    if let Err(e) = r {
        eprintln!("toast: {e}");
    }
}

pub fn set_clipboard(text: &str) {
    let w = wide(text);
    unsafe {
        if OpenClipboard(None).is_err() {
            return;
        }
        let _ = EmptyClipboard();
        if let Ok(h) = GlobalAlloc(GMEM_MOVEABLE, w.len() * 2) {
            let p = GlobalLock(h) as *mut u16;
            if !p.is_null() {
                std::ptr::copy_nonoverlapping(w.as_ptr(), p, w.len());
                let _ = GlobalUnlock(h);
                // On success the clipboard owns the memory.
                let _ = SetClipboardData(CF_UNICODETEXT, Some(HANDLE(h.0)));
            }
        }
        let _ = CloseClipboard();
    }
}

/// "11" for builds 22000+, else "10".
pub fn os_version() -> String {
    let v = windows_version::OsVersion::current();
    if v.build >= 22000 { "11".into() } else { v.major.to_string() }
}
