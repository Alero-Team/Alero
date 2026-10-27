//! Two real engines on loopback exercise pairing, reconnection, revocation, transfers and cancel (G4 criteria).

use std::net::TcpStream;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use std::time::{Duration, Instant};

use pb_core::engine::{sas_code, Config, Engine, Event, EventSink, PeerState};
use pb_core::frame::{read_frame, write_frame};
use pb_core::identity::Identity;
use pb_core::tls::{client_config, Verifier};
use rustls::pki_types::ServerName;
use rustls::{ClientConnection, StreamOwned};
use serde_json::json;

#[derive(Default)]
struct Sink {
    ev: Mutex<Vec<Event>>,
    cv: Condvar,
}

impl EventSink for Sink {
    fn on_event(&self, e: Event) {
        self.ev.lock().unwrap().push(e);
        self.cv.notify_all();
    }
}

impl Sink {
    /// First event (past or future) for which `f` returns Some, within `secs`.
    fn wait<T>(&self, secs: u64, f: impl FnMut(&Event) -> Option<T>) -> T {
        self.wait_after(0, secs, f)
    }

    fn mark(&self) -> usize {
        self.ev.lock().unwrap().len()
    }

    /// Like `wait` but only looks at events after position `from` (see `mark`).
    fn wait_after<T>(&self, from: usize, secs: u64, mut f: impl FnMut(&Event) -> Option<T>) -> T {
        let end = Instant::now() + Duration::from_secs(secs);
        let mut g = self.ev.lock().unwrap();
        loop {
            if let Some(v) = g.iter().skip(from).find_map(&mut f) {
                return v;
            }
            let left = end.checked_duration_since(Instant::now()).unwrap_or_else(|| panic!("timeout waiting for event; got {:#?}", *g));
            g = self.cv.wait_timeout(g, left).unwrap().0;
        }
    }
}

static N: AtomicU32 = AtomicU32::new(0);

struct Node {
    e: Engine,
    s: Arc<Sink>,
    dl: PathBuf,
    data: PathBuf,
}

fn tmp(label: &str) -> PathBuf {
    let d = std::env::temp_dir().join(format!("pb-eng-{}-{}-{label}", std::process::id(), N.fetch_add(1, Ordering::Relaxed)));
    let _ = std::fs::remove_dir_all(&d);
    std::fs::create_dir_all(&d).unwrap();
    d
}

fn node_at(name: &str, auto: bool, data: PathBuf, dl: PathBuf, port: u16) -> Node {
    let s = Arc::new(Sink::default());
    let e = Engine::start(Config { data_dir: data.clone(), download_dir: dl.clone(), name: name.into(), port, discovery_port: 0, auto_accept: auto }, s.clone()).unwrap();
    Node { e, s, dl, data }
}

fn node(name: &str, auto: bool) -> Node {
    node_at(name, auto, tmp(&format!("{name}-data")), tmp(&format!("{name}-dl")), 0)
}

fn pair(a: &Node, b: &Node) {
    a.e.pair_with_addr(&format!("127.0.0.1:{}", b.e.port())).unwrap();
    let cb = b.s.wait(10, |e| match e { Event::PairRequest { code, incoming: true, .. } => Some(code.clone()), _ => None });
    let (pa, ca) = a.s.wait(10, |e| match e { Event::PairRequest { peer_id, code, incoming: false, .. } => Some((peer_id.clone(), code.clone())), _ => None });
    assert_eq!(ca, cb, "both users must see the same code");
    assert_eq!(pa, b.e.device_id());
    a.e.respond_pair(&b.e.device_id(), true);
    b.e.respond_pair(&a.e.device_id(), true);
    for n in [a, b] {
        n.s.wait(10, |e| match e { Event::PairFinished { ok: true, .. } => Some(()), _ => None });
    }
}

fn connected(n: &Node, other: &Node) {
    let id = other.e.device_id();
    n.s.wait(25, |e| match e { Event::PeerChanged { peer } if peer.id == id && peer.state == PeerState::Connected => Some(()), _ => None });
}

fn write_file(dir: &PathBuf, name: &str, len: usize) -> PathBuf {
    let p = dir.join(name);
    let data: Vec<u8> = (0..len).map(|i| (i.wrapping_mul(31) ^ (i >> 7)) as u8).collect();
    std::fs::write(&p, data).unwrap();
    p
}

#[test]
fn sas_depends_on_session_and_is_symmetric() {
    let (a, b) = ("a".repeat(64), "b".repeat(64));
    assert_eq!(sas_code(&[1; 32], &a, &b), sas_code(&[1; 32], &b, &a));
    assert_ne!(sas_code(&[1; 32], &a, &b), sas_code(&[2; 32], &a, &b), "a MITM has a different TLS session, so a different code");
    assert_eq!(sas_code(&[1; 32], &a, &b).len(), 6);
}

#[test]
fn pairing_then_control_connection() {
    let (a, b) = (node("alice", true), node("bob", true));
    pair(&a, &b);
    assert!(a.e.peers().iter().any(|p| p.id == b.e.device_id() && p.trusted));
    connected(&a, &b);
    connected(&b, &a);
}

#[test]
fn declined_pairing_trusts_nobody() {
    let (a, b) = (node("alice", true), node("bob", true));
    a.e.pair_with_addr(&format!("127.0.0.1:{}", b.e.port())).unwrap();
    b.s.wait(10, |e| matches!(e, Event::PairRequest { .. }).then_some(()));
    a.s.wait(10, |e| matches!(e, Event::PairRequest { .. }).then_some(()));
    a.e.respond_pair(&b.e.device_id(), true);
    b.e.respond_pair(&a.e.device_id(), false);
    let code = a.s.wait(10, |e| match e { Event::PairFinished { ok: false, code, .. } => Some(code.clone()), _ => None });
    assert_eq!(code, "DECLINED_BY_PEER");
    assert!(!a.e.peers().iter().any(|p| p.trusted));
    assert!(!b.e.peers().iter().any(|p| p.trusted));
}

#[test]
fn trust_survives_restart_and_connection_comes_back() {
    let (a, b) = (node("alice", true), node("bob", true));
    pair(&a, &b);
    connected(&a, &b);
    let (bport, bdata, bdl) = (b.e.port(), b.data.clone(), b.dl.clone());
    let before_drop = a.s.mark();
    drop(b);
    // Alice must notice the drop...
    let id = node_id_hint(&a);
    a.s.wait_after(before_drop, 30, |e| match e { Event::PeerChanged { peer } if peer.id == id && peer.state != PeerState::Connected => Some(()), _ => None });
    let from = a.s.ev.lock().unwrap().iter().rposition(|e| matches!(e, Event::PeerChanged { peer } if peer.id == id && peer.state != PeerState::Connected)).unwrap();
    // ...and, with the same identity on the same port, reconnect by herself.
    let b2 = node_at("bob", true, bdata, bdl, bport);
    assert_eq!(b2.e.device_id(), id);
    assert!(b2.e.peers().iter().any(|p| p.trusted), "pairing was persisted");
    a.s.wait_after(from, 40, |e| match e { Event::PeerChanged { peer } if peer.id == id && peer.state == PeerState::Connected => Some(()), _ => None });
}

/// The only trusted peer of `n`.
fn node_id_hint(n: &Node) -> String {
    n.e.peers().into_iter().find(|p| p.trusted).unwrap().id
}

#[test]
fn revoked_device_is_refused_and_cannot_receive() {
    let (a, b) = (node("alice", true), node("bob", true));
    pair(&a, &b);
    connected(&a, &b);
    a.e.revoke(&b.e.device_id()).unwrap();
    assert!(a.e.send_file(&b.e.device_id(), &write_file(&a.dl, "x.bin", 10), None).is_err());
    // Bob keeps trusting Alice but she no longer trusts him: his next dial is refused.
    let id = a.e.device_id();
    b.s.wait(40, |e| match e { Event::PeerChanged { peer } if peer.id == id && peer.state == PeerState::Rejected => Some(()), _ => None });
}

#[test]
fn file_arrives_identical_both_directions_and_is_in_history() {
    let (a, b) = (node("alice", true), node("bob", true));
    pair(&a, &b);
    connected(&a, &b);
    let src = write_file(&a.dl, "photo.bin", 3 * 1024 * 1024 + 123);
    let id = a.e.send_file(&b.e.device_id(), &src, None).unwrap();
    let path = b.s.wait(20, |e| match e { Event::TransferFinished { ok: true, path, .. } => Some(path.clone()), _ => None });
    a.s.wait(20, |e| match e { Event::TransferFinished { id: i, ok: true, .. } if *i == id => Some(()), _ => None });
    assert_eq!(std::fs::read(&src).unwrap(), std::fs::read(&path).unwrap());
    assert!(a.e.history().iter().any(|h| h.id == id && h.status == "done" && !h.incoming));
    assert!(b.e.history().iter().any(|h| h.status == "done" && h.incoming));
    // And back.
    let back = write_file(&b.dl, "reply.bin", 70_000);
    b.e.send_file(&a.e.device_id(), &back, None).unwrap();
    let got = a.s.wait(20, |e| match e { Event::TransferFinished { ok: true, path, id: i, .. } if *i != id => Some(path.clone()), _ => None });
    assert_eq!(std::fs::read(&back).unwrap(), std::fs::read(&got).unwrap());
}

#[test]
fn declined_offer_is_not_retried() {
    let (a, b) = (node("alice", true), node("bob", false));
    pair(&a, &b);
    connected(&a, &b);
    let id = a.e.send_file(&b.e.device_id(), &write_file(&a.dl, "no.bin", 5000), None).unwrap();
    let offer = b.s.wait(10, |e| match e { Event::TransferOffer { id, .. } => Some(id.clone()), _ => None });
    assert_eq!(offer, id);
    b.e.respond_transfer(&offer, false);
    let code = a.s.wait(10, |e| match e { Event::TransferFinished { id: i, ok: false, code, .. } if *i == id => Some(code.clone()), _ => None });
    assert_eq!(code, "REJECTED");
    assert!(std::fs::read_dir(&b.dl).unwrap().next().is_none(), "nothing written for a declined offer");
}

#[test]
fn cancelling_a_send_leaves_no_part_file_on_the_receiver() {
    let (a, b) = (node("alice", true), node("bob", true));
    pair(&a, &b);
    connected(&a, &b);
    let src = write_file(&a.dl, "big.bin", 200 * 1024 * 1024);
    let id = a.e.send_file(&b.e.device_id(), &src, None).unwrap();
    a.s.wait(20, |e| match e { Event::TransferProgress { done, .. } if *done > 4 * 1024 * 1024 => Some(()), _ => None });
    a.e.cancel_transfer(&id);
    let code = a.s.wait(20, |e| match e { Event::TransferFinished { id: i, code, .. } if *i == id => Some(code.clone()), _ => None });
    assert_eq!(code, "CANCELLED");
    b.s.wait(20, |e| match e { Event::TransferFinished { ok: false, code, .. } if code == "CANCELLED" => Some(()), _ => None });
    assert!(std::fs::read_dir(&b.dl).unwrap().next().is_none(), "receiver cleaned its .part");
    assert_eq!(a.e.history().iter().find(|h| h.id == id).unwrap().status, "cancelled");
}

#[test]
fn unpaired_client_cannot_open_control_or_data() {
    let a = node("alice", true);
    let stranger = Identity::generate("mallory").unwrap();
    for kind in ["control", "data"] {
        let cfg = client_config(&stranger, Verifier::new([], true)).unwrap();
        let mut tcp = TcpStream::connect(("127.0.0.1", a.e.port())).unwrap();
        tcp.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
        let mut conn = ClientConnection::new(cfg, ServerName::try_from("phonebridge").unwrap()).unwrap();
        while conn.is_handshaking() {
            conn.complete_io(&mut tcp).unwrap();
        }
        let mut s = StreamOwned::new(conn, tcp);
        write_frame(&mut s, &json!({"type":"pb.hello","body":{"name":"mallory","port":1,"protocol":1,"kind":kind}})).unwrap();
        let r = read_frame(&mut s).unwrap();
        assert_eq!(r["type"], "pb.error");
        assert_eq!(r["body"]["code"], "NOT_TRUSTED");
    }
    assert!(a.e.peers().iter().all(|p| !p.trusted));
}

#[test]
fn wrong_protocol_version_gets_a_clear_error() {
    let a = node("alice", true);
    let stranger = Identity::generate("old").unwrap();
    let cfg = client_config(&stranger, Verifier::new([], true)).unwrap();
    let mut tcp = TcpStream::connect(("127.0.0.1", a.e.port())).unwrap();
    tcp.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
    let mut conn = ClientConnection::new(cfg, ServerName::try_from("phonebridge").unwrap()).unwrap();
    while conn.is_handshaking() {
        conn.complete_io(&mut tcp).unwrap();
    }
    let mut s = StreamOwned::new(conn, tcp);
    write_frame(&mut s, &json!({"type":"pb.hello","body":{"name":"old","port":1,"protocol":0,"kind":"pair"}})).unwrap();
    assert_eq!(read_frame(&mut s).unwrap()["body"]["code"], "VERSION");
}

#[test]
fn transfer_survives_the_receiver_dropping_and_resumes_by_itself() {
    let (a, b) = (node("alice", true), node("bob", true));
    pair(&a, &b);
    connected(&a, &b);
    let src = write_file(&a.dl, "huge.bin", 300 * 1024 * 1024);
    let id = a.e.send_file(&b.e.device_id(), &src, None).unwrap();
    a.s.wait(30, |e| match e { Event::TransferProgress { done, .. } if *done > 8 * 1024 * 1024 => Some(()), _ => None });
    let (bport, bdata, bdl) = (b.e.port(), b.data.clone(), b.dl.clone());
    drop(b); // the "network" goes away mid-file
    std::thread::sleep(Duration::from_millis(500));
    let b2 = node_at("bob", true, bdata, bdl, bport);
    a.s.wait(120, |e| match e { Event::TransferFinished { id: i, ok: true, .. } if *i == id => Some(()), _ => None });
    let got = b2.s.wait(30, |e| match e { Event::TransferFinished { ok: true, path, .. } => Some(path.clone()), _ => None });
    assert!(a.s.ev.lock().unwrap().iter().any(|e| matches!(e, Event::TransferNote { id: i, .. } if *i == id)), "sender announced a retry");
    assert_eq!(std::fs::metadata(&src).unwrap().len(), std::fs::metadata(&got).unwrap().len());
    assert_eq!(std::fs::read(&src).unwrap() == std::fs::read(&got).unwrap(), true, "byte-identical after resume");
}

#[test]
fn app_messages_reach_paired_peers_only() {
    let (a, b) = (node("alice", true), node("bob", true));
    assert!(a.e.send_message(&b.e.device_id(), "pb.x.info", serde_json::json!({})).is_err(), "not paired yet");
    pair(&a, &b);
    connected(&a, &b);
    assert!(a.e.send_message(&b.e.device_id(), "pb.ping", serde_json::json!({})).is_err(), "protocol namespace is off limits");
    a.e.send_message(&b.e.device_id(), "pb.x.clip", serde_json::json!({"text": "hola"})).unwrap();
    let a_id = a.e.device_id();
    let text = b.s.wait(10, |e| match e {
        Event::Message { peer_id, kind, body } if *peer_id == a_id && kind == "pb.x.clip" => body["text"].as_str().map(String::from),
        _ => None,
    });
    assert_eq!(text, "hola");
}

#[test]
fn linking_a_paired_address_adds_a_route_without_pairing_again() {
    let (a, b) = (node("a", true), node("b", true));
    pair(&a, &b);
    connected(&a, &b);
    let from = a.s.mark();
    // The cable case: the user (or the app) points at an address of a device that is already paired.
    a.e.pair_with_addr(&format!("127.0.0.1:{}", b.e.port())).unwrap();
    std::thread::sleep(Duration::from_secs(2));
    let again = a.s.ev.lock().unwrap().iter().skip(from).any(|e| matches!(e, Event::PairRequest { .. }));
    assert!(!again, "an already paired device must not ask for a new code");
    assert!(a.e.peers().iter().any(|p| p.id == b.e.device_id() && p.trusted && p.state == PeerState::Connected));
}
