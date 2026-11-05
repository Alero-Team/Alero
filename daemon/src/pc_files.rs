//! Explicitly authorized Windows folders, browsed from an already paired
//! Android device via Alero's encrypted peer channel. No ADB or cloud server.
//! A folder is never exposed by default. File edits require separate consent.

use std::fs;
use std::path::{Component, Path, PathBuf};
use std::sync::Arc;
use std::time::SystemTime;

use pb_core::engine::{Engine, PeerState};
use serde_json::{json, Value};

const PAGE: usize = 100;

fn config(data: &Path) -> Value {
    fs::read_to_string(data.join("remote.json"))
        .ok()
        .and_then(|s| serde_json::from_str(&s).ok())
        .unwrap_or(Value::Null)
}

fn roots(cfg: &Value) -> Vec<PathBuf> {
    cfg["folders"]
        .as_array()
        .into_iter()
        .flat_map(|a| a.iter())
        .filter_map(Value::as_str)
        .filter_map(|raw| fs::canonicalize(raw).ok())
        .filter(|path| path.is_dir())
        .collect()
}

/// We never trust a path supplied by a phone: reject absolute paths,
/// traversal, drive prefixes and symbolic links escaping the approved folder.
fn safe_relative(raw: &str) -> Option<PathBuf> {
    let relative = PathBuf::from(raw);
    if raw.len() > 4096 || relative.is_absolute() {
        return None;
    }
    if relative
        .components()
        .any(|c| !matches!(c, Component::Normal(_)))
    {
        if !raw.is_empty() {
            return None;
        }
    }
    Some(relative)
}

fn resolve(approved: &[PathBuf], body: &Value, key: &str) -> Option<(PathBuf, PathBuf)> {
    let index: usize = body["root"].as_str()?.parse().ok()?;
    let root = approved.get(index)?.clone();
    let rel = safe_relative(body[key].as_str()?)?;
    let path = fs::canonicalize(root.join(rel)).ok()?;
    if !path.starts_with(&root) {
        return None;
    }
    Some((root, path))
}

fn relative_path(root: &Path, item: &Path) -> String {
    item.strip_prefix(root).unwrap_or(item).to_string_lossy().to_string()
}

fn entry(root: &Path, path: &Path) -> Option<Value> {
    let safe = fs::canonicalize(path).ok()?;
    if !safe.starts_with(root) {
        return None;
    }
    let metadata = fs::metadata(&safe).ok()?;
    let name = path.file_name()?.to_string_lossy().to_string();
    let rel = relative_path(root, path);
    let date = metadata.modified().ok()?.duration_since(SystemTime::UNIX_EPOCH).ok()?.as_secs();
    Some(json!({
        "name": name,
        "dir": metadata.is_dir(),
        "size": if metadata.is_dir() { 0 } else { metadata.len() },
        "mtime": date,
        "id": rel,
        "path": rel,
    }))
}

fn valid_new_name(name: &str) -> bool {
    !name.is_empty()
        && name.len() <= 180
        && name != "."
        && name != ".."
        && name.trim_end_matches([' ', '.']) == name
        && !name.chars().any(|c| c.is_control()
            || matches!(c, '/' | '\\' | ':' | '*' | '?' | '"' | '<' | '>' | '|'))
}

fn denied(engine: &Engine, peer: &str, reason: &str) {
    let _ = engine.send_message(peer, "pb.x.pcfs.denied", json!({"reason": reason}));
}

pub fn handle(
    engine: &Arc<Engine>,
    peer: &str,
    kind: &str,
    body: &Value,
    data: &Path,
) -> bool {
    if !kind.starts_with("pb.x.pcfs.") {
        return false;
    }
    // Defense in depth: a client must still be paired and currently connected.
    if !engine.peers().iter().any(|p| p.id == peer && p.trusted && p.state == PeerState::Connected) {
        return true;
    }
    let cfg = config(data);
    let approved = roots(&cfg);
    if approved.is_empty() {
        denied(engine, peer, "not_allowed");
        return true;
    }
    match kind {
        "pb.x.pcfs.roots.request" => {
            let items: Vec<_> = approved.iter().enumerate().map(|(id, p)| {
                json!({
                    "id": id.to_string(),
                    "name": p.file_name().map(|s| s.to_string_lossy().to_string())
                        .unwrap_or_else(|| p.display().to_string()),
                    "kind": "folder",
                    "ok": true,
                })
            }).collect();
            let _ = engine.send_message(peer, "pb.x.pcfs.roots", json!({"roots": items}));
        }
        "pb.x.pcfs.list" => {
            let Some((root, path)) = resolve(&approved, body, "path") else {
                denied(engine, peer, "invalid_path");
                return true;
            };
            if !path.is_dir() {
                denied(engine, peer, "not_directory");
                return true;
            }
            let mut files: Vec<_> = match fs::read_dir(path) {
                Ok(dir) => dir.flatten()
                    .filter_map(|item| entry(&root, &item.path()))
                    .collect(),
                Err(_) => {
                    denied(engine, peer, "read_failed");
                    return true;
                }
            };
            files.sort_by(|a, b| {
                let aa = a["name"].as_str().unwrap_or("").to_lowercase();
                let bb = b["name"].as_str().unwrap_or("").to_lowercase();
                aa.cmp(&bb)
            });
            let offset = body["offset"].as_u64().unwrap_or(0).min(files.len() as u64) as usize;
            let total = files.len();
            let page: Vec<_> = files.into_iter().skip(offset).take(PAGE).collect();
            let _ = engine.send_message(peer, "pb.x.pcfs.entries", json!({
                "root": body["root"],
                "path": body["path"],
                "offset": offset,
                "total": total,
                "entries": page,
            }));
        }
        "pb.x.pcfs.get" => {
            let Some((_, path)) = resolve(&approved, body, "id") else {
                denied(engine, peer, "invalid_path");
                return true;
            };
            if !path.is_file() {
                denied(engine, peer, "not_file");
                return true;
            }
            #[cfg(windows)]
            crate::win::toast("Descarga desde Alero", "Un teléfono emparejado está descargando un archivo autorizado");
            let name = path.file_name().map(|s| s.to_string_lossy().into_owned()).unwrap_or_default();
            if engine.send_file(peer, &path, Some(&name)).is_err() {
                denied(engine, peer, "send_failed");
            }
        }
        "pb.x.pcfs.rename" | "pb.x.pcfs.delete" => {
            if cfg["allowPcFileEdits"] != true {
                denied(engine, peer, "read_only");
                return true;
            }
            let Some((root, path)) = resolve(&approved, body, "id") else {
                denied(engine, peer, "invalid_path");
                return true;
            };
            if !path.is_file() || path == root {
                denied(engine, peer, "not_file");
                return true;
            }
            #[cfg(windows)]
            crate::win::toast("Archivos de Alero", "Un teléfono emparejado solicitó modificar un archivo compartido");
            let name = path.file_name().map(|s| s.to_string_lossy().into_owned()).unwrap_or_default();
            let ok = if kind == "pb.x.pcfs.delete" {
                fs::remove_file(&path).is_ok()
            } else {
                let new_name = body["to"].as_str().unwrap_or("");
                let dest = path.parent().unwrap_or(&root).join(new_name);
                valid_new_name(new_name)
                    && !dest.exists()
                    && fs::rename(&path, dest).is_ok()
            };
            let _ = engine.send_message(peer, "pb.x.pcfs.done", json!({
                "op": if kind.ends_with("delete") { "delete" } else { "rename" },
                "name": name,
                "ok": ok,
            }));
        }
        _ => denied(engine, peer, "unknown_command"),
    }
    true
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rejects_escape_and_absolute_paths() {
        assert!(safe_relative("").is_some());
        assert!(safe_relative("Documents").is_some());
        assert!(safe_relative("../outside").is_none());
        assert!(safe_relative("./outside").is_none());
        assert!(safe_relative("/root").is_none());
    }

    #[test]
    fn validates_rename_targets() {
        assert!(valid_new_name("documento.txt"));
        assert!(!valid_new_name(".."));
        assert!(!valid_new_name("foo/bar"));
        assert!(!valid_new_name("carpeta\\archivo"));
        assert!(!valid_new_name("sin-permiso."));
    }
}
