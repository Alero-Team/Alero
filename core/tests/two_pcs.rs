//! A phone paired with two computers: forgetting one must leave the other paired and connected.
use std::path::PathBuf;
use std::sync::mpsc::{channel, Receiver, Sender};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use pb_core::engine::{Config, Engine, Event, EventSink, PeerState};

struct Sink(Mutex<Sender<Event>>);
impl EventSink for Sink {
    fn on_event(&self, e: Event) {
        let _ = self.0.lock().unwrap().send(e);
    }
}

fn dir(tag: &str) -> PathBuf {
    let d = std::env::temp_dir().join(format!("alero-test-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&d);
    d
}

fn start(d: &PathBuf, name: &str) -> (Engine, Receiver<Event>) {
    let (tx, rx) = channel();
    let e = Engine::start(
        Config { data_dir: d.join("data"), download_dir: d.join("dl"), name: name.into(), port: 0, discovery_port: 0, auto_accept: true },
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

fn view(e: &Engine, id: &str) -> Option<(PeerState, bool)> {
    e.peers().into_iter().find(|p| p.id == id).map(|p| (p.state, p.trusted))
}

#[test]
fn forgetting_one_computer_keeps_the_other() {
    let (dp, da, db) = (dir("tp"), dir("ta"), dir("tb"));
    let (phone, rp) = start(&dp, "Pixel");
    let (a, ra) = start(&da, "Windows");
    let (b, rb) = start(&db, "Debian");
    let (ia, ib) = (a.device_id(), b.device_id());
    let confirm = |rx: &Receiver<Event>, e: &Engine| {
        wait("pair request", || matches!(rx.try_recv(), Ok(Event::PairRequest { peer_id, .. }) if { e.respond_pair(&peer_id, true); true }));
    };
    for (pc, rpc, id) in [(&a, &ra, &ia), (&b, &rb, &ib)] {
        phone.pair_with_addr(&format!("127.0.0.1:{}", pc.port())).unwrap();
        confirm(&rp, &phone);
        confirm(rpc, pc);
        wait("connected", || view(&phone, id) == Some((PeerState::Connected, true)));
    }
    assert_eq!(phone.peers().iter().filter(|p| p.trusted).count(), 2);

    phone.revoke(&ia).unwrap();
    assert_eq!(view(&phone, &ib), Some((PeerState::Connected, true)));
    assert!(phone.peers().iter().all(|p| p.id != ia || !p.trusted));
    // Still true once everything has settled (reconnect loops, rejections from the forgotten side).
    std::thread::sleep(Duration::from_secs(4));
    assert_eq!(view(&phone, &ib), Some((PeerState::Connected, true)));
    drop(phone);
    let _ = (std::fs::remove_dir_all(dp), std::fs::remove_dir_all(da), std::fs::remove_dir_all(db));
}
