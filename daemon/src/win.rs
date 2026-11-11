//! Windows-only helpers for when no window is open: system toasts and the clipboard.
//! Toasts need an AppUserModelID; an unpackaged app registers one under HKCU (documented by Microsoft for
//! "other types of unpackaged apps"), so the toast shows "Alero" instead of an unknown app.

use windows::core::{HSTRING, PCWSTR};
use windows::Data::Xml::Dom::XmlDocument;
use windows::core::{IInspectable, Interface, Ref};
use windows::Foundation::TypedEventHandler;
use windows::UI::Notifications::{ToastActivatedEventArgs, ToastNotification, ToastNotificationManager};
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

/// A toast button: opens a `file:` URI with the shell, or calls the toast's handler with its argument.
pub enum Button {
    Open(String, std::path::PathBuf),
    Call(String, String),
}

/// File types Windows would run instead of open: a toast never offers to "open" one of these.
pub fn runs_code(path: &std::path::Path) -> bool {
    const RISKY: &[&str] = &[
        "exe", "msi", "msix", "msixbundle", "appx", "appxbundle", "bat", "cmd", "com", "scr", "pif", "ps1", "psm1",
        "vbs", "vbe", "js", "jse", "wsf", "wsh", "hta", "cpl", "msc", "jar", "lnk", "url", "reg", "inf", "dll", "sys",
        "appref-ms", "application", "gadget", "settingcontent-ms", "chm", "msp", "scf", "sct", "wsc", "xll", "website",
        "library-ms", "search-ms", "diagcab", "iso", "img", "vhd", "vhdx", "py", "pyw",
        // Active content the shell hands to a privileged handler: macro Office files, themes, remote desktop,
        // installers by reference, web queries and old shell scraps.
        "docm", "dotm", "xlsm", "xltm", "xlam", "pptm", "potm", "ppam", "ppsm", "sldm", "theme", "themepack",
        "deskthemepack", "rdp", "appinstaller", "jnlp", "iqy", "slk", "psc1", "ps1xml", "psd1", "shs", "mht",
        "mhtml", "xbap", "vsto", "mcl", "mof", "wsb",
    ];
    // The text after the last dot, as the shell reads it: Path::extension() says a file named ".bat" has none.
    let name = path.file_name().and_then(|n| n.to_str()).unwrap_or("");
    name.rsplit_once('.').is_some_and(|(_, e)| RISKY.contains(&e.to_ascii_lowercase().as_str()))
}

/// `file:///C:/…` with everything but plain path characters percent-encoded (spaces, accents, `#`, `%`).
pub fn file_uri(path: &std::path::Path) -> String {
    let s = path.to_string_lossy().replace('\\', "/");
    let mut out = String::from("file:///");
    for b in s.bytes() {
        match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' | b'/' | b':' => out.push(b as char),
            _ => out.push_str(&format!("%{b:02X}")),
        }
    }
    out
}

/// Toasts with buttons stay referenced here so their click handler outlives `Show` (a handful at most).
static LIVE: std::sync::Mutex<Vec<ToastNotification>> = std::sync::Mutex::new(Vec::new());

/// Toast with buttons. `Call` buttons reach `on_click` while this process runs (the tray daemon always does);
/// `Open` buttons hand a file or folder to Explorer, which opens it with the user's default app.
pub fn toast_buttons(title: &str, body: &str, buttons: &[Button], on_click: impl Fn(&str) + Send + 'static) {
    let actions: String = buttons
        .iter()
        .map(|b| match b {
            Button::Open(label, path) => format!(
                "<action content=\"{}\" activationType=\"protocol\" arguments=\"{}\"/>",
                esc(label),
                esc(&file_uri(path))
            ),
            Button::Call(label, arg) => {
                format!("<action content=\"{}\" activationType=\"foreground\" arguments=\"{}\"/>", esc(label), esc(arg))
            }
        })
        .collect();
    let r = (|| -> windows::core::Result<()> {
        let xml = XmlDocument::new()?;
        xml.LoadXml(&HSTRING::from(format!(
            "<toast><visual><binding template=\"ToastGeneric\"><text>{}</text><text>{}</text></binding></visual><actions>{actions}</actions></toast>",
            esc(title),
            esc(body)
        )))?;
        let n = ToastNotification::CreateToastNotification(&xml)?;
        n.Activated(&TypedEventHandler::<ToastNotification, IInspectable>::new(
            move |_: Ref<ToastNotification>, args: Ref<IInspectable>| {
                if let Some(a) = args.as_ref().and_then(|a| a.cast::<ToastActivatedEventArgs>().ok()) {
                    let arg = a.Arguments()?.to_string();
                    if !arg.is_empty() {
                        on_click(&arg);
                    }
                }
                Ok(())
            },
        ))?;
        ToastNotificationManager::CreateToastNotifierWithId(&HSTRING::from(AUMID))?.Show(&n)?;
        let mut live = LIVE.lock().unwrap_or_else(|e| e.into_inner());
        if live.len() >= 8 {
            live.remove(0);
        }
        live.push(n);
        Ok(())
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

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::Path;

    #[test]
    fn received_file_buttons_are_safe() {
        assert_eq!(file_uri(Path::new(r"C:\Users\Nicolás\Downloads\Alero\a b#1.pdf")), "file:///C:/Users/Nicol%C3%A1s/Downloads/Alero/a%20b%231.pdf");
        assert!(runs_code(Path::new("setup.EXE")) && runs_code(Path::new("x.ps1")) && runs_code(Path::new("a.lnk")));
        assert!(runs_code(Path::new(".bat")) && runs_code(Path::new(r"C:\x\.LNK")) && runs_code(Path::new("q.docm")) && runs_code(Path::new("a.theme")));
        assert!(!runs_code(Path::new("foto.jpg")) && !runs_code(Path::new("doc.pdf")) && !runs_code(Path::new("sin_extension")));
    }
}
