//! The pairing code: both devices must show the same six digits after the commit-and-reveal exchange.
use std::sync::mpsc::{channel, Receiver, Sender};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use pb_core::engine::{sas_code, Config, Engine, Event, EventSink};

struct Sink(Mutex<Sender<Event>>);
impl EventSink for Sink {
    fn on_event(&self, e: Event) {
        let _ = self.0.lock().unwrap().send(e);
    }
}

fn start(tag: &str) -> (Engine, Receiver<Event>) {
    let d = std::env::temp_dir().join(format!("alero-code-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&d);
    let (tx, rx) = channel();
    let cfg = Config { data_dir: d.join("data"), download_dir: d.join("dl"), name: tag.into(), port: 0, discovery_port: 0, auto_accept: true };
    (Engine::start(cfg, Arc::new(Sink(Mutex::new(tx)))).unwrap(), rx)
}

fn code(rx: &Receiver<Event>) -> String {
    let until = Instant::now() + Duration::from_secs(20);
    while Instant::now() < until {
        if let Ok(Event::PairRequest { code, .. }) = rx.recv_timeout(Duration::from_millis(200)) {
            return code;
        }
    }
    panic!("no pairing request");
}

#[test]
fn both_devices_show_the_same_code() {
    let (a, ra) = start("a");
    let (b, rb) = start("b");
    a.pair_with_addr(&format!("127.0.0.1:{}", b.port())).unwrap();
    let (ca, cb) = (code(&ra), code(&rb));
    assert_eq!(ca.len(), 6);
    assert_eq!(ca, cb);
}

#[test]
fn the_code_depends_on_both_nonces() {
    let (exp, n1, n2) = ([7u8; 32], [1u8; 32], [2u8; 32]);
    let base = sas_code(&exp, "aa", "bb", &n1, &n2);
    // Same for both sides whatever the order of the ids; the nonces have fixed roles.
    assert_eq!(base, sas_code(&exp, "bb", "aa", &n1, &n2));
    let other: Vec<String> = (3u8..40).map(|i| sas_code(&exp, "aa", "bb", &n1, &[i; 32])).collect();
    assert!(other.iter().any(|c| *c != base));
    let other: Vec<String> = (3u8..40).map(|i| sas_code(&exp, "aa", "bb", &[i; 32], &n2)).collect();
    assert!(other.iter().any(|c| *c != base));
}
