//! The engine: everything a front end needs, with no UI inside (Protocol.md §3–§7).
//!
//! Connections, all TLS 1.3 with mutual pinning (see `tls`). The first frame the initiator sends is
//! `pb.hello {kind}` and decides what the connection is for:
//!   - `pair`    both sides show the same 6-digit code derived from the TLS exporter; trust is stored only if
//!               both users accept (defeats a man in the middle: two TLS sessions have different exporters).
//!   - `control` one per trusted pair, kept alive with ping/pong; the side with the lower deviceId dials.
//!   - `data`    one per file transfer, sender dials (see `transfer`).
//! Unknown devices can only reach `pair`. Identity always comes from the certificate, never from a hello
//! or a discovery announcement.
//!
//! Threads, not async: simple to reason about and to expose over FFI. shortcut: one thread per connection,
//! fine for a handful of devices; revisit if the engine ever serves many peers.

use std::collections::{HashMap, HashSet};
use std::io::{Read, Write};
use std::net::{IpAddr, Ipv4Addr, SocketAddr, TcpListener, TcpStream, ToSocketAddrs, UdpSocket};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::sync::mpsc::{channel, Receiver, RecvTimeoutError, Sender};
use std::sync::{Arc, Mutex, MutexGuard, RwLock};
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use rustls::pki_types::ServerName;
use rustls::{ClientConnection, ServerConfig, ServerConnection, StreamOwned};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};

use crate::frame::{read_frame, read_frame_max, write_frame, write_frame_max, MAX_APP_BODY};
use crate::identity::Identity;
use crate::store::{HistoryEntry, PeerRecord, Store};
use crate::tls::{client_config, peer_device_id, server_config, Verifier};
use crate::transfer::{receive_file_ex, safe_name, send_file_ex, TransferError, DEFAULT_BLOCK};

pub const PROTOCOL: u64 = 1;
pub const DEFAULT_PORT: u16 = 41420;
const MAX_HANDSHAKES: usize = 16;
const PING_EVERY: Duration = Duration::from_secs(10);
const PAIR_TIMEOUT: Duration = Duration::from_secs(120);
const OFFER_TIMEOUT: Duration = Duration::from_secs(120);
const MAX_SEND_ATTEMPTS: u32 = 6;
/// A peer silent for this long is not dialed any more (it is off or away); hearing it again resumes at once.
const STALE_PEER: Duration = Duration::from_secs(90);
const MSG_IDLE: Duration = Duration::from_secs(60);
/// Phones announce rarely once settled (see discovery_loop).
const QUIET_DISCOVERY: bool = cfg!(target_os = "android");

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum PeerState {
    Disconnected,
    Connecting,
    Connected,
    /// The other device no longer trusts us (it revoked us). We stop dialing until the user acts.
    Rejected,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct PeerView {
    pub id: String,
    pub name: String,
    pub addr: String,
    pub state: PeerState,
    pub trusted: bool,
    pub detail: String,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(tag = "type")]
pub enum Event {
    PeerChanged { peer: PeerView },
    PeerGone { id: String },
    PairRequest { peer_id: String, name: String, code: String, incoming: bool },
    PairFinished { peer_id: String, name: String, ok: bool, code: String, message: String },
    /// An incoming transfer waits for `respond_transfer` (only when auto-accept is off).
    TransferOffer { id: String, peer_id: String, peer_name: String, name: String, size: u64 },
    TransferStarted { id: String, peer_id: String, peer_name: String, name: String, size: u64, incoming: bool },
    TransferProgress { id: String, done: u64, total: u64, bytes_per_sec: u64 },
    TransferNote { id: String, message: String },
    TransferFinished { id: String, ok: bool, code: String, message: String, path: String },
    Log { message: String },
    /// An app message (`pb.x.*`) from a paired device: device info, clipboard, notifications, media…
    /// The core only carries it; each app gives it meaning (Protocol.md §6).
    Message { peer_id: String, kind: String, body: Value },
}

pub trait EventSink: Send + Sync {
    fn on_event(&self, e: Event);
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Config {
    pub data_dir: PathBuf,
    pub download_dir: PathBuf,
    pub name: String,
    /// TCP port to listen on; 0 picks a free one (tests).
    pub port: u16,
    /// UDP port for LAN discovery; 0 disables discovery.
    pub discovery_port: u16,
    pub auto_accept: bool,
}

// ---------------------------------------------------------------------------------------------------------
// TLS stream wrapper

enum Tls {
    C(StreamOwned<ClientConnection, TcpStream>),
    S(StreamOwned<ServerConnection, TcpStream>),
}

impl Read for Tls {
    fn read(&mut self, b: &mut [u8]) -> std::io::Result<usize> {
        match self {
            Tls::C(s) => s.read(b),
            Tls::S(s) => s.read(b),
        }
    }
}

impl Write for Tls {
    fn write(&mut self, b: &[u8]) -> std::io::Result<usize> {
        match self {
            Tls::C(s) => s.write(b),
            Tls::S(s) => s.write(b),
        }
    }
    fn flush(&mut self) -> std::io::Result<()> {
        match self {
            Tls::C(s) => s.flush(),
            Tls::S(s) => s.flush(),
        }
    }
}

impl Tls {
    fn tcp(&self) -> &TcpStream {
        match self {
            Tls::C(s) => &s.sock,
            Tls::S(s) => &s.sock,
        }
    }

    fn peer_id(&self) -> Result<String, String> {
        match self {
            Tls::C(s) => peer_device_id(s.conn.peer_certificates()),
            Tls::S(s) => peer_device_id(s.conn.peer_certificates()),
        }
    }

    fn exporter(&self) -> Result<[u8; 32], String> {
        let r = match self {
            Tls::C(s) => s.conn.export_keying_material([0u8; 32], b"pb pairing sas", None),
            Tls::S(s) => s.conn.export_keying_material([0u8; 32], b"pb pairing sas", None),
        };
        r.map_err(|e| e.to_string())
    }

    fn timeouts(&self, d: Duration) {
        let _ = self.tcp().set_read_timeout(Some(d));
        let _ = self.tcp().set_write_timeout(Some(d));
    }
}

/// 6-digit code both users compare. Binds the TLS session (exporter) and both identities.
pub fn sas_code(exporter: &[u8; 32], id_a: &str, id_b: &str) -> String {
    let (lo, hi) = if id_a <= id_b { (id_a, id_b) } else { (id_b, id_a) };
    let mut h = Sha256::new();
    h.update(b"pb-sas-v1");
    h.update(exporter);
    h.update(lo.as_bytes());
    h.update(hi.as_bytes());
    let d = h.finalize();
    format!("{:06}", u32::from_be_bytes([d[0], d[1], d[2], d[3]]) % 1_000_000)
}

// ---------------------------------------------------------------------------------------------------------
// State

struct Peer {
    name: String,
    addr: Option<SocketAddr>,
    state: PeerState,
    detail: String,
    seen: Instant,
    next_try: Instant,
    backoff: Duration,
    wait_since: Option<Instant>,
    busy: bool,
}

struct ConnHandle {
    initiator_id: String,
    sock: TcpStream,
    gen: u64,
}

struct Xfer {
    id: String,
    peer_id: String,
    peer_name: String,
    name: String,
    size: u64,
    incoming: bool,
    /// Source path of an outgoing transfer, for history/retry.
    src: String,
    cancel: Arc<AtomicBool>,
    sock: Mutex<Option<TcpStream>>,
}

struct Meter {
    t: Instant,
    b: Option<u64>,
    rate: f64,
}

impl Meter {
    fn new() -> Self {
        Self { t: Instant::now(), b: None, rate: 0.0 }
    }
}

struct Inner {
    id: Identity,
    store: Store,
    download_dir: PathBuf,
    name: RwLock<String>,
    auto_accept: AtomicBool,
    port: u16,
    discovery_port: u16,
    trusted: Arc<RwLock<HashSet<String>>>,
    server_cfg: Arc<ServerConfig>,
    peers: Mutex<HashMap<String, Peer>>,
    pair_wait: Mutex<HashMap<String, Sender<bool>>>,
    conns: Mutex<HashMap<String, ConnHandle>>,
    xfers: Mutex<HashMap<String, Arc<Xfer>>>,
    cancelled: Mutex<HashSet<String>>,
    offers: Mutex<HashMap<String, Sender<bool>>>,
    sink: Arc<dyn EventSink>,
    stop: AtomicBool,
    seq: AtomicU64,
    inflight: AtomicUsize,
    disco_status: Mutex<String>,
    /// One ordered queue (and one kept-open connection) per peer for app messages.
    msg_queues: Mutex<HashMap<String, Sender<Value>>>,
}

fn lk<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|e| e.into_inner())
}

/// Names come from the network: bound them and drop control characters before any UI sees them.
fn clean(s: &str) -> String {
    s.chars().filter(|c| !c.is_control()).take(64).collect::<String>().trim().to_string()
}

/// App messages live in their own namespace so they can never be mistaken for protocol frames.
fn app_kind(k: &str) -> bool {
    k.len() <= 64 && k.starts_with("pb.x.") && k[5..].chars().all(|c| c.is_ascii_alphanumeric() || c == '.' || c == '_')
}

fn now_secs() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |d| d.as_secs())
}

fn random_id() -> String {
    let mut b = [0u8; 12];
    let _ = rustls::crypto::ring::default_provider().secure_random.fill(&mut b);
    b.iter().map(|x| format!("{x:02x}")).collect()
}

/// Primary LAN IPv4 address (no packet is sent).
fn primary_ip() -> Option<Ipv4Addr> {
    let s = UdpSocket::bind("0.0.0.0:0").ok()?;
    s.connect("192.0.2.1:9").ok()?;
    match s.local_addr().ok()?.ip() {
        IpAddr::V4(v4) if !v4.is_unspecified() => Some(v4),
        _ => None,
    }
}

fn err_code(e: &TransferError) -> (&'static str, String) {
    match e {
        TransferError::Io(m) => ("NETWORK", m.clone()),
        TransferError::Protocol(m) => ("PROTOCOL", m.clone()),
        TransferError::Integrity => ("INTEGRITY", "checksum mismatch".into()),
        TransferError::InvalidName => ("INVALID_NAME", "file name not allowed".into()),
        TransferError::Aborted => ("ABORTED", "aborted".into()),
        TransferError::Cancelled => ("CANCELLED", "cancelled".into()),
        TransferError::Rejected(r) => ("REJECTED", r.clone()),
    }
}

impl Inner {
    fn emit(&self, e: Event) {
        self.sink.on_event(e);
    }

    fn log(&self, m: impl Into<String>) {
        self.emit(Event::Log { message: m.into() });
    }

    fn my_name(&self) -> String {
        self.name.read().map(|n| n.clone()).unwrap_or_default()
    }

    fn is_trusted(&self, id: &str) -> bool {
        self.trusted.read().map_or(false, |t| t.contains(id))
    }

    fn hello(&self, kind: &str) -> Value {
        json!({"type":"pb.hello","body":{"name":self.my_name(),"port":self.port,"protocol":PROTOCOL,"kind":kind}})
    }

    // --- peers -------------------------------------------------------------------------------------------

    fn view(&self, id: &str) -> PeerView {
        let trusted = self.is_trusted(id);
        let known = self.store.peers().into_iter().find(|p| p.id == id).map(|p| p.name);
        let peers = lk(&self.peers);
        match peers.get(id) {
            Some(p) => PeerView {
                id: id.into(),
                name: if p.name.is_empty() { known.unwrap_or_default() } else { p.name.clone() },
                addr: p.addr.map(|a| a.to_string()).unwrap_or_default(),
                state: p.state.clone(),
                trusted,
                detail: p.detail.clone(),
            },
            None => PeerView {
                id: id.into(),
                name: known.unwrap_or_default(),
                addr: String::new(),
                state: PeerState::Disconnected,
                trusted,
                detail: String::new(),
            },
        }
    }

    fn changed(&self, id: &str) {
        self.emit(Event::PeerChanged { peer: self.view(id) });
    }

    fn with_peer<R>(&self, id: &str, f: impl FnOnce(&mut Peer) -> R) -> R {
        let mut peers = lk(&self.peers);
        let p = peers.entry(id.to_string()).or_insert_with(|| Peer {
            name: String::new(),
            addr: None,
            state: PeerState::Disconnected,
            detail: String::new(),
            seen: Instant::now(),
            next_try: Instant::now(),
            backoff: Duration::from_secs(1),
            wait_since: None,
            busy: false,
        });
        f(p)
    }

    /// Records what we just heard about a peer. True when it is new, changed, or had been silent for a while.
    fn note_peer(&self, id: &str, name: &str, addr: Option<SocketAddr>) -> bool {
        if id == self.id.device_id {
            return false;
        }
        let name = clean(name);
        let changed = self.with_peer(id, |p| {
            let c = (!name.is_empty() && p.name != name) || (addr.is_some() && p.addr != addr) || p.seen.elapsed() > Duration::from_secs(25);
            if !name.is_empty() {
                p.name = name.clone();
            }
            if addr.is_some() && p.addr != addr {
                p.addr = addr;
                p.next_try = Instant::now();
            }
            p.seen = Instant::now();
            c
        });
        if changed {
            self.changed(id);
        }
        changed
    }

    fn set_state(&self, id: &str, state: PeerState, detail: &str) {
        let diff = self.with_peer(id, |p| {
            let d = p.state != state || p.detail != detail;
            p.state = state;
            p.detail = detail.into();
            d
        });
        if diff {
            self.changed(id);
        }
    }

    fn add_trust(&self, id: &str, name: &str) {
        if let Ok(mut t) = self.trusted.write() {
            t.insert(id.to_string());
        }
        let mut list = self.store.peers();
        list.retain(|p| p.id != id);
        list.push(PeerRecord { id: id.into(), name: clean(name) });
        if let Err(e) = self.store.save_peers(&list) {
            self.log(format!("could not save peers: {e}"));
        }
        self.with_peer(id, |p| {
            p.next_try = Instant::now();
            p.backoff = Duration::from_secs(1);
            p.state = PeerState::Disconnected;
            p.detail.clear();
        });
        self.changed(id);
    }

    // --- TLS plumbing ------------------------------------------------------------------------------------

    fn accept_tls(&self, tcp: TcpStream) -> Result<Tls, String> {
        let _ = tcp.set_nodelay(true);
        let mut tcp = tcp;
        let _ = tcp.set_read_timeout(Some(Duration::from_secs(10)));
        let _ = tcp.set_write_timeout(Some(Duration::from_secs(10)));
        let mut conn = ServerConnection::new(self.server_cfg.clone()).map_err(|e| e.to_string())?;
        while conn.is_handshaking() {
            conn.complete_io(&mut tcp).map_err(|e| format!("handshake: {e}"))?;
        }
        Ok(Tls::S(StreamOwned::new(conn, tcp)))
    }

    /// `expected = Some(id)` pins the peer; `None` accepts any certificate (pairing only).
    fn dial(&self, addr: SocketAddr, expected: Option<&str>) -> Result<Tls, String> {
        let mut tcp = TcpStream::connect_timeout(&addr, Duration::from_secs(5)).map_err(|e| e.to_string())?;
        let _ = tcp.set_nodelay(true);
        let _ = tcp.set_read_timeout(Some(Duration::from_secs(10)));
        let _ = tcp.set_write_timeout(Some(Duration::from_secs(10)));
        let verifier = match expected {
            Some(id) => Verifier::new([id.to_string()], false),
            None => Verifier::new([], true),
        };
        let cfg = client_config(&self.id, verifier).map_err(|e| e.to_string())?;
        let mut conn = ClientConnection::new(cfg, ServerName::try_from("phonebridge").unwrap()).map_err(|e| e.to_string())?;
        while conn.is_handshaking() {
            conn.complete_io(&mut tcp).map_err(|e| format!("handshake: {e}"))?;
        }
        let tls = Tls::C(StreamOwned::new(conn, tcp));
        if let Some(id) = expected {
            if tls.peer_id()? != id {
                return Err("peer identity changed".into());
            }
        }
        Ok(tls)
    }

    /// Initiator side of the hello exchange. Returns the peer's cleaned name.
    fn hello_out(&self, tls: &mut Tls, kind: &str) -> Result<String, String> {
        write_frame(tls, &self.hello(kind)).map_err(|e| e.code().to_string())?;
        let r = read_frame(tls).map_err(|e| e.code().to_string())?;
        match r["type"].as_str() {
            Some("pb.hello") => Ok(clean(r["body"]["name"].as_str().unwrap_or(""))),
            Some("pb.error") => Err(r["body"]["code"].as_str().unwrap_or("ERROR").to_string()),
            _ => Err("PROTOCOL".into()),
        }
    }

    // --- incoming connections ----------------------------------------------------------------------------

    fn handle_incoming(self: &Arc<Self>, tcp: TcpStream) -> Result<(), String> {
        let ip = tcp.peer_addr().map_err(|e| e.to_string())?.ip();
        let mut tls = self.accept_tls(tcp)?;
        let peer_id = tls.peer_id()?;
        let hello = read_frame(&mut tls).map_err(|e| e.code().to_string())?;
        if hello["type"] != "pb.hello" {
            return Err("first frame is not hello".into());
        }
        let b = &hello["body"];
        let (name, port, kind) = (clean(b["name"].as_str().unwrap_or("")), b["port"].as_u64().unwrap_or(0), b["kind"].as_str().unwrap_or("").to_string());
        if b["protocol"].as_u64() != Some(PROTOCOL) {
            let _ = write_frame(&mut tls, &json!({"type":"pb.error","body":{"code":"VERSION","protocol":PROTOCOL}}));
            return Err(format!("peer speaks protocol {}", b["protocol"]));
        }
        let ok = match kind.as_str() {
            "pair" => true,
            "control" | "data" | "msg" => self.is_trusted(&peer_id),
            _ => false,
        };
        if !ok {
            let _ = write_frame(&mut tls, &json!({"type":"pb.error","body":{"code":"NOT_TRUSTED"}}));
            return Ok(());
        }
        write_frame(&mut tls, &self.hello(&kind)).map_err(|e| e.code().to_string())?;
        let addr = (port > 0 && port < 65536).then(|| SocketAddr::new(ip, port as u16));
        self.note_peer(&peer_id, &name, addr);
        match kind.as_str() {
            "pair" => self.run_pair(tls, &peer_id, &name, true),
            "control" => self.run_control(tls, peer_id, false),
            "msg" => self.run_msg_in(tls, &peer_id),
            _ => self.run_data_in(tls, &peer_id),
        }
    }

    // --- app messages ------------------------------------------------------------------------------------
    // One msg connection per peer stays open and carries messages in order, each answered with pb.ack
    // (a handshake per message made remote-control input laggy and unordered). The sender closes it after a
    // minute without traffic; the receiver also gives up on a silent connection.

    fn run_msg_in(&self, mut tls: Tls, peer_id: &str) -> Result<(), String> {
        tls.timeouts(MSG_IDLE + Duration::from_secs(30));
        loop {
            // A closed or silent connection simply ends the loop.
            let Ok(m) = read_frame_max(&mut tls, MAX_APP_BODY) else { return Ok(()) };
            let kind = m["type"].as_str().unwrap_or("");
            if !app_kind(kind) {
                let _ = write_frame(&mut tls, &json!({"type":"pb.error","body":{"code":"PROTOCOL"}}));
                return Err(format!("not an app message: {kind}"));
            }
            if !self.is_trusted(peer_id) {
                return Ok(());
            }
            self.emit(Event::Message { peer_id: peer_id.into(), kind: kind.into(), body: m["body"].clone() });
            write_frame(&mut tls, &json!({"type":"pb.ack","body":{}})).map_err(|e| e.code().to_string())?;
        }
    }

    /// Sends one message over the kept-open connection, opening it first if needed.
    fn msg_once(&self, conn: &mut Option<Tls>, peer_id: &str, m: &Value) -> Result<(), String> {
        if conn.is_none() {
            let addr = self.with_peer(peer_id, |p| p.addr).ok_or("that device has not been seen on the network")?;
            let mut tls = self.dial(addr, Some(peer_id))?;
            tls.timeouts(Duration::from_secs(10));
            self.hello_out(&mut tls, "msg")?;
            *conn = Some(tls);
        }
        let tls = conn.as_mut().expect("just opened");
        write_frame_max(tls, m, MAX_APP_BODY).map_err(|e| e.code().to_string())?;
        let r = read_frame(tls).map_err(|e| e.code().to_string())?;
        if r["type"] == "pb.ack" { Ok(()) } else { Err(r["body"]["code"].as_str().unwrap_or("PROTOCOL").to_string()) }
    }

    fn msg_worker(self: Arc<Self>, id: String, rx: Receiver<Value>) {
        let mut conn: Option<Tls> = None;
        while !self.stop.load(Ordering::Relaxed) {
            let m = match rx.recv_timeout(MSG_IDLE) {
                Ok(m) => m,
                Err(RecvTimeoutError::Timeout) => {
                    // Idle: close. Under the lock, so a message queued just now is not lost.
                    let mut q = lk(&self.msg_queues);
                    match rx.try_recv() {
                        Ok(m) => m,
                        Err(_) => {
                            q.remove(&id);
                            return;
                        }
                    }
                }
                Err(RecvTimeoutError::Disconnected) => return,
            };
            for attempt in 0..2 {
                match self.msg_once(&mut conn, &id, &m) {
                    Ok(()) => break,
                    Err(e) => {
                        conn = None; // a stale connection (peer restarted) is replaced once
                        if attempt == 1 || !self.is_trusted(&id) {
                            self.log(format!("{} to {id} failed: {e}", m["type"].as_str().unwrap_or("message")));
                        }
                    }
                }
            }
        }
    }
    // --- pairing -----------------------------------------------------------------------------------------

    fn run_pair(self: &Arc<Self>, mut tls: Tls, peer_id: &str, name: &str, incoming: bool) -> Result<(), String> {
        tls.timeouts(PAIR_TIMEOUT + Duration::from_secs(10));
        let code = sas_code(&tls.exporter()?, &self.id.device_id, peer_id);
        let (tx, rx) = channel();
        {
            let mut w = lk(&self.pair_wait);
            if w.len() >= 3 && !w.contains_key(peer_id) {
                return Err("too many pending pairings".into());
            }
            w.insert(peer_id.to_string(), tx);
        }
        self.emit(Event::PairRequest { peer_id: peer_id.into(), name: name.into(), code, incoming });
        let local = rx.recv_timeout(PAIR_TIMEOUT).unwrap_or(false);
        lk(&self.pair_wait).remove(peer_id);
        write_frame(&mut tls, &json!({"type":"pb.pair.response","body":{"accept":local}})).map_err(|e| e.code().to_string())?;
        let remote = read_frame(&mut tls).ok().map_or(false, |r| r["type"] == "pb.pair.response" && r["body"]["accept"] == true);
        let (ok, code, message) = match (local, remote) {
            (true, true) => (true, "", "paired"),
            (false, _) => (false, "DECLINED", "you declined or did not answer in time"),
            (true, false) => (false, "DECLINED_BY_PEER", "the other device declined or did not answer in time"),
        };
        if ok {
            self.add_trust(peer_id, name);
        }
        self.emit(Event::PairFinished { peer_id: peer_id.into(), name: name.into(), ok, code: code.into(), message: message.into() });
        Ok(())
    }

    // --- control connection ------------------------------------------------------------------------------

    fn run_control(self: &Arc<Self>, tls: Tls, peer_id: String, initiator: bool) -> Result<(), String> {
        let initiator_id = if initiator { self.id.device_id.clone() } else { peer_id.clone() };
        let gen = self.seq.fetch_add(1, Ordering::Relaxed);
        let sock = tls.tcp().try_clone().map_err(|e| e.to_string())?;
        {
            // One control connection per peer. On a simultaneous open the one dialed by the lower id wins,
            // and the same dialer replaces its own stale connection (peer restarted).
            let mut conns = lk(&self.conns);
            if let Some(old) = conns.get(&peer_id) {
                if old.initiator_id == initiator_id || initiator_id < old.initiator_id {
                    let _ = old.sock.shutdown(std::net::Shutdown::Both);
                } else {
                    let _ = tls.tcp().shutdown(std::net::Shutdown::Both);
                    return Ok(());
                }
            }
            conns.insert(peer_id.clone(), ConnHandle { initiator_id, sock, gen });
        }
        self.with_peer(&peer_id, |p| {
            p.backoff = Duration::from_secs(1);
            p.wait_since = None;
        });
        self.set_state(&peer_id, PeerState::Connected, "");
        tls.timeouts(Duration::from_secs(30));
        let r = if initiator { self.control_dialer(tls, &peer_id, gen) } else { self.control_listener(tls, &peer_id) };
        let mine = {
            let mut conns = lk(&self.conns);
            if conns.get(&peer_id).map_or(false, |c| c.gen == gen) {
                conns.remove(&peer_id);
                true
            } else {
                false
            }
        };
        if mine {
            // Dropped just now: keep redialing for a while (a Wi-Fi blip), then give up until it is heard again.
            self.with_peer(&peer_id, |p| p.seen = Instant::now());
            let detail = if self.is_trusted(&peer_id) { "connection lost" } else { "" };
            self.set_state(&peer_id, PeerState::Disconnected, detail);
        }
        r
    }

    fn still_current(&self, peer_id: &str, gen: u64) -> bool {
        !self.stop.load(Ordering::Relaxed) && self.is_trusted(peer_id) && lk(&self.conns).get(peer_id).map_or(false, |c| c.gen == gen)
    }

    fn control_dialer(&self, mut tls: Tls, peer_id: &str, gen: u64) -> Result<(), String> {
        loop {
            let until = Instant::now() + PING_EVERY;
            while Instant::now() < until {
                if !self.still_current(peer_id, gen) {
                    let _ = write_frame(&mut tls, &json!({"type":"pb.bye","body":{}}));
                    return Ok(());
                }
                thread::sleep(Duration::from_millis(250));
            }
            write_frame(&mut tls, &json!({"type":"pb.ping","body":{}})).map_err(|e| e.code().to_string())?;
            let r = read_frame(&mut tls).map_err(|e| e.code().to_string())?;
            if r["type"] != "pb.pong" {
                return Err("expected pong".into());
            }
        }
    }

    fn control_listener(&self, mut tls: Tls, peer_id: &str) -> Result<(), String> {
        loop {
            let m = read_frame(&mut tls).map_err(|e| e.code().to_string())?;
            if !self.is_trusted(peer_id) {
                return Ok(());
            }
            match m["type"].as_str() {
                Some("pb.ping") => write_frame(&mut tls, &json!({"type":"pb.pong","body":{}})).map_err(|e| e.code().to_string())?,
                Some("pb.bye") => return Ok(()),
                _ => {}
            }
        }
    }

    // --- connector: keeps control connections to trusted peers alive -------------------------------------

    fn connector_loop(self: Arc<Self>) {
        while !self.stop.load(Ordering::Relaxed) {
            let ids: Vec<String> = self.trusted.read().map(|t| t.iter().cloned().collect()).unwrap_or_default();
            for id in ids {
                let go = self.with_peer(&id, |p| {
                    if p.busy || p.state == PeerState::Connected || p.state == PeerState::Rejected {
                        return None;
                    }
                    let addr = p.addr?;
                    if p.seen.elapsed() > STALE_PEER {
                        return None; // off or away: wait to hear it instead of dialing a dead address forever
                    }
                    let now = Instant::now();
                    let since = *p.wait_since.get_or_insert(now);
                    // The lower id dials at once; the other waits a moment so we do not dial each other.
                    let grace = if self.id.device_id < id { Duration::ZERO } else { Duration::from_secs(6) };
                    if now < p.next_try || now.duration_since(since) < grace {
                        return None;
                    }
                    p.busy = true;
                    Some(addr)
                });
                if let Some(addr) = go {
                    self.set_state(&id, PeerState::Connecting, "");
                    let me = self.clone();
                    thread::spawn(move || me.dial_control(id, addr));
                }
            }
            thread::sleep(Duration::from_millis(1000));
        }
    }

    fn dial_control(self: Arc<Self>, id: String, addr: SocketAddr) {
        let r = (|| {
            let mut tls = self.dial(addr, Some(&id))?;
            self.hello_out(&mut tls, "control")?;
            self.run_control(tls, id.clone(), true)
        })();
        let mut state = (PeerState::Disconnected, String::new());
        let ok = r.is_ok();
        if let Err(e) = &r {
            if e == "NOT_TRUSTED" {
                state = (PeerState::Rejected, "the other device no longer trusts this one".into());
            } else if !self.stop.load(Ordering::Relaxed) {
                state.1 = format!("cannot reach {addr}: {e}");
            }
        }
        self.with_peer(&id, |p| {
            p.busy = false;
            p.wait_since = None;
            p.backoff = if ok { Duration::from_secs(1) } else { (p.backoff * 2).min(Duration::from_secs(30)) };
            p.next_try = Instant::now() + p.backoff;
        });
        if self.view(&id).state != PeerState::Connected {
            self.set_state(&id, state.0, &state.1);
        }
    }

    // --- transfers ---------------------------------------------------------------------------------------

    fn emit_progress(&self, m: &mut Meter, id: &str, done: u64, total: u64) {
        let now = Instant::now();
        match m.b {
            None => {
                m.b = Some(done);
                m.t = now;
                self.emit(Event::TransferProgress { id: id.into(), done, total, bytes_per_sec: 0 });
            }
            Some(b) => {
                let dt = now.duration_since(m.t).as_secs_f64();
                if dt >= 0.25 || done == total {
                    let inst = done.saturating_sub(b) as f64 / dt.max(1e-3);
                    m.rate = if m.rate == 0.0 { inst } else { 0.7 * m.rate + 0.3 * inst };
                    m.t = now;
                    m.b = Some(done);
                    self.emit(Event::TransferProgress { id: id.into(), done, total, bytes_per_sec: m.rate as u64 });
                }
            }
        }
    }

    fn finish(&self, x: &Xfer, r: Result<String, (&str, String)>) {
        lk(&self.xfers).remove(&x.id);
        let (ok, code, message, path) = match r {
            Ok(path) => (true, String::new(), String::new(), path),
            Err((c, m)) => (false, c.to_string(), m, String::new()),
        };
        let status = if ok { "done" } else if code == "CANCELLED" { "cancelled" } else { "failed" };
        let keep = if ok && x.incoming { path.clone() } else if x.src.starts_with("fd:") { String::new() } else { x.src.clone() };
        let _ = self.store.push_history(HistoryEntry {
            id: x.id.clone(),
            peer_id: x.peer_id.clone(),
            peer_name: x.peer_name.clone(),
            name: x.name.clone(),
            size: x.size,
            incoming: x.incoming,
            status: status.into(),
            code: code.clone(),
            message: message.clone(),
            time: now_secs(),
            path: keep,
        });
        self.emit(Event::TransferFinished { id: x.id.clone(), ok, code, message, path });
    }

    fn run_data_in(self: &Arc<Self>, tls: Tls, peer_id: &str) -> Result<(), String> {
        let mut tls = tls;
        tls.timeouts(Duration::from_secs(30));
        let peer_name = self.view(peer_id).name;
        let cancel = Arc::new(AtomicBool::new(false));
        let cell: Mutex<Option<Arc<Xfer>>> = Mutex::new(None);
        let sock = tls.tcp().try_clone().ok();
        let mut decide = |id: &str, name: &str, size: u64| -> Result<(), String> {
            let id = if id.is_empty() || id.len() > 64 { random_id() } else { id.to_string() };
            if lk(&self.cancelled).contains(&id) {
                return Err("cancelled".into());
            }
            let x = Arc::new(Xfer {
                id: id.clone(),
                peer_id: peer_id.into(),
                peer_name: peer_name.clone(),
                name: name.into(),
                size,
                incoming: true,
                src: String::new(),
                cancel: cancel.clone(),
                sock: Mutex::new(sock.as_ref().and_then(|s| s.try_clone().ok())),
            });
            if !self.auto_accept.load(Ordering::Relaxed) {
                let (tx, rx) = channel();
                lk(&self.offers).insert(id.clone(), tx);
                self.emit(Event::TransferOffer { id: id.clone(), peer_id: peer_id.into(), peer_name: peer_name.clone(), name: name.into(), size });
                let yes = rx.recv_timeout(OFFER_TIMEOUT).unwrap_or(false);
                lk(&self.offers).remove(&id);
                if !yes {
                    return Err("declined".into());
                }
            }
            if let Some(old) = lk(&self.xfers).insert(id.clone(), x.clone()) {
                old.cancel.store(true, Ordering::Relaxed); // stale record of a dropped connection
            }
            self.emit(Event::TransferStarted { id, peer_id: peer_id.into(), peer_name: peer_name.clone(), name: name.into(), size, incoming: true });
            *lk(&cell) = Some(x);
            Ok(())
        };
        let mut meter = Meter::new();
        let mut progress = |done: u64, total: u64| {
            if let Some(x) = lk(&cell).as_ref() {
                self.emit_progress(&mut meter, &x.id, done, total);
            }
        };
        let r = receive_file_ex(&mut tls, &self.download_dir, &mut decide, &cancel, &mut progress);
        let x = lk(&cell).take();
        match (r, x) {
            (Ok((_, path)), Some(x)) => self.finish(&x, Ok(path.to_string_lossy().into_owned())),
            (Err(TransferError::Rejected(_)), None) => {}
            (Err(e), Some(x)) => {
                let (c, m) = err_code(&e);
                self.finish(&x, Err((c, m)));
            }
            (Err(e), None) => return Err(format!("{e:?}")),
            (Ok(_), None) => {}
        }
        Ok(())
    }

    fn run_send(self: Arc<Self>, x: Arc<Xfer>, path: PathBuf) {
        let mut attempt = 0u32;
        let mut meter = Meter::new();
        let result = loop {
            if x.cancel.load(Ordering::Relaxed) {
                break Err(("CANCELLED", "cancelled".to_string()));
            }
            let outcome: Result<(), TransferError> = (|| {
                let addr = self.with_peer(&x.peer_id, |p| p.addr).ok_or_else(|| TransferError::Io("peer address unknown".into()))?;
                let mut tls = self.dial(addr, Some(&x.peer_id)).map_err(TransferError::Io)?;
                self.hello_out(&mut tls, "data").map_err(|e| if e == "NOT_TRUSTED" { TransferError::Rejected("the other device does not trust this one".into()) } else { TransferError::Io(e) })?;
                tls.timeouts(Duration::from_secs(30));
                *lk(&x.sock) = tls.tcp().try_clone().ok();
                let mut progress = |d: u64, t: u64| self.emit_progress(&mut meter, &x.id, d, t);
                send_file_ex(&mut tls, &path, &x.name, &x.id, DEFAULT_BLOCK, None, &x.cancel, &mut progress).map(|_| ())
            })();
            match outcome {
                Ok(()) => break Ok(String::new()),
                Err(e @ (TransferError::Cancelled | TransferError::Rejected(_) | TransferError::InvalidName | TransferError::Protocol(_))) => {
                    let (c, m) = err_code(&e);
                    break Err((c, m));
                }
                Err(e) => {
                    attempt += 1;
                    let (c, m) = err_code(&e);
                    if attempt >= MAX_SEND_ATTEMPTS || self.stop.load(Ordering::Relaxed) {
                        break Err((c, m));
                    }
                    let wait = Duration::from_secs((1u64 << attempt).min(30));
                    self.emit(Event::TransferNote { id: x.id.clone(), message: format!("{m}; retrying in {}s ({attempt}/{MAX_SEND_ATTEMPTS})", wait.as_secs()) });
                    let until = Instant::now() + wait;
                    while Instant::now() < until && !x.cancel.load(Ordering::Relaxed) {
                        thread::sleep(Duration::from_millis(200));
                    }
                    meter = Meter::new();
                }
            }
        };
        self.finish(&x, result);
    }

    // --- discovery ---------------------------------------------------------------------------------------

    /// UDP broadcast announcements. They only say "something is at ip:port"; identity is checked by the
    /// certificate when we connect. shortcut: assumes a /24 subnet for the directed broadcast; add
    /// interface enumeration (or mDNS) if it misses networks.
    fn discovery_loop(self: Arc<Self>) {
        let sock = match UdpSocket::bind(("0.0.0.0", self.discovery_port)) {
            Ok(s) => s,
            Err(e) => {
                *lk(&self.disco_status) = format!("discovery disabled: cannot bind UDP {}: {e}", self.discovery_port);
                return;
            }
        };
        let _ = sock.set_broadcast(true);
        let _ = sock.set_read_timeout(Some(Duration::from_secs(1)));
        *lk(&self.disco_status) = format!("discovery on UDP {}", self.discovery_port);
        let started = Instant::now();
        let mut next = Instant::now();
        let mut buf = [0u8; 1024];
        let announce = |to: SocketAddr| {
            let msg = json!({"type":"pb.announce","body":{"id":self.id.device_id,"name":self.my_name(),"port":self.port,"protocol":PROTOCOL}});
            let _ = sock.send_to(msg.to_string().as_bytes(), to);
        };
        while !self.stop.load(Ordering::Relaxed) {
            if Instant::now() >= next {
                // A phone only shouts for its first minutes; after that it listens and answers whoever appears
                // (battery, and no endless "searching" when the computer is off). Desktops keep the fast cadence.
                let quiet = QUIET_DISCOVERY && started.elapsed() > Duration::from_secs(120);
                next = Instant::now() + Duration::from_secs(if quiet { 30 } else { 4 });
                announce(SocketAddr::from((Ipv4Addr::BROADCAST, self.discovery_port)));
                if let Some(ip) = primary_ip() {
                    let o = ip.octets();
                    announce(SocketAddr::from((Ipv4Addr::new(o[0], o[1], o[2], 255), self.discovery_port)));
                }
            }
            if let Ok((n, from)) = sock.recv_from(&mut buf) {
                let Ok(v) = serde_json::from_slice::<Value>(&buf[..n]) else { continue };
                let b = &v["body"];
                if v["type"] != "pb.announce" || b["protocol"].as_u64() != Some(PROTOCOL) {
                    continue;
                }
                let (Some(id), Some(port)) = (b["id"].as_str(), b["port"].as_u64()) else { continue };
                if id.len() != 64 || port == 0 || port > 65535 {
                    continue;
                }
                // Someone new (or back after a silence): answer at once so they find us without waiting our slow cadence.
                if self.note_peer(id, b["name"].as_str().unwrap_or(""), Some(SocketAddr::new(from.ip(), port as u16))) {
                    announce(SocketAddr::new(from.ip(), self.discovery_port));
                }
            }
        }
    }

    fn sweep_loop(self: Arc<Self>) {
        while !self.stop.load(Ordering::Relaxed) {
            thread::sleep(Duration::from_secs(5));
            let gone: Vec<String> = {
                let mut peers = lk(&self.peers);
                let dead: Vec<String> = peers
                    .iter()
                    .filter(|(id, p)| !self.is_trusted(id) && p.state != PeerState::Connected && p.seen.elapsed() > Duration::from_secs(25))
                    .map(|(id, _)| id.clone())
                    .collect();
                for id in &dead {
                    peers.remove(id);
                }
                dead
            };
            for id in gone {
                self.emit(Event::PeerGone { id });
            }
        }
    }
}

// ---------------------------------------------------------------------------------------------------------
// Public API

pub struct Engine {
    inner: Arc<Inner>,
}

impl Engine {
    pub fn start(cfg: Config, sink: Arc<dyn EventSink>) -> Result<Engine, String> {
        let store = Store::open(&cfg.data_dir)?;
        let id = store.identity(&cfg.name)?;
        let trusted = Arc::new(RwLock::new(store.peers().into_iter().map(|p| p.id).collect::<HashSet<_>>()));
        let server_cfg = server_config(&id, Verifier::shared(trusted.clone(), true)).map_err(|e| e.to_string())?;
        let listener = TcpListener::bind(("0.0.0.0", cfg.port)).map_err(|e| format!("cannot listen on TCP {}: {e}", cfg.port))?;
        let port = listener.local_addr().map_err(|e| e.to_string())?.port();
        std::fs::create_dir_all(&cfg.download_dir).map_err(|e| e.to_string())?;
        let inner = Arc::new(Inner {
            id,
            store,
            download_dir: cfg.download_dir,
            name: RwLock::new(clean(&cfg.name)),
            auto_accept: AtomicBool::new(cfg.auto_accept),
            port,
            discovery_port: cfg.discovery_port,
            trusted,
            server_cfg,
            peers: Mutex::new(HashMap::new()),
            pair_wait: Mutex::new(HashMap::new()),
            conns: Mutex::new(HashMap::new()),
            xfers: Mutex::new(HashMap::new()),
            cancelled: Mutex::new(HashSet::new()),
            offers: Mutex::new(HashMap::new()),
            sink,
            stop: AtomicBool::new(false),
            seq: AtomicU64::new(1),
            inflight: AtomicUsize::new(0),
            disco_status: Mutex::new(if cfg.discovery_port == 0 { "discovery off".into() } else { "starting".into() }),
            msg_queues: Mutex::new(HashMap::new()),
        });
        let me = inner.clone();
        thread::spawn(move || {
            for c in listener.incoming() {
                if me.stop.load(Ordering::Relaxed) {
                    break;
                }
                let Ok(tcp) = c else { continue };
                if me.inflight.fetch_add(1, Ordering::Relaxed) >= MAX_HANDSHAKES * 4 {
                    me.inflight.fetch_sub(1, Ordering::Relaxed);
                    continue; // shortcut: global cap, no per-IP limit; add one before exposing to hostile LANs
                }
                let me2 = me.clone();
                thread::spawn(move || {
                    if let Err(e) = me2.handle_incoming(tcp) {
                        me2.log(format!("incoming connection: {e}"));
                    }
                    me2.inflight.fetch_sub(1, Ordering::Relaxed);
                });
            }
        });
        let me = inner.clone();
        thread::spawn(move || me.connector_loop());
        let me = inner.clone();
        thread::spawn(move || me.sweep_loop());
        if cfg.discovery_port != 0 {
            let me = inner.clone();
            thread::spawn(move || me.discovery_loop());
        }
        Ok(Engine { inner })
    }

    pub fn device_id(&self) -> String {
        self.inner.id.device_id.clone()
    }

    pub fn port(&self) -> u16 {
        self.inner.port
    }

    pub fn name(&self) -> String {
        self.inner.my_name()
    }

    pub fn set_name(&self, name: &str) {
        if let Ok(mut n) = self.inner.name.write() {
            *n = clean(name);
        }
    }

    pub fn set_auto_accept(&self, on: bool) {
        self.inner.auto_accept.store(on, Ordering::Relaxed);
    }

    /// Trusted devices plus everything discovered recently.
    pub fn peers(&self) -> Vec<PeerView> {
        let mut ids: HashSet<String> = lk(&self.inner.peers).keys().cloned().collect();
        ids.extend(self.inner.store.peers().into_iter().map(|p| p.id));
        let mut v: Vec<PeerView> = ids.iter().map(|i| self.inner.view(i)).collect();
        v.sort_by(|a, b| b.trusted.cmp(&a.trusted).then(a.name.cmp(&b.name)));
        v
    }

    /// Start pairing with a device by id (its address must be known) or directly by `ip[:port]`.
    pub fn pair_with_peer(&self, peer_id: &str) -> Result<(), String> {
        let addr = self.inner.with_peer(peer_id, |p| p.addr).ok_or("address of that device is unknown")?;
        self.pair_addr_parsed(addr);
        Ok(())
    }

    pub fn pair_with_addr(&self, addr: &str) -> Result<(), String> {
        let with_port = if addr.contains(':') && !addr.ends_with(']') { addr.to_string() } else { format!("{addr}:{DEFAULT_PORT}") };
        let a = with_port.to_socket_addrs().map_err(|e| format!("bad address: {e}"))?.next().ok_or("bad address")?;
        self.pair_addr_parsed(a);
        Ok(())
    }

    fn pair_addr_parsed(&self, addr: SocketAddr) {
        let me = self.inner.clone();
        thread::spawn(move || {
            let r = (|| {
                let mut tls = me.dial(addr, None)?;
                let peer_id = tls.peer_id()?;
                if me.is_trusted(&peer_id) {
                    // Already paired: this address is one more route to it (USB cable, VPN). Dial it right away.
                    me.note_peer(&peer_id, "", Some(addr));
                    me.with_peer(&peer_id, |p| p.wait_since = Instant::now().checked_sub(Duration::from_secs(6)));
                    return Ok(());
                }
                let name = me.hello_out(&mut tls, "pair")?;
                me.note_peer(&peer_id, &name, Some(addr));
                me.run_pair(tls, &peer_id, &name, false)
            })();
            if let Err(e) = r {
                me.emit(Event::PairFinished { peer_id: String::new(), name: String::new(), ok: false, code: "CONNECT".into(), message: e });
            }
        });
    }

    /// Answer a `PairRequest`.
    pub fn respond_pair(&self, peer_id: &str, accept: bool) {
        if let Some(tx) = lk(&self.inner.pair_wait).get(peer_id) {
            let _ = tx.send(accept);
        }
    }

    /// Forget a device: its next handshake is refused and any open connection is closed.
    pub fn revoke(&self, peer_id: &str) -> Result<(), String> {
        if let Ok(mut t) = self.inner.trusted.write() {
            t.remove(peer_id);
        }
        let mut list = self.inner.store.peers();
        list.retain(|p| p.id != peer_id);
        self.inner.store.save_peers(&list)?;
        if let Some(c) = lk(&self.inner.conns).get(peer_id) {
            let _ = c.sock.shutdown(std::net::Shutdown::Both);
        }
        self.inner.set_state(peer_id, PeerState::Disconnected, "");
        self.inner.changed(peer_id);
        Ok(())
    }

    /// Queue a file for a trusted peer. `display_name` overrides the name the receiver sees.
    pub fn send_file(&self, peer_id: &str, path: &Path, display_name: Option<&str>) -> Result<String, String> {
        if !self.inner.is_trusted(peer_id) {
            return Err("that device is not paired".into());
        }
        let name = match display_name {
            Some(n) => n.to_string(),
            None => path.file_name().and_then(|n| n.to_str()).ok_or("file has no usable name")?.to_string(),
        };
        safe_name(&name).map_err(|_| "file name not allowed".to_string())?;
        let size = crate::transfer::open_source(path).and_then(|f| f.metadata()).map_err(|e| format!("cannot read file: {e}"))?.len();
        let id = random_id();
        let x = Arc::new(Xfer {
            id: id.clone(),
            peer_id: peer_id.into(),
            peer_name: self.inner.view(peer_id).name,
            name: name.clone(),
            size,
            incoming: false,
            src: path.to_string_lossy().into_owned(),
            cancel: Arc::new(AtomicBool::new(false)),
            sock: Mutex::new(None),
        });
        lk(&self.inner.xfers).insert(id.clone(), x.clone());
        self.inner.emit(Event::TransferStarted { id: id.clone(), peer_id: peer_id.into(), peer_name: x.peer_name.clone(), name, size, incoming: false });
        let me = self.inner.clone();
        let p = path.to_path_buf();
        thread::spawn(move || me.run_send(x, p));
        Ok(id)
    }

    /// Sends an app message (`kind` must start with `pb.x.`) to a paired, reachable device. Returns at once;
    /// delivery runs in the background and a failure is reported as a `Log` event.
    pub fn send_message(&self, peer_id: &str, kind: &str, body: Value) -> Result<(), String> {
        if !app_kind(kind) {
            return Err("message kind must start with pb.x.".into());
        }
        if !self.inner.is_trusted(peer_id) {
            return Err("that device is not paired".into());
        }
        self.inner.with_peer(peer_id, |p| p.addr).ok_or("that device has not been seen on the network")?;
        let m = json!({"type": kind, "body": body});
        if m.to_string().len() > MAX_APP_BODY {
            return Err("message too large".into());
        }
        let mut q = lk(&self.inner.msg_queues);
        if let Some(tx) = q.get(peer_id) {
            if tx.send(m.clone()).is_ok() {
                return Ok(());
            }
        }
        let (tx, rx) = channel();
        let _ = tx.send(m);
        q.insert(peer_id.to_string(), tx);
        let (me, id) = (self.inner.clone(), peer_id.to_string());
        thread::spawn(move || me.msg_worker(id, rx));
        Ok(())
    }

    pub fn respond_transfer(&self, id: &str, accept: bool) {
        if let Some(tx) = lk(&self.inner.offers).get(id) {
            let _ = tx.send(accept);
        }
    }

    /// Cancel an active transfer. Cancelling a receive deletes its `.part`; cancelling a send tells the receiver.
    pub fn cancel_transfer(&self, id: &str) {
        self.respond_transfer(id, false);
        let Some(x) = lk(&self.inner.xfers).get(id).cloned() else { return };
        x.cancel.store(true, Ordering::Relaxed);
        if x.incoming {
            lk(&self.inner.cancelled).insert(id.to_string());
        }
        // A sender notices the flag at the next block and says goodbye; the socket is cut only if it is stuck.
        let delay = if x.incoming { Duration::ZERO } else { Duration::from_secs(5) };
        thread::spawn(move || {
            thread::sleep(delay);
            if let Some(s) = lk(&x.sock).as_ref() {
                let _ = s.shutdown(std::net::Shutdown::Both);
            }
        });
    }

    pub fn history(&self) -> Vec<HistoryEntry> {
        self.inner.store.history()
    }

    pub fn remove_history(&self, id: &str) -> Result<(), String> {
        self.inner.store.remove_history(id)
    }

    pub fn clear_history(&self) -> Result<(), String> {
        self.inner.store.clear_history()
    }

    /// Send a failed outgoing transfer again (the receiver resumes from its `.part`).
    pub fn retry(&self, history_id: &str) -> Result<String, String> {
        let h = self.inner.store.history().into_iter().find(|h| h.id == history_id).ok_or("no such transfer")?;
        if h.incoming || h.path.is_empty() {
            return Err("this transfer cannot be retried".into());
        }
        self.send_file(&h.peer_id, Path::new(&h.path), Some(&h.name))
    }

    /// Human-readable network facts for the "why can't I connect" screen (F14).
    pub fn diagnostics(&self) -> Vec<String> {
        vec![
            format!("device id: {}", self.inner.id.device_id),
            format!("listening on TCP {}", self.inner.port),
            lk(&self.inner.disco_status).clone(),
            format!("local address: {}", primary_ip().map_or("none (no network?)".to_string(), |i| i.to_string())),
        ]
    }

    pub fn shutdown(&self) {
        self.inner.stop.store(true, Ordering::Relaxed);
        for c in lk(&self.inner.conns).values() {
            let _ = c.sock.shutdown(std::net::Shutdown::Both);
        }
        // Cut running transfers without the cancel flag: the receiver keeps its `.part` so a restart resumes.
        for x in lk(&self.inner.xfers).values() {
            if let Some(s) = lk(&x.sock).as_ref() {
                let _ = s.shutdown(std::net::Shutdown::Both);
            }
        }
        let _ = TcpStream::connect_timeout(&SocketAddr::from((Ipv4Addr::LOCALHOST, self.inner.port)), Duration::from_millis(300));
    }
}

impl Drop for Engine {
    fn drop(&mut self) {
        self.shutdown();
    }
}
