use std::net::IpAddr;

use napi::bindgen_prelude::*;
use napi_derive::napi;
use rcgen::{
  BasicConstraints, CertificateParams, DistinguishedName, DnType, ExtendedKeyUsagePurpose, IsCa,
  KeyPair, KeyUsagePurpose, SanType,
};
use time::{Duration, OffsetDateTime};

#[napi(object)]
pub struct MtlsBundle {
  pub ca_cert_pem: String,
  pub app_cert_pem: String,
  pub app_key_pem: String,
  pub worker_cert_pem: String,
  pub worker_key_pem: String,
}

fn gen_error(scope: &str, error: impl std::fmt::Display) -> Error {
  Error::new(
    Status::GenericFailure,
    format!("mTLS bundle {scope}: {error}"),
  )
}

fn distinguished_name(common_name: &str) -> DistinguishedName {
  let mut name = DistinguishedName::new();
  name.push(DnType::CommonName, common_name);
  name
}

/// Generates a self-signed mTLS bundle for the app <-> computer-worker link:
/// one root CA, a client certificate for the app, and a server certificate for
/// the worker carrying the supplied DNS/IP SANs. Keys are ECDSA P-256; validity
/// is `validDays` from now.
#[napi]
pub fn generate_mtls_bundle(
  worker_dns_names: Vec<String>,
  worker_ip_addresses: Vec<String>,
  valid_days: u32,
) -> Result<MtlsBundle> {
  let not_before = OffsetDateTime::now_utc();
  let not_after = not_before + Duration::days(i64::from(valid_days));

  let ca_key = KeyPair::generate().map_err(|e| gen_error("CA key", e))?;
  let mut ca_params = CertificateParams::default();
  ca_params.distinguished_name = distinguished_name("BullX Computer Root CA");
  ca_params.is_ca = IsCa::Ca(BasicConstraints::Unconstrained);
  ca_params.key_usages = vec![KeyUsagePurpose::KeyCertSign, KeyUsagePurpose::CrlSign];
  ca_params.not_before = not_before;
  ca_params.not_after = not_after;
  let ca_cert = ca_params
    .self_signed(&ca_key)
    .map_err(|e| gen_error("CA certificate", e))?;
  let ca_issuer = rcgen::Issuer::new(ca_params, ca_key);

  let app_key = KeyPair::generate().map_err(|e| gen_error("app key", e))?;
  let mut app_params = CertificateParams::default();
  app_params.distinguished_name = distinguished_name("BullX Agent App");
  app_params.key_usages = vec![
    KeyUsagePurpose::DigitalSignature,
    KeyUsagePurpose::KeyEncipherment,
  ];
  app_params.extended_key_usages = vec![ExtendedKeyUsagePurpose::ClientAuth];
  app_params.not_before = not_before;
  app_params.not_after = not_after;
  let app_cert = app_params
    .signed_by(&app_key, &ca_issuer)
    .map_err(|e| gen_error("app certificate", e))?;

  let worker_key = KeyPair::generate().map_err(|e| gen_error("worker key", e))?;
  let mut worker_params = CertificateParams::default();
  worker_params.distinguished_name = distinguished_name("BullX Computer Worker");
  worker_params.key_usages = vec![
    KeyUsagePurpose::DigitalSignature,
    KeyUsagePurpose::KeyEncipherment,
  ];
  worker_params.extended_key_usages = vec![ExtendedKeyUsagePurpose::ServerAuth];
  worker_params.not_before = not_before;
  worker_params.not_after = not_after;
  for dns in &worker_dns_names {
    worker_params.subject_alt_names.push(SanType::DnsName(
      dns
        .clone()
        .try_into()
        .map_err(|e| gen_error("worker DNS SAN", e))?,
    ));
  }
  for ip in &worker_ip_addresses {
    let parsed: IpAddr = ip
      .parse()
      .map_err(|e| gen_error(&format!("worker IP SAN {ip}"), e))?;
    worker_params
      .subject_alt_names
      .push(SanType::IpAddress(parsed));
  }
  let worker_cert = worker_params
    .signed_by(&worker_key, &ca_issuer)
    .map_err(|e| gen_error("worker certificate", e))?;

  Ok(MtlsBundle {
    ca_cert_pem: ca_cert.pem(),
    app_cert_pem: app_cert.pem(),
    app_key_pem: app_key.serialize_pem(),
    worker_cert_pem: worker_cert.pem(),
    worker_key_pem: worker_key.serialize_pem(),
  })
}
