//! "Desconectar" keeps the pairing and stops reconnecting (even across a restart); "Conectar" brings it back.
use std::path::PathBuf;
use std::sync::mpsc::{channel, Receiver, Sender};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use pb_core::engine::{Config, Engine, Event, EventSink, PeerState, PAUSED, PAUSED_REMOTE};

struct Sink(Mutex<Sender<Event>>);
impl EventSink for Sink {
    fn on_event(&self, e: Event) {
        let _ = self.0.lock().unwrap().send(e);
    }
}

fn dir(tag: &str) -> PathBuf {
    let d = std::env::temp_dir().join(format!("alero-test-{tag}-{}-{}", std::process::id(), Instant::now().elapsed().as_nanos()));
    let _ = std::fs::remove_dir_all(&d);
    d
}

fn start(d: &PathBuf, name: &str, port: u16) -> (Engine, Receiver<Event>) {
    let (tx, rx) = channel();
    let e = Engine::start(
        Config { data_dir: d.join("data"), download_dir: d.join("dl"), name: name.into(), port, discovery_port: 0, auto_accept: true },
        Arc::new(Sink(Mutex::new(tx))),
    )
    .unwrap();
    (e, rx)
}

fn wait(what: &str, mut ok: impl FnMut() -> bool) {
    let until = Instant::now() + Duration::from_secs(25);
    while Instant::now() < until {
        if ok() {
            return;
        }
        std::thread::sleep(Duration::from_millis(100));
    }
    panic!("timed out waiting for {what}");
}

fn state(e: &Engine, id: &str) -> (PeerState, String) {
    e.peers().into_iter().find(|p| p.id == id).map(|p| (p.state, p.detail)).unwrap_or((PeerState::Disconnected, String::new()))
}

#[test]
fn disconnect_keeps_pairing_and_connect_restores_it() {
    let (da, db) = (dir("a"), dir("b"));
    let (a, ra) = start(&da, "PC", 0);
    let (b, rb) = start(&db, "Pixel", 0);
    let (ia, ib) = (a.device_id(), b.device_id());

    // Pair: both users confirm the code.
    a.pair_with_addr(&format!("127.0.0.1:{}", b.port())).unwrap();
    let confirm = |rx: &Receiver<Event>, e: &Engine| {
        wait("pair request", || matches!(rx.try_recv(), Ok(Event::PairRequest { peer_id, .. }) if { e.respond_pair(&peer_id, true); true }));
    };
    confirm(&ra, &a);
    confirm(&rb, &b);
    wait("connected", || state(&a, &ib).0 == PeerState::Connected && state(&b, &ia).0 == PeerState::Connected);

    // Disconnect on A: still paired, told apart from a network loss, and nothing goes out.
    a.disconnect(&ib).unwrap();
    assert_eq!(state(&a, &ib), (PeerState::Disconnected, PAUSED.to_string()));
    assert!(a.peers().iter().any(|p| p.id == ib && p.trusted));
    assert!(a.send_message(&ib, "pb.x.test", serde_json::json!({})).is_err());
    // B redials and is refused: it shows the other side's choice, not a dead connection.
    wait("B sees the pause", || state(&b, &ia) == (PeerState::Disconnected, PAUSED_REMOTE.to_string()));
    std::thread::sleep(Duration::from_secs(3));
    assert_eq!(state(&a, &ib).0, PeerState::Disconnected, "no automatic reconnection after Desconectar");

    // A restart keeps both the pairing and the choice. Same port: loopback addresses are never stored, so the
    // test cannot rely on a remembered one as a real LAN address would.
    let port_a = a.port();
    drop(a);
    drop(ra);
    std::thread::sleep(Duration::from_millis(300));
    let (a, _ra) = start(&da, "PC", port_a);
    assert!(a.peers().iter().any(|p| p.id == ib && p.trusted));
    assert_eq!(state(&a, &ib).1, PAUSED);

    // Connect: back without pairing again (B's next attempt reaches A).
    a.connect(&ib).unwrap();
    wait("reconnected", || state(&a, &ib).0 == PeerState::Connected);
    assert!(b.peers().iter().any(|p| p.id == ia && p.trusted));

    // Regression: a stale control socket must not overwrite a deliberate
    // pause, and reconnect must work repeatedly without a new QR/TLS trust.
    for _ in 0..3 {
        a.disconnect(&ib).unwrap();
        wait("paused after stale socket shutdown", || state(&a, &ib) == (PeerState::Disconnected, PAUSED.to_string()));
        std::thread::sleep(Duration::from_millis(350));
        assert_eq!(state(&a, &ib).1, PAUSED);
        a.connect(&ib).unwrap();
        wait("connected again without pairing", || state(&a, &ib).0 == PeerState::Connected);
        assert!(a.peers().iter().any(|p| p.id == ib && p.trusted));
    }
    let _ = (std::fs::remove_dir_all(da), std::fs::remove_dir_all(db));
}

/// Bug 01: after "Desvincular" on one side, pairing again from either side must work (the other side still
/// trusted the first one and used to treat the new attempt as "already paired").
#[test]
fn unpair_then_pair_again_from_either_side() {
    let (da, db) = (dir("ua"), dir("ub"));
    let (a, ra) = start(&da, "PC", 0);
    let (b, rb) = start(&db, "Pixel", 0);
    let (ia, ib) = (a.device_id(), b.device_id());
    let confirm = |rx: &Receiver<Event>, e: &Engine| {
        wait("pair request", || matches!(rx.try_recv(), Ok(Event::PairRequest { peer_id, .. }) if { e.respond_pair(&peer_id, true); true }));
    };
    let paired = |a: &Engine, b: &Engine| {
        wait("connected", || state(a, &ib).0 == PeerState::Connected && state(b, &ia).0 == PeerState::Connected);
    };

    a.pair_with_addr(&format!("127.0.0.1:{}", b.port())).unwrap();
    confirm(&ra, &a);
    confirm(&rb, &b);
    paired(&a, &b);

    for round in 0..2 {
        // A unpairs B; B still trusts A and is turned away.
        a.revoke(&ib).unwrap();
        assert!(!a.peers().iter().any(|p| p.id == ib && p.trusted));
        // B (the side that kept the stale trust) starts the new pairing, as when the phone scans the QR again.
        // Round 1 starts it while B may not have noticed the refusal yet.
        if round == 1 {
            b.pair_with_addr(&format!("127.0.0.1:{}", a.port())).unwrap();
        } else {
            wait("B is refused", || state(&b, &ia).0 == PeerState::Rejected);
            b.pair_with_addr(&format!("127.0.0.1:{}", a.port())).unwrap();
        }
        confirm(&ra, &a);
        confirm(&rb, &b);
        paired(&a, &b);
        assert!(a.peers().iter().any(|p| p.id == ib && p.trusted));
        assert!(b.peers().iter().any(|p| p.id == ia && p.trusted));
    }
    let _ = (std::fs::remove_dir_all(da), std::fs::remove_dir_all(db));
}
