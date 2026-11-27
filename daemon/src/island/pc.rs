//! What happens on this computer, for the island: downloads that are growing in the Downloads folder, and Claude Code
//! or Codex at work. Two polling threads that run only while the island and its `pc` module are on; nothing here
//! touches the drawing thread. Downloads travel as the same events a phone transfer uses, so they get its card.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::Sender;
use std::sync::Arc;
use std::time::{Duration, Instant, SystemTime};

use pb_core::engine::Event;

use super::run::Msg;
use crate::lang::t;

/// Id prefix of a download seen in the Downloads folder (a phone transfer's id never starts like this).
pub const PC_ID: &str = "pc:";

/// A partial file that has not grown for this long is paused or abandoned: its card ends.
const STALE_SECS: f64 = 60.0;
const PARTIAL: [&str; 4] = [".crdownload", ".part", ".partial", ".download"];

/// The name a partial file will have once finished ("a.zip.crdownload" -> "a.zip").
pub fn partial_target(name: &str) -> Option<&str> {
    let lower = name.to_ascii_lowercase();
    let suffix = PARTIAL.iter().find(|s| lower.ends_with(**s))?;
    Some(&name[..name.len() - suffix.len()]).filter(|n| !n.is_empty())
}

struct Seen {
    size: u64,
    /// When it last grew, and when `size` was read, in seconds of the thread's clock.
    grew_at: f64,
    at: f64,
    rate: f64,
    /// It has been seen growing (a partial file that was already there and never grows says nothing).
    started: bool,
}

#[derive(Default)]
pub struct Downloads {
    seen: HashMap<PathBuf, Seen>,
}

fn event_id(p: &Path) -> String {
    format!("{PC_ID}{}", p.display())
}

fn finished(id: String, ok: bool, message: String, path: String) -> Event {
    Event::TransferFinished { id, ok, code: String::new(), message, path }
}

impl Downloads {
    /// One look at the folder: `parts` are its partial files with their sizes, `now` is seconds on any steady clock.
    /// `resolve` finds the finished file of a partial one that went away, skipping the files already given to another
    /// partial in this step. Returns the transfer events to feed.
    pub fn step(&mut self, now: f64, parts: &[(PathBuf, u64)], resolve: &dyn Fn(&Path, u64, &[PathBuf]) -> Option<PathBuf>) -> Vec<Event> {
        let mut out = Vec::new();
        let mut taken: Vec<PathBuf> = Vec::new();
        let mut stale = Vec::new();
        for (p, size) in parts {
            let Some(s) = self.seen.get_mut(p) else {
                self.seen.insert(p.clone(), Seen { size: *size, grew_at: now, at: now, rate: 0.0, started: false });
                continue;
            };
            let id = event_id(p);
            if *size > s.size {
                let inst = (*size - s.size) as f64 / (now - s.at).max(0.001);
                s.rate = if s.rate == 0.0 { inst } else { 0.7 * s.rate + 0.3 * inst };
                (s.size, s.grew_at) = (*size, now);
                if !s.started {
                    s.started = true;
                    let stem = p.file_name().and_then(|n| n.to_str()).and_then(partial_target).unwrap_or_default();
                    // Chrome downloads to "Unconfirmed 123.crdownload" and names the file at the end.
                    let name = if stem.starts_with("Unconfirmed ") { t("Descarga del navegador", "Browser download").to_string() } else { stem.to_string() };
                    out.push(Event::TransferStarted { id: id.clone(), peer_id: String::new(), peer_name: String::new(), name, size: 0, incoming: true });
                }
                out.push(Event::TransferProgress { id, done: *size, total: 0, bytes_per_sec: s.rate as u64 });
            } else if s.started {
                (s.size, s.rate) = (*size, 0.0);
                if now - s.grew_at > STALE_SECS {
                    out.push(finished(id, false, t("Descarga detenida", "Download stopped").into(), String::new()));
                    stale.push(p.clone());
                } else {
                    out.push(Event::TransferProgress { id, done: *size, total: 0, bytes_per_sec: 0 });
                }
            } else {
                s.size = *size;
            }
            s.at = now;
        }
        for p in stale {
            self.seen.remove(&p);
        }
        let gone: Vec<PathBuf> = self.seen.keys().filter(|p| !parts.iter().any(|(q, _)| q == *p)).cloned().collect();
        for p in gone {
            let Some(s) = self.seen.remove(&p) else { continue };
            if s.started {
                let id = event_id(&p);
                let found = resolve(&p, s.size, &taken);
                taken.extend(found.clone());
                out.push(match found {
                    Some(f) => finished(id, true, String::new(), f.to_string_lossy().into_owned()),
                    None => finished(id, false, t("Descarga cancelada", "Download canceled").into(), String::new()),
                });
            }
        }
        out
    }
}

impl Downloads {
    /// The island or its `pc` switch went off: what was being followed ends here, so no card stays "downloading".
    pub fn stop(&mut self) -> Vec<Event> {
        std::mem::take(&mut self.seen)
            .into_iter()
            .filter(|(_, s)| s.started)
            .map(|(p, _)| finished(event_id(&p), false, t("Descarga detenida", "Download stopped").into(), String::new()))
            .collect()
    }
}

/// The file a partial one became: its name without the suffix, else (Chrome) the newest file just written that is
/// at least as big.
pub fn resolve_final(partial: &Path, size: u64, taken: &[PathBuf]) -> Option<PathBuf> {
    let direct = partial.with_file_name(partial_target(partial.file_name()?.to_str()?)?);
    if direct.is_file() && !taken.contains(&direct) {
        return Some(direct);
    }
    let now = SystemTime::now();
    std::fs::read_dir(partial.parent()?)
        .ok()?
        .flatten()
        .filter(|e| !taken.contains(&e.path()))
        .filter_map(|e| {
            let m = e.metadata().ok()?;
            let fresh = now.duration_since(m.modified().ok()?).ok()? < Duration::from_secs(15);
            (m.is_file() && m.len() >= size && fresh && partial_target(e.file_name().to_str()?).is_none()).then(|| (m.modified().ok(), e.path()))
        })
        .max()
        .map(|(_, p)| p)
}

/// Writes `bytes` as `<stem>-<unix secs>.png` in `dir`, never over a file that is there (a second one in the same
/// second gets a number). Returns the file's name.
pub fn save_new(dir: &Path, stem: &str, bytes: &[u8]) -> Option<String> {
    use std::io::Write;
    let secs = SystemTime::now().duration_since(SystemTime::UNIX_EPOCH).map_or(0, |d| d.as_secs());
    for n in 0..100u32 {
        let name = if n == 0 { format!("{stem}-{secs}.png") } else { format!("{stem}-{secs}-{n}.png") };
        match std::fs::OpenOptions::new().write(true).create_new(true).open(dir.join(&name)) {
            Ok(mut f) => return f.write_all(bytes).ok().map(|_| name),
            Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => continue,
            Err(_) => return None,
        }
    }
    None
}

/// A full-screen PNG of this computer's primary screen into `dir`. Returns the file's name. Slow: call it off the
/// drawing thread.
pub fn screenshot(dir: &Path) -> Option<String> {
    let (w, h, mut px) = crate::sys::capture_monitor(u32::MAX, 0, false)?;
    // The capture is BGRA (Windows leaves alpha at 0); the PNG wants opaque RGBA.
    px.chunks_exact_mut(4).for_each(|p| {
        p.swap(0, 2);
        p[3] = 255;
    });
    let png = crate::remote::png_of(w, h, &px)?;
    std::fs::create_dir_all(dir).ok()?;
    save_new(dir, "Captura-PC", &png)
}

fn scan(dir: &Path) -> Vec<(PathBuf, u64)> {
    let Ok(rd) = std::fs::read_dir(dir) else { return Vec::new() };
    rd.flatten()
        .filter(|e| e.file_name().to_str().is_some_and(|n| partial_target(n).is_some()))
        .filter_map(|e| e.metadata().ok().filter(|m| m.is_file()).map(|m| (e.path(), m.len())))
        .collect()
}

#[cfg(windows)]
pub fn downloads_dir() -> Option<PathBuf> {
    use windows::Win32::System::Com::CoTaskMemFree;
    use windows::Win32::UI::Shell::{FOLDERID_Downloads, SHGetKnownFolderPath, KF_FLAG_DEFAULT};
    // The known folder follows a Downloads folder the user moved; the profile's is the fallback.
    let known = unsafe {
        SHGetKnownFolderPath(&FOLDERID_Downloads, KF_FLAG_DEFAULT, None).ok().and_then(|p| {
            let s = p.to_string().ok();
            CoTaskMemFree(Some(p.0 as *const _));
            s
        })
    };
    known.map(PathBuf::from).or_else(|| std::env::var_os("USERPROFILE").map(|h| PathBuf::from(h).join("Downloads")))
}

#[cfg(target_os = "linux")]
pub fn downloads_dir() -> Option<PathBuf> {
    let home = PathBuf::from(std::env::var_os("HOME")?);
    let conf = std::env::var_os("XDG_CONFIG_HOME").map(PathBuf::from).unwrap_or_else(|| home.join(".config"));
    let text = std::fs::read_to_string(conf.join("user-dirs.dirs")).unwrap_or_default();
    Some(parse_user_dir(&text, &home).unwrap_or_else(|| home.join("Downloads")))
}

/// `XDG_DOWNLOAD_DIR="$HOME/Descargas"` from user-dirs.dirs.
#[cfg(any(target_os = "linux", test))]
fn parse_user_dir(text: &str, home: &Path) -> Option<PathBuf> {
    let v = text.lines().find_map(|l| l.trim().strip_prefix("XDG_DOWNLOAD_DIR="))?.trim().trim_matches('"');
    if let Some(rel) = v.strip_prefix("$HOME/") {
        return (!rel.is_empty()).then(|| home.join(rel));
    }
    v.starts_with('/').then(|| PathBuf::from(v))
}

#[cfg(not(any(windows, target_os = "linux")))]
pub fn downloads_dir() -> Option<PathBuf> {
    None
}

// ------------------------------------------------------------------------------------------------------ agents

/// A terminal coding agent on this computer.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Agent {
    Claude = 0,
    Codex = 1,
}

impl Agent {
    pub fn name(self) -> &'static str {
        match self {
            Agent::Claude => "Claude Code",
            Agent::Codex => "Codex",
        }
    }
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Work {
    Working,
    Idle,
    /// Not running.
    Gone,
}

// Working or not is read from the agents' own session logs, not from CPU use: both burn CPU at their prompt
// (terminal redraws, MCP servers), which made the island say "working" on launch and "finished" at random.

/// A log not written for this long is ignored, so a session killed mid-turn does not "work" forever.
// shortcut: a single tool call that runs silently for longer (a huge build) reads as finished; raise it if seen.
const FRESH: Duration = Duration::from_secs(15 * 60);
/// Bytes read from the end of a log: one line can be a big tool result.
const TAIL: u64 = 512 * 1024;

/// A Claude Code transcript line: Some(true) while a turn runs, Some(false) when it ended, None says nothing.
pub fn claude_line(line: &str) -> Option<bool> {
    let j: serde_json::Value = serde_json::from_str(line).ok()?;
    let m = &j["message"];
    match j["type"].as_str()? {
        "assistant" => Some(!matches!(m["stop_reason"].as_str(), Some("end_turn" | "stop_sequence" | "refusal"))),
        "user" if j["isMeta"] != true => {
            let text = m["content"].as_str().or_else(|| m["content"][0]["text"].as_str()).unwrap_or("").trim_start();
            if text.starts_with("[Request interrupted") {
                return Some(false);
            }
            // Slash commands (/model…), their output and `!` shell lines never reach the model.
            (!["<command-", "<local-command-", "<bash-"].iter().any(|p| text.starts_with(p))).then_some(true)
        }
        _ => None,
    }
}

/// A Codex rollout line, same meaning as `claude_line`.
pub fn codex_line(line: &str) -> Option<bool> {
    let j: serde_json::Value = serde_json::from_str(line).ok()?;
    if j["type"] != "event_msg" {
        return None;
    }
    match j["payload"]["type"].as_str()? {
        "task_started" => Some(true),
        "task_complete" | "turn_aborted" => Some(false),
        _ => None,
    }
}

/// What the last decisive line of a log says (a half-written last line just fails to parse).
fn log_busy(path: &Path, read: fn(&str) -> Option<bool>) -> bool {
    use std::io::{Read, Seek, SeekFrom};
    let Ok(mut f) = std::fs::File::open(path) else { return false };
    let len = f.metadata().map_or(0, |m| m.len());
    let mut buf = Vec::new();
    if f.seek(SeekFrom::Start(len.saturating_sub(TAIL))).is_err() || f.read_to_end(&mut buf).is_err() {
        return false;
    }
    String::from_utf8_lossy(&buf).lines().rev().find_map(read).unwrap_or(false)
}

/// `*.jsonl` files right inside `dirs` written within `FRESH`.
fn fresh_logs(dirs: impl IntoIterator<Item = PathBuf>) -> Vec<PathBuf> {
    let now = SystemTime::now();
    dirs.into_iter()
        .filter_map(|d| std::fs::read_dir(d).ok())
        .flat_map(|rd| rd.flatten())
        .filter(|e| e.path().extension().is_some_and(|x| x == "jsonl"))
        .filter(|e| e.metadata().ok().and_then(|m| m.modified().ok()).and_then(|t| now.duration_since(t).ok()).is_some_and(|age| age < FRESH))
        .map(|e| e.path())
        .collect()
}

fn subdirs(d: &Path) -> Vec<PathBuf> {
    let mut v: Vec<PathBuf> = std::fs::read_dir(d).map(|rd| rd.flatten().map(|e| e.path()).filter(|p| p.is_dir()).collect()).unwrap_or_default();
    v.sort();
    v
}

/// Whether any recent session of each agent is mid-turn.
fn busy_by_agent() -> [bool; 2] {
    let home = std::env::var_os("USERPROFILE").or_else(|| std::env::var_os("HOME")).map(PathBuf::from).unwrap_or_default();
    let root = |var: &str, dot: &str| std::env::var_os(var).map(PathBuf::from).unwrap_or_else(|| home.join(dot));
    // Claude: <config>/projects/<project>/<session>.jsonl (subagents live one level deeper and are skipped).
    let claude = fresh_logs(subdirs(&root("CLAUDE_CONFIG_DIR", ".claude").join("projects")));
    // Codex: <home>/sessions/YYYY/MM/DD/rollout-*.jsonl; the two newest days cover a session past midnight.
    let days: Vec<PathBuf> = subdirs(&root("CODEX_HOME", ".codex").join("sessions")).iter().flat_map(|y| subdirs(y)).flat_map(|m| subdirs(&m)).collect();
    let codex = fresh_logs(days.into_iter().rev().take(2));
    [claude.iter().any(|p| log_busy(p, claude_line)), codex.iter().any(|p| log_busy(p, codex_line))]
}

/// Which agent a process is: its executable (path or name) and, where the system gives it, its command line.
/// The desktop apps of both are Electron programs with the same file names, so their install folders are refused.
// shortcut: on Windows there is no command line here, so a node-run npm install is missed (the packages ship a
// native claude.exe / codex.exe); read the process's command line if that shows up.
pub fn agent_of(exe: &str, cmd: &str) -> Option<Agent> {
    let lower = exe.to_ascii_lowercase().replace('\\', "/");
    // Squirrel installs of the desktop apps live in AppData\Local\<app>\app-<version>.
    if lower.contains("windowsapps") || lower.contains("anthropicclaude") || (lower.contains("/appdata/local/") && lower.contains("/app-")) {
        return None;
    }
    let base = lower.rsplit('/').next()?;
    match base.strip_suffix(".exe").unwrap_or(base) {
        "claude" => Some(Agent::Claude),
        "codex" => Some(Agent::Codex),
        "node" | "bun" if cmd.contains("@anthropic-ai/claude-code") => Some(Agent::Claude),
        "node" | "bun" if cmd.contains("@openai/codex") => Some(Agent::Codex),
        _ => None,
    }
}

/// Total CPU seconds of each agent's processes, None when it is not running.
#[cfg(windows)]
fn cpu_by_agent() -> [Option<f64>; 2] {
    use std::mem::size_of;
    use windows::core::PWSTR;
    use windows::Win32::Foundation::{CloseHandle, FILETIME};
    use windows::Win32::System::Diagnostics::ToolHelp::{CreateToolhelp32Snapshot, Process32FirstW, Process32NextW, PROCESSENTRY32W, TH32CS_SNAPPROCESS};
    use windows::Win32::System::Threading::{GetProcessTimes, OpenProcess, QueryFullProcessImageNameW, PROCESS_NAME_WIN32, PROCESS_QUERY_LIMITED_INFORMATION};
    let secs = |f: FILETIME| ((f.dwHighDateTime as u64) << 32 | f.dwLowDateTime as u64) as f64 / 1e7;
    let mut out = [None; 2];
    unsafe {
        let Ok(snap) = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0) else { return out };
        let mut e = PROCESSENTRY32W { dwSize: size_of::<PROCESSENTRY32W>() as u32, ..Default::default() };
        let mut more = Process32FirstW(snap, &mut e).is_ok();
        while more {
            let len = e.szExeFile.iter().position(|&c| c == 0).unwrap_or(e.szExeFile.len());
            let name = String::from_utf16_lossy(&e.szExeFile[..len]);
            // Only the two names are worth opening a handle for (the path then tells the terminal agent from the app).
            if agent_of(&name, "").is_some() {
                if let Ok(h) = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, e.th32ProcessID) {
                    let mut buf = [0u16; 1024];
                    let mut n = buf.len() as u32;
                    let path = QueryFullProcessImageNameW(h, PROCESS_NAME_WIN32, PWSTR(buf.as_mut_ptr()), &mut n).ok().map(|_| String::from_utf16_lossy(&buf[..n as usize]));
                    let (mut c, mut x, mut k, mut u) = (FILETIME::default(), FILETIME::default(), FILETIME::default(), FILETIME::default());
                    if let (Some(a), true) = (path.and_then(|p| agent_of(&p, "")), GetProcessTimes(h, &mut c, &mut x, &mut k, &mut u).is_ok()) {
                        *out[a as usize].get_or_insert(0.0) += secs(k) + secs(u);
                    }
                    let _ = CloseHandle(h);
                }
            }
            more = Process32NextW(snap, &mut e).is_ok();
        }
        let _ = CloseHandle(snap);
    }
    out
}

/// utime + stime of `/proc/<pid>/stat`, in clock ticks (the comm field may hold spaces and parentheses: cut after the last ')').
#[cfg(any(target_os = "linux", test))]
fn stat_ticks(stat: &str) -> Option<u64> {
    let mut f = stat[stat.rfind(')')? + 1..].split_whitespace().skip(11);
    Some(f.next()?.parse::<u64>().ok()? + f.next()?.parse::<u64>().ok()?)
}

#[cfg(target_os = "linux")]
fn cpu_by_agent() -> [Option<f64>; 2] {
    let tick = (unsafe { libc::sysconf(libc::_SC_CLK_TCK) }).max(1) as f64;
    let mut out = [None; 2];
    let Ok(rd) = std::fs::read_dir("/proc") else { return out };
    for e in rd.flatten() {
        let pid = e.file_name();
        if !pid.to_str().is_some_and(|s| s.bytes().all(|b| b.is_ascii_digit())) {
            continue;
        }
        let dir = e.path();
        let comm = std::fs::read_to_string(dir.join("comm")).unwrap_or_default();
        let comm = comm.trim();
        let cmd = if matches!(comm, "node" | "bun") { std::fs::read(dir.join("cmdline")).map(|b| String::from_utf8_lossy(&b).replace('\0', " ")).unwrap_or_default() } else { String::new() };
        let Some(a) = agent_of(comm, &cmd) else { continue };
        if let Some(ticks) = std::fs::read_to_string(dir.join("stat")).ok().and_then(|s| stat_ticks(&s)) {
            *out[a as usize].get_or_insert(0.0) += ticks as f64 / tick;
        }
    }
    out
}

#[cfg(not(any(windows, target_os = "linux")))]
fn cpu_by_agent() -> [Option<f64>; 2] {
    [None; 2]
}

/// Starts both threads. `on` is the island's switch: while it is off they only look at it now and then.
pub fn spawn(tx: Sender<Msg>, on: Arc<AtomicBool>, agents_on: Arc<AtomicBool>) {
    let (tx2, on2) = (tx.clone(), agents_on);
    let _ = std::thread::Builder::new().name("island-downloads".into()).spawn(move || {
        let (mut dl, t0, dir) = (Downloads::default(), Instant::now(), downloads_dir());
        loop {
            if !on.load(Ordering::Relaxed) || dir.is_none() {
                for e in dl.stop() {
                    if tx.send(Msg::Event(e)).is_err() {
                        return;
                    }
                }
                std::thread::sleep(Duration::from_secs(3));
                continue;
            }
            for e in dl.step(t0.elapsed().as_secs_f64(), &scan(dir.as_deref().unwrap_or(Path::new(""))), &resolve_final) {
                if tx.send(Msg::Event(e)).is_err() {
                    return;
                }
            }
            std::thread::sleep(Duration::from_secs(1));
        }
    });
    let _ = std::thread::Builder::new().name("island-agents".into()).spawn(move || {
        let mut shown: [Option<Work>; 2] = [None; 2];
        loop {
            if !on2.load(Ordering::Relaxed) {
                shown = [None; 2];
                std::thread::sleep(Duration::from_secs(3));
                continue;
            }
            // The process tells running from gone (the logs outlive it); the logs tell working from idle.
            let (cpu, busy) = (cpu_by_agent(), busy_by_agent());
            for (i, a) in [Agent::Claude, Agent::Codex].into_iter().enumerate() {
                let s = match (cpu[i].is_some(), busy[i]) {
                    (false, _) => Work::Gone,
                    (true, true) => Work::Working,
                    (true, false) => Work::Idle,
                };
                if shown[i].replace(s) != Some(s) && tx2.send(Msg::Agent(a, s)).is_err() {
                    return;
                }
            }
            std::thread::sleep(Duration::from_millis(2500));
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    fn none(_: &Path, _: u64, _: &[PathBuf]) -> Option<PathBuf> {
        None
    }

    #[test]
    fn partial_names_lose_their_suffix() {
        assert_eq!(partial_target("a.zip.crdownload"), Some("a.zip"));
        assert_eq!(partial_target("A.ISO.PART"), Some("A.ISO"));
        assert_eq!(partial_target("x.partial"), Some("x"));
        assert_eq!(partial_target("movie.mp4.download"), Some("movie.mp4"));
        assert_eq!(partial_target(".part"), None);
        assert_eq!(partial_target("notes.txt"), None);
    }

    #[test]
    fn a_growing_partial_file_becomes_a_download_and_ends_with_its_file() {
        let mut d = Downloads::default();
        let p = PathBuf::from("/dl/a.zip.crdownload");
        // First sight says nothing: it may be an old half-file.
        assert!(d.step(0.0, &[(p.clone(), 100)], &none).is_empty());
        assert!(d.step(1.0, &[(p.clone(), 100)], &none).is_empty());
        let ev = d.step(2.0, &[(p.clone(), 1100)], &none);
        assert!(matches!(&ev[0], Event::TransferStarted { name, incoming: true, .. } if name == "a.zip"));
        assert!(matches!(&ev[1], Event::TransferProgress { done: 1100, total: 0, bytes_per_sec: 1000, .. }));
        let done = |_: &Path, _: u64, _: &[PathBuf]| Some(PathBuf::from("/dl/a.zip"));
        let ev = d.step(3.0, &[], &done);
        assert!(matches!(&ev[..], [Event::TransferFinished { ok: true, path, .. }] if path.ends_with("a.zip")));
        assert!(d.step(4.0, &[], &done).is_empty());
    }

    #[test]
    fn a_partial_file_that_vanishes_without_a_result_is_a_canceled_download() {
        let mut d = Downloads::default();
        let p = PathBuf::from("/dl/b.part");
        d.step(0.0, &[(p.clone(), 1)], &none);
        d.step(1.0, &[(p.clone(), 9)], &none);
        assert!(matches!(&d.step(2.0, &[], &none)[..], [Event::TransferFinished { ok: false, .. }]));
    }

    #[test]
    fn a_stalled_download_ends_after_a_minute_and_its_rate_drops_meanwhile() {
        let mut d = Downloads::default();
        let p = PathBuf::from("/dl/c.part");
        d.step(0.0, &[(p.clone(), 1)], &none);
        d.step(1.0, &[(p.clone(), 9)], &none);
        assert!(matches!(&d.step(5.0, &[(p.clone(), 9)], &none)[..], [Event::TransferProgress { bytes_per_sec: 0, .. }]));
        assert!(matches!(&d.step(62.0, &[(p.clone(), 9)], &none)[..], [Event::TransferFinished { ok: false, .. }]));
        // Forgotten: if it grows again it is a new download.
        assert!(d.step(63.0, &[(p.clone(), 20)], &none).is_empty());
        assert!(matches!(&d.step(64.0, &[(p, 30)], &none)[0], Event::TransferStarted { .. }));
    }

    #[test]
    fn turning_it_off_ends_the_started_downloads_only() {
        let mut d = Downloads::default();
        let (a, b) = (PathBuf::from("/dl/a.part"), PathBuf::from("/dl/b.part"));
        d.step(0.0, &[(a.clone(), 1), (b.clone(), 1)], &none);
        d.step(1.0, &[(a, 9), (b, 1)], &none);
        assert!(matches!(&d.stop()[..], [Event::TransferFinished { ok: false, id, .. }] if id.ends_with("a.part")));
        assert!(d.stop().is_empty());
    }

    #[test]
    fn two_partials_never_resolve_to_the_same_file() {
        let dir = std::env::temp_dir().join(format!("alero-resolve-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let f = dir.join("x.bin");
        std::fs::write(&f, b"data").unwrap();
        let p = dir.join("Unconfirmed 1.crdownload");
        assert_eq!(resolve_final(&p, 1, &[]), Some(f.clone()));
        assert_eq!(resolve_final(&p, 1, &[f]), None);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_screenshot_never_overwrites_a_file() {
        let dir = std::env::temp_dir().join(format!("alero-save-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let (a, b) = (save_new(&dir, "S", b"1").unwrap(), save_new(&dir, "S", b"2").unwrap());
        assert_ne!(a, b);
        assert_eq!(std::fs::read(dir.join(&a)).unwrap(), b"1");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn claude_works_from_a_prompt_to_its_end_turn_and_slash_commands_are_not_work() {
        let user = |c: &str| format!(r#"{{"type":"user","message":{{"role":"user","content":{c}}}}}"#);
        let asst = |r: &str| format!(r#"{{"type":"assistant","message":{{"stop_reason":{r},"content":[]}}}}"#);
        assert_eq!(claude_line(&user(r#""<command-name>/model</command-name>""#)), None, "opening Claude and running /model");
        assert_eq!(claude_line(&user(r#""<local-command-stdout>Set model</local-command-stdout>""#)), None);
        assert_eq!(claude_line(r#"{"type":"user","isMeta":true,"message":{"content":"<local-command-caveat>x"}}"#), None);
        assert_eq!(claude_line(&user(r#"[{"type":"text","text":"arregla el bug"}]"#)), Some(true));
        assert_eq!(claude_line(&user(r#"[{"type":"tool_result","content":"ok"}]"#)), Some(true));
        assert_eq!(claude_line(&asst(r#""tool_use""#)), Some(true));
        assert_eq!(claude_line(&asst("null")), Some(true), "still streaming");
        assert_eq!(claude_line(&asst(r#""end_turn""#)), Some(false));
        assert_eq!(claude_line(&user(r#"[{"type":"text","text":"[Request interrupted by user]"}]"#)), Some(false));
        assert_eq!(claude_line(r#"{"type":"system","subtype":"stop_hook_summary"}"#), None);
        assert_eq!(claude_line(r#"{"type":"user","message":"#), None, "half-written line");
    }

    #[test]
    fn codex_works_between_task_started_and_its_end() {
        let ev = |t: &str| format!(r#"{{"type":"event_msg","payload":{{"type":"{t}"}}}}"#);
        assert_eq!(codex_line(&ev("task_started")), Some(true));
        assert_eq!(codex_line(&ev("task_complete")), Some(false));
        assert_eq!(codex_line(&ev("turn_aborted")), Some(false));
        assert_eq!(codex_line(&ev("token_count")), None);
        assert_eq!(codex_line(r#"{"type":"response_item","payload":{"type":"message"}}"#), None);
    }

    #[test]
    fn a_log_says_what_its_last_decisive_line_says() {
        let p = std::env::temp_dir().join(format!("alero-log-{}.jsonl", std::process::id()));
        let lines = [r#"{"type":"event_msg","payload":{"type":"task_started"}}"#, r#"{"type":"event_msg","payload":{"type":"token_count"}}"#, r#"{"type":"event"#];
        std::fs::write(&p, lines.join("\n")).unwrap();
        assert!(log_busy(&p, codex_line));
        std::fs::write(&p, format!("{}\n{}\n", lines[0], r#"{"type":"event_msg","payload":{"type":"task_complete"}}"#)).unwrap();
        assert!(!log_busy(&p, codex_line));
        let _ = std::fs::remove_file(&p);
    }

    #[test]
    fn the_terminal_agents_are_told_from_the_desktop_apps() {
        assert_eq!(agent_of(r"C:\Users\a\.local\bin\claude.exe", ""), Some(Agent::Claude));
        assert_eq!(agent_of("codex", ""), Some(Agent::Codex));
        assert_eq!(agent_of("node", "node /usr/lib/node_modules/@anthropic-ai/claude-code/cli.js"), Some(Agent::Claude));
        assert_eq!(agent_of("node", "node /x/@openai/codex/bin/codex.js"), Some(Agent::Codex));
        assert_eq!(agent_of("node", "node server.js"), None);
        assert_eq!(agent_of(r"C:\Users\a\AppData\Local\AnthropicClaude\app-1.0\claude.exe", ""), None);
        assert_eq!(agent_of(r"C:\dev\app-server\codex.exe", ""), Some(Agent::Codex), "only the apps' own folders are refused");
        assert_eq!(agent_of(r"C:\Users\a\AppData\Local\Codex\app-1.0\codex.exe", ""), None);
        assert_eq!(agent_of(r"C:\Program Files\WindowsApps\Claude_1.0_x64\app\Claude.exe", ""), None);
    }

    #[test]
    fn linux_stat_and_user_dirs_are_read() {
        let stat = "123 (my (odd) name) S 1 2 3 4 5 6 7 8 9 10 250 50 0 0 20";
        assert_eq!(stat_ticks(stat), Some(300));
        let home = Path::new("/home/u");
        assert_eq!(parse_user_dir("XDG_MUSIC_DIR=\"$HOME/M\"\nXDG_DOWNLOAD_DIR=\"$HOME/Descargas\"\n", home), Some(PathBuf::from("/home/u/Descargas")));
        assert_eq!(parse_user_dir("XDG_DOWNLOAD_DIR=\"/data/dl\"\n", home), Some(PathBuf::from("/data/dl")));
        assert_eq!(parse_user_dir("# none\n", home), None);
    }
}
