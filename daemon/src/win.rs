//! Windows-only helpers for when no window is open: system toasts and the clipboard.
//! Toasts need an AppUserModelID; an unpackaged app registers one under HKCU (documented by Microsoft for
//! "other types of unpackaged apps"), so the toast shows "Alero" instead of an unknown app.

use std::sync::atomic::{AtomicU32, Ordering};
use std::time::{Duration, Instant};
use windows::core::{HSTRING, PCWSTR};
use windows::Data::Xml::Dom::XmlDocument;
use windows::core::{IInspectable, Interface, Ref};
use windows::Foundation::TypedEventHandler;
use windows::UI::Notifications::{NotificationData, ToastActivatedEventArgs, ToastNotification, ToastNotificationManager};
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
const GROUP: &str = "transfer";
static SEQ: AtomicU32 = AtomicU32::new(1);
/// Transfer id and time of the last card redraw: progress events come much faster than a card needs.
static DRAWN: std::sync::Mutex<Option<(String, Instant)>> = std::sync::Mutex::new(None);

/// Toast with buttons. `Call` buttons reach `on_click` while this process runs (the tray daemon always does);
/// `Open` buttons hand a file or folder to Explorer, which opens it with the user's default app.
pub fn toast_buttons(title: &str, body: &str, buttons: &[Button], on_click: impl Fn(&str) + Send + 'static) {
    show_card("", title, body, None, buttons, None, on_click);
}

/// Tags are limited to 64 characters.
fn tag_of(id: &str) -> String {
    id.chars().filter(|c| c.is_ascii_alphanumeric() || *c == '-' || *c == '_').take(60).collect()
}

fn is_image(path: &std::path::Path) -> bool {
    let e = path.extension().and_then(|e| e.to_str()).unwrap_or("").to_ascii_lowercase();
    // Toasts drop images over 3 MB; these are the formats the toast engine decodes by itself.
    ["jpg", "jpeg", "png", "gif", "bmp"].contains(&e.as_str()) && std::fs::metadata(path).is_ok_and(|m| m.len() <= 3 << 20)
}

fn mb(b: u64) -> String {
    if b >= 1 << 30 {
        format!("{:.1} GB", b as f64 / (1u64 << 30) as f64)
    } else {
        format!("{:.1} MB", b as f64 / (1u64 << 20) as f64)
    }
}

/// Values bound to the card's `<progress>`: (value 0..1 or "indeterminate", "x MB de y MB", speed).
fn progress_text(done: u64, total: u64, rate: u64) -> (String, String, String) {
    let value = if total > 0 { format!("{:.3}", (done as f64 / total as f64).min(1.0)) } else { "indeterminate".into() };
    let amount = if total > 0 { format!("{} de {}", mb(done), mb(total)) } else { mb(done) };
    (value, amount, if rate > 0 { format!("{}/s", mb(rate)) } else { String::new() })
}

fn progress_data(name: &str, done: u64, total: u64, rate: u64) -> windows::core::Result<NotificationData> {
    let (value, amount, status) = progress_text(done, total, rate);
    let d = NotificationData::new()?;
    let v = d.Values()?;
    for (k, val) in [("progressTitle", name.to_string()), ("progressValue", value), ("progressValueString", amount), ("progressStatus", status)] {
        v.Insert(&HSTRING::from(k), &HSTRING::from(val))?;
    }
    d.SetSequenceNumber(SEQ.fetch_add(1, Ordering::Relaxed))?;
    Ok(d)
}

/// Card with title, file name, optional thumbnail and buttons. A non-empty `tag` makes it replace the card
/// shown earlier with that tag (the progress card turns into the result). `data` fills a `<progress>` binding.
fn show_card(
    tag: &str,
    title: &str,
    body: &str,
    image: Option<&std::path::Path>,
    buttons: &[Button],
    data: Option<NotificationData>,
    on_click: impl Fn(&str) + Send + 'static,
) {
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
    let image = image.map(|p| format!("<image placement=\"appLogoOverride\" src=\"{}\"/>", esc(&file_uri(p)))).unwrap_or_default();
    let progress = if data.is_some() {
        "<progress title=\"{progressTitle}\" value=\"{progressValue}\" valueStringOverride=\"{progressValueString}\" status=\"{progressStatus}\"/>"
    } else {
        ""
    };
    let r = (|| -> windows::core::Result<()> {
        let xml = XmlDocument::new()?;
        xml.LoadXml(&HSTRING::from(format!(
            "<toast><visual><binding template=\"ToastGeneric\">{image}<text>{}</text><text>{}</text>{progress}</binding></visual><actions>{actions}</actions></toast>",
            esc(title),
            esc(body)
        )))?;
        let n = ToastNotification::CreateToastNotification(&xml)?;
        if !tag.is_empty() {
            n.SetTag(&HSTRING::from(tag))?;
            n.SetGroup(&HSTRING::from(GROUP))?;
        }
        if let Some(d) = &data {
            n.SetData(d)?;
        }
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

/// The card of a transfer in progress: peer, file name, "x MB de y MB" and Cancelar.
pub fn transfer_start(id: &str, incoming: bool, peer: &str, name: &str, total: u64, on_click: impl Fn(&str) + Send + 'static) {
    let title = format!("{} {}", if incoming { "Recibiendo de" } else { "Enviando a" }, if peer.is_empty() { "un dispositivo" } else { peer });
    *DRAWN.lock().unwrap_or_else(|e| e.into_inner()) = Some((id.to_string(), Instant::now()));
    let data = progress_data(name, 0, total, 0).ok();
    show_card(&tag_of(id), &title, "", None, &[Button::Call("Cancelar".into(), format!("cancel:{id}"))], data, on_click);
}

/// Moves the bar of the card started by [`transfer_start`], at most once a second.
pub fn transfer_progress(id: &str, name: &str, done: u64, total: u64, rate: u64) {
    {
        let mut last = DRAWN.lock().unwrap_or_else(|e| e.into_inner());
        if last.as_ref().is_some_and(|(i, t)| i == id && t.elapsed() < Duration::from_secs(1)) {
            return;
        }
        *last = Some((id.to_string(), Instant::now()));
    }
    let r = (|| -> windows::core::Result<()> {
        let d = progress_data(name, done, total, rate)?;
        let notifier = ToastNotificationManager::CreateToastNotifierWithId(&HSTRING::from(AUMID))?;
        notifier.UpdateWithTagAndGroup(&d, &HSTRING::from(tag_of(id)), &HSTRING::from(GROUP))?;
        Ok(())
    })();
    if let Err(e) = r {
        eprintln!("toast: {e}");
    }
}

/// Closes the card of a transfer that ended without a result worth showing (sent, cancelled).
pub fn transfer_clear(id: &str) {
    let r = ToastNotificationManager::History()
        .and_then(|h| h.RemoveGroupedTagWithId(&HSTRING::from(tag_of(id)), &HSTRING::from(GROUP), &HSTRING::from(AUMID)));
    if let Err(e) = r {
        eprintln!("toast: {e}");
    }
}

/// The result card of a received file: replaces the progress card, with a thumbnail when it is a small image.
/// Opening a file that runs code is never offered; only its folder.
pub fn transfer_done(id: &str, file: &std::path::Path) {
    let name = file.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
    let mut buttons = Vec::new();
    if !runs_code(file) {
        buttons.push(Button::Open("Abrir".into(), file.to_path_buf()));
    }
    if let Some(dir) = file.parent() {
        buttons.push(Button::Open("Abrir carpeta".into(), dir.to_path_buf()));
    }
    let image = if is_image(file) { Some(file) } else { None };
    show_card(&tag_of(id), "Archivo recibido", &name, image, &buttons, None, |_| {});
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
        let (v, a, r) = progress_text(5 << 20, 10 << 20, 1 << 20);
        assert_eq!((v.as_str(), a.as_str(), r.as_str()), ("0.500", "5.0 MB de 10.0 MB", "1.0 MB/s"));
        assert_eq!(progress_text(0, 0, 0).0, "indeterminate");
        assert!(!runs_code(Path::new("foto.jpg")) && !runs_code(Path::new("doc.pdf")) && !runs_code(Path::new("sin_extension")));
    }
}
