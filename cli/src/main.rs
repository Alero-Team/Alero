//! CLI test bench. Usage:
//!   pb-cli run <dir> <name> [tcpPort] [downloadDir]   full engine, commands on stdin (type `help`)
//! Spike commands from S3/S4 (single connection, no pairing):
//!   pb-cli id <dir> <name>
//!   pb-cli listen|connect <dir> <addr> <trusted_id|*> ping
//!   pb-cli listen|connect <dir> <addr> <trusted_id|*> send <file> [blockSize] [abortAfterBlocks]
//!   pb-cli listen|connect <dir> <addr> <trusted_id|*> recv <destDir>
//! `*` = pairing mode (accept any peer). Keys are plain files: spike only, the real app
//! uses the OS keystore (Protocol.md §2). TLS role (listen/connect) is independent of send/recv.

use std::io::{BufRead, Read, Write};
use std::sync::Arc;
use std::net::{TcpListener, TcpStream};
use std::path::Path;
use std::time::{Duration, Instant};

use pb_core::engine::{Config, Engine, Event, EventSink, DEFAULT_PORT};
use pb_core::identity::{device_id_from_cert, Identity};
use pb_core::tls::{client_config, peer_device_id, server_config, Verifier};
use pb_core::transfer::{receive_file, send_file, DEFAULT_BLOCK};
use rustls::pki_types::{CertificateDer, PrivatePkcs8KeyDer, ServerName};
use rustls::{ClientConnection, ServerConnection, StreamOwned};

fn load_or_generate(dir: &str, name: &str) -> Result<Identity, String> {
    let (cp, kp) = (Path::new(dir).join("cert.der"), Path::new(dir).join("key.der"));
    if cp.exists() && kp.exists() {
        let cert = CertificateDer::from(std::fs::read(&cp).map_err(|e| e.to_string())?);
        let device_id = device_id_from_cert(&cert)?;
        let key = PrivatePkcs8KeyDer::from(std::fs::read(&kp).map_err(|e| e.to_string())?);
        return Ok(Identity { cert, key, device_id });
    }
    std::fs::create_dir_all(dir).map_err(|e| e.to_string())?;
    let id = Identity::generate(name)?;
    std::fs::write(&cp, id.cert.as_ref()).map_err(|e| e.to_string())?;
    std::fs::write(&kp, id.key.secret_pkcs8_der()).map_err(|e| e.to_string())?;
    Ok(id)
}

fn verifier(arg: &str) -> Verifier {
    if arg == "*" { Verifier::new([], true) } else { Verifier::new([arg.to_string()], false) }
}

fn hex(b: &[u8]) -> String {
    b.iter().map(|x| format!("{x:02x}")).collect()
}

fn report_tls(certs: Option<&[CertificateDer<'static>]>, exporter: Result<[u8; 32], rustls::Error>) -> Result<(), String> {
    println!("peer {}", peer_device_id(certs)?);
    println!("exporter {}", hex(&exporter.map_err(|e| e.to_string())?));
    Ok(())
}

fn run_role<S: Read + Write>(s: &mut S, client: bool, role: &[String]) -> Result<(), String> {
    let arg = |i: usize| role.get(i).map(String::as_str).ok_or_else(|| "missing role argument".to_string());
    let t = Instant::now();
    let line = |kind: &str, r: &pb_core::transfer::Report| {
        let secs = t.elapsed().as_secs_f64();
        println!(
            "RESULT {kind} name={} size={} resumed_from_block={} bytes={} secs={:.3} MB/s={:.1}",
            r.name, r.size, r.resumed_from_block, r.bytes, secs, r.bytes as f64 / 1e6 / secs.max(1e-9)
        );
    };
    match arg(0)? {
        "ping" => {
            let mut b = [0u8; 4];
            if client {
                s.write_all(b"ping").and_then(|_| s.read_exact(&mut b)).map_err(|e| format!("ping failed: {e}"))
            } else {
                s.read_exact(&mut b).and_then(|_| s.write_all(b"pong")).and_then(|_| s.flush()).map_err(|e| format!("ping failed: {e}"))
            }
        }
        "send" => {
            let bs = role.get(2).map_or(Ok(DEFAULT_BLOCK), |v| v.parse()).map_err(|_| "bad blockSize")?;
            let abort = role.get(3).map(|v| v.parse::<u64>()).transpose().map_err(|_| "bad abortAfter")?;
            match send_file(s, Path::new(arg(1)?), bs, abort) {
                Ok(r) => Ok(line("send", &r)),
                Err(e) => Err(format!("send failed: {e:?}")),
            }
        }
        "recv" => match receive_file(s, Path::new(arg(1)?)) {
            Ok((r, path)) => {
                line("recv", &r);
                println!("saved {}", path.display());
                Ok(())
            }
            Err(e) => Err(format!("recv failed: {e:?}")),
        },
        other => Err(format!("unknown role {other}")),
    }
}

struct Print;

impl EventSink for Print {
    fn on_event(&self, e: Event) {
        match e {
            // Progress is chatty on a terminal: print every ~5% only.
            Event::TransferProgress { id, done, total, bytes_per_sec } => {
                if total > 0 && (done * 20 / total != (done.saturating_sub(1_000_000)) * 20 / total || done == total) {
                    println!("PROGRESS {id} {done}/{total} {:.1} MB/s", bytes_per_sec as f64 / 1e6);
                }
            }
            other => println!("EVENT {other:?}"),
        }
    }
}

/// Peer ids are 64 hex chars; accept any unambiguous prefix.
fn resolve(engine: &Engine, prefix: &str) -> Result<String, String> {
    let m: Vec<_> = engine.peers().into_iter().filter(|p| p.id.starts_with(prefix)).collect();
    match m.len() {
        1 => Ok(m[0].id.clone()),
        0 => Err("no such device".into()),
        _ => Err("ambiguous prefix".into()),
    }
}

fn run_engine(a: &[String]) -> Result<(), String> {
    let arg = |i: usize| a.get(i).map(String::as_str).ok_or_else(|| "usage: run <dir> <name> [tcpPort] [downloadDir]".to_string());
    let dir = std::path::PathBuf::from(arg(2)?);
    let port: u16 = a.get(4).map_or(Ok(DEFAULT_PORT), |v| v.parse()).map_err(|_| "bad port")?;
    let cfg = Config {
        data_dir: dir.join("data"),
        download_dir: a.get(5).map_or(dir.join("downloads"), Into::into),
        name: arg(3)?.to_string(),
        port,
        discovery_port: DEFAULT_PORT,
        auto_accept: true,
    };
    let engine = Engine::start(cfg, Arc::new(Print))?;
    println!("READY id={} port={}", engine.device_id(), engine.port());
    for line in std::io::stdin().lock().lines() {
        let line = line.map_err(|e| e.to_string())?;
        let w: Vec<&str> = line.split_whitespace().collect();
        let r: Result<(), String> = match w.as_slice() {
            ["help"] => Ok(println!("peers | pair <id|ip[:port]> | yes <id> | no <id> | send <id> <file> | cancel <xferId> | revoke <id> | history | retry <xferId> | diag | quit")),
            ["peers"] => Ok(engine.peers().iter().for_each(|p| println!("PEER {} {:?} trusted={} {} {}", p.id, p.name, p.trusted, p.addr, format!("{:?}", p.state)))),
            ["pair", t] => resolve(&engine, t).and_then(|id| engine.pair_with_peer(&id)).or_else(|_| engine.pair_with_addr(t)),
            ["yes", id] => resolve(&engine, id).map(|id| engine.respond_pair(&id, true)),
            ["no", id] => resolve(&engine, id).map(|id| engine.respond_pair(&id, false)),
            ["send", id, file] => resolve(&engine, id).and_then(|id| engine.send_file(&id, std::path::Path::new(file), None)).map(|x| println!("QUEUED {x}")),
            ["cancel", x] => Ok(engine.cancel_transfer(x)),
            ["revoke", id] => resolve(&engine, id).and_then(|id| engine.revoke(&id)),
            ["history"] => Ok(engine.history().iter().for_each(|h| println!("HIST {} {} {} {} {}", h.id, if h.incoming { "in" } else { "out" }, h.status, h.name, h.size))),
            ["retry", x] => engine.retry(x).map(|n| println!("QUEUED {n}")),
            ["diag"] => Ok(engine.diagnostics().iter().for_each(|l| println!("DIAG {l}"))),
            ["quit"] => break,
            [] => Ok(()),
            _ => Err("unknown command, try `help`".into()),
        };
        if let Err(e) = r {
            println!("ERROR {e}");
        }
    }
    engine.shutdown();
    Ok(())
}

fn run() -> Result<(), String> {
    let a: Vec<String> = std::env::args().collect();
    let arg = |i: usize| a.get(i).map(String::as_str).ok_or_else(|| "missing argument".to_string());
    let e = |x: &dyn ToString| x.to_string();
    match arg(1)? {
        "run" => run_engine(&a),
        "id" => {
            println!("{}", load_or_generate(arg(2)?, arg(3)?)?.device_id);
            Ok(())
        }
        "listen" => {
            let id = load_or_generate(arg(2)?, "pb-cli")?;
            let cfg = server_config(&id, verifier(arg(4)?)).map_err(|x| e(&x))?;
            let listener = TcpListener::bind(arg(3)?).map_err(|x| e(&x))?;
            println!("listening as {}", id.device_id);
            let (mut tcp, _) = listener.accept().map_err(|x| e(&x))?;
            tcp.set_read_timeout(Some(Duration::from_secs(30))).ok();
            tcp.set_nodelay(true).ok();
            let mut conn = ServerConnection::new(cfg).map_err(|x| e(&x))?;
            while conn.is_handshaking() {
                conn.complete_io(&mut tcp).map_err(|x| format!("handshake failed: {x}"))?;
            }
            report_tls(conn.peer_certificates(), conn.export_keying_material([0u8; 32], b"pb-test", None))?;
            run_role(&mut StreamOwned::new(conn, tcp), false, &a[5..])
        }
        "connect" => {
            let id = load_or_generate(arg(2)?, "pb-cli")?;
            let cfg = client_config(&id, verifier(arg(4)?)).map_err(|x| e(&x))?;
            let mut tcp = TcpStream::connect(arg(3)?).map_err(|x| e(&x))?;
            tcp.set_read_timeout(Some(Duration::from_secs(30))).ok();
            tcp.set_nodelay(true).ok();
            let mut conn = ClientConnection::new(cfg, ServerName::try_from("phonebridge").unwrap()).map_err(|x| e(&x))?;
            while conn.is_handshaking() {
                conn.complete_io(&mut tcp).map_err(|x| format!("handshake failed: {x}"))?;
            }
            report_tls(conn.peer_certificates(), conn.export_keying_material([0u8; 32], b"pb-test", None))?;
            run_role(&mut StreamOwned::new(conn, tcp), true, &a[5..])
        }
        other => Err(format!("unknown command {other}")),
    }
}

fn main() {
    if let Err(e) = run() {
        eprintln!("ERROR {e}");
        std::process::exit(1);
    }
}
