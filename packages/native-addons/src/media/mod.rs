use std::net::{IpAddr, Ipv4Addr, Ipv6Addr};
use std::str::FromStr;
use std::sync::LazyLock;

use ipnet::{Ipv4Net, Ipv6Net};
use napi::bindgen_prelude::*;
use napi_derive::napi;

/// IPv4 ranges that must never be fetched for external media (SSRF guard):
/// "this network", RFC 1918 private, loopback, CGNAT, link-local, benchmarking,
/// and reserved-future blocks.
static BLOCKED_V4: LazyLock<Vec<Ipv4Net>> = LazyLock::new(|| {
  [
    "0.0.0.0/8",
    "10.0.0.0/8",
    "100.64.0.0/10",
    "127.0.0.0/8",
    "169.254.0.0/16",
    "172.16.0.0/12",
    "192.0.0.0/24",
    "192.168.0.0/16",
    "198.18.0.0/15",
    "240.0.0.0/4",
  ]
  .iter()
  .map(|net| Ipv4Net::from_str(net).expect("static network"))
  .collect()
});

/// IPv6 ranges blocked for external media: unspecified, loopback, ULA,
/// link-local, and the NAT64 well-known prefix (whose embedded v4 target is
/// checked separately).
static BLOCKED_V6: LazyLock<Vec<Ipv6Net>> = LazyLock::new(|| {
  ["::/128", "::1/128", "fc00::/7", "fe80::/10", "64:ff9b::/96"]
    .iter()
    .map(|net| Ipv6Net::from_str(net).expect("static network"))
    .collect()
});

fn v4_blocked(address: Ipv4Addr) -> bool {
  BLOCKED_V4.iter().any(|net| net.contains(&address))
}

fn v6_blocked(address: Ipv6Addr) -> bool {
  if let Some(mapped) = address.to_ipv4_mapped() {
    return v4_blocked(mapped);
  }
  if BLOCKED_V6.iter().any(|net| net.contains(&address)) {
    // NAT64 prefix: also classify by the embedded IPv4 address.
    return true;
  }
  false
}

/// Returns true when an IP address (v4 or v6 textual form) must not be fetched
/// for external media: private, loopback, link-local, CGNAT, ULA, v4-mapped
/// and NAT64-embedded forms included. Unparseable input is blocked.
#[napi]
pub fn is_blocked_ip_address(host: String) -> bool {
  match IpAddr::from_str(host.trim()) {
    Ok(IpAddr::V4(address)) => v4_blocked(address),
    Ok(IpAddr::V6(address)) => v6_blocked(address),
    Err(_) => true,
  }
}

#[napi(object)]
pub struct SniffedImage {
  pub mime_type: String,
  pub default_ext: String,
}

/// Sniffs image bytes by magic numbers (PNG/JPEG/GIF/BMP/WebP/HEIC/AVIF/...).
/// Returns null when the buffer is not a recognized image format.
#[napi]
pub fn sniff_image_media(data: Buffer) -> Option<SniffedImage> {
  let kind = infer::get(data.as_ref())?;
  if !kind.mime_type().starts_with("image/") {
    return None;
  }
  Some(SniffedImage {
    mime_type: kind.mime_type().to_string(),
    default_ext: format!(".{}", kind.extension()),
  })
}
