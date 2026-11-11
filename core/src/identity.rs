//! Device identity: self-signed ECDSA P-256 cert; deviceId = SHA-256(SPKI), lowercase hex.
//! The id is derived from the certificate, never from anything a peer merely announces.

use rcgen::{CertificateParams, KeyPair, PKCS_ECDSA_P256_SHA256};
use rustls::pki_types::{CertificateDer, PrivateKeyDer, PrivatePkcs8KeyDer};
use sha2::{Digest, Sha256};

pub struct Identity {
    pub cert: CertificateDer<'static>,
    pub key: PrivatePkcs8KeyDer<'static>,
    pub device_id: String,
}

impl Identity {
    /// `name` only labels the certificate; it carries no trust.
    pub fn generate(name: &str) -> Result<Self, String> {
        let key_pair = KeyPair::generate_for(&PKCS_ECDSA_P256_SHA256).map_err(|e| e.to_string())?;
        let params = CertificateParams::new(vec![name.to_string()]).map_err(|e| e.to_string())?;
        let cert = params.self_signed(&key_pair).map_err(|e| e.to_string())?;
        let cert = cert.der().clone();
        let device_id = device_id_from_cert(&cert)?;
        let key = PrivatePkcs8KeyDer::from(key_pair.serialize_der());
        Ok(Self { cert, key, device_id })
    }

    pub fn key_der(&self) -> PrivateKeyDer<'static> {
        PrivateKeyDer::Pkcs8(self.key.clone_key())
    }
}

/// SHA-256 over the DER-encoded SubjectPublicKeyInfo, as lowercase hex.
pub fn device_id_from_cert(cert: &CertificateDer<'_>) -> Result<String, String> {
    let (_, parsed) = x509_parser::parse_x509_certificate(cert.as_ref()).map_err(|e| e.to_string())?;
    let digest = Sha256::digest(parsed.tbs_certificate.subject_pki.raw);
    Ok(digest.iter().map(|b| format!("{b:02x}")).collect())
}
