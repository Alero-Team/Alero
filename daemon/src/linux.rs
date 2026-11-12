//! Linux helpers for when no window is open: desktop notifications (D-Bus `org.freedesktop.Notifications`, with
//! action buttons) and the clipboard. Same public API as `win.rs`; `main.rs` reaches both as `platform::`.
//! Notifications use libdbus (the `dbus` crate, already pulled in by tao), so no new crate is added.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::{mpsc, Arc, Mutex, OnceLock};
use std::time::Duration;

use dbus::arg::{RefArg, Variant};
use dbus::blocking::Connection;
use dbus::message::MatchRule;

const NOTIFY: &str = "org.freedesktop.Notifications";
const ICON_NAME: &str = "dev.alero.app";

/// Idempotent; called once at start. The .desktop file installed by the package is the registration on Linux.
pub fn register_app() {}

/// True on a Wayland session (X11 tools only reach XWayland clients there).
pub fn is_wayland() -> bool {
    match std::env::var("XDG_SESSION_TYPE").as_deref() {
        Ok("wayland") => true,
        Ok("x11") => false,
        _ => std::env::var_os("WAYLAND_DISPLAY").is_some(),
    }
}

/// First executable called `cmd` in `PATH`.
pub fn which(cmd: &str) -> Option<PathBuf> {
    use std::os::unix::fs::PermissionsExt;
    std::env::split_paths(&std::env::var_os("PATH")?)
        .map(|d| d.join(cmd))
        .find(|p| p.metadata().is_ok_and(|m| m.is_file() && m.permissions().mode() & 0o111 != 0))
}

/// Notification bodies accept a small HTML subset: escape what the phone sent.
fn esc(s: &str) -> String {
    s.chars()
        .take(300)
        .map(|c| match c {
            '&' => "&amp;".to_string(),
            '<' => "&lt;".to_string(),
            '>' => "&gt;".to_string(),
            c if c.is_control() && c != '\n' => " ".to_string(),
            c => c.to_string(),
        })
        .collect()
}

pub fn toast(title: &str, body: &str) {
    toast_icon(title, body, "", "");
}

/// Writes the phone app's icon (base64 PNG) to the runtime folder and returns its `file://` URI, or "" if it has none.
fn icon_uri(pkg: &str, b64: &str) -> String {
    use base64::Engine;
    let name: String = pkg.chars().filter(|c| c.is_ascii_alphanumeric() || *c == '.' || *c == '_').collect();
    if name.is_empty() || b64.is_empty() {
        return String::new();
    }
    let Ok(png) = base64::engine::general_purpose::STANDARD.decode(b64) else { return String::new() };
    let base = std::env::var_os("XDG_RUNTIME_DIR").map(PathBuf::from).unwrap_or_else(std::env::temp_dir);
    let dir = base.join("alero-icons");
    let path = dir.join(format!("{name}.png"));
    if std::fs::create_dir_all(&dir).and_then(|_| std::fs::write(&path, png)).is_err() {
        return String::new();
    }
    file_uri(&path)
}

/// Toast with the icon of the phone app it comes from; without one the toast keeps Alero's icon.
pub fn toast_icon(title: &str, body: &str, pkg: &str, icon_b64: &str) {
    let icon = icon_uri(pkg, icon_b64);
    show(Notice { title: title.into(), body: esc(body), icon, buttons: Vec::new(), on_click: None });
}

/// A toast button: opens a file or folder with the desktop's default app, or calls the toast's handler with its argument.
#[derive(Clone)]
pub enum Button {
    Open(String, PathBuf),
    Call(String, String),
}

/// File types a double click would run or install instead of open: a toast never offers to "open" one of these.
pub fn runs_code(path: &Path) -> bool {
    const RISKY: &[&str] = &[
        "sh", "bash", "zsh", "fish", "ksh", "csh", "run", "bin", "out", "appimage", "desktop", "deb", "rpm", "snap",
        "flatpakref", "flatpakrepo", "py", "pyw", "pl", "rb", "php", "jar", "jnlp", "so", "service", "timer", "command",
        // Windows programs and scripts (Wine or a cross-platform file manager would run them) and active content.
        "exe", "msi", "bat", "cmd", "com", "scr", "ps1", "vbs", "js", "lnk", "url", "reg", "dll", "hta", "docm", "xlsm",
        "pptm", "iso", "img",
    ];
    // The text after the last dot, as a file manager reads it: Path::extension() says a file named ".sh" has none.
    let name = path.file_name().and_then(|n| n.to_str()).unwrap_or("");
    name.rsplit_once('.').is_some_and(|(_, e)| RISKY.contains(&e.to_ascii_lowercase().as_str()))
}

/// `file:///…` with everything but plain path characters percent-encoded (spaces, accents, `#`, `%`).
pub fn file_uri(path: &Path) -> String {
    use std::os::unix::ffi::OsStrExt;
    let mut out = String::from("file://");
    for &b in path.as_os_str().as_bytes() {
        match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' | b'/' => out.push(b as char),
            _ => out.push_str(&format!("%{b:02X}")),
        }
    }
    out
}

fn xdg_open(path: &Path) {
    let _ = Command::new("xdg-open").arg(path).stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null()).spawn();
}

/// Toast with buttons. `Call` buttons reach `on_click` while this process runs (the tray daemon always does);
/// `Open` buttons hand a file or folder to `xdg-open`, which opens it with the user's default app.
/// Needs a notification server that supports actions (KDE Plasma, GNOME and most others do); without actions it
/// is still shown, just without buttons.
pub fn toast_buttons(title: &str, body: &str, buttons: &[Button], on_click: impl Fn(&str) + Send + 'static) {
    let buttons = buttons.to_vec();
    show(Notice { title: title.into(), body: esc(body), icon: String::new(), buttons, on_click: Some(Box::new(on_click)) });
}

// shortcut: no live progress card on Linux (Windows has one); add it with `replaces_id` + the "value" hint when asked.
pub fn transfer_start(_: &str, _: bool, _: &str, _: &str, _: u64, _: impl Fn(&str) + Send + 'static) {}
pub fn transfer_progress(_: &str, _: &str, _: u64, _: u64, _: u64) {}
pub fn transfer_clear(_: &str) {}

/// "Archivo recibido" with Abrir / Abrir carpeta; an executable gets only its folder, since opening would run it.
pub fn transfer_done(_: &str, file: &Path) {
    let name = file.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
    let mut buttons = Vec::new();
    if !runs_code(file) {
        buttons.push(Button::Open("Abrir".into(), file.to_path_buf()));
    }
    if let Some(dir) = file.parent() {
        buttons.push(Button::Open("Abrir carpeta".into(), dir.to_path_buf()));
    }
    toast_buttons("Archivo recibido", &name, &buttons, |_| {});
}

struct Notice {
    title: String,
    body: String,
    icon: String,
    buttons: Vec<Button>,
    on_click: Option<Box<dyn Fn(&str) + Send>>,
}

/// One thread owns the session-bus connection: it sends the notifications and receives their `ActionInvoked`
/// signals (servers may address those to the sender only, so both must happen on the same connection).
fn show(n: Notice) {
    static TX: OnceLock<Mutex<mpsc::Sender<Notice>>> = OnceLock::new();
    let tx = TX.get_or_init(|| {
        let (tx, rx) = mpsc::channel();
        let _ = std::thread::Builder::new().name("notifications".into()).spawn(move || worker(rx));
        Mutex::new(tx)
    });
    if tx.lock().unwrap_or_else(|e| e.into_inner()).send(n).is_err() {
        eprintln!("toast: no hay conexión con el bus de sesión");
    }
}

type Handlers = Arc<Mutex<HashMap<u32, (Vec<Button>, Option<Box<dyn Fn(&str) + Send>>)>>>;

fn worker(rx: mpsc::Receiver<Notice>) {
    let conn = match Connection::new_session() {
        Ok(c) => c,
        Err(e) => {
            eprintln!("toast: {e}");
            return;
        }
    };
    let handlers: Handlers = Arc::default();
    let h = handlers.clone();
    let _ = conn.add_match(MatchRule::new_signal(NOTIFY, "ActionInvoked"), move |(): (), _, m| {
        if let (Some(id), Some(key)) = m.get2::<u32, String>() {
            // The server closes the notification after an action: this handler is single-use.
            if let Some((buttons, on_click)) = h.lock().unwrap_or_else(|e| e.into_inner()).remove(&id) {
                match key.parse::<usize>().ok().and_then(|i| buttons.get(i)) {
                    // Defense in depth: even if a caller offers a program, only its folder is opened.
                    Some(Button::Open(_, p)) if runs_code(p) => p.parent().map(xdg_open).unwrap_or_default(),
                    Some(Button::Open(_, p)) => xdg_open(p),
                    Some(Button::Call(_, arg)) => on_click.iter().for_each(|f| f(arg)),
                    None => {}
                }
            }
        }
        true
    });
    let h = handlers.clone();
    let _ = conn.add_match(MatchRule::new_signal(NOTIFY, "NotificationClosed"), move |(): (), _, m| {
        if let Some(id) = m.get1::<u32>() {
            h.lock().unwrap_or_else(|e| e.into_inner()).remove(&id);
        }
        true
    });
    loop {
        while let Ok(n) = rx.try_recv() {
            match notify(&conn, &n) {
                Ok(id) if !n.buttons.is_empty() => {
                    let mut hs = handlers.lock().unwrap_or_else(|e| e.into_inner());
                    // A handful at most: drop the oldest if the server never reports closing.
                    if hs.len() >= 16 {
                        if let Some(&oldest) = hs.keys().min() {
                            hs.remove(&oldest);
                        }
                    }
                    hs.insert(id, (n.buttons, n.on_click));
                }
                Ok(_) => {}
                Err(e) => eprintln!("toast: {e}"),
            }
        }
        // Wakes up on any signal; a new notification waits at most this long.
        if let Err(e) = conn.process(Duration::from_millis(150)) {
            eprintln!("toast: {e}");
            return;
        }
    }
}

fn notify(conn: &Connection, n: &Notice) -> Result<u32, dbus::Error> {
    let actions: Vec<String> = n
        .buttons
        .iter()
        .enumerate()
        .flat_map(|(i, b)| {
            let label = match b {
                Button::Open(l, _) | Button::Call(l, _) => l.clone(),
            };
            [i.to_string(), label]
        })
        .collect();
    let mut hints: HashMap<String, Variant<Box<dyn RefArg>>> = HashMap::new();
    hints.insert("desktop-entry".into(), Variant(Box::new(ICON_NAME.to_string())));
    let icon = if n.icon.is_empty() { ICON_NAME } else { n.icon.as_str() };
    let proxy = conn.with_proxy(NOTIFY, "/org/freedesktop/Notifications", Duration::from_secs(3));
    let (id,): (u32,) = proxy.method_call(NOTIFY, "Notify", ("Alero", 0u32, icon, n.title.as_str(), n.body.as_str(), actions, hints, -1i32))?;
    Ok(id)
}

/// Copies text to the clipboard with the first tool that works: wl-copy on Wayland, then xclip, then xsel.
pub fn set_clipboard(text: &str) {
    use std::io::Write;
    let wl: &[(&str, &[&str])] = &[("wl-copy", &[])];
    let x: &[(&str, &[&str])] = &[("xclip", &["-selection", "clipboard", "-in"]), ("xsel", &["--clipboard", "--input"])];
    let order: Vec<_> = if is_wayland() { wl.iter().chain(x).collect() } else { x.iter().chain(wl).collect() };
    for (tool, args) in order {
        let Some(path) = which(tool) else { continue };
        let Ok(mut child) = Command::new(path).args(*args).stdin(Stdio::piped()).stdout(Stdio::null()).stderr(Stdio::null()).spawn() else {
            continue;
        };
        if let Some(mut stdin) = child.stdin.take() {
            let _ = stdin.write_all(text.as_bytes());
        }
        // The tools fork a background owner of the selection and the parent returns at once.
        if child.wait().is_ok_and(|s| s.success()) {
            return;
        }
    }
    eprintln!("portapapeles: instala wl-clipboard (Wayland) o xclip (X11)");
}

/// "Debian 12", "Ubuntu 24.04"… from /etc/os-release; just the name when the distribution has no version.
pub fn os_version() -> String {
    os_version_from(&std::fs::read_to_string("/etc/os-release").unwrap_or_default(), &std::env::var("XDG_CURRENT_DESKTOP").unwrap_or_default())
}

/// "Debian GNU/Linux 13 (trixie) · KDE": the distro's own PRETTY_NAME plus the desktop.
fn os_version_from(release: &str, desktop: &str) -> String {
    let field = |key: &str| {
        release
            .lines()
            .find_map(|l| l.strip_prefix(key).and_then(|v| v.strip_prefix('=')))
            .map(|v| v.trim().trim_matches('"').to_string())
            .unwrap_or_default()
    };
    let name = match field("PRETTY_NAME") {
        p if !p.is_empty() => p,
        _ => [field("NAME"), field("VERSION_ID")].into_iter().filter(|s| !s.is_empty()).collect::<Vec<_>>().join(" "),
    };
    [name, desktop.split(':').next().unwrap_or("").to_string()].into_iter().filter(|s| !s.is_empty()).collect::<Vec<_>>().join(" · ")
}

#[cfg(test)]
mod os_tests {
    #[test]
    fn os_label_uses_pretty_name_and_desktop() {
        let r = "NAME=\"Debian GNU/Linux\"\nPRETTY_NAME=\"Debian GNU/Linux 13 (trixie)\"\nVERSION_ID=\"13\"\n";
        assert_eq!(super::os_version_from(r, "KDE"), "Debian GNU/Linux 13 (trixie) · KDE");
        assert_eq!(super::os_version_from("NAME=\"Arch\"\n", ""), "Arch");
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn received_file_buttons_are_safe() {
        assert_eq!(file_uri(Path::new("/home/nicolás/Descargas/Alero/a b#1.pdf")), "file:///home/nicol%C3%A1s/Descargas/Alero/a%20b%231.pdf");
        assert!(runs_code(Path::new("setup.SH")) && runs_code(Path::new("/x/a.AppImage")) && runs_code(Path::new("x.desktop")));
        assert!(runs_code(Path::new(".sh")) && runs_code(Path::new("q.deb")) && runs_code(Path::new("a.exe")));
        assert!(!runs_code(Path::new("foto.jpg")) && !runs_code(Path::new("doc.pdf")) && !runs_code(Path::new("sin_extension")));
    }

    #[test]
    fn body_is_escaped_and_capped() {
        assert_eq!(esc("<b>a&b</b>\u{7}"), "&lt;b&gt;a&amp;b&lt;/b&gt; ");
        assert_eq!(esc(&"x".repeat(500)).len(), 300);
    }
}
