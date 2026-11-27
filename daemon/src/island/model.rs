//! What the island knows about the connected devices. It is fed with the engine's events (`Event`) and holds just
//! what the screens need: no I/O and no drawing, so it can be tested on its own.

use std::collections::{HashMap, VecDeque};
use std::time::{Duration, Instant};

use base64::Engine as _;
use pb_core::engine::{Event, PeerState, PeerView};
use serde_json::Value;

use super::gfx::{decode_image, Image};

#[derive(Clone, Debug, Default)]
pub struct Info {
    pub phone: bool,
    pub battery: i32,
    pub charging: bool,
}

#[derive(Clone, Debug, Default)]
pub struct PhoneSt {
    pub dnd: bool,
    pub torch: bool,
    pub finding: bool,
    pub ringer: String,
    pub media: i32,
    pub media_max: i32,
}

#[allow(dead_code)]
#[derive(Clone, Debug, Default)]
pub struct Call {
    pub ringing: bool,
    pub can_answer: bool,
    pub name: String,
    pub text: String,
    /// The phone's microphone is muted.
    pub muted: bool,
    /// When it was answered (the compact island's timer); None while it rings.
    pub since: Option<Instant>,
}

#[derive(Clone, Debug)]
pub struct Offer {
    pub id: String,
    pub peer_id: String,
    pub peer_name: String,
    pub name: String,
    pub size: u64,
}

#[derive(Clone, Debug, PartialEq)]
pub enum XState {
    Running,
    Done,
    Failed(String),
}

#[allow(dead_code)]
#[derive(Clone, Debug)]
pub struct Xfer {
    pub id: String,
    pub name: String,
    pub peer_name: String,
    pub incoming: bool,
    pub done: u64,
    pub total: u64,
    pub rate: u64,
    pub state: XState,
    pub at: Instant,
    /// Where a received file was saved, once it is done.
    pub path: Option<std::path::PathBuf>,
    /// A saved file's preview (decoded off the drawing thread, see `run.rs`).
    pub thumb: Option<Image>,
}

impl Xfer {
    /// A received file, saved: the island asks what to do with it.
    pub fn saved(&self) -> Option<&std::path::Path> {
        self.path.as_deref().filter(|_| self.incoming && self.state == XState::Done)
    }

    /// The saved file's extension, lowercase ("" when it has none).
    pub fn ext(&self) -> String {
        self.saved().and_then(|p| p.extension()).and_then(|e| e.to_str()).unwrap_or("").to_ascii_lowercase()
    }
}

impl Xfer {
    /// A download of this computer (see `pc`), not a transfer with a phone.
    pub fn local(&self) -> bool {
        self.id.starts_with(super::pc::PC_ID)
    }

    /// Its size is not known (a browser's partial file): the bar cannot say how far it is.
    pub fn no_total(&self) -> bool {
        self.local() && self.state == XState::Running && self.total == 0
    }

    pub fn fraction(&self) -> f32 {
        if self.state == XState::Done {
            1.0
        } else if self.total == 0 {
            0.0
        } else {
            (self.done as f64 / self.total as f64).clamp(0.0, 1.0) as f32
        }
    }
}

#[derive(Clone)]
pub struct Notif {
    pub key: String,
    pub app: String,
    pub pkg: String,
    pub title: String,
    pub text: String,
    pub at: Instant,
    /// The phone can answer it in place (a chat with a reply action).
    pub replyable: bool,
    /// The app has a "mark as read" action.
    pub markable: bool,
    /// The sender's picture (the chat's contact photo), when the app gives one.
    pub avatar: Option<Image>,
}

#[derive(Clone, Debug)]
pub struct Clip {
    pub text: String,
    pub from: String,
}

/// What a media player reports. The computer's own player and the phone's use the same shape.
#[allow(dead_code)]
#[derive(Clone, Default)]
pub struct Media {
    pub title: String,
    pub artist: String,
    pub app: String,
    /// The phone's package (the computer's player id is in `app`).
    pub pkg: String,
    /// The PC media worker verified this source, including the browser when applicable.
    pub approved_source: bool,
    pub playing: bool,
    pub position_ms: i64,
    pub duration_ms: i64,
    pub speed: f64,
    pub at: Option<Instant>,
    pub art: Option<Image>,
    /// Icon of the app that plays (Spotify, YouTube, the browser).
    pub icon: Option<Image>,
}

impl Media {
    pub fn island_allowed(&self) -> bool {
        !self.is_empty() && (self.approved_source || super::media::native_allowed(if self.pkg.is_empty() { &self.app } else { &self.pkg }))
    }

    /// Position now, extrapolated from the last report while it plays (reports come only on change: no cap on its age).
    pub fn position_now(&self) -> i64 {
        let extra = match (self.playing, self.at) {
            (true, Some(t)) => (t.elapsed().as_millis() as f64 * self.speed.max(0.0)) as i64,
            _ => 0,
        };
        let p = self.position_ms + extra;
        if self.duration_ms > 0 {
            p.clamp(0, self.duration_ms)
        } else {
            p.max(0)
        }
    }

    pub fn is_empty(&self) -> bool {
        self.title.is_empty() && self.artist.is_empty()
    }
}

/// Something worth waking the island for.
#[derive(Clone, Debug, PartialEq)]
pub enum Notice {
    Call,
    Offer(String),
    XferStarted(String),
    XferDone(String, bool),
    Notif(String),
    Clip,
    /// The phone appeared or disappeared: the screens must pick another target.
    Peers,
    /// The phone answered a reply sent from the island: sent or not.
    Replied(bool),
    /// A paired device connected (true) or disconnected: (peer id, name, up). Debounced by `link`.
    Link(String, String, bool),
}

#[derive(Default)]
pub struct Model {
    pub peers: Vec<PeerView>,
    /// Picture of each phone, by peer id (the app finds them; see `load_devices`).
    pub devices: HashMap<String, Image>,
    /// Phones reachable by adb now, with their radios (the island's extra controls).
    pub adb: HashMap<String, super::adb::Radios>,
    /// A phone was just plugged in (taken by the island to show the charging activity).
    pub charging_started: bool,
    pub info: HashMap<String, Info>,
    pub phone: HashMap<String, PhoneSt>,
    pub calls: HashMap<String, Call>,
    /// The call that just ended (taken by the island to say how long it lasted).
    pub ended: Option<Call>,
    pub offers: Vec<Offer>,
    pub xfers: Vec<Xfer>,
    pub notifs: VecDeque<Notif>,
    pub clips: VecDeque<Clip>,
    pub phone_media: Option<Media>,
    pub pc_media: Option<Media>,
    /// The phone the buttons talk to (the one the user picked, else the first one connected).
    pub chosen: Option<String>,
    icons: HashMap<String, Image>,
    media_key: String,
    /// The peer that reported `phone_media`.
    media_peer: Option<String>,
}

/// `island-devices.json` (written by the app): `{"peer id": "path of its picture"}`. Pictures that cannot be read or
/// are not PNG/JPEG are left out (the island then draws its generic phone).
pub fn load_devices(json: &str) -> HashMap<String, Image> {
    let Ok(Value::Object(map)) = serde_json::from_str::<Value>(json) else { return HashMap::new() };
    map.iter()
        .filter_map(|(id, p)| {
            let bytes = std::fs::read(p.as_str()?).ok()?;
            Some((id.clone(), decode_image(&bytes)?))
        })
        .collect()
}

/// A paired device that is connected: the only kind the connect / disconnect alerts are about.
fn linked(p: &PeerView) -> bool {
    p.trusted && p.state == PeerState::Connected
}

/// Dialers and chats wrap names in bidi isolates (U+2066..2069) and marks: invisible, but the fonts draw them as boxes.
fn s(v: &Value, k: &str) -> String {
    v[k].as_str().unwrap_or("").chars().filter(|c| !matches!(c, '\u{200E}' | '\u{200F}' | '\u{202A}'..='\u{202E}' | '\u{2066}'..='\u{2069}')).collect()
}

fn b64(v: &Value) -> Option<Vec<u8>> {
    let t = v.as_str().filter(|t| !t.is_empty())?;
    base64::engine::general_purpose::STANDARD.decode(t).ok()
}

impl Model {
    pub fn set_peers(&mut self, peers: Vec<PeerView>) {
        self.peers = peers;
    }

    /// Drops what only made sense while the peer was there.
    fn forget(&mut self, id: &str) {
        self.calls.remove(id);
        self.offers.retain(|o| o.peer_id != id);
        if self.media_peer.as_deref() == Some(id) {
            self.phone_media = None;
            self.media_key.clear();
            self.media_peer = None;
        }
    }

    /// Paired phones that are connected now.
    pub fn phones(&self) -> Vec<&PeerView> {
        self.peers.iter().filter(|p| p.trusted && p.state == PeerState::Connected && self.info.get(&p.id).is_some_and(|i| i.phone)).collect()
    }

    /// The phone the island acts on.
    pub fn target(&self) -> Option<&PeerView> {
        let phones = self.phones();
        self.chosen.as_ref().and_then(|c| phones.iter().find(|p| &p.id == c).copied()).or_else(|| phones.first().copied())
    }

    pub fn target_id(&self) -> Option<String> {
        self.target().map(|p| p.id.clone())
    }

    /// Moves to the next connected phone (when there are several).
    pub fn cycle_target(&mut self) {
        let ids: Vec<String> = self.phones().iter().map(|p| p.id.clone()).collect();
        if ids.len() < 2 {
            return;
        }
        let cur = self.target_id().and_then(|t| ids.iter().position(|i| *i == t)).unwrap_or(0);
        self.chosen = Some(ids[(cur + 1) % ids.len()].clone());
    }

    pub fn icon(&self, pkg: &str) -> Option<&Image> {
        self.icons.get(pkg)
    }

    pub fn call(&self) -> Option<(&String, &Call)> {
        self.calls.iter().next()
    }

    #[allow(dead_code)]
    pub fn running(&self) -> impl Iterator<Item = &Xfer> {
        self.xfers.iter().filter(|x| x.state == XState::Running)
    }

    /// Updates the state from one engine event. The returned notices say what the user should be shown.
    pub fn feed(&mut self, e: &Event) -> Vec<Notice> {
        let mut out = Vec::new();
        match e {
            Event::PeerChanged { peer } => {
                let was = self.peers.iter().any(|p| p.id == peer.id && linked(p));
                match self.peers.iter_mut().find(|p| p.id == peer.id) {
                    Some(p) => *p = peer.clone(),
                    None => self.peers.push(peer.clone()),
                }
                if peer.state != PeerState::Connected {
                    self.forget(&peer.id);
                }
                out.push(Notice::Peers);
                if was != linked(peer) {
                    out.push(Notice::Link(peer.id.clone(), peer.name.clone(), !was));
                }
            }
            Event::PeerGone { id } => {
                let gone = self.peers.iter().find(|p| &p.id == id && linked(p)).map(|p| p.name.clone());
                self.peers.retain(|p| &p.id != id);
                self.forget(id);
                out.push(Notice::Peers);
                if let Some(name) = gone {
                    out.push(Notice::Link(id.clone(), name, false));
                }
            }
            Event::TransferOffer { id, peer_id, peer_name, name, size } => {
                self.offers.retain(|o| &o.id != id);
                self.offers.push(Offer { id: id.clone(), peer_id: peer_id.clone(), peer_name: peer_name.clone(), name: name.clone(), size: *size });
                if self.offers.len() > 16 {
                    self.offers.remove(0);
                }
                out.push(Notice::Offer(id.clone()));
            }
            Event::TransferStarted { id, peer_name, name, size, incoming, .. } => {
                // The offer is answered: it is a transfer now.
                self.offers.retain(|o| &o.id != id);
                self.xfers.retain(|x| &x.id != id);
                self.xfers.insert(0, Xfer { id: id.clone(), name: name.clone(), peer_name: peer_name.clone(), incoming: *incoming, done: 0, total: *size, rate: 0, state: XState::Running, at: Instant::now(), path: None, thumb: None });
                // A burst of downloads of this computer never pushes out a running phone transfer.
                while self.xfers.len() > 8 {
                    let at = self.xfers.iter().rposition(|x| x.state != XState::Running || x.local()).unwrap_or(self.xfers.len() - 1);
                    self.xfers.remove(at);
                }
                if self.xfers.iter().any(|x| &x.id == id) {
                    out.push(Notice::XferStarted(id.clone()));
                }
            }
            Event::TransferProgress { id, done, total, bytes_per_sec } => {
                if let Some(x) = self.xfers.iter_mut().find(|x| &x.id == id) {
                    x.done = *done;
                    x.total = *total;
                    x.rate = *bytes_per_sec;
                }
            }
            Event::TransferFinished { id, ok, message, path, .. } => {
                self.offers.retain(|o| &o.id != id);
                if let Some(x) = self.xfers.iter_mut().find(|x| &x.id == id) {
                    x.state = if *ok { XState::Done } else { XState::Failed(message.clone()) };
                    x.at = Instant::now();
                    x.path = (*ok && !path.is_empty()).then(|| path.into());
                    // A browser names its file at the end ("Unconfirmed 123.crdownload"): the card shows the real name.
                    if let (true, Some(n)) = (x.local(), x.path.as_ref().and_then(|p| p.file_name())) {
                        x.name = n.to_string_lossy().into_owned();
                    }
                    out.push(Notice::XferDone(id.clone(), *ok));
                }
            }
            Event::Message { peer_id, kind, body } => out.extend(self.message(peer_id, kind, body)),
            _ => {}
        }
        out
    }

    fn message(&mut self, peer: &str, kind: &str, b: &Value) -> Option<Notice> {
        match kind {
            "pb.x.info" => {
                let i = self.info.entry(peer.to_string()).or_default();
                i.phone = b["kind"] == "phone";
                i.battery = b["battery"]["level"].as_i64().map_or(-1, |v| v as i32);
                let was = i.charging;
                i.charging = b["battery"]["charging"].as_bool().unwrap_or(false);
                if i.phone && i.charging && !was {
                    self.charging_started = true;
                }
                Some(Notice::Peers)
            }
            "pb.x.phone.state" => {
                let p = self.phone.entry(peer.to_string()).or_default();
                p.dnd = b["dnd"].as_bool().unwrap_or(false);
                p.torch = b["torch"].as_bool().unwrap_or(false);
                p.finding = b["finding"].as_bool().unwrap_or(false);
                p.ringer = b["ringer"].as_str().unwrap_or("normal").to_string();
                p.media = b["media"].as_i64().unwrap_or(0) as i32;
                p.media_max = b["mediaMax"].as_i64().unwrap_or(15).max(1) as i32;
                None
            }
            "pb.x.call" => {
                if b["active"].as_bool() == Some(true) {
                    let was = self.calls.get(peer).map(|c| c.ringing);
                    let ringing = b["ringing"].as_bool().unwrap_or(false);
                    let since = if ringing { None } else { self.calls.get(peer).and_then(|c| c.since).or(Some(Instant::now())) };
                    let c = Call { ringing, can_answer: b["canAnswer"].as_bool().unwrap_or(false), name: s(b, "name"), text: s(b, "text"), muted: b["muted"].as_bool().unwrap_or(false), since };
                    let wake = was != Some(c.ringing);
                    self.calls.insert(peer.to_string(), c);
                    wake.then_some(Notice::Call)
                } else {
                    // The snapshot a phone sends on connecting says "no call": that is not a call ending.
                    self.ended = self.calls.remove(peer);
                    self.ended.is_some().then_some(Notice::Call)
                }
            }
            "pb.x.notif.posted" => {
                let key = s(b, "key");
                let pkg = s(b, "pkg");
                if !pkg.is_empty() && !self.icons.contains_key(&pkg) {
                    if let Some(img) = b64(&b["icon"]).and_then(|d| decode_image(&d)) {
                        if self.icons.len() >= 64 {
                            self.icons.clear();
                        }
                        self.icons.insert(pkg, img);
                    }
                }
                let n = Notif {
                    key: key.clone(),
                    app: s(b, "app"),
                    pkg: s(b, "pkg"),
                    title: s(b, "title"),
                    text: s(b, "text"),
                    at: Instant::now(),
                    replyable: b["replyable"].as_bool().unwrap_or(false),
                    markable: b["markable"].as_bool().unwrap_or(false),
                    avatar: b64(&b["avatar"]).and_then(|d| decode_image(&d)),
                };
                // A reply (from the app or the phone) re-posts the chat with your own message last, and some apps
                // re-post unchanged: neither is news, so the list updates but the island does not pop.
                let own = b["messages"].as_array().and_then(|m| m.last()).is_some_and(|m| m["out"].as_bool() == Some(true));
                let same = self.notifs.iter().any(|o| o.key == key && o.title == n.title && o.text == n.text);
                self.notifs.retain(|o| o.key != key);
                self.notifs.push_front(n);
                self.notifs.truncate(12);
                (!own && !same).then_some(Notice::Notif(key))
            }
            // The phone's answer to a reply sent from the island.
            "pb.x.notif.reply.result" => Some(Notice::Replied(b["ok"].as_bool().unwrap_or(false))),
            "pb.x.notif.removed" => {
                let key = s(b, "key");
                self.notifs.retain(|o| o.key != key);
                None
            }
            "pb.x.clip" => {
                let text = s(b, "text");
                if text.is_empty() {
                    return None;
                }
                let from = self.peers.iter().find(|p| p.id == peer).map(|p| p.name.clone()).unwrap_or_default();
                self.clips.push_front(Clip { text, from });
                self.clips.truncate(8);
                Some(Notice::Clip)
            }
            "pb.x.media.state" => {
                if b["active"].as_bool() != Some(true) {
                    // Only the peer that owns the media can end it; the cover must not outlive it.
                    if self.media_peer.as_deref().is_none_or(|p| p == peer) {
                        self.phone_media = None;
                        self.media_key.clear();
                        self.media_peer = None;
                    }
                    return None;
                }
                self.media_peer = Some(peer.to_string());
                let key = format!("{}|{}|{}", s(b, "title"), s(b, "artist"), b["art"].as_str().map_or(0, str::len));
                let art = if key == self.media_key { self.phone_media.as_ref().and_then(|m| m.art.clone()) } else { b64(&b["art"]).and_then(|d| decode_image(&d)) };
                self.media_key = key;
                let pkg = s(b, "pkg");
                if !pkg.is_empty() && !self.icons.contains_key(&pkg) {
                    if let Some(img) = b64(&b["icon"]).and_then(|d| decode_image(&d)) {
                        if self.icons.len() >= 64 {
                            self.icons.clear();
                        }
                        self.icons.insert(pkg.clone(), img);
                    }
                }
                self.phone_media = Some(Media {
                    icon: self.icons.get(&pkg).cloned(),
                    title: s(b, "title"),
                    artist: s(b, "artist"),
                    app: s(b, "app"),
                    pkg: pkg.clone(),
                    approved_source: false,
                    playing: b["playing"].as_bool().unwrap_or(false),
                    position_ms: b["position"].as_i64().unwrap_or(0),
                    duration_ms: b["duration"].as_i64().unwrap_or(0),
                    speed: b["speed"].as_f64().unwrap_or(1.0),
                    at: Some(Instant::now()),
                    art,
                });
                None
            }
            _ => None,
        }
    }

    /// Drops finished transfers and old notifications so the lists never grow without bound.
    pub fn tidy(&mut self, now: Instant) {
        self.xfers.retain(|x| x.state == XState::Running || now.duration_since(x.at) < Duration::from_secs(600));
        self.notifs.retain(|n| now.duration_since(n.at) < Duration::from_secs(3600));
    }

    /// How many notifications arrived since `since`.
    pub fn unread(&self, since: Instant) -> usize {
        self.notifs.iter().filter(|n| n.at > since).count()
    }

    pub fn dismiss_notif(&mut self, key: &str) {
        self.notifs.retain(|n| n.key != key);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn peer(id: &str, connected: bool) -> PeerView {
        PeerView { id: id.into(), name: format!("Phone {id}"), addr: String::new(), state: if connected { PeerState::Connected } else { PeerState::Disconnected }, trusted: true, detail: String::new() }
    }

    fn msg(peer: &str, kind: &str, body: Value) -> Event {
        Event::Message { peer_id: peer.into(), kind: kind.into(), body }
    }

    #[test]
    fn target_is_the_first_connected_phone_until_one_is_chosen() {
        let mut m = Model::default();
        m.feed(&Event::PeerChanged { peer: peer("a", true) });
        m.feed(&Event::PeerChanged { peer: peer("b", true) });
        assert!(m.target().is_none(), "not a phone until it says so");
        m.feed(&msg("a", "pb.x.info", json!({"kind":"phone","battery":{"level":80,"charging":true}})));
        m.feed(&msg("b", "pb.x.info", json!({"kind":"phone","battery":{"level":20}})));
        assert_eq!(m.target_id().as_deref(), Some("a"));
        m.cycle_target();
        assert_eq!(m.target_id().as_deref(), Some("b"));
        m.feed(&Event::PeerChanged { peer: peer("b", false) });
        assert_eq!(m.target_id().as_deref(), Some("a"), "a disconnected phone cannot be the target");
        assert_eq!(m.info["a"].battery, 80);
        assert!(m.info["a"].charging);
    }

    #[test]
    fn calls_wake_the_island_when_they_start_change_or_end() {
        let mut m = Model::default();
        assert_eq!(m.feed(&msg("a", "pb.x.call", json!({"active":true,"ringing":true,"canAnswer":true,"name":"Mamá"}))), vec![Notice::Call]);
        assert!(m.call().unwrap().1.ringing);
        // The same state again is not news.
        assert!(m.feed(&msg("a", "pb.x.call", json!({"active":true,"ringing":true,"name":"Mamá"}))).is_empty());
        assert_eq!(m.feed(&msg("a", "pb.x.call", json!({"active":true,"ringing":false,"name":"Mamá"}))), vec![Notice::Call]);
        assert_eq!(m.feed(&msg("a", "pb.x.call", json!({"active":false}))), vec![Notice::Call]);
        assert!(m.call().is_none());
    }

    #[test]
    fn a_transfer_goes_from_offer_to_progress_to_done() {
        let mut m = Model::default();
        m.feed(&Event::TransferOffer { id: "t".into(), peer_id: "a".into(), peer_name: "Pixel".into(), name: "foto.jpg".into(), size: 4_000_000 });
        assert_eq!(m.offers.len(), 1);
        m.feed(&Event::TransferStarted { id: "t".into(), peer_id: "a".into(), peer_name: "Pixel".into(), name: "foto.jpg".into(), size: 4_000_000, incoming: true });
        assert!(m.offers.is_empty());
        m.feed(&Event::TransferProgress { id: "t".into(), done: 1_000_000, total: 4_000_000, bytes_per_sec: 2_000_000 });
        assert!((m.xfers[0].fraction() - 0.25).abs() < 1e-6);
        let n = m.feed(&Event::TransferFinished { id: "t".into(), ok: true, code: String::new(), message: String::new(), path: "x".into() });
        assert_eq!(n, vec![Notice::XferDone("t".into(), true)]);
        assert_eq!(m.xfers[0].fraction(), 1.0);
        assert_eq!(m.running().count(), 0);
    }

    #[test]
    fn a_download_of_this_computer_has_no_size_and_takes_the_real_name_at_the_end() {
        let mut m = Model::default();
        m.feed(&Event::TransferStarted { id: "pc:/dl/Unconfirmed 1.crdownload".into(), peer_id: String::new(), peer_name: String::new(), name: "Descarga".into(), size: 0, incoming: true });
        assert!(m.xfers[0].local() && m.xfers[0].no_total());
        m.feed(&Event::TransferFinished { id: "pc:/dl/Unconfirmed 1.crdownload".into(), ok: true, code: String::new(), message: String::new(), path: "/dl/foto.png".into() });
        assert_eq!(m.xfers[0].name, "foto.png");
        assert!(!m.xfers[0].no_total());
    }

    #[test]
    fn a_burst_of_downloads_never_evicts_a_running_phone_transfer() {
        let mut m = Model::default();
        m.feed(&Event::TransferStarted { id: "t".into(), peer_id: "a".into(), peer_name: "Pixel".into(), name: "x".into(), size: 9, incoming: true });
        for i in 0..12 {
            m.feed(&Event::TransferStarted { id: format!("pc:/dl/{i}.part"), peer_id: String::new(), peer_name: String::new(), name: "d".into(), size: 0, incoming: true });
        }
        assert_eq!(m.xfers.len(), 8);
        assert!(m.xfers.iter().any(|x| x.id == "t"));
    }

    #[test]
    fn phone_media_carries_its_app_icon() {
        const PNG: &str = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==";
        let mut m = Model::default();
        m.feed(&msg("a", "pb.x.media.state", json!({"active":true,"playing":true,"title":"T","pkg":"com.spotify.music","icon":PNG})));
        assert!(m.phone_media.as_ref().unwrap().icon.is_some());
        // Later states of the same app keep it without decoding again.
        m.feed(&msg("a", "pb.x.media.state", json!({"active":true,"playing":false,"title":"T","pkg":"com.spotify.music"})));
        assert!(m.phone_media.as_ref().unwrap().icon.is_some());
        m.feed(&msg("a", "pb.x.media.state", json!({"active":true,"playing":true,"title":"U","pkg":"other"})));
        assert!(m.phone_media.as_ref().unwrap().icon.is_none());
    }

    #[test]
    fn notifications_replace_by_key_and_are_bounded() {
        let mut m = Model::default();
        for i in 0..20 {
            m.feed(&msg("a", "pb.x.notif.posted", json!({"key": format!("k{i}"), "app":"WhatsApp","title":"Ana","text":"hola"})));
        }
        assert_eq!(m.notifs.len(), 12);
        m.feed(&msg("a", "pb.x.notif.posted", json!({"key":"k19","app":"WhatsApp","title":"Ana","text":"otra vez"})));
        assert_eq!(m.notifs.len(), 12);
        assert_eq!(m.notifs[0].text, "otra vez");
        m.feed(&msg("a", "pb.x.notif.removed", json!({"key":"k19"})));
        assert_eq!(m.notifs.len(), 11);
    }

    #[test]
    fn only_real_transitions_of_paired_devices_make_a_link_notice() {
        let link = |n: Vec<Notice>| n.into_iter().filter(|n| matches!(n, Notice::Link(..))).collect::<Vec<_>>();
        let mut m = Model::default();
        m.set_peers(vec![peer("a", true)]);
        // Already connected when the island started, and a refresh of the same state: nothing.
        assert!(link(m.feed(&Event::PeerChanged { peer: peer("a", true) })).is_empty());
        assert_eq!(link(m.feed(&Event::PeerChanged { peer: peer("a", false) })), vec![Notice::Link("a".into(), "Phone a".into(), false)]);
        assert!(link(m.feed(&Event::PeerChanged { peer: peer("a", false) })).is_empty());
        assert_eq!(link(m.feed(&Event::PeerChanged { peer: peer("a", true) })), vec![Notice::Link("a".into(), "Phone a".into(), true)]);
        // A device never seen before that connects.
        assert_eq!(link(m.feed(&Event::PeerChanged { peer: peer("b", true) })).len(), 1);
        // Not paired: not announced. Disappearing while connected is a disconnection.
        let stranger = PeerView { trusted: false, ..peer("c", true) };
        assert!(link(m.feed(&Event::PeerChanged { peer: stranger })).is_empty());
        assert_eq!(link(m.feed(&Event::PeerGone { id: "b".into() })), vec![Notice::Link("b".into(), "Phone b".into(), false)]);
        assert!(link(m.feed(&Event::PeerGone { id: "c".into() })).is_empty());
    }

    #[test]
    fn position_keeps_running_long_after_the_report() {
        let at = Instant::now() - Duration::from_secs(60);
        let md = Media { playing: true, position_ms: 1000, duration_ms: 200_000, speed: 1.0, at: Some(at), ..Default::default() };
        assert!((60_900..62_500).contains(&md.position_now()));
        let paused = Media { playing: false, ..md.clone() };
        assert_eq!(paused.position_now(), 1000);
        let end = Media { position_ms: 199_000, ..md };
        assert_eq!(end.position_now(), 200_000);
    }

    #[test]
    fn phone_media_position_runs_while_it_plays() {
        let mut m = Model::default();
        m.feed(&msg("a", "pb.x.media.state", json!({"active":true,"playing":true,"title":"T","artist":"A","position":1000,"duration":60000,"speed":1.0})));
        let md = m.phone_media.as_ref().unwrap();
        assert!(md.position_now() >= 1000 && md.position_now() < 2000);
        m.feed(&msg("a", "pb.x.media.state", json!({"active":false})));
        assert!(m.phone_media.is_none());
    }

    #[test]
    fn a_peer_that_goes_takes_its_offers_and_media_with_it() {
        let mut m = Model::default();
        m.feed(&Event::PeerChanged { peer: peer("a", true) });
        m.feed(&Event::TransferOffer { id: "t".into(), peer_id: "a".into(), peer_name: "Phone a".into(), name: "x".into(), size: 1 });
        m.feed(&msg("a", "pb.x.media.state", json!({"active":true,"title":"T"})));
        // Another peer cannot end the media of the first one.
        m.feed(&msg("b", "pb.x.media.state", json!({"active":false})));
        assert!(m.phone_media.is_some());
        m.feed(&Event::PeerChanged { peer: peer("a", false) });
        assert!(m.offers.is_empty() && m.phone_media.is_none());
        m.feed(&msg("a", "pb.x.media.state", json!({"active":true,"title":"T"})));
        m.feed(&Event::PeerGone { id: "a".into() });
        assert!(m.phone_media.is_none());
    }

    #[test]
    fn own_replies_and_unchanged_reposts_do_not_pop() {
        let mut m = Model::default();
        let n = |out: bool| json!({"key":"k","app":"Chat","title":"Ana","text":"hola","messages":[{"text":"hola","out":out}]});
        assert!(m.feed(&msg("a", "pb.x.notif.posted", n(false))).iter().any(|x| matches!(x, Notice::Notif(_))));
        assert!(m.feed(&msg("a", "pb.x.notif.posted", n(false))).is_empty());
        let mut r = n(true);
        r["text"] = json!("ok");
        assert!(m.feed(&msg("a", "pb.x.notif.posted", r)).is_empty());
        assert_eq!(m.notifs[0].text, "ok");
    }

    #[test]
    fn a_chat_notification_carries_the_senders_photo() {
        const PNG: &str = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==";
        let mut m = Model::default();
        m.feed(&msg("a", "pb.x.notif.posted", json!({"key":"k","app":"WhatsApp","title":"\u{2068}Ana\u{2069}","text":"hola","avatar":PNG})));
        assert!(m.notifs[0].avatar.is_some());
        assert_eq!(m.notifs[0].title, "Ana");
        m.feed(&msg("a", "pb.x.notif.posted", json!({"key":"j","app":"Gmail","title":"B","text":"c","avatar":""})));
        assert!(m.notifs[0].avatar.is_none());
    }

    #[test]
    fn clipboard_history_is_kept_newest_first() {
        let mut m = Model::default();
        m.feed(&Event::PeerChanged { peer: peer("a", true) });
        m.feed(&msg("a", "pb.x.clip", json!({"text":"uno"})));
        m.feed(&msg("a", "pb.x.clip", json!({"text":"dos"})));
        m.feed(&msg("a", "pb.x.clip", json!({"text":""})));
        assert_eq!(m.clips.len(), 2);
        assert_eq!(m.clips[0].text, "dos");
        assert_eq!(m.clips[0].from, "Phone a");
    }
}
