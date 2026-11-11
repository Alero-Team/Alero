//! Persistent state in one directory: identity, trusted peers, transfer history.
//! shortcut: the private key is a plain file (0600 on Unix; private app dir on Android). Before 1.0 wrap it
//! with the Android Keystore / Windows DPAPI / Secret Service (Protocol.md §2).

use std::path::{Path, PathBuf};
use std::sync::Mutex;

use rustls::pki_types::{CertificateDer, PrivatePkcs8KeyDer};
use serde::{Deserialize, Serialize};

use crate::identity::{device_id_from_cert, Identity};

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct PeerRecord {
    pub id: String,
    pub name: String,
    /// Last address it was reached at, so a restart can dial it before anything is heard (older files lack it).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub addr: Option<String>,
    /// The user chose "Desconectar": stay paired, but do not connect until they choose "Conectar".
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub paused: bool,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct HistoryEntry {
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
    /// Received file, or the source file of an outgoing transfer (empty when it is not re-openable).
    pub path: String,
}

const HISTORY_MAX: usize = 200;

pub struct Store {
    dir: PathBuf,
    /// Several threads read-modify-write the same files (discovery, revoke, pairing, transfers):
    /// one at a time, or a stale copy can bring back a device the user just removed.
    lock: Mutex<()>,
}

fn write_atomic(path: &Path, data: &[u8]) -> Result<(), String> {
    let tmp = path.with_extension("tmp");
    std::fs::write(&tmp, data).map_err(|e| e.to_string())?;
    std::fs::rename(&tmp, path).map_err(|e| e.to_string())
}

impl Store {
    pub fn open(dir: &Path) -> Result<Self, String> {
        std::fs::create_dir_all(dir).map_err(|e| e.to_string())?;
        Ok(Self { dir: dir.to_path_buf(), lock: Mutex::new(()) })
    }

    /// Loads the identity, or creates and saves one on first run.
    pub fn identity(&self, name: &str) -> Result<Identity, String> {
        let (cp, kp) = (self.dir.join("cert.der"), self.dir.join("key.der"));
        if cp.exists() && kp.exists() {
            let cert = CertificateDer::from(std::fs::read(&cp).map_err(|e| e.to_string())?);
            let key = PrivatePkcs8KeyDer::from(std::fs::read(&kp).map_err(|e| e.to_string())?);
            return Ok(Identity { device_id: device_id_from_cert(&cert)?, cert, key });
        }
        let id = Identity::generate(name)?;
        write_atomic(&kp, id.key.secret_pkcs8_der())?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let _ = std::fs::set_permissions(&kp, std::fs::Permissions::from_mode(0o600));
        }
        write_atomic(&cp, id.cert.as_ref())?;
        Ok(id)
    }

    fn load<T: for<'a> Deserialize<'a>>(&self, file: &str) -> Vec<T> {
        std::fs::read(self.dir.join(file)).ok().and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or_default()
    }

    fn save<T: Serialize>(&self, file: &str, v: &[T]) -> Result<(), String> {
        write_atomic(&self.dir.join(file), &serde_json::to_vec_pretty(v).map_err(|e| e.to_string())?)
    }

    pub fn peers(&self) -> Vec<PeerRecord> {
        self.load("peers.json")
    }

    pub fn save_peers(&self, v: &[PeerRecord]) -> Result<(), String> {
        let _g = self.lock.lock().unwrap_or_else(|e| e.into_inner());
        self.save("peers.json", v)
    }

    /// Changes the paired list atomically: `f` edits it and says whether to save. An existing but
    /// unreadable file is an error, never treated as empty (that would forget every other device).
    pub fn update_peers(&self, f: impl FnOnce(&mut Vec<PeerRecord>) -> bool) -> Result<(), String> {
        let _g = self.lock.lock().unwrap_or_else(|e| e.into_inner());
        let path = self.dir.join("peers.json");
        let mut list: Vec<PeerRecord> = match std::fs::read(&path) {
            Ok(b) => serde_json::from_slice(&b).map_err(|e| format!("peers.json: {e}"))?,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Vec::new(),
            Err(e) => return Err(e.to_string()),
        };
        if f(&mut list) { self.save("peers.json", &list) } else { Ok(()) }
    }

    pub fn history(&self) -> Vec<HistoryEntry> {
        self.load("history.json")
    }

    /// Newest first, capped.
    pub fn push_history(&self, e: HistoryEntry) -> Result<(), String> {
        let _g = self.lock.lock().unwrap_or_else(|e| e.into_inner());
        let mut h = self.history();
        h.retain(|x| x.id != e.id);
        h.insert(0, e);
        h.truncate(HISTORY_MAX);
        self.save("history.json", &h)
    }

    /// Forgets one record. Only the list changes: the transferred file is never touched.
    pub fn remove_history(&self, id: &str) -> Result<(), String> {
        let _g = self.lock.lock().unwrap_or_else(|e| e.into_inner());
        let mut h = self.history();
        h.retain(|x| x.id != id);
        self.save("history.json", &h)
    }

    /// A peer forgot these shared transfers: forget them too, but only records that involve that peer.
    pub fn remove_history_of(&self, peer_id: &str, ids: &[String]) -> Result<(), String> {
        let _g = self.lock.lock().unwrap_or_else(|e| e.into_inner());
        let mut h = self.history();
        h.retain(|x| x.peer_id != peer_id || !ids.contains(&x.id));
        self.save("history.json", &h)
    }

    pub fn clear_history(&self) -> Result<(), String> {
        let _g = self.lock.lock().unwrap_or_else(|e| e.into_inner());
        self.save::<HistoryEntry>("history.json", &[])
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_peer_only_removes_its_own_history() {
        let dir = std::env::temp_dir().join(format!("alero-hist-{}", std::process::id()));
        let _ = std::fs::create_dir_all(&dir);
        let s = Store::open(&dir).unwrap();
        let e = |id: &str, peer: &str| HistoryEntry {
            id: id.into(), peer_id: peer.into(), peer_name: String::new(), name: "f".into(), size: 1, incoming: true,
            status: "done".into(), code: String::new(), message: String::new(), time: 0, path: String::new(),
        };
        s.push_history(e("1", "a")).unwrap();
        s.push_history(e("2", "b")).unwrap();
        s.remove_history_of("a", &["1".into(), "2".into()]).unwrap();
        let left: Vec<String> = s.history().into_iter().map(|h| h.id).collect();
        assert_eq!(left, vec!["2".to_string()]);
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn a_damaged_peers_file_is_never_overwritten_with_an_empty_list() {
        let dir = std::env::temp_dir().join(format!("alero-peers-{}", std::process::id()));
        let s = Store::open(&dir).unwrap();
        s.update_peers(|l| { l.push(PeerRecord { id: "a".into(), name: "Pixel".into(), addr: None, paused: false }); true }).unwrap();
        s.update_peers(|l| { l.retain(|p| p.id != "a"); true }).unwrap();
        assert!(s.peers().is_empty());
        std::fs::write(dir.join("peers.json"), b"{broken").unwrap();
        assert!(s.update_peers(|l| { l.push(PeerRecord { id: "b".into(), name: "x".into(), addr: None, paused: false }); true }).is_err());
        assert_eq!(std::fs::read(dir.join("peers.json")).unwrap(), b"{broken");
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn peers_file_from_before_addresses_still_loads_and_stays_compatible() {
        let old: Vec<PeerRecord> = serde_json::from_str(r#"[{"id":"a","name":"Pixel"}]"#).unwrap();
        assert_eq!(old[0].addr, None);
        assert!(!serde_json::to_string(&old).unwrap().contains("addr")); // older versions read what we write
        let new: Vec<PeerRecord> = serde_json::from_str(r#"[{"id":"a","name":"Pixel","addr":"192.168.1.5:41421"}]"#).unwrap();
        assert_eq!(new[0].addr.as_deref(), Some("192.168.1.5:41421"));
        assert!(!new[0].paused);
        assert!(!serde_json::to_string(&new).unwrap().contains("paused")); // unchanged files for older versions
    }
}
