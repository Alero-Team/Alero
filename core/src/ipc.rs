//! Local control of an engine that runs in another process (desktop: the tray daemon drives it, the Flutter
//! window is a client). JSON lines over 127.0.0.1 on an ephemeral port. The first line of every connection must
//! be the random token stored in `ipc.json` inside the user's data dir, so only that user can drive the engine.
//!
//! Requests get one reply line: `{"Ok": value}` or `{"Err": "message"}`. A connection that sends `Subscribe`
//! becomes a one-way stream of `Push` lines.

use std::fs;
use std::io::{self, BufRead, BufReader, Read, Write};
use std::net::{TcpListener, TcpStream};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Duration;

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

use crate::engine::{Config, Engine, Event};

pub const IPC_FILE: &str = "ipc.json";

/// How the window starts the daemon: `pb_daemon <Launch as JSON>`.
#[derive(Serialize, Deserialize, Debug)]
pub struct Launch {
    pub config: Config,
    /// The window executable, started again when the user (or an incoming request) needs it.
    pub ui: PathBuf,
}

#[derive(Serialize, Deserialize, Debug)]
#[serde(tag = "cmd")]
pub enum Cmd {
    DeviceId,
    Name,
    SetName { name: String },
    SetAutoAccept { on: bool },
    Peers,
    PairPeer { id: String },
    PairAddr { addr: String },
    RespondPair { id: String, accept: bool },
    Revoke { id: String },
    Disconnect { id: String },
    Connect { id: String },
    SendFile { peer: String, path: String, name: Option<String> },
    RespondTransfer { id: String, accept: bool },
    Cancel { id: String },
    History,
    ClearHistory,
    RemoveHistory { id: String },
    Retry { id: String },
    Diagnostics,
    SendMessage { peer: String, kind: String, body: Value },
    Subscribe,
}

/// What the daemon pushes to subscribed windows.
#[derive(Serialize, Deserialize, Debug, Clone)]
#[serde(tag = "push")]
pub enum Push {
    Event { event: Event },
    /// Bring the window to the front.
    Show,
    /// The user chose "Salir" in the tray.
    Quit,
}

impl Push {
    /// Events that need an answer from the user: kept for the next window if none is open.
    fn needs_user(&self) -> bool {
        matches!(self, Push::Event { event: Event::PairRequest { .. } | Event::TransferOffer { .. } })
    }
}

/// Runs one command against a local engine. The bridge uses it too, so both sides share one mapping.
pub fn exec(e: &Engine, c: Cmd) -> Result<Value, String> {
    Ok(match c {
        Cmd::DeviceId => json!(e.device_id()),
        Cmd::Name => json!(e.name()),
        Cmd::SetName { name } => json!(e.set_name(&name)),
        Cmd::SetAutoAccept { on } => json!(e.set_auto_accept(on)),
        Cmd::Peers => json!(e.peers()),
        Cmd::PairPeer { id } => json!(e.pair_with_peer(&id)?),
        Cmd::PairAddr { addr } => json!(e.pair_with_addr(addr.trim())?),
        Cmd::RespondPair { id, accept } => json!(e.respond_pair(&id, accept)),
        Cmd::Revoke { id } => json!(e.revoke(&id)?),
        Cmd::Disconnect { id } => json!(e.disconnect(&id)?),
        Cmd::Connect { id } => json!(e.connect(&id)?),
        Cmd::SendFile { peer, path, name } => json!(e.send_file(&peer, Path::new(&path), name.as_deref())?),
        Cmd::RespondTransfer { id, accept } => json!(e.respond_transfer(&id, accept)),
        Cmd::Cancel { id } => json!(e.cancel_transfer(&id)),
        Cmd::History => json!(e.history()),
        Cmd::ClearHistory => json!(e.clear_history()?),
        Cmd::RemoveHistory { id } => json!(e.remove_history(&id)?),
        Cmd::Retry { id } => json!(e.retry(&id)?),
        Cmd::Diagnostics => json!(e.diagnostics()),
        Cmd::SendMessage { peer, kind, body } => json!(e.send_message(&peer, &kind, body)?),
        Cmd::Subscribe => return Err("Subscribe solo vale como orden de conexión".into()),
    })
}

/// Open windows. Pushes that need the user and reach nobody are replayed to the next window that subscribes.
#[derive(Default)]
pub struct Subscribers(Mutex<Subs>);

#[derive(Default)]
struct Subs {
    next: u64,
    conns: Vec<(u64, TcpStream)>,
    pending: Vec<String>,
}

impl Subscribers {
    /// Returns whether at least one window got it.
    pub fn push(&self, p: &Push) -> bool {
        let line = serde_json::to_string(p).expect("push serializes") + "\n";
        let mut s = self.0.lock().unwrap();
        s.conns.retain_mut(|(_, c)| c.write_all(line.as_bytes()).is_ok());
        let delivered = !s.conns.is_empty();
        if !delivered && p.needs_user() {
            s.pending.push(line);
        }
        delivered
    }

    fn add(&self, mut c: TcpStream) -> io::Result<u64> {
        let mut s = self.0.lock().unwrap();
        for line in std::mem::take(&mut s.pending) {
            c.write_all(line.as_bytes())?;
        }
        s.next += 1;
        let id = s.next;
        s.conns.push((id, c));
        Ok(id)
    }

    fn remove(&self, id: u64) {
        self.0.lock().unwrap().conns.retain(|(i, _)| *i != id);
    }
}

/// Binds the control port, writes `ipc.json` with a fresh token and serves clients on background threads.
pub fn listen(data_dir: &Path, engine: Arc<Engine>, subs: Arc<Subscribers>) -> io::Result<()> {
    let l = TcpListener::bind(("127.0.0.1", 0))?;
    let mut raw = [0u8; 32];
    getrandom::getrandom(&mut raw).map_err(|e| io::Error::other(e.to_string()))?;
    let token: String = raw.iter().map(|b| format!("{b:02x}")).collect();
    let info = json!({ "port": l.local_addr()?.port(), "token": token });
    fs::write(data_dir.join(IPC_FILE), info.to_string())?;
    thread::spawn(move || {
        for s in l.incoming().flatten() {
            let (token, engine, subs) = (token.clone(), engine.clone(), subs.clone());
            thread::spawn(move || {
                let _ = serve(s, &token, &engine, &subs);
            });
        }
    });
    Ok(())
}

fn serve(s: TcpStream, token: &str, engine: &Engine, subs: &Subscribers) -> io::Result<()> {
    let mut r = BufReader::new(s.try_clone()?);
    let mut w = s;
    let mut line = String::new();
    // Unauthenticated input: bounded read, bounded wait (a silent local client must not keep a thread),
    // constant-time compare.
    w.set_read_timeout(Some(Duration::from_secs(5)))?;
    (&mut r).take(128).read_line(&mut line)?;
    if !same(line.trim_end().as_bytes(), token.as_bytes()) {
        return Ok(());
    }
    w.set_read_timeout(None)?;
    loop {
        line.clear();
        if r.read_line(&mut line)? == 0 {
            return Ok(());
        }
        let reply = match serde_json::from_str::<Cmd>(&line) {
            Ok(Cmd::Subscribe) => {
                w.set_write_timeout(Some(Duration::from_secs(2)))?;
                let id = subs.add(w)?;
                // Keep reading so a closed window is dropped at once, not at the next push.
                let _ = io::copy(&mut r, &mut io::sink());
                subs.remove(id);
                return Ok(());
            }
            Ok(c) => exec(engine, c),
            Err(e) => Err(format!("orden no válida: {e}")),
        };
        w.write_all((serde_json::to_string(&reply)? + "\n").as_bytes())?;
    }
}

fn same(a: &[u8], b: &[u8]) -> bool {
    a.len() == b.len() && a.iter().zip(b).fold(0, |x, (p, q)| x | (p ^ q)) == 0
}

/// A window's connection to the daemon.
pub struct Client {
    r: BufReader<TcpStream>,
    w: TcpStream,
}

impl Client {
    pub fn connect(data_dir: &Path) -> io::Result<Client> {
        let info: Value = serde_json::from_slice(&fs::read(data_dir.join(IPC_FILE))?)?;
        let bad = || io::Error::other("ipc.json no válido");
        let port = info["port"].as_u64().and_then(|p| u16::try_from(p).ok()).ok_or_else(bad)?;
        let token = info["token"].as_str().ok_or_else(bad)?;
        let mut w = TcpStream::connect(("127.0.0.1", port))?;
        w.write_all(format!("{token}\n").as_bytes())?;
        Ok(Client { r: BufReader::new(w.try_clone()?), w })
    }

    pub fn call(&mut self, c: &Cmd) -> Result<Value, String> {
        let lost = |e: io::Error| format!("sin conexión con el servicio en segundo plano: {e}");
        self.w.write_all((serde_json::to_string(c).map_err(|e| e.to_string())? + "\n").as_bytes()).map_err(lost)?;
        let mut line = String::new();
        if self.r.read_line(&mut line).map_err(lost)? == 0 {
            return Err(lost(io::ErrorKind::UnexpectedEof.into()));
        }
        serde_json::from_str::<Result<Value, String>>(&line).map_err(|e| e.to_string())?
    }

    /// Turns this connection into the push stream and calls `f` for each push until the daemon goes away.
    pub fn subscribe(mut self, mut f: impl FnMut(Push)) -> io::Result<()> {
        self.w.write_all((serde_json::to_string(&Cmd::Subscribe)? + "\n").as_bytes())?;
        for line in self.r.lines() {
            if let Ok(p) = serde_json::from_str(&line?) {
                f(p);
            }
        }
        Ok(())
    }
}
