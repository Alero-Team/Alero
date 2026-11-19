//! What only adb can do (wireless debugging or a USB cable): the island's extra phone controls. Same rules as the
//! app (`app/lib/phone_adb.dart`): the adb bundled next to the executable (or the distro's on Linux), the phone found
//! by its IP. Every call runs on the `island-adb` thread, never in the drawing loop.

use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::sync::mpsc::{Receiver, Sender};

use super::run::Msg;

/// Switches read from the phone's settings.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Radios {
    pub wifi: bool,
    pub bt: bool,
    pub rotate: bool,
}

/// A request for the adb thread: refresh this phone (peer id, its IP), and first apply `act` if there is one.
pub struct Req {
    pub peer: String,
    pub ip: String,
    pub act: Option<(&'static str, bool)>,
}

fn adb() -> Option<PathBuf> {
    let dir = std::env::current_exe().ok()?.parent()?.join("scrcpy");
    let bundled = dir.join(if cfg!(windows) { "adb.exe" } else { "adb" });
    if bundled.is_file() {
        return Some(bundled);
    }
    #[cfg(target_os = "linux")]
    return crate::linux::which("adb");
    #[cfg(not(target_os = "linux"))]
    None
}

// shortcut: no timeout on adb calls (a hung adb only stalls this thread, not the island); add one if that shows up.
fn run(args: &[&str]) -> Option<String> {
    let mut c = Command::new(adb()?);
    c.args(args).env("ADB_MDNS_AUTO_CONNECT", "adb-tls-connect").stdin(Stdio::null()).stderr(Stdio::null());
    #[cfg(target_os = "linux")]
    c.env("ADB_MDNS_OPENSCREEN", "1");
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        c.creation_flags(0x0800_0000); // CREATE_NO_WINDOW
    }
    let out = c.output().ok()?;
    out.status.success().then(|| String::from_utf8_lossy(&out.stdout).into_owned())
}

/// From `adb devices`: the phone's wireless-debugging serial (`ip:port`), else the only ready device.
pub fn serial_in(devices: &str, ip: &str) -> Option<String> {
    let ready: Vec<&str> = devices
        .lines()
        .skip(1)
        .filter_map(|l| {
            let mut p = l.split_whitespace();
            let serial = p.next()?;
            (p.next()? == "device").then_some(serial)
        })
        .collect();
    let by_ip = ready.iter().find(|s| !ip.is_empty() && s.starts_with(&format!("{ip}:")));
    by_ip.or(if ready.len() == 1 { ready.first() } else { None }).map(|s| s.to_string())
}

pub fn radios_in(out: &str) -> Radios {
    let v: Vec<&str> = out.split_whitespace().collect();
    Radios { wifi: v.first().is_some_and(|x| *x != "0"), bt: v.get(1) == Some(&"1"), rotate: v.get(2) == Some(&"1") }
}

fn apply(serial: &str, what: &str, on: bool) {
    let cmd = match (what, on) {
        ("wifi", _) => format!("svc wifi {}", if on { "enable" } else { "disable" }),
        ("bt", _) => format!("cmd bluetooth_manager {}", if on { "enable" } else { "disable" }),
        ("rotate", _) => format!("settings put system accelerometer_rotation {}", on as u8),
        ("lock", _) => "input keyevent 223".into(),
        // Android has no command to start the hotspot: this opens its settings screen, as the app does.
        ("hotspot", _) => "am start -a android.settings.TETHER_SETTINGS".into(),
        _ => return,
    };
    let _ = run(&["-s", serial, "shell", &cmd]);
}

/// The adb thread: answers each request with `Msg::Adb(peer, radios)`; None when the phone has no adb now.
pub fn spawn(rx: Receiver<Req>, tx: Sender<Msg>) {
    let _ = std::thread::Builder::new().name("island-adb".into()).spawn(move || {
        while let Ok(mut req) = rx.recv() {
            // Polls pile up while adb is slow: only the last one matters, but no action is dropped.
            while let Ok(next) = rx.try_recv() {
                if req.act.is_some() && next.act.is_none() {
                    continue;
                }
                req = next;
            }
            let serial = run(&["devices"]).and_then(|d| serial_in(&d, &req.ip));
            if let (Some(s), Some((what, on))) = (&serial, req.act) {
                apply(s, what, on);
                // The radios take a moment to report their new state.
                std::thread::sleep(std::time::Duration::from_millis(800));
            }
            let radios = serial.as_ref().and_then(|s| {
                run(&["-s", s, "shell", "settings get global wifi_on; settings get global bluetooth_on; settings get system accelerometer_rotation"])
            });
            if tx.send(Msg::Adb(req.peer, radios.map(|o| radios_in(&o)))).is_err() {
                return;
            }
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_phone_is_found_by_its_ip_or_as_the_only_device() {
        let list = "List of devices attached\n192.168.1.20:41257\tdevice\nemulator-5554\toffline\n";
        assert_eq!(serial_in(list, "192.168.1.20").as_deref(), Some("192.168.1.20:41257"));
        assert_eq!(serial_in(list, "10.0.0.2").as_deref(), Some("192.168.1.20:41257"));
        let two = "List of devices attached\nA\tdevice\nB\tdevice\n";
        assert_eq!(serial_in(two, "10.0.0.2"), None);
        assert_eq!(serial_in("List of devices attached\n", ""), None);
        assert_eq!(radios_in("1\n0\n1\n"), Radios { wifi: true, bt: false, rotate: true });
        assert_eq!(radios_in("2 1 0"), Radios { wifi: true, bt: true, rotate: false });
    }
}
