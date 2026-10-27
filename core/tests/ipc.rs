//! The daemon control channel: token check, a call round trip, pushes, and replay of a request nobody saw.

use std::io::{BufRead, BufReader, Write};
use std::net::TcpStream;
use std::sync::mpsc::channel;
use std::sync::Arc;
use std::time::Duration;

use pb_core::engine::{Config, Engine, Event, EventSink};
use pb_core::ipc::{listen, Client, Cmd, Push, Subscribers, IPC_FILE};

struct Quiet;
impl EventSink for Quiet {
    fn on_event(&self, _: Event) {}
}

#[test]
fn control_channel() {
    let data = std::env::temp_dir().join(format!("pb-ipc-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&data);
    let cfg = Config { data_dir: data.clone(), download_dir: data.join("dl"), name: "pc".into(), port: 0, discovery_port: 0, auto_accept: true };
    let engine = Arc::new(Engine::start(cfg, Arc::new(Quiet)).unwrap());
    let subs = Arc::new(Subscribers::default());
    listen(&data, engine.clone(), subs.clone()).unwrap();

    // Wrong token: the daemon hangs up without answering.
    let info: serde_json::Value = serde_json::from_slice(&std::fs::read(data.join(IPC_FILE)).unwrap()).unwrap();
    let mut bad = TcpStream::connect(("127.0.0.1", info["port"].as_u64().unwrap() as u16)).unwrap();
    bad.write_all(b"nope\n{\"cmd\":\"DeviceId\"}\n").unwrap();
    let mut line = String::new();
    assert_eq!(BufReader::new(bad).read_line(&mut line).unwrap_or(0), 0);

    let mut c = Client::connect(&data).unwrap();
    assert_eq!(c.call(&Cmd::DeviceId).unwrap(), serde_json::json!(engine.device_id()));
    c.call(&Cmd::SetName { name: "otro".into() }).unwrap();
    assert_eq!(engine.name(), "otro");
    assert!(c.call(&Cmd::PairPeer { id: "nadie".into() }).is_err());

    // A pairing request with no window open waits for the next one.
    let req = Event::PairRequest { peer_id: "x".into(), name: "tel".into(), code: "123456".into(), incoming: true };
    assert!(!subs.push(&Push::Event { event: req }));
    let (tx, rx) = channel();
    let sub = Client::connect(&data).unwrap();
    std::thread::spawn(move || sub.subscribe(|p| tx.send(p).unwrap()));
    let first = rx.recv_timeout(Duration::from_secs(5)).unwrap();
    assert!(matches!(first, Push::Event { event: Event::PairRequest { .. } }), "{first:?}");
    assert!(subs.push(&Push::Show));
    assert!(matches!(rx.recv_timeout(Duration::from_secs(5)).unwrap(), Push::Show));
    engine.shutdown();
}
