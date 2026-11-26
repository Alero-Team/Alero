//! Island's opt-in media sources. Unknown audio must not wake the overlay.

pub fn native_allowed(app: &str) -> bool {
    let a = app.to_lowercase();
    if ["whatsapp", "tiktok", "musically", "telegram", "signal", "messenger", "discord", "teams", "zoom"]
        .iter().any(|s| a.contains(s)) {
        return false;
    }
    if browser_exe(&a).is_some() {
        return false;
    }
    let id = a.trim().strip_suffix(".exe").or_else(|| a.trim().strip_suffix(".desktop")).unwrap_or(a.trim());
    ["spotify", "com.spotify.music", "tidal", "com.aspiro.tidal", "deezer", "deezer.android.app",
        "applemusic", "apple music", "com.apple.android.music", "amazonmusic", "amazon music", "com.amazon.mp3",
        "qobuz", "com.qobuz.music", "com.qobuz.app", "soundcloud", "com.soundcloud.android", "bandcamp", "com.bandcamp.android",
        "pandora", "com.pandora.android", "youtube", "youtube music", "youtubemusic", "youtube-music", "ytmusic", "ytmdesktop",
        "com.google.android.youtube", "com.google.android.apps.youtube.music", "app.revanced.android.youtube", "org.schabi.newpipe",
        "spotube", "oss.krtirtho.spotube", "twitch", "tv.twitch.android.app", "netflix", "com.netflix.mediaclient",
        "primevideo", "prime video", "com.amazon.avod.thirdpartyclient", "disneyplus", "disney+", "com.disney.disneyplus",
        "crunchyroll", "com.crunchyroll.crunchyroid"].contains(&id)
        || ["spotifyab.spotifymusic_", "appleinc.applemusic_", "deezer.deezer_", "tidalmusicas.tidal_", "amazonmobilellc.amazonmusic_"]
            .iter().any(|prefix| id.starts_with(prefix))
}

fn browser_exe(app: &str) -> Option<&'static str> {
    [("chrome", "chrome.exe"), ("msedge", "msedge.exe"), ("microsoftedge", "msedge.exe"),
        ("firefox", "firefox.exe"), ("brave", "brave.exe"), ("vivaldi", "vivaldi.exe"), ("opera", "opera.exe")]
        .into_iter().find_map(|(id, exe)| app.contains(id).then_some(exe))
}

fn allowed_url(url: &str) -> bool {
    let url = url.to_ascii_lowercase();
    let Some(rest) = url.strip_prefix("https://").or_else(|| url.strip_prefix("http://")) else { return false };
    let host = rest.split(['/', '?', '#']).next().unwrap_or("");
    if host.contains('@') { return false; }
    let host = host.split(':').next().unwrap_or("").trim_end_matches('.');
    ["spotify.com", "tidal.com", "deezer.com", "music.apple.com", "music.amazon.com", "music.amazon.es",
        "qobuz.com", "soundcloud.com", "bandcamp.com", "pandora.com", "youtube.com", "youtu.be",
        "twitch.tv", "netflix.com", "primevideo.com", "disneyplus.com", "crunchyroll.com"]
        .iter().any(|domain| host == *domain || host.ends_with(&format!(".{domain}")))
}

fn streaming_caption(caption: &str, title: &str, artist: &str) -> bool {
    let caption = caption.to_lowercase().replace(['—', '–', '|'], " - ");
    let parts: Vec<_> = caption.split(" - ").map(str::trim).collect();
    let services = ["spotify", "tidal", "deezer", "apple music", "amazon music", "qobuz", "soundcloud",
        "bandcamp", "pandora", "youtube", "youtube music", "twitch", "netflix", "prime video", "disney+", "crunchyroll"];
    let Some(site) = parts.iter().rposition(|p| services.contains(p)) else { return false };
    let content = parts[..site].join(" - ");
    // Match this session, not an unrelated YouTube window left open next to WhatsApp Web.
    [title, artist].iter().any(|s| {
        let s = s.trim().to_lowercase();
        s.chars().count() >= 3 && (content == s || content.starts_with(&format!("{s} - ")))
    })
}

pub fn approved_pc(m: &crate::sys::Media) -> bool {
    if native_allowed(&m.app) { return true; }
    let Some(exe) = browser_exe(&m.app.to_lowercase()) else { return false };
    if !m.source_url.is_empty() { return allowed_url(&m.source_url); }
    browser_window(exe, &m.title, &m.artist)
}

#[cfg(not(windows))]
fn browser_window(_exe: &str, _title: &str, _artist: &str) -> bool { false }

#[cfg(windows)]
fn browser_window(exe: &str, title: &str, artist: &str) -> bool {
    use std::collections::HashMap;
    use windows::core::{BOOL, PWSTR};
    use windows::Win32::Foundation::{CloseHandle, HWND, LPARAM};
    use windows::Win32::System::Threading::{OpenProcess, QueryFullProcessImageNameW, PROCESS_NAME_WIN32, PROCESS_QUERY_LIMITED_INFORMATION};
    use windows::Win32::UI::WindowsAndMessaging::{EnumWindows, GetWindowTextW, GetWindowThreadProcessId, IsWindowVisible};
    struct Search<'a> { exe: &'a str, title: &'a str, artist: &'a str, found: bool, pids: HashMap<u32, bool> }
    unsafe extern "system" fn visit(hwnd: HWND, arg: LPARAM) -> BOOL {
        let s = &mut *(arg.0 as *mut Search<'_>);
        if !IsWindowVisible(hwnd).as_bool() { return BOOL(1); }
        let mut caption = [0u16; 2048];
        let n = GetWindowTextW(hwnd, &mut caption) as usize;
        if n == 0 || !streaming_caption(&String::from_utf16_lossy(&caption[..n]), s.title, s.artist) {
            return BOOL(1);
        }
        let mut pid = 0;
        GetWindowThreadProcessId(hwnd, Some(&mut pid));
        let owned = *s.pids.entry(pid).or_insert_with(|| {
            let Ok(handle) = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid) else { return false };
            let mut path = [0u16; 4096];
            let mut n = path.len() as u32;
            let read = QueryFullProcessImageNameW(handle, PROCESS_NAME_WIN32, PWSTR(path.as_mut_ptr()), &mut n).is_ok();
            let _ = CloseHandle(handle);
            read && String::from_utf16_lossy(&path[..n as usize]).rsplit('\\').next().is_some_and(|p| p.eq_ignore_ascii_case(s.exe))
        });
        s.found = owned;
        BOOL((!owned) as i32)
    }
    let mut search = Search { exe, title, artist, found: false, pids: HashMap::new() };
    unsafe { let _ = EnumWindows(Some(visit), LPARAM(&mut search as *mut _ as isize)); }
    search.found
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn only_streaming_apps_are_allowed() {
        for app in ["Spotify.exe", "SpotifyAB.SpotifyMusic_123!Spotify", "com.spotify.music", "com.aspiro.tidal", "com.google.android.youtube", "tv.twitch.android.app", "YouTube Music"] {
            assert!(native_allowed(app), "{app}");
        }
        for app in ["WhatsApp.exe", "com.whatsapp", "com.whatsapp.w4b", "com.zhiliaoapp.musically", "TikTok", "Discord", "unknown", "", "chrome.exe", "msedge.exe", "firefox", "Spotify downloader", "com.example.youtube.downloader"] {
            assert!(!native_allowed(app), "{app}");
        }
    }
    #[test]
    fn web_sources_require_a_real_allowed_host() {
        for url in ["https://www.youtube.com/watch?v=1", "https://music.youtube.com/", "https://open.spotify.com/track/1", "https://www.twitch.tv/channel"] { assert!(allowed_url(url), "{url}"); }
        for url in ["https://web.whatsapp.com", "https://www.tiktok.com", "https://youtube.com.evil.test/", "https://youtube.com@evil.test/", "https://evil.test/?site=youtube.com", "file:///youtube.com", ""] { assert!(!allowed_url(url), "{url}"); }
    }
    #[test]
    fn a_browser_caption_must_match_the_playing_session() {
        assert!(streaming_caption("My song - YouTube - Google Chrome", "My song", "Channel"));
        assert!(streaming_caption("My song - Artist — Spotify — Mozilla Firefox", "My song", "Artist"));
        assert!(streaming_caption("SomeChannel - Twitch - Microsoft Edge", "Live broadcast", "SomeChannel"));
        assert!(!streaming_caption("My song - YouTube - Google Chrome", "(30) WhatsApp", ""));
        assert!(!streaming_caption("My song - TikTok - Google Chrome", "My song", ""));
        assert!(!streaming_caption("YouTube tutorial - WhatsApp - Google Chrome", "YouTube tutorial", ""));
        assert!(!streaming_caption("My song - YouTube - Google Chrome", "", "YouTube"));
    }
}
