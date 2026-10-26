use std::net::{TcpListener, TcpStream};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU32, Ordering};

use pb_core::transfer::{receive_file, safe_name, send_file, Report, TransferError};

const BS: u32 = 4096;

fn tmp(label: &str) -> PathBuf {
    static N: AtomicU32 = AtomicU32::new(0);
    let d = std::env::temp_dir().join(format!("pb-test-{}-{}-{label}", std::process::id(), N.fetch_add(1, Ordering::SeqCst)));
    let _ = std::fs::remove_dir_all(&d);
    std::fs::create_dir_all(&d).unwrap();
    d
}

/// Deterministic, non-repeating bytes (xorshift) so shifted/misplaced blocks cannot match by luck.
fn data(len: usize, seed: u64) -> Vec<u8> {
    let mut x = seed | 1;
    (0..len)
        .map(|_| {
            x ^= x << 13;
            x ^= x >> 7;
            x ^= x << 17;
            (x >> 24) as u8
        })
        .collect()
}

type Rx = Result<(Report, PathBuf), TransferError>;

/// One transfer over loopback TCP. `abort` makes the sender drop the connection after N blocks.
fn transfer(src: &Path, dest: &Path, abort: Option<u64>) -> (Result<Report, TransferError>, Rx) {
    let l = TcpListener::bind("127.0.0.1:0").unwrap();
    let addr = l.local_addr().unwrap();
    let dest = dest.to_path_buf();
    let rx = std::thread::spawn(move || {
        let (mut s, _) = l.accept().unwrap();
        receive_file(&mut s, &dest)
    });
    let mut s = TcpStream::connect(addr).unwrap();
    let tx = send_file(&mut s, src, BS, abort);
    drop(s);
    (tx, rx.join().unwrap())
}

fn write_src(dir: &Path, name: &str, bytes: &[u8]) -> PathBuf {
    let p = dir.join(name);
    std::fs::write(&p, bytes).unwrap();
    p
}

#[test]
fn sizes_around_the_block_boundary_arrive_identical() {
    for (i, len) in [0usize, 1, 4095, 4096, 4097, 3 * 4096, 3 * 4096 + 17].into_iter().enumerate() {
        let (src_dir, dst_dir) = (tmp("src"), tmp("dst"));
        let bytes = data(len, 7 + i as u64);
        let src = write_src(&src_dir, "f.bin", &bytes);
        let (tx, rx) = transfer(&src, &dst_dir, None);
        let (r, path) = rx.unwrap_or_else(|e| panic!("len {len}: {e:?}"));
        tx.unwrap();
        assert_eq!(std::fs::read(path).unwrap(), bytes, "len {len}");
        assert_eq!((r.resumed_from_block, r.bytes), (0, len as u64), "len {len}");
        assert!(!dst_dir.join("f.bin.part").exists(), "len {len}: .part must be gone");
    }
}

#[test]
fn interrupted_transfer_resumes_from_the_last_complete_block() {
    let (src_dir, dst_dir) = (tmp("src"), tmp("dst"));
    let bytes = data(10 * 4096 + 100, 42);
    let src = write_src(&src_dir, "big.bin", &bytes);

    let (tx, rx) = transfer(&src, &dst_dir, Some(3));
    assert_eq!(tx.unwrap_err(), TransferError::Aborted);
    assert!(rx.is_err(), "receiver must see the cut");
    assert_eq!(std::fs::metadata(dst_dir.join("big.bin.part")).unwrap().len(), 3 * 4096);
    assert!(!dst_dir.join("big.bin").exists(), "no final file before verification");

    let (tx, rx) = transfer(&src, &dst_dir, None);
    let tx = tx.unwrap();
    let (r, path) = rx.unwrap();
    assert_eq!((tx.resumed_from_block, r.resumed_from_block), (3, 3));
    assert_eq!(r.bytes, bytes.len() as u64 - 3 * 4096, "only the missing tail travels");
    assert_eq!(std::fs::read(path).unwrap(), bytes);
}

#[test]
fn source_changed_between_sessions_restarts_from_zero() {
    let (src_dir, dst_dir) = (tmp("src"), tmp("dst"));
    let src = write_src(&src_dir, "f.bin", &data(8 * 4096, 1));
    let _ = transfer(&src, &dst_dir, Some(4));

    let mut changed = data(8 * 4096, 1);
    changed[100] ^= 0xff; // inside the already-received prefix
    std::fs::write(&src, &changed).unwrap();

    let (tx, rx) = transfer(&src, &dst_dir, None);
    assert_eq!(tx.unwrap().resumed_from_block, 0);
    let (r, path) = rx.unwrap();
    assert_eq!((r.resumed_from_block, r.bytes), (0, 8 * 4096));
    assert_eq!(std::fs::read(path).unwrap(), changed);
}

#[test]
fn corrupted_part_file_on_the_receiver_is_detected_and_restarted() {
    let (src_dir, dst_dir) = (tmp("src"), tmp("dst"));
    let bytes = data(8 * 4096, 5);
    let src = write_src(&src_dir, "f.bin", &bytes);
    let _ = transfer(&src, &dst_dir, Some(4));

    let part = dst_dir.join("f.bin.part");
    let mut p = std::fs::read(&part).unwrap();
    p[5000] ^= 1; // bit rot on the receiver's disk
    std::fs::write(&part, p).unwrap();

    let (tx, rx) = transfer(&src, &dst_dir, None);
    assert_eq!(tx.unwrap().resumed_from_block, 0, "prefix hash mismatch must force a restart");
    assert_eq!(std::fs::read(rx.unwrap().1).unwrap(), bytes);
}

#[test]
fn existing_file_is_never_overwritten() {
    let (src_dir, dst_dir) = (tmp("src"), tmp("dst"));
    let src = write_src(&src_dir, "doc.txt", b"new");
    std::fs::write(dst_dir.join("doc.txt"), b"old").unwrap();
    let (tx, rx) = transfer(&src, &dst_dir, None);
    tx.unwrap();
    let (_, path) = rx.unwrap();
    assert_eq!(path.file_name().unwrap(), "doc (1).txt");
    assert_eq!(std::fs::read(dst_dir.join("doc.txt")).unwrap(), b"old");
    assert_eq!(std::fs::read(path).unwrap(), b"new");
}

#[test]
fn hostile_names_are_rejected() {
    for bad in ["", ".", "..", "../x", "a/b", "a\\b", "C:x", "con", "NUL.txt", "lpt1", "a?b", "trail.", "trail ", "x\u{0}y"] {
        assert_eq!(safe_name(bad), Err(TransferError::InvalidName), "{bad:?}");
    }
    for good in ["a.txt", "Pixel de Ana.jpg", "archivo (1).tar.gz", "console.log"] {
        assert!(safe_name(good).is_ok(), "{good:?}");
    }
}

#[test]
fn receiver_rejects_a_hostile_name_in_the_offer() {
    use pb_core::frame::write_frame;
    let dst = tmp("dst");
    let l = TcpListener::bind("127.0.0.1:0").unwrap();
    let addr = l.local_addr().unwrap();
    let d = dst.clone();
    let rx = std::thread::spawn(move || receive_file(&mut l.accept().unwrap().0, &d));
    let mut s = TcpStream::connect(addr).unwrap();
    write_frame(&mut s, &serde_json::json!({"type":"pb.transfer.offer","body":{"name":"../evil","size":1,"blockSize":4096}})).unwrap();
    assert_eq!(rx.join().unwrap().unwrap_err(), TransferError::InvalidName);
    assert!(std::fs::read_dir(&dst).unwrap().next().is_none(), "nothing written");
}
