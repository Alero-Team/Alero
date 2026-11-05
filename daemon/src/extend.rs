//! Alero second screen: control the installed, signed IddCx virtual display
//! driver and expose its real Windows monitor through the existing encrypted
//! screen protocol. This is not a cloned image of monitor 0.
use std::io::{Read, Write};
use std::path::Path;
use std::time::{Duration, Instant};

#[cfg(windows)]
const PIPE: &str = r"\\.\pipe\MTTVirtualDisplayPipe";

#[cfg(windows)]
fn send_command(cmd: &str) -> Result<String, String> {
    let mut pipe = std::fs::OpenOptions::new()
        .read(true).write(true).open(PIPE)
        .map_err(|_| "driver_missing".to_string())?;
    let bytes: Vec<u8> = cmd.encode_utf16()
        .flat_map(|word| word.to_le_bytes()).collect();
    pipe.write_all(&bytes).map_err(|_| "driver_write".to_string())?;
    let mut data = [0u8; 1024];
    let n = pipe.read(&mut data).map_err(|_| "driver_read".to_string())?;
    if n == 0 || n % 2 != 0 { return Err("driver_response".into()); }
    let message = String::from_utf16_lossy(
        &data[..n].chunks_exact(2)
            .map(|b| u16::from_le_bytes([b[0], b[1]]))
            .collect::<Vec<_>>(),
    ).trim_matches('\0').trim().to_string();
    if message.to_lowercase().contains("error")
        || message.to_lowercase().contains("invalid") {
        return Err(message);
    }
    Ok(message)
}

#[cfg(not(windows))]
fn send_command(_cmd: &str) -> Result<String, String> {
    Err("unsupported_platform".into())
}

/// A signed IddCx driver must already be installed. Alero never changes
/// driver signature policy and never installs a driver without user consent.
pub fn available() -> bool {
    send_command("PING").map(|r| r.contains("PONG")).unwrap_or(false)
}

pub fn add_display() -> Result<usize, String> {
    let before = crate::sys::monitors();
    if !available() {
        return Err("driver_missing".into());
    }
    send_command("SETDISPLAYCOUNT 1")?;
    let deadline = Instant::now() + Duration::from_secs(6);
    while Instant::now() < deadline {
        let now = crate::sys::monitors();
        if let Some((i, _)) = now.iter().enumerate()
            .find(|(_, rectangle)| !before.contains(rectangle)) {
            return Ok(i);
        }
        std::thread::sleep(Duration::from_millis(150));
    }
    // A driver may have had an active virtual monitor already. The owner can
    // choose its monitor from the Windows settings; never steal monitor zero.
    let monitors = crate::sys::monitors();
    if monitors.len() > 1 { return Ok(monitors.len() - 1); }
    Err("no_virtual_display".into())
}

pub fn remove_display() {
    let _ = send_command("SETDISPLAYCOUNT 0");
}

pub fn installer_url() -> &'static str {
    "https://github.com/VirtualDrivers/Virtual-Display-Driver"
}

pub fn config_enabled(path: &Path) -> bool {
    std::fs::read_to_string(path.join("remote.json"))
        .ok()
        .and_then(|s| serde_json::from_str::<serde_json::Value>(&s).ok())
        .is_some_and(|v| v["allowExtend"] == true)
}
