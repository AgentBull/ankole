//! Computer mTLS bundle loading.
//!
//! The Bun app stores a plaintext app-config envelope whose payload is sealed
//! with BULLX_COMPUTER_TOKEN. The worker can unseal it without BULLX_SECRET_BASE.

use std::io::Cursor;
use std::sync::Arc;

use anyhow::{Context, Result};
use rustls::pki_types::{CertificateDer, PrivateKeyDer};
use rustls::server::WebPkiClientVerifier;
use rustls::{RootCertStore, ServerConfig};
use serde::Deserialize;
use tokio_postgres::NoTls;

use crate::sealed;

const COMPUTER_TLS_BUNDLE_KEY: &str = "computer.tls.bundle.v1";
const KEY_SUB_ID: &str = "computer_tls_bundle";
const KEY_CONTEXT: &str = "v1";
const SEAL_LABEL: &str = "computer TLS bundle";

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ComputerTlsMaterial {
  pub ca_cert_pem: String,
  pub worker_cert_pem: String,
  pub worker_key_pem: String,
}

#[derive(Deserialize)]
struct StoredEnvelope {
  #[serde(rename = "type")]
  value_type: String,
  value: SealedBundle,
}

#[derive(Deserialize)]
struct SealedBundle {
  version: u8,
  sealed: String,
}

pub async fn load_computer_tls_material(
  database_url: &str,
  computer_token: &str,
) -> Result<ComputerTlsMaterial> {
  let (client, connection) = tokio_postgres::connect(database_url, NoTls)
    .await
    .context("connect PostgreSQL for computer TLS bundle")?;
  tokio::spawn(async move {
    if let Err(error) = connection.await {
      tracing::warn!(%error, "PostgreSQL TLS bundle connection task ended");
    }
  });
  let row = client
    .query_opt(
      "select value from app_configure where key = $1 limit 1",
      &[&COMPUTER_TLS_BUNDLE_KEY],
    )
    .await
    .context("read computer TLS bundle from app_configure")?
    .context("computer TLS bundle is missing; start the BullX app once to create it")?;
  let envelope: serde_json::Value = row.get(0);
  let envelope: StoredEnvelope =
    serde_json::from_value(envelope).context("decode computer TLS app-config envelope")?;
  anyhow::ensure!(
    envelope.value_type == "plaintext",
    "computer TLS bundle must be stored as plaintext sealed envelope"
  );
  anyhow::ensure!(
    envelope.value.version == 1,
    "unsupported computer TLS bundle version"
  );
  let plain = sealed::unseal(
    &envelope.value.sealed,
    computer_token,
    KEY_SUB_ID,
    Some(KEY_CONTEXT),
    SEAL_LABEL,
  )?;
  serde_json::from_slice(&plain).context("decode unsealed computer TLS bundle")
}

pub fn rustls_server_config(material: &ComputerTlsMaterial) -> Result<ServerConfig> {
  let ca_certs = certificates(&material.ca_cert_pem)?;
  let worker_certs = certificates(&material.worker_cert_pem)?;
  let worker_key = private_key(&material.worker_key_pem)?;

  let mut roots = RootCertStore::empty();
  for cert in ca_certs {
    roots.add(cert).context("add computer CA certificate")?;
  }
  let client_verifier = WebPkiClientVerifier::builder(Arc::new(roots))
    .build()
    .context("build computer client certificate verifier")?;
  let mut config = ServerConfig::builder()
    .with_client_cert_verifier(client_verifier)
    .with_single_cert(worker_certs, worker_key)
    .context("build computer worker TLS certificate")?;
  config.alpn_protocols = vec![b"h2".to_vec()];
  Ok(config)
}

fn certificates(pem: &str) -> Result<Vec<CertificateDer<'static>>> {
  rustls_pemfile::certs(&mut Cursor::new(pem))
    .collect::<std::result::Result<Vec<_>, _>>()
    .context("parse certificate PEM")
}

fn private_key(pem: &str) -> Result<PrivateKeyDer<'static>> {
  rustls_pemfile::private_key(&mut Cursor::new(pem))
    .context("parse private key PEM")?
    .context("private key PEM is missing")
}
