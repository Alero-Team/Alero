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
}

#[derive(Clone, Debug)]
pub struct Offer {
    pub id: String,
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
}

impl Xfer {
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
    pub playing: bool,
    pub position_ms: i64,
    pub duration_ms: i64,
    pub speed: f64,
    pub at: Option<Instant>,
    pub art: Option<Image>,
}

impl Media {
    /// Position now, extrapolated from the last report while it plays.
    pub fn position_now(&self) -> i64 {
        let extra = match (self.playing, self.at) {
            (true, Some(t)) => (t.elapsed().as_millis().min(15_000) as f64 * self.speed.max(0.0)) as i64,
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
}

#[derive(Default)]
pub struct Model {
    pub peers: Vec<PeerView>,
    pub info: HashMap<String, Info>,
    pub phone: HashMap<String, PhoneSt>,
    pub calls: HashMap<String, Call>,
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
}

fn s(v: &Value, k: &str) -> String {
    v[k].as_str().unwrap_or("").to_string()
}

fn b64(v: &Value) -> Option<Vec<u8>> {
    let t = v.as_str().filter(|t| !t.is_empty())?;
    base64::engine::general_purpose::STANDARD.decode(t).ok()
}

impl Model {
    pub fn set_peers(&mut self, peers: Vec<PeerView>) {
        self.peers = peers;
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
                match self.peers.iter_mut().find(|p| p.id == peer.id) {
                    Some(p) => *p = peer.clone(),
                    None => self.peers.push(peer.clone()),
                }
                if peer.state != PeerState::Connected {
                    self.calls.remove(&peer.id);
                }
                out.push(Notice::Peers);
            }
            Event::PeerGone { id } => {
                self.peers.retain(|p| &p.id != id);
                self.calls.remove(id);
                out.push(Notice::Peers);
            }
            Event::TransferOffer { id, peer_name, name, size, .. } => {
                self.offers.retain(|o| &o.id != id);
                self.offers.push(Offer { id: id.clone(), peer_name: peer_name.clone(), name: name.clone(), size: *size });
                out.push(Notice::Offer(id.clone()));
            }
            Event::TransferStarted { id, peer_name, name, size, incoming, .. } => {
                // The offer is answered: it is a transfer now.
                self.offers.retain(|o| &o.id != id);
                self.xfers.retain(|x| &x.id != id);
                self.xfers.insert(0, Xfer { id: id.clone(), name: name.clone(), peer_name: peer_name.clone(), incoming: *incoming, done: 0, total: *size, rate: 0, state: XState::Running, at: Instant::now() });
                self.xfers.truncate(8);
                out.push(Notice::XferStarted(id.clone()));
            }
            Event::TransferProgress { id, done, total, bytes_per_sec } => {
                if let Some(x) = self.xfers.iter_mut().find(|x| &x.id == id) {
                    x.done = *done;
                    x.total = *total;
                    x.rate = *bytes_per_sec;
                }
            }
            Event::TransferFinished { id, ok, message, .. } => {
                self.offers.retain(|o| &o.id != id);
                if let Some(x) = self.xfers.iter_mut().find(|x| &x.id == id) {
                    x.state = if *ok { XState::Done } else { XState::Failed(message.clone()) };
                    x.at = Instant::now();
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
                i.charging = b["battery"]["charging"].as_bool().unwrap_or(false);
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
                    let c = Call { ringing: b["ringing"].as_bool().unwrap_or(false), can_answer: b["canAnswer"].as_bool().unwrap_or(false), name: s(b, "name"), text: s(b, "text") };
                    let wake = was != Some(c.ringing);
                    self.calls.insert(peer.to_string(), c);
                    wake.then_some(Notice::Call)
                } else {
                    self.calls.remove(peer);
                    Some(Notice::Call)
                }
            }
            "pb.x.notif.posted" => {
                let key = s(b, "key");
                if let (pkg, Some(img)) = (s(b, "pkg"), b64(&b["icon"]).and_then(|d| decode_image(&d))) {
                    if !pkg.is_empty() {
                        self.icons.insert(pkg, img);
                    }
                }
                let n = Notif { key: key.clone(), app: s(b, "app"), pkg: s(b, "pkg"), title: s(b, "title"), text: s(b, "text"), at: Instant::now() };
                self.notifs.retain(|o| o.key != key);
                self.notifs.push_front(n);
                self.notifs.truncate(12);
                Some(Notice::Notif(key))
            }
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
                    self.phone_media = None;
                    return None;
                }
                let key = format!("{}|{}|{}", s(b, "title"), s(b, "artist"), b["art"].as_str().map_or(0, str::len));
                let art = if key == self.media_key { self.phone_media.as_ref().and_then(|m| m.art.clone()) } else { b64(&b["art"]).and_then(|d| decode_image(&d)) };
                self.media_key = key;
                self.phone_media = Some(Media {
                    title: s(b, "title"),
                    artist: s(b, "artist"),
                    app: s(b, "app"),
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
    fn phone_media_position_runs_while_it_plays() {
        let mut m = Model::default();
        m.feed(&msg("a", "pb.x.media.state", json!({"active":true,"playing":true,"title":"T","artist":"A","position":1000,"duration":60000,"speed":1.0})));
        let md = m.phone_media.as_ref().unwrap();
        assert!(md.position_now() >= 1000 && md.position_now() < 2000);
        m.feed(&msg("a", "pb.x.media.state", json!({"active":false})));
        assert!(m.phone_media.is_none());
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
