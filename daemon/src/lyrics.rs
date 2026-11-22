//! Synced lyrics for Alero Island, from LRCLIB (lrclib.net: a free, open lyrics database; no account, no key).
//! Asked only when the user turns lyrics on, and only for music apps (see [`music_app`]): the song's title, artist
//! and length are the whole question. Fetched with the system's curl (Windows 10 and later ship `curl.exe`; Linux
//! already uses curl for covers), so the daemon carries no HTTP stack of its own.

use std::process::{Command, Stdio};

/// (time in ms, line). An empty line is a pause in the singing.
pub type Lines = Vec<(i64, String)>;

/// Apps whose lyrics the island offers: the big music services, nothing else (a video site or a local file player
/// has no lyrics worth asking for). `app` is the computer's player id or the phone's app name and package.
pub fn music_app(app: &str) -> bool {
    let a = app.to_lowercase();
    a.contains("spotify")
        || a.contains("tidal")
        || a.contains("aspiro")
        || a.contains("deezer")
        || a.contains("applemusic")
        || a.contains("apple music")
        || a.contains("com.apple.android.music")
        || a.contains("youtube music")
        || a.contains("youtubemusic")
        || a.contains("youtube-music")
        || a.contains("yt music")
        || a.contains("ytmusic")
        || a.contains("ytmdesktop")
        || a.contains("music.youtube")
        || a.contains("apps.youtube.music")
}

/// The song's synced lyrics. Some(empty) for an instrumental; None when there are none (or no network).
pub fn fetch(title: &str, artist: &str, duration_ms: i64) -> Option<Lines> {
    if title.trim().is_empty() {
        return None;
    }
    let base = format!("https://lrclib.net/api/get?track_name={}&artist_name={}", enc(title), enc(first_artist(artist)));
    // The exact match wants the length within 2 s; players round it differently, so try without it too.
    let exact = (duration_ms > 0).then(|| get(&format!("{base}&duration={}", (duration_ms + 500) / 1000))).flatten();
    if let Some(l) = exact.as_deref().and_then(from_record) {
        return Some(l);
    }
    if let Some(l) = get(&base).as_deref().and_then(from_record) {
        return Some(l);
    }
    // Last, a search: the first result with synced lyrics and a length close to the song's.
    let list = get(&format!("https://lrclib.net/api/search?track_name={}&artist_name={}", enc(title), enc(first_artist(artist))))?;
    let v: serde_json::Value = serde_json::from_str(&list).ok()?;
    v.as_array()?
        .iter()
        .filter(|r| duration_ms <= 0 || r["duration"].as_f64().is_none_or(|d| (d * 1000.0 - duration_ms as f64).abs() < 4000.0))
        .find_map(|r| record(r))
}

fn from_record(body: &str) -> Option<Lines> {
    record(&serde_json::from_str(body).ok()?)
}

fn record(v: &serde_json::Value) -> Option<Lines> {
    if v["instrumental"].as_bool() == Some(true) {
        return Some(Vec::new());
    }
    let l = parse_lrc(v["syncedLyrics"].as_str()?);
    (!l.is_empty()).then_some(l)
}

/// "A, B & C" or "A feat. B": the first name finds the song more often than all of them.
fn first_artist(a: &str) -> &str {
    let cut = [",", " & ", " feat.", " ft.", " x ", ";"].iter().filter_map(|s| a.find(s)).min().unwrap_or(a.len());
    a[..cut].trim()
}

/// LRC text to sorted lines. A line may carry several time tags (a repeated chorus); tags that are not times
/// (`[ar:...]`) are skipped.
pub fn parse_lrc(text: &str) -> Lines {
    let mut out = Vec::new();
    for raw in text.lines() {
        let mut rest = raw.trim();
        let mut times = Vec::new();
        while let Some(body) = rest.strip_prefix('[') {
            let Some(end) = body.find(']') else { break };
            if let Some(ms) = time(&body[..end]) {
                times.push(ms);
            } else if times.is_empty() {
                break;
            }
            rest = body[end + 1..].trim_start();
        }
        for t in times {
            out.push((t, rest.trim().to_string()));
        }
    }
    out.sort_by_key(|l| l.0);
    out
}

/// "mm:ss", "mm:ss.xx" or "mm:ss.xxx" to milliseconds.
fn time(s: &str) -> Option<i64> {
    let (m, rest) = s.split_once(':')?;
    let m: i64 = m.trim().parse().ok()?;
    let (sec, frac) = rest.split_once('.').unwrap_or((rest, "0"));
    let sec: i64 = sec.trim().parse().ok()?;
    if !(0..60).contains(&sec) || frac.is_empty() || !frac.chars().all(|c| c.is_ascii_digit()) {
        return None;
    }
    let ms = match frac.len() {
        1 => frac.parse::<i64>().ok()? * 100,
        2 => frac.parse::<i64>().ok()? * 10,
        _ => frac[..3].parse::<i64>().ok()?,
    };
    Some(m * 60_000 + sec * 1000 + ms)
}

/// Percent-encoding for a query value.
fn enc(s: &str) -> String {
    let mut out = String::with_capacity(s.len() * 2);
    for b in s.bytes() {
        match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => out.push(b as char),
            _ => out.push_str(&format!("%{b:02X}")),
        }
    }
    out
}

/// GET `url` with curl; the body on a 2xx answer.
fn get(url: &str) -> Option<String> {
    let mut cmd = Command::new(if cfg!(windows) { "curl.exe" } else { "curl" });
    cmd.args(["-sfL", "--max-time", "8", "--max-filesize", "400000", "-A", "Alero (https://github.com/Alero-Team/Alero)", "--", url])
        .stdin(Stdio::null())
        .stderr(Stdio::null());
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        // No console window flashing over the desktop.
        cmd.creation_flags(0x0800_0000);
    }
    let out = cmd.output().ok()?;
    out.status.success().then(|| String::from_utf8_lossy(&out.stdout).into_owned())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn lrc_lines_are_timed_sorted_and_repeated_choruses_kept() {
        let l = parse_lrc("[ar:Los Demo]\n[00:12.30]Primera\n[00:05.00]Antes\n[01:02.345][01:30.10]Coro\n[00:20.00]\nsin tiempo");
        assert_eq!(l, vec![(5000, "Antes".into()), (12300, "Primera".into()), (20000, String::new()), (62345, "Coro".into()), (90100, "Coro".into())]);
    }

    #[test]
    fn only_music_services_get_lyrics() {
        for a in ["Spotify.exe", "Spotify", "com.spotify.music", "YouTube Music", "com.google.android.apps.youtube.music", "TIDAL", "com.aspiro.tidal", "AppleInc.AppleMusicWin_nzyj5cx40ttqa!App", "deezer.android.app"] {
            assert!(music_app(a), "{a}");
        }
        for a in ["YouTube", "com.google.android.youtube", "Chrome", "VLC media player", "org.videolan.vlc", "Firefox"] {
            assert!(!music_app(a), "{a}");
        }
    }

    #[test]
    fn query_values_are_encoded_and_the_first_artist_is_used() {
        assert_eq!(enc("Atardecer en la costa & más"), "Atardecer%20en%20la%20costa%20%26%20m%C3%A1s");
        assert_eq!(first_artist("Los Demo, Ichu & Puerto Norte"), "Los Demo");
        assert_eq!(first_artist("Ichu feat. Los Demo"), "Ichu");
    }
}
