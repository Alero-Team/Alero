//! Resumable file transfer over any `Read + Write` stream (Protocol.md §7).
//!
//! Wire after the TLS handshake:
//!   S→R frame `pb.transfer.offer {name,size,blockSize}`
//!   R→S frame `pb.transfer.accept {blocks,prefixRoot}`  (R re-hashes its `.part` prefix from disk)
//!        or frame `pb.transfer.reject {reason}` (R declines; S stops and must not retry)
//!   S→R frame `pb.transfer.start {fromBlock}`           (S re-hashes the same prefix; equal ⇒ resume, else 0)
//!   S→R repeated `0x01 | u32 len | sha256(block) | block`, then `0x02` + frame `pb.transfer.done {root}`
//!        or a single `0x03` byte if the sender cancels (R then deletes its `.part`)
//!   R→S frame `pb.transfer.result {ok}`
//! `root` = SHA-256 over the concatenated per-block hashes of the whole file, so a resumed file is
//! checked end to end without a second full-file pass.

use std::fs::{File, OpenOptions};
use std::io::{Read, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};

use serde_json::{json, Value};
use sha2::{Digest, Sha256};

use crate::frame::{read_frame, write_frame, FrameError};

pub const DEFAULT_BLOCK: u32 = 1024 * 1024;
const MIN_BLOCK: u32 = 4096;
const MAX_BLOCK: u32 = 16 * 1024 * 1024;
const TAG_BLOCK: u8 = 1;
const TAG_DONE: u8 = 2;
const TAG_CANCEL: u8 = 3;

#[derive(Debug, PartialEq, Eq)]
pub enum TransferError {
    Io(String),
    Protocol(String),
    Integrity,
    InvalidName,
    /// Test hook: the sender stopped on purpose.
    Aborted,
    /// The user cancelled this transfer on this side or the peer said so with a cancel tag.
    Cancelled,
    /// The receiver declined the offer; retrying is pointless.
    Rejected(String),
}

impl From<std::io::Error> for TransferError {
    fn from(e: std::io::Error) -> Self {
        Self::Io(e.to_string())
    }
}

impl From<FrameError> for TransferError {
    fn from(e: FrameError) -> Self {
        Self::Protocol(e.code().into())
    }
}

#[derive(Debug, Default)]
pub struct Report {
    pub name: String,
    pub size: u64,
    /// First block this run actually sent/received (0 = from scratch).
    pub resumed_from_block: u64,
    /// File payload bytes moved in this run.
    pub bytes: u64,
}

/// Opens the source of an outgoing transfer. `fd:N` means "duplicate descriptor N that the host app already opened"
/// (Android content URIs: re-opening `/proc/self/fd/N` by path is denied without storage permission).
/// The duplicate shares the file offset with the original, so only one transfer may use a descriptor at a time.
pub fn open_source(path: &Path) -> std::io::Result<File> {
    #[cfg(unix)]
    if let Some(n) = path.to_str().and_then(|p| p.strip_prefix("fd:")) {
        use std::os::fd::{BorrowedFd, RawFd};
        let fd: RawFd = n.parse().map_err(|_| std::io::Error::new(std::io::ErrorKind::InvalidInput, "bad fd"))?;
        // SAFETY: the host promises `fd` stays open for the duration of the transfer; we only duplicate it.
        return Ok(File::from(unsafe { BorrowedFd::borrow_raw(fd) }.try_clone_to_owned()?));
    }
    File::open(path)
}

fn hex(b: &[u8]) -> String {
    b.iter().map(|x| format!("{x:02x}")).collect()
}

fn proto<T>(msg: &str) -> Result<T, TransferError> {
    Err(TransferError::Protocol(msg.into()))
}

/// Rejects names that could escape the destination or break on Windows (Protocol.md §8).
/// shortcut: no Unicode normalization, add the `unicode-normalization` crate before 1.0.
pub fn safe_name(name: &str) -> Result<(), TransferError> {
    const RESERVED: [&str; 22] = [
        "CON", "PRN", "AUX", "NUL", "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9", "LPT1",
        "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9",
    ];
    let stem = name.split('.').next().unwrap_or("").to_ascii_uppercase();
    let bad = name.is_empty()
        || name.len() > 255
        || name == "."
        || name == ".."
        || name.ends_with('.')
        || name.ends_with(' ')
        || name.chars().any(|c| c.is_control() || "/\\:*?\"<>|".contains(c))
        || RESERVED.contains(&stem.as_str());
    if bad { Err(TransferError::InvalidName) } else { Ok(()) }
}

/// A file inside a sent folder travels as `Folder/sub/name`: every segment must be a safe name, and at most
/// 16 deep, so a peer can never climb out of the download folder or reach a drive or device path.
pub fn safe_rel(name: &str) -> Result<(), TransferError> {
    let parts: Vec<&str> = name.split('/').collect();
    if parts.len() > 16 || name.len() > 1024 {
        return Err(TransferError::InvalidName);
    }
    parts.iter().try_for_each(|p| safe_name(p))
}

/// Hasher state after folding in the per-block hashes of the first `n` blocks of `f`.
fn hash_prefix(f: &mut File, n: u64, bs: u32) -> std::io::Result<Sha256> {
    let mut root = Sha256::new();
    let mut buf = vec![0u8; bs as usize];
    f.seek(SeekFrom::Start(0))?;
    for _ in 0..n {
        f.read_exact(&mut buf)?;
        root.update(Sha256::digest(&buf));
    }
    Ok(root)
}

fn field<'a>(v: &'a Value, ty: &str) -> Result<&'a Value, TransferError> {
    if v["type"] != ty {
        return proto(&format!("expected {ty}"));
    }
    Ok(&v["body"])
}

pub fn send_file<S: Read + Write>(
    s: &mut S,
    path: &Path,
    block_size: u32,
    abort_after_blocks: Option<u64>,
) -> Result<Report, TransferError> {
    let name = path.file_name().and_then(|n| n.to_str()).ok_or(TransferError::InvalidName)?.to_string();
    send_file_ex(s, path, &name, "", block_size, abort_after_blocks, &AtomicBool::new(false), &mut |_, _| {})
}

/// `name` is what the receiver will call the file (it may differ from `path`, e.g. `/proc/self/fd/N` on Android).
/// `id` identifies the transfer across retries. `progress(done, total)` runs after every block.
#[allow(clippy::too_many_arguments)]
pub fn send_file_ex<S: Read + Write>(
    s: &mut S,
    path: &Path,
    name: &str,
    id: &str,
    block_size: u32,
    abort_after_blocks: Option<u64>,
    cancel: &AtomicBool,
    progress: &mut dyn FnMut(u64, u64),
) -> Result<Report, TransferError> {
    let r = send_inner(s, path, name, id, block_size, abort_after_blocks, cancel, progress);
    match r {
        Err(_) if cancel.load(Ordering::Relaxed) => Err(TransferError::Cancelled),
        other => other,
    }
}

#[allow(clippy::too_many_arguments)]
fn send_inner<S: Read + Write>(
    s: &mut S,
    path: &Path,
    name: &str,
    id: &str,
    block_size: u32,
    abort_after_blocks: Option<u64>,
    cancel: &AtomicBool,
    progress: &mut dyn FnMut(u64, u64),
) -> Result<Report, TransferError> {
    safe_rel(name)?;
    let name = name.to_string();
    if !(MIN_BLOCK..=MAX_BLOCK).contains(&block_size) {
        return proto("block size out of range");
    }
    let mut f = open_source(path)?;
    let size = f.metadata()?.len();
    write_frame(s, &json!({"type":"pb.transfer.offer","body":{"id":id,"name":name,"size":size,"blockSize":block_size}}))?;

    let acc = read_frame(s)?;
    if acc["type"] == "pb.transfer.reject" {
        return Err(TransferError::Rejected(acc["body"]["reason"].as_str().unwrap_or("rejected").to_string()));
    }
    let acc = field(&acc, "pb.transfer.accept")?;
    let (blocks, their_root) = (acc["blocks"].as_u64().ok_or(TransferError::Protocol("blocks".into()))?, acc["prefixRoot"].as_str().unwrap_or(""));
    let bs = block_size as u64;
    if blocks.checked_mul(bs).map_or(true, |b| b > size) {
        return proto("accept.blocks beyond file size");
    }
    let mut root = hash_prefix(&mut f, blocks, block_size)?;
    let from = if hex(&root.clone().finalize()) == their_root { blocks } else { 0 };
    if from == 0 {
        root = Sha256::new();
    }
    write_frame(s, &json!({"type":"pb.transfer.start","body":{"fromBlock":from}}))?;

    f.seek(SeekFrom::Start(from * bs))?;
    // One buffer per block: tag | len | hash | data, sent with a single write. Separate small writes
    // interact with Nagle + delayed ACK and cost ~300 ms per block (measured: 3.3 MB/s on Wi-Fi).
    const HDR: usize = 1 + 4 + 32;
    let mut buf = vec![0u8; HDR + block_size as usize];
    let (mut sent_blocks, mut bytes) = (0u64, 0u64);
    progress(from * bs, size);
    loop {
        if cancel.load(Ordering::Relaxed) {
            s.write_all(&[TAG_CANCEL])?;
            s.flush()?;
            return Err(TransferError::Cancelled);
        }
        let mut n = 0;
        while n < block_size as usize {
            let r = f.read(&mut buf[HDR + n..])?;
            if r == 0 {
                break;
            }
            n += r;
        }
        if n == 0 {
            break;
        }
        let h = Sha256::digest(&buf[HDR..HDR + n]);
        root.update(h);
        buf[0] = TAG_BLOCK;
        buf[1..5].copy_from_slice(&(n as u32).to_be_bytes());
        buf[5..HDR].copy_from_slice(&h);
        s.write_all(&buf[..HDR + n])?;
        sent_blocks += 1;
        bytes += n as u64;
        progress(from * bs + bytes, size);
        if abort_after_blocks == Some(sent_blocks) {
            s.flush()?;
            return Err(TransferError::Aborted);
        }
        if n < block_size as usize {
            break;
        }
    }
    s.write_all(&[TAG_DONE])?;
    write_frame(s, &json!({"type":"pb.transfer.done","body":{"root":hex(&root.finalize())}}))?;
    s.flush()?;
    let res = read_frame(s)?;
    if field(&res, "pb.transfer.result")?["ok"] != true {
        return Err(TransferError::Integrity);
    }
    Ok(Report { name, size, resumed_from_block: from, bytes })
}

fn unique_path(dir: &Path, name: &str) -> PathBuf {
    let first = dir.join(name);
    if !first.exists() {
        return first;
    }
    let p = Path::new(name);
    let (stem, ext) = (p.file_stem().and_then(|s| s.to_str()).unwrap_or(name), p.extension().and_then(|s| s.to_str()));
    (1..)
        .map(|i| dir.join(match ext { Some(e) => format!("{stem} ({i}).{e}"), None => format!("{stem} ({i})") }))
        .find(|c| !c.exists())
        .unwrap()
}

pub fn receive_file<S: Read + Write>(s: &mut S, dest_dir: &Path) -> Result<(Report, PathBuf), TransferError> {
    receive_file_ex(s, dest_dir, &mut |_, _, _| Ok(()), &AtomicBool::new(false), &mut |_, _| {})
}

/// `decide(id, name, size)` may refuse the offer with a reason. `.part` files are removed on cancel.
pub fn receive_file_ex<S: Read + Write>(
    s: &mut S,
    dest_dir: &Path,
    decide: &mut dyn FnMut(&str, &str, u64) -> Result<(), String>,
    cancel: &AtomicBool,
    progress: &mut dyn FnMut(u64, u64),
) -> Result<(Report, PathBuf), TransferError> {
    let mut part_path = None;
    let r = receive_inner(s, dest_dir, decide, cancel, progress, &mut part_path);
    match r {
        Err(_) if cancel.load(Ordering::Relaxed) => {
            if let Some(p) = part_path {
                let _ = std::fs::remove_file(p);
            }
            Err(TransferError::Cancelled)
        }
        other => other,
    }
}

fn receive_inner<S: Read + Write>(
    s: &mut S,
    dest_dir: &Path,
    decide: &mut dyn FnMut(&str, &str, u64) -> Result<(), String>,
    cancel: &AtomicBool,
    progress: &mut dyn FnMut(u64, u64),
    part_out: &mut Option<PathBuf>,
) -> Result<(Report, PathBuf), TransferError> {
    let offer = read_frame(s)?;
    let o = field(&offer, "pb.transfer.offer")?;
    let name = o["name"].as_str().ok_or(TransferError::InvalidName)?.to_string();
    safe_rel(&name)?;
    let size = o["size"].as_u64().ok_or(TransferError::Protocol("size".into()))?;
    let bs = o["blockSize"].as_u64().unwrap_or(0) as u32;
    if !(MIN_BLOCK..=MAX_BLOCK).contains(&bs) {
        return proto("block size out of range");
    }
    if let Err(reason) = decide(o["id"].as_str().unwrap_or(""), &name, size) {
        write_frame(s, &json!({"type":"pb.transfer.reject","body":{"reason":reason}}))?;
        s.flush()?;
        return Err(TransferError::Rejected(reason));
    }

    // A file of a folder lands in the same subfolders under the download folder.
    let (sub, file) = name.rsplit_once('/').unwrap_or(("", name.as_str()));
    let dest_dir = &dest_dir.join(sub);
    std::fs::create_dir_all(dest_dir)?;
    let part_path = dest_dir.join(format!("{file}.part"));
    *part_out = Some(part_path.clone());
    let mut part = OpenOptions::new().read(true).write(true).create(true).truncate(false).open(&part_path)?;
    let blocks = (part.metadata()?.len() / bs as u64).min(size / bs as u64);
    let prefix = hash_prefix(&mut part, blocks, bs)?;
    write_frame(s, &json!({"type":"pb.transfer.accept","body":{"blocks":blocks,"prefixRoot":hex(&prefix.clone().finalize())}}))?;

    let start = read_frame(s)?;
    let from = field(&start, "pb.transfer.start")?["fromBlock"].as_u64().unwrap_or(u64::MAX);
    let mut root = if from == blocks && from > 0 {
        prefix
    } else if from == 0 {
        Sha256::new()
    } else {
        return proto("start.fromBlock does not match the accepted prefix");
    };
    part.set_len(from * bs as u64)?;
    part.seek(SeekFrom::Start(from * bs as u64))?;

    let (mut written, mut buf) = (from * bs as u64, vec![0u8; bs as usize]);
    let mut tag = [0u8; 1];
    progress(written, size);
    loop {
        if cancel.load(Ordering::Relaxed) {
            return Err(TransferError::Cancelled);
        }
        s.read_exact(&mut tag)?;
        match tag[0] {
            TAG_BLOCK => {
                let mut hdr = [0u8; 36];
                s.read_exact(&mut hdr)?;
                let n = u32::from_be_bytes(hdr[..4].try_into().unwrap()) as usize;
                if n == 0 || n > bs as usize || written + n as u64 > size {
                    return proto("bad block length");
                }
                s.read_exact(&mut buf[..n])?;
                let h = Sha256::digest(&buf[..n]);
                if h.as_slice() != &hdr[4..] {
                    return Err(TransferError::Integrity);
                }
                part.write_all(&buf[..n])?;
                root.update(h);
                written += n as u64;
                progress(written, size);
            }
            TAG_DONE => break,
            TAG_CANCEL => {
                cancel.store(true, Ordering::Relaxed);
                return Err(TransferError::Cancelled);
            }
            _ => return proto("unknown tag"),
        }
    }
    let done = read_frame(s)?;
    let their_root = field(&done, "pb.transfer.done")?["root"].as_str().unwrap_or("").to_string();
    let ok = written == size && hex(&root.finalize()) == their_root;
    write_frame(s, &json!({"type":"pb.transfer.result","body":{"ok":ok}}))?;
    s.flush()?;
    if !ok {
        drop(part);
        let _ = std::fs::remove_file(&part_path);
        return Err(TransferError::Integrity);
    }
    part.sync_all()?;
    drop(part);
    let final_path = unique_path(dest_dir, file);
    std::fs::rename(&part_path, &final_path)?;
    Ok((Report { name, size, resumed_from_block: from, bytes: written - from * bs as u64 }, final_path))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn folder_paths_are_checked_segment_by_segment() {
        assert!(safe_rel("Viaje/día 1/foto.jpg").is_ok());
        for bad in ["../x", "a/../b", "/abs", "a//b", "C:/x", r"a\b", "a/NUL", "a/b."] {
            assert!(safe_rel(bad).is_err(), "{bad}");
        }
        assert!(safe_rel(&vec!["a"; 17].join("/")).is_err());
    }

    #[test]
    fn a_file_of_a_folder_lands_in_its_subfolder() {
        let dir = std::env::temp_dir().join(format!("alero-rel-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let src = dir.join("src.txt");
        std::fs::write(&src, b"hola").unwrap();
        let l = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = l.local_addr().unwrap();
        let out = dir.join("out");
        let rx = std::thread::spawn(move || receive_file(&mut l.accept().unwrap().0, &out).unwrap().1);
        let mut s = std::net::TcpStream::connect(addr).unwrap();
        send_file_ex(&mut s, &src, "Viaje/día 1/nota.txt", "t", DEFAULT_BLOCK, None, &AtomicBool::new(false), &mut |_, _| {}).unwrap();
        let got = rx.join().unwrap();
        assert_eq!(got, dir.join("out").join("Viaje").join("día 1").join("nota.txt"));
        assert_eq!(std::fs::read(got).unwrap(), b"hola");
        let _ = std::fs::remove_dir_all(dir);
    }
}
