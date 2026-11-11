//! TLS 1.3 with mutual authentication and pinning by deviceId.
//! A certificate is accepted only if its deviceId is trusted, or while pairing (the caller
//! then checks `peer_device_id` against the QR/SAS). Early data stays off: rustls' default
//! `max_early_data_size` is 0, so there is no 0-RTT.

use std::collections::HashSet;
use std::sync::{Arc, RwLock};

use rustls::client::danger::{HandshakeSignatureValid, ServerCertVerified, ServerCertVerifier};
use rustls::crypto::{ring, verify_tls12_signature, verify_tls13_signature, CryptoProvider};
use rustls::pki_types::{CertificateDer, UnixTime};
use rustls::server::danger::{ClientCertVerified, ClientCertVerifier};
use rustls::{CertificateError, ClientConfig, DigitallySignedStruct, DistinguishedName, Error, ServerConfig, SignatureScheme};

use crate::identity::{device_id_from_cert, Identity};

/// Decides which certificates are accepted. The trusted set can be shared and edited at runtime, so
/// pairing and revoking take effect on the next handshake without rebuilding the config.
#[derive(Debug)]
pub struct Verifier {
    trusted: Arc<RwLock<HashSet<String>>>,
    accept_unknown: bool,
    provider: Arc<CryptoProvider>,
}

impl Verifier {
    pub fn new(trusted: impl IntoIterator<Item = String>, accept_unknown: bool) -> Self {
        Self::shared(Arc::new(RwLock::new(trusted.into_iter().collect())), accept_unknown)
    }

    pub fn shared(trusted: Arc<RwLock<HashSet<String>>>, accept_unknown: bool) -> Self {
        Self { trusted, accept_unknown, provider: provider() }
    }

    fn check(&self, cert: &CertificateDer<'_>) -> Result<(), Error> {
        let id = device_id_from_cert(cert).map_err(|_| CertificateError::BadEncoding)?;
        if self.accept_unknown || self.trusted.read().map_err(|_| Error::General("trust lock poisoned".into()))?.contains(&id) {
            Ok(())
        } else {
            Err(CertificateError::ApplicationVerificationFailure.into())
        }
    }
}

fn provider() -> Arc<CryptoProvider> {
    Arc::new(ring::default_provider())
}

impl ServerCertVerifier for Verifier {
    fn verify_server_cert(
        &self,
        end_entity: &CertificateDer<'_>,
        _intermediates: &[CertificateDer<'_>],
        _server_name: &rustls::pki_types::ServerName<'_>,
        _ocsp: &[u8],
        _now: UnixTime,
    ) -> Result<ServerCertVerified, Error> {
        self.check(end_entity).map(|_| ServerCertVerified::assertion())
    }

    fn verify_tls12_signature(&self, m: &[u8], c: &CertificateDer<'_>, d: &DigitallySignedStruct) -> Result<HandshakeSignatureValid, Error> {
        verify_tls12_signature(m, c, d, &self.provider.signature_verification_algorithms)
    }

    fn verify_tls13_signature(&self, m: &[u8], c: &CertificateDer<'_>, d: &DigitallySignedStruct) -> Result<HandshakeSignatureValid, Error> {
        verify_tls13_signature(m, c, d, &self.provider.signature_verification_algorithms)
    }

    fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
        self.provider.signature_verification_algorithms.supported_schemes()
    }
}

impl ClientCertVerifier for Verifier {
    fn root_hint_subjects(&self) -> &[DistinguishedName] {
        &[]
    }

    fn verify_client_cert(&self, end_entity: &CertificateDer<'_>, _intermediates: &[CertificateDer<'_>], _now: UnixTime) -> Result<ClientCertVerified, Error> {
        self.check(end_entity).map(|_| ClientCertVerified::assertion())
    }

    fn verify_tls12_signature(&self, m: &[u8], c: &CertificateDer<'_>, d: &DigitallySignedStruct) -> Result<HandshakeSignatureValid, Error> {
        verify_tls12_signature(m, c, d, &self.provider.signature_verification_algorithms)
    }

    fn verify_tls13_signature(&self, m: &[u8], c: &CertificateDer<'_>, d: &DigitallySignedStruct) -> Result<HandshakeSignatureValid, Error> {
        verify_tls13_signature(m, c, d, &self.provider.signature_verification_algorithms)
    }

    fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
        self.provider.signature_verification_algorithms.supported_schemes()
    }
}

pub fn client_config(id: &Identity, verifier: Verifier) -> Result<Arc<ClientConfig>, Error> {
    Ok(Arc::new(
        ClientConfig::builder_with_provider(provider())
            .with_protocol_versions(&[&rustls::version::TLS13])?
            .dangerous()
            .with_custom_certificate_verifier(Arc::new(verifier))
            .with_client_auth_cert(vec![id.cert.clone()], id.key_der())?,
    ))
}

pub fn server_config(id: &Identity, verifier: Verifier) -> Result<Arc<ServerConfig>, Error> {
    Ok(Arc::new(
        ServerConfig::builder_with_provider(provider())
            .with_protocol_versions(&[&rustls::version::TLS13])?
            .with_client_cert_verifier(Arc::new(verifier))
            .with_single_cert(vec![id.cert.clone()], id.key_der())?,
    ))
}

/// DeviceId of the peer, from the certificate it presented during the handshake.
pub fn peer_device_id(certs: Option<&[CertificateDer<'static>]>) -> Result<String, String> {
    device_id_from_cert(certs.and_then(|c| c.first()).ok_or("peer sent no certificate")?)
}
