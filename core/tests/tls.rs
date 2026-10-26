use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::time::Duration;

use pb_core::identity::Identity;
use pb_core::tls::{client_config, peer_device_id, server_config, Verifier};
use rustls::pki_types::ServerName;
use rustls::{ClientConnection, ServerConnection, StreamOwned};

/// What one side learned: the peer's deviceId (from its certificate) and the TLS exporter output.
type Outcome = Result<(String, [u8; 32]), String>;

fn run(srv: (&Identity, Verifier), cli: (&Identity, Verifier)) -> (Outcome, Outcome) {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let addr = listener.local_addr().unwrap();
    let cfg = server_config(srv.0, srv.1).unwrap();

    let server = std::thread::spawn(move || -> Outcome {
        let (tcp, _) = listener.accept().map_err(|e| e.to_string())?;
        tcp.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
        let mut s = StreamOwned::new(ServerConnection::new(cfg).map_err(|e| e.to_string())?, tcp);
        let mut buf = [0u8; 4];
        s.read_exact(&mut buf).map_err(|e| e.to_string())?;
        s.write_all(b"pong").map_err(|e| e.to_string())?;
        s.flush().map_err(|e| e.to_string())?;
        let id = peer_device_id(s.conn.peer_certificates())?;
        let ex = s.conn.export_keying_material([0u8; 32], b"pb-test", None).map_err(|e| e.to_string())?;
        Ok((id, ex))
    });

    let cfg = client_config(cli.0, cli.1).unwrap();
    let client = (|| -> Outcome {
        let tcp = TcpStream::connect(addr).map_err(|e| e.to_string())?;
        tcp.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
        let name = ServerName::try_from("phonebridge").unwrap();
        let mut s = StreamOwned::new(ClientConnection::new(cfg, name).map_err(|e| e.to_string())?, tcp);
        s.write_all(b"ping").map_err(|e| e.to_string())?;
        let mut buf = [0u8; 4];
        s.read_exact(&mut buf).map_err(|e| e.to_string())?;
        assert_eq!(&buf, b"pong");
        let id = peer_device_id(s.conn.peer_certificates())?;
        let ex = s.conn.export_keying_material([0u8; 32], b"pb-test", None).map_err(|e| e.to_string())?;
        Ok((id, ex))
    })();
    (server.join().unwrap(), client)
}

fn trust(ids: &[&Identity]) -> Verifier {
    Verifier::new(ids.iter().map(|i| i.device_id.clone()), false)
}

#[test]
fn device_id_is_sha256_hex_and_unique() {
    let (a, b) = (Identity::generate("a").unwrap(), Identity::generate("a").unwrap());
    assert_eq!(a.device_id.len(), 64);
    assert!(a.device_id.bytes().all(|c| c.is_ascii_digit() || (b'a'..=b'f').contains(&c)));
    assert_ne!(a.device_id, b.device_id, "same name must not give the same id");
}

#[test]
fn mutual_trust_succeeds_and_each_side_derives_the_peer_id() {
    let (pc, phone) = (Identity::generate("pc").unwrap(), Identity::generate("phone").unwrap());
    let (srv, cli) = run((&pc, trust(&[&phone])), (&phone, trust(&[&pc])));
    let (srv, cli) = (srv.unwrap(), cli.unwrap());
    assert_eq!(srv.0, phone.device_id);
    assert_eq!(cli.0, pc.device_id);
    assert_eq!(srv.1, cli.1, "exporter output must match on both sides (usable for SAS channel binding)");
}

#[test]
fn server_rejects_unknown_client() {
    let (pc, phone) = (Identity::generate("pc").unwrap(), Identity::generate("phone").unwrap());
    let (srv, cli) = run((&pc, trust(&[])), (&phone, trust(&[&pc])));
    assert!(srv.is_err(), "server must reject an untrusted client");
    assert!(cli.is_err(), "client must not get a response");
}

#[test]
fn client_rejects_unknown_server() {
    let (pc, phone) = (Identity::generate("pc").unwrap(), Identity::generate("phone").unwrap());
    let (srv, cli) = run((&pc, trust(&[&phone])), (&phone, trust(&[])));
    assert!(cli.is_err(), "client must reject an untrusted server");
    assert!(srv.is_err());
}

#[test]
fn same_name_different_key_is_rejected() {
    // An attacker presents the same certificate name as the paired PC but with another key.
    let (pc, phone) = (Identity::generate("pc").unwrap(), Identity::generate("phone").unwrap());
    let impostor = Identity::generate("pc").unwrap();
    let (_, cli) = run((&impostor, trust(&[&phone])), (&phone, trust(&[&pc])));
    assert!(cli.is_err(), "pinned deviceId must not match a different key with the same name");
}

#[test]
fn pairing_mode_accepts_unknown_and_exposes_the_real_ids() {
    let (pc, phone) = (Identity::generate("pc").unwrap(), Identity::generate("phone").unwrap());
    let open = || Verifier::new([], true);
    let (srv, cli) = run((&pc, open()), (&phone, open()));
    assert_eq!(srv.unwrap().0, phone.device_id);
    assert_eq!(cli.unwrap().0, pc.device_id, "caller compares this id with the QR/SAS");
}
