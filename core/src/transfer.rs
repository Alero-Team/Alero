//! Resumable file transfer over any `Read + Write` stream (Protocol.md §7).
//!
//! Wire after the TLS handshake:
//!   S→R frame `pb.transfer.offer {name,size,blockSize}`
//!   R→S frame `pb.transfer.accept {blocks,prefixRoot}`  (R re-hashes its `.part` prefix from disk)
//!   S→R frame `pb.transfer.start {fromBlock}`           (S re-hashes the same prefix; equal ⇒ resume, else 0)
//!   S→R repeated `0x01 | u32 len | sha256(block) | block`, then `0x02` + frame `pb.transfer.done {root}`
//!   R→S frame `pb.transfer.result {ok}`
//! `root` = SHA-256 over the concatenated per-block hashes of the whole file, so a resumed file is
//! checked end to end without a second full-file pass.

use std::fs::{File, OpenOptions};
use std::io::{Read, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};

use serde_json::{json, Value};
use sha2::{Digest, Sha256};

use crate::frame::{read_frame, write_frame, FrameError};

pub const DEFAULT_BLOCK: u32 = 1024 * 1024;
const MIN_BLOCK: u32 = 4096;
const MAX_BLOCK: u32 = 16 * 1024 * 1024;
const TAG_BLOCK: u8 = 1;
const TAG_DONE: u8 = 2;

#[derive(Debug, PartialEq, Eq)]
pub enum TransferError {
    Io(String),
    Protocol(String),
    Integrity,
    InvalidName,
    /// Test hook: the sender stopped on purpose.
    Aborted,
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
    safe_name(&name)?;
    if !(MIN_BLOCK..=MAX_BLOCK).contains(&block_size) {
        return proto("block size out of range");
    }
    let mut f = File::open(path)?;
    let size = f.metadata()?.len();
    write_frame(s, &json!({"type":"pb.transfer.offer","body":{"name":name,"size":size,"blockSize":block_size}}))?;

    let acc = read_frame(s)?;
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
    loop {
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
    let offer = read_frame(s)?;
    let o = field(&offer, "pb.transfer.offer")?;
    let name = o["name"].as_str().ok_or(TransferError::InvalidName)?.to_string();
    safe_name(&name)?;
    let size = o["size"].as_u64().ok_or(TransferError::Protocol("size".into()))?;
    let bs = o["blockSize"].as_u64().unwrap_or(0) as u32;
    if !(MIN_BLOCK..=MAX_BLOCK).contains(&bs) {
        return proto("block size out of range");
    }

    std::fs::create_dir_all(dest_dir)?;
    let part_path = dest_dir.join(format!("{name}.part"));
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
    loop {
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
            }
            TAG_DONE => break,
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
    let final_path = unique_path(dest_dir, &name);
    std::fs::rename(&part_path, &final_path)?;
    Ok((Report { name, size, resumed_from_block: from, bytes: written - from * bs as u64 }, final_path))
}
