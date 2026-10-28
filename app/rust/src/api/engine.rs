//! Dart surface of `pb-core`. Thin on purpose: every rule (trust, pairing, transfer) lives in the core; this file
//! only converts types and forwards calls.
//!
//! Android: the engine is one per process and outlives the Dart side (the foreground service keeps the process
//! alive). Desktop: the engine lives in the tray daemon (`alero_daemon`) and every call goes over `pb_core::ipc`, so
//! closing the window frees Flutter's memory. Either way a new UI calls `start` (no-op if done) and `events` again
//! to re-attach.

use std::sync::{Arc, Mutex};

use pb_core::engine as core;
use pb_core::ipc::{self, Cmd};
use pb_core::store::HistoryEntry;

use crate::frb_generated::StreamSink;

pub struct Config {
    pub data_dir: String,
    pub download_dir: String,
    pub name: String,
    pub port: u16,
    pub discovery_port: u16,
    pub auto_accept: bool,
}

pub enum PeerState {
    Disconnected,
    Connecting,
    Connected,
    Rejected,
}

pub struct Peer {
    pub id: String,
    pub name: String,
    pub addr: String,
    pub state: PeerState,
    pub trusted: bool,
    pub detail: String,
}

pub struct HistoryItem {
    pub id: String,
    pub peer_id: String,
    pub peer_name: String,
    pub name: String,
    pub size: u64,
    pub incoming: bool,
    /// "done" | "failed" | "cancelled"
    pub status: String,
    pub code: String,
    pub message: String,
    pub time: u64,
    pub path: String,
}

pub enum Event {
    PeerChanged { peer: Peer },
    PeerGone { id: String },
    PairRequest { peer_id: String, name: String, code: String, incoming: bool },
    PairFinished { peer_id: String, name: String, ok: bool, code: String, message: String },
    TransferOffer { id: String, peer_id: String, peer_name: String, name: String, size: u64 },
    TransferStarted { id: String, peer_id: String, peer_name: String, name: String, size: u64, incoming: bool },
    TransferProgress { id: String, done: u64, total: u64, bytes_per_sec: u64 },
    TransferNote { id: String, message: String },
    TransferFinished { id: String, ok: bool, code: String, message: String, path: String },
    Log { message: String },
    /// App message from a paired device (`pb.x.*`); `body` is JSON text.
    Message { peer_id: String, kind: String, body: String },
    /// Desktop: the tray asks to bring the window up.
    Show,
    /// Desktop: the user chose "Salir" in the tray.
    Quit,
}

#[flutter_rust_bridge::frb(init)]
pub fn init_app() {
    flutter_rust_bridge::setup_default_user_utils();
}

enum Backend {
    Local(Arc<core::Engine>),
    Remote(Mutex<ipc::Client>),
}

static BACKEND: Mutex<Option<Arc<Backend>>> = Mutex::new(None);
static SINK: Mutex<Option<StreamSink<Event>>> = Mutex::new(None);
const REMOTE: bool = cfg!(not(any(target_os = "android", target_os = "ios")));

fn emit(e: Event) {
    // No UI attached (or it went away): drop the event; the UI re-reads state when it attaches.
    if let Some(s) = SINK.lock().unwrap().as_ref() {
        let _ = s.add(e);
    }
}

struct Forward;

impl core::EventSink for Forward {
    fn on_event(&self, e: core::Event) {
        #[cfg(target_os = "android")]
        crate::jni_api::push(&e);
        emit(event(e));
    }
}

pub(crate) fn call(c: Cmd) -> Result<serde_json::Value, String> {
    let b = BACKEND.lock().unwrap().clone().ok_or_else(|| "El motor no está iniciado".to_string())?;
    match &*b {
        Backend::Local(e) => ipc::exec(e, c),
        Backend::Remote(cl) => cl.lock().unwrap().call(&c),
    }
}

fn get<T: serde::de::DeserializeOwned>(c: Cmd) -> Result<T, String> {
    serde_json::from_value(call(c)?).map_err(|e| e.to_string())
}

/// Starts the engine (Android) or connects to the daemon, starting it if needed (desktop). No-op if already
/// done. Returns this device's id.
pub fn start(config: Config) -> Result<String, String> {
    let mut slot = BACKEND.lock().unwrap();
    if slot.is_none() {
        let cfg = core::Config {
            data_dir: config.data_dir.into(),
            download_dir: config.download_dir.into(),
            name: config.name,
            port: config.port,
            discovery_port: config.discovery_port,
            auto_accept: config.auto_accept,
        };
        let b = if REMOTE { connect(cfg)? } else { Backend::Local(Arc::new(core::Engine::start(cfg, Arc::new(Forward))?)) };
        *slot = Some(Arc::new(b));
    }
    drop(slot);
    get(Cmd::DeviceId)
}

/// Connects to a running daemon, or starts one with `cfg` (the window's settings) and waits for it.
fn connect(cfg: core::Config) -> Result<Backend, String> {
    let data = cfg.data_dir.clone();
    let alive = ipc::Client::connect(&data).ok().and_then(|mut c| c.call(&Cmd::DeviceId).ok().map(|_| c));
    let client = match alive {
        Some(c) => c,
        None => {
            let exe = std::env::current_exe().map_err(|e| e.to_string())?;
            let daemon = exe.with_file_name(if cfg!(windows) { "alero_daemon.exe" } else { "alero_daemon" });
            let _ = std::fs::remove_file(data.join(ipc::IPC_FILE));
            let launch = serde_json::to_string(&ipc::Launch { config: cfg, ui: exe }).map_err(|e| e.to_string())?;
            std::process::Command::new(&daemon)
                .arg(launch)
                .spawn()
                .map_err(|e| format!("no se pudo lanzar {}: {e}", daemon.display()))?;
            let mut tries = 0;
            loop {
                std::thread::sleep(std::time::Duration::from_millis(100));
                if let Ok(c) = ipc::Client::connect(&data) {
                    break c;
                }
                tries += 1;
                if tries == 50 {
                    let why = std::fs::read_to_string(data.join("daemon-error.txt")).unwrap_or_else(|_| "no responde".into());
                    return Err(format!("el servicio en segundo plano no arrancó: {why}"));
                }
            }
        }
    };
    let sub = ipc::Client::connect(&data).map_err(|e| e.to_string())?;
    std::thread::spawn(move || {
        let _ = sub.subscribe(|p| match p {
            ipc::Push::Event { event: e } => emit(event(e)),
            ipc::Push::Show => emit(Event::Show),
            ipc::Push::Quit => emit(Event::Quit),
        });
    });
    Ok(Backend::Remote(Mutex::new(client)))
}

/// Engine events for the current UI. Calling it again replaces the previous listener.
pub fn events(sink: StreamSink<Event>) {
    *SINK.lock().unwrap() = Some(sink);
}

/// Android: stops the engine. Desktop: only disconnects; the daemon keeps running (its tray has "Salir").
pub fn shutdown() {
    if let Some(b) = BACKEND.lock().unwrap().take() {
        if let Backend::Local(e) = &*b {
            e.shutdown();
        }
    }
}

#[flutter_rust_bridge::frb(sync)]
pub fn default_port() -> u16 {
    core::DEFAULT_PORT
}

pub fn device_name() -> Result<String, String> {
    get(Cmd::Name)
}

pub fn set_name(name: String) -> Result<(), String> {
    call(Cmd::SetName { name }).map(drop)
}

pub fn set_auto_accept(on: bool) -> Result<(), String> {
    call(Cmd::SetAutoAccept { on }).map(drop)
}

pub fn peers() -> Result<Vec<Peer>, String> {
    Ok(get::<Vec<core::PeerView>>(Cmd::Peers)?.into_iter().map(peer).collect())
}

pub fn pair_with_peer(peer_id: String) -> Result<(), String> {
    call(Cmd::PairPeer { id: peer_id }).map(drop)
}

pub fn pair_with_addr(addr: String) -> Result<(), String> {
    call(Cmd::PairAddr { addr }).map(drop)
}

pub fn respond_pair(peer_id: String, accept: bool) -> Result<(), String> {
    call(Cmd::RespondPair { id: peer_id, accept }).map(drop)
}

pub fn revoke(peer_id: String) -> Result<(), String> {
    call(Cmd::Revoke { id: peer_id }).map(drop)
}

/// `path` may be `fd:N` (Android: a descriptor the app opened for a content URI); `display_name` is then required.
/// Returns the transfer id.
pub fn send_file(peer_id: String, path: String, display_name: Option<String>) -> Result<String, String> {
    get(Cmd::SendFile { peer: peer_id, path, name: display_name })
}

pub fn respond_transfer(id: String, accept: bool) -> Result<(), String> {
    call(Cmd::RespondTransfer { id, accept }).map(drop)
}

pub fn cancel_transfer(id: String) -> Result<(), String> {
    call(Cmd::Cancel { id }).map(drop)
}

pub fn history() -> Result<Vec<HistoryItem>, String> {
    Ok(get::<Vec<HistoryEntry>>(Cmd::History)?
        .into_iter()
        .map(|h| HistoryItem {
            id: h.id,
            peer_id: h.peer_id,
            peer_name: h.peer_name,
            name: h.name,
            size: h.size,
            incoming: h.incoming,
            status: h.status,
            code: h.code,
            message: h.message,
            time: h.time,
            path: h.path,
        })
        .collect())
}

/// Removes one record from the list; never deletes the file itself.
pub fn remove_history(id: String) -> Result<(), String> {
    call(Cmd::RemoveHistory { id }).map(drop)
}

pub fn clear_history() -> Result<(), String> {
    call(Cmd::ClearHistory).map(drop)
}

/// Returns the new transfer id.
pub fn retry(history_id: String) -> Result<String, String> {
    get(Cmd::Retry { id: history_id })
}

/// Sends an app message; `body` is JSON text.
pub fn send_message(peer_id: String, kind: String, body: String) -> Result<(), String> {
    let body = serde_json::from_str(&body).map_err(|e| e.to_string())?;
    call(Cmd::SendMessage { peer: peer_id, kind, body }).map(drop)
}

pub fn diagnostics() -> Result<Vec<String>, String> {
    get(Cmd::Diagnostics)
}

fn peer(p: core::PeerView) -> Peer {
    Peer {
        id: p.id,
        name: p.name,
        addr: p.addr,
        state: match p.state {
            core::PeerState::Disconnected => PeerState::Disconnected,
            core::PeerState::Connecting => PeerState::Connecting,
            core::PeerState::Connected => PeerState::Connected,
            core::PeerState::Rejected => PeerState::Rejected,
        },
        trusted: p.trusted,
        detail: p.detail,
    }
}

fn event(e: core::Event) -> Event {
    use core::Event as E;
    match e {
        E::PeerChanged { peer: p } => Event::PeerChanged { peer: peer(p) },
        E::PeerGone { id } => Event::PeerGone { id },
        E::PairRequest { peer_id, name, code, incoming } => Event::PairRequest { peer_id, name, code, incoming },
        E::PairFinished { peer_id, name, ok, code, message } => Event::PairFinished { peer_id, name, ok, code, message },
        E::TransferOffer { id, peer_id, peer_name, name, size } => Event::TransferOffer { id, peer_id, peer_name, name, size },
        E::TransferStarted { id, peer_id, peer_name, name, size, incoming } => {
            Event::TransferStarted { id, peer_id, peer_name, name, size, incoming }
        }
        E::TransferProgress { id, done, total, bytes_per_sec } => Event::TransferProgress { id, done, total, bytes_per_sec },
        E::TransferNote { id, message } => Event::TransferNote { id, message },
        E::TransferFinished { id, ok, code, message, path } => Event::TransferFinished { id, ok, code, message, path },
        E::Log { message } => Event::Log { message },
        E::Message { peer_id, kind, body } => Event::Message { peer_id, kind, body: body.to_string() },
    }
}
