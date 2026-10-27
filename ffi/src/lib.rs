//! UniFFI surface of `pb-core` for Kotlin. Thin on purpose: every rule (trust, pairing, transfer) lives in
//! the core; this file only converts types and forwards calls.

use std::path::Path;
use std::sync::Arc;

use pb_core::engine as core;

uniffi::setup_scaffolding!();

#[derive(Debug, uniffi::Error)]
#[uniffi(flat_error)]
pub enum PbError {
    Failed(String),
}

impl std::fmt::Display for PbError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            PbError::Failed(m) => f.write_str(m),
        }
    }
}

impl std::error::Error for PbError {}

impl From<String> for PbError {
    fn from(m: String) -> Self {
        PbError::Failed(m)
    }
}

#[derive(uniffi::Record)]
pub struct Config {
    pub data_dir: String,
    pub download_dir: String,
    pub name: String,
    pub port: u16,
    pub discovery_port: u16,
    pub auto_accept: bool,
}

#[derive(uniffi::Enum)]
pub enum PeerState {
    Disconnected,
    Connecting,
    Connected,
    Rejected,
}

#[derive(uniffi::Record)]
pub struct Peer {
    pub id: String,
    pub name: String,
    pub addr: String,
    pub state: PeerState,
    pub trusted: bool,
    pub detail: String,
}

#[derive(uniffi::Record)]
pub struct HistoryItem {
    pub id: String,
    pub peer_id: String,
    pub peer_name: String,
    pub name: String,
    pub size: u64,
    pub incoming: bool,
    pub status: String,
    pub code: String,
    pub message: String,
    pub time: u64,
    pub path: String,
}

#[derive(uniffi::Enum)]
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
}

/// Implemented in Kotlin. Called from engine threads: switch to the main thread before touching UI state.
#[uniffi::export(with_foreign)]
pub trait EventListener: Send + Sync {
    fn on_event(&self, event: Event);
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
        E::TransferStarted { id, peer_id, peer_name, name, size, incoming } => Event::TransferStarted { id, peer_id, peer_name, name, size, incoming },
        E::TransferProgress { id, done, total, bytes_per_sec } => Event::TransferProgress { id, done, total, bytes_per_sec },
        E::TransferNote { id, message } => Event::TransferNote { id, message },
        E::TransferFinished { id, ok, code, message, path } => Event::TransferFinished { id, ok, code, message, path },
        E::Log { message } => Event::Log { message },
        // Legacy alpha UI: app messages (pb.x.*) are not used here.
        E::Message { kind, .. } => Event::Log { message: format!("app message {kind}") },
    }
}

struct Adapter(Arc<dyn EventListener>);

impl core::EventSink for Adapter {
    fn on_event(&self, e: core::Event) {
        self.0.on_event(event(e));
    }
}

#[derive(uniffi::Object)]
pub struct PbEngine {
    inner: core::Engine,
}

#[uniffi::export]
impl PbEngine {
    #[uniffi::constructor]
    pub fn start(config: Config, listener: Arc<dyn EventListener>) -> Result<Arc<Self>, PbError> {
        let cfg = core::Config {
            data_dir: config.data_dir.into(),
            download_dir: config.download_dir.into(),
            name: config.name,
            port: config.port,
            discovery_port: config.discovery_port,
            auto_accept: config.auto_accept,
        };
        Ok(Arc::new(Self { inner: core::Engine::start(cfg, Arc::new(Adapter(listener)))? }))
    }

    pub fn device_id(&self) -> String {
        self.inner.device_id()
    }

    pub fn port(&self) -> u16 {
        self.inner.port()
    }

    pub fn set_name(&self, name: String) {
        self.inner.set_name(&name);
    }

    pub fn set_auto_accept(&self, on: bool) {
        self.inner.set_auto_accept(on);
    }

    pub fn peers(&self) -> Vec<Peer> {
        self.inner.peers().into_iter().map(peer).collect()
    }

    pub fn pair_with_peer(&self, peer_id: String) -> Result<(), PbError> {
        Ok(self.inner.pair_with_peer(&peer_id)?)
    }

    pub fn pair_with_addr(&self, addr: String) -> Result<(), PbError> {
        Ok(self.inner.pair_with_addr(&addr)?)
    }

    pub fn respond_pair(&self, peer_id: String, accept: bool) {
        self.inner.respond_pair(&peer_id, accept);
    }

    pub fn revoke(&self, peer_id: String) -> Result<(), PbError> {
        Ok(self.inner.revoke(&peer_id)?)
    }

    /// `path` may be `fd:N` (a descriptor the app opened for a content URI and keeps open); `display_name` is then required.
    pub fn send_file(&self, peer_id: String, path: String, display_name: Option<String>) -> Result<String, PbError> {
        Ok(self.inner.send_file(&peer_id, Path::new(&path), display_name.as_deref())?)
    }

    pub fn respond_transfer(&self, id: String, accept: bool) {
        self.inner.respond_transfer(&id, accept);
    }

    pub fn cancel_transfer(&self, id: String) {
        self.inner.cancel_transfer(&id);
    }

    pub fn history(&self) -> Vec<HistoryItem> {
        self.inner
            .history()
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
            .collect()
    }

    pub fn clear_history(&self) -> Result<(), PbError> {
        Ok(self.inner.clear_history()?)
    }

    pub fn retry(&self, history_id: String) -> Result<String, PbError> {
        Ok(self.inner.retry(&history_id)?)
    }

    pub fn diagnostics(&self) -> Vec<String> {
        self.inner.diagnostics()
    }

    pub fn shutdown(&self) {
        self.inner.shutdown();
    }
}
