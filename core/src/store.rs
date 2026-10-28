//! Persistent state in one directory: identity, trusted peers, transfer history.
//! shortcut: the private key is a plain file (0600 on Unix; private app dir on Android). Before 1.0 wrap it
//! with the Android Keystore / Windows DPAPI / Secret Service (Protocol.md §2).

use std::path::{Path, PathBuf};

use rustls::pki_types::{CertificateDer, PrivatePkcs8KeyDer};
use serde::{Deserialize, Serialize};

use crate::identity::{device_id_from_cert, Identity};

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct PeerRecord {
    pub id: String,
    pub name: String,
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
}

fn write_atomic(path: &Path, data: &[u8]) -> Result<(), String> {
    let tmp = path.with_extension("tmp");
    std::fs::write(&tmp, data).map_err(|e| e.to_string())?;
    std::fs::rename(&tmp, path).map_err(|e| e.to_string())
}

impl Store {
    pub fn open(dir: &Path) -> Result<Self, String> {
        std::fs::create_dir_all(dir).map_err(|e| e.to_string())?;
        Ok(Self { dir: dir.to_path_buf() })
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
        self.save("peers.json", v)
    }

    pub fn history(&self) -> Vec<HistoryEntry> {
        self.load("history.json")
    }

    /// Newest first, capped.
    pub fn push_history(&self, e: HistoryEntry) -> Result<(), String> {
        let mut h = self.history();
        h.retain(|x| x.id != e.id);
        h.insert(0, e);
        h.truncate(HISTORY_MAX);
        self.save("history.json", &h)
    }

    /// Forgets one record. Only the list changes: the transferred file is never touched.
    pub fn remove_history(&self, id: &str) -> Result<(), String> {
        let mut h = self.history();
        h.retain(|x| x.id != id);
        self.save("history.json", &h)
    }

    pub fn clear_history(&self) -> Result<(), String> {
        self.save::<HistoryEntry>("history.json", &[])
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn entry(id: &str, path: &str) -> HistoryEntry {
        HistoryEntry {
            id: id.into(),
            peer_id: "p".into(),
            peer_name: "p".into(),
            name: "f.txt".into(),
            size: 1,
            incoming: true,
            status: "done".into(),
            code: String::new(),
            message: String::new(),
            time: 1,
            path: path.into(),
        }
    }

    #[test]
    fn remove_history_drops_the_record_and_keeps_the_file() {
        let dir = std::env::temp_dir().join(format!("alero-store-test-{}", std::process::id()));
        let file = dir.join("keep.txt");
        let store = Store::open(&dir).unwrap();
        std::fs::write(&file, b"x").unwrap();
        store.push_history(entry("a", file.to_str().unwrap())).unwrap();
        store.push_history(entry("b", "")).unwrap();
        store.remove_history("a").unwrap();
        assert_eq!(store.history().iter().map(|h| h.id.as_str()).collect::<Vec<_>>(), ["b"]);
        assert!(file.exists());
        std::fs::remove_dir_all(&dir).unwrap();
    }
}
