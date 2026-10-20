//! WHATWG URL facts for the shared web URL policy.
//!
//! AIGateway `web_fetch` validation, Brain source fetches, the Lark image
//! resolver and browser consume these rules through NIF and Node-API bindings.
//! Callers supply scheme restrictions and the private-network setting. The
//! connection owner must use the checked IP address without another DNS lookup.

use std::net::{IpAddr, Ipv4Addr, Ipv6Addr};

use url::{Host, Url as URL};

use crate::common::{KernelError, KernelResult};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum HostClass {
    /// Cloud metadata endpoints; rejected regardless of policy.
    Metadata,
    /// Localhost names and non-public literal IP addresses; rejected only when
    /// `security.ssrf_filter` is enabled.
    Private,
    /// Everything else, including DNS names that are only resolved later.
    Public,
}

impl HostClass {
    pub fn as_str(self) -> &'static str {
        match self {
            HostClass::Metadata => "metadata",
            HostClass::Private => "private",
            HostClass::Public => "public",
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct WebURLFacts {
    pub scheme: String,
    /// `None` for host-less URLs such as `data:` and `about:`.
    pub host: Option<String>,
    pub host_class: Option<HostClass>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum WebURLRejection {
    Metadata,
    Private,
    Invalid,
}

impl WebURLRejection {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Metadata => "metadata",
            Self::Private => "private",
            Self::Invalid => "invalid",
        }
    }
}

/// Checks URL syntax, allowed schemes, and the literal host. Does not do DNS.
pub fn validate_web_url(
    input: &str,
    schemes: &[&str],
    ssrf_filter: bool,
) -> Result<(), WebURLRejection> {
    let facts = web_url_facts(input).map_err(|_| WebURLRejection::Invalid)?;
    let class = facts.host_class.ok_or(WebURLRejection::Invalid)?;
    validate_host_class(class, ssrf_filter)?;
    if !schemes.contains(&facts.scheme.as_str()) {
        // Preserve the established private-host rejection for unsupported schemes.
        return Err(if class == HostClass::Private {
            WebURLRejection::Private
        } else {
            WebURLRejection::Invalid
        });
    }
    Ok(())
}

/// Checks every DNS answer, including addresses that a client might try later.
pub fn validate_ip_addresses(
    addresses: &[IpAddr],
    ssrf_filter: bool,
) -> Result<(), WebURLRejection> {
    if addresses.is_empty() {
        return Err(WebURLRejection::Invalid);
    }
    for address in addresses {
        validate_host_class(classify_ip(*address), ssrf_filter)?;
    }
    Ok(())
}

#[cfg(feature = "web_proxy")]
pub(crate) fn validate_host<S: AsRef<str>>(
    host: &Host<S>,
    ssrf_filter: bool,
) -> Result<(), WebURLRejection> {
    validate_host_class(classify_host(host), ssrf_filter)
}

fn validate_host_class(class: HostClass, ssrf_filter: bool) -> Result<(), WebURLRejection> {
    match class {
        HostClass::Metadata => Err(WebURLRejection::Metadata),
        HostClass::Private if ssrf_filter => Err(WebURLRejection::Private),
        _ => Ok(()),
    }
}

pub fn web_url_facts(input: &str) -> KernelResult<WebURLFacts> {
    let url =
        URL::parse(input).map_err(|error| KernelError::new(format!("invalid web url: {error}")))?;

    let (host, host_class) = match url.host() {
        Some(host) => (Some(host_text(&host)), Some(classify_host(&host))),
        None => (None, None),
    };

    Ok(WebURLFacts {
        scheme: url.scheme().to_string(),
        host,
        host_class,
    })
}

fn host_text(host: &Host<&str>) -> String {
    match host {
        Host::Domain(domain) => (*domain).to_string(),
        Host::Ipv4(ip) => ip.to_string(),
        Host::Ipv6(ip) => ip.to_string(),
    }
}

fn classify_host<S: AsRef<str>>(host: &Host<S>) -> HostClass {
    match host {
        Host::Domain(domain) => classify_domain(domain.as_ref()),
        Host::Ipv4(ip) => classify_ipv4(*ip),
        Host::Ipv6(ip) => classify_ipv6(*ip),
    }
}

fn classify_ip(ip: IpAddr) -> HostClass {
    match ip {
        IpAddr::V4(ip) => classify_ipv4(ip),
        IpAddr::V6(ip) => classify_ipv6(ip),
    }
}

fn classify_domain(domain: &str) -> HostClass {
    let domain = domain.trim_end_matches('.');
    if domain == "metadata" || domain == "metadata.google.internal" {
        return HostClass::Metadata;
    }
    if domain == "localhost" || domain.ends_with(".localhost") {
        return HostClass::Private;
    }
    HostClass::Public
}

const METADATA_IPV4: [Ipv4Addr; 3] = [
    Ipv4Addr::new(169, 254, 169, 254),
    Ipv4Addr::new(169, 254, 169, 250),
    Ipv4Addr::new(169, 254, 169, 251),
];

/// AWS IMDSv6 endpoint.
const METADATA_IPV6: Ipv6Addr = Ipv6Addr::new(0xfd00, 0x0ec2, 0, 0, 0, 0, 0, 0x0254);

fn classify_ipv4(ip: Ipv4Addr) -> HostClass {
    if METADATA_IPV4.contains(&ip) {
        return HostClass::Metadata;
    }

    let [first, second, _, _] = ip.octets();
    let private = first == 0
        || first == 10
        || first == 127
        || (first == 100 && (64..=127).contains(&second))
        || (first == 169 && second == 254)
        || (first == 172 && (16..=31).contains(&second))
        || (first == 192 && second == 168);

    if private {
        HostClass::Private
    } else {
        HostClass::Public
    }
}

fn classify_ipv6(ip: Ipv6Addr) -> HostClass {
    // IPv4-mapped addresses take the IPv4 verdict so `[::ffff:10.0.0.1]`
    // cannot sidestep the RFC1918 classification.
    if let Some(mapped) = ip.to_ipv4_mapped() {
        return classify_ipv4(mapped);
    }
    if ip == METADATA_IPV6 {
        return HostClass::Metadata;
    }

    let first_segment = ip.segments()[0];
    // Link-local (fe80::/10) stays in the always-rejected metadata set.
    if (first_segment & 0xffc0) == 0xfe80 {
        return HostClass::Metadata;
    }
    if ip == Ipv6Addr::LOCALHOST || (first_segment & 0xfe00) == 0xfc00 {
        return HostClass::Private;
    }
    HostClass::Public
}

#[cfg(test)]
mod tests {
    use super::*;

    fn class_of(url: &str) -> Option<HostClass> {
        web_url_facts(url).unwrap().host_class
    }

    #[test]
    fn classifies_domains() {
        assert_eq!(class_of("https://metadata/x"), Some(HostClass::Metadata));
        assert_eq!(
            class_of("https://metadata.google.internal/computeMetadata/v1/"),
            Some(HostClass::Metadata)
        );
        assert_eq!(class_of("https://localhost/x"), Some(HostClass::Private));
        assert_eq!(
            class_of("https://svc.localhost/x"),
            Some(HostClass::Private)
        );
        assert_eq!(class_of("https://example.com/x"), Some(HostClass::Public));
        assert_eq!(class_of("https://intranet-wiki/x"), Some(HostClass::Public));
    }

    #[test]
    fn classifies_ipv4_ranges() {
        for private in [
            "10.1.2.3",
            "127.0.0.1",
            "169.254.1.1",
            "172.16.0.1",
            "172.31.255.255",
            "192.168.1.1",
            "100.64.0.1",
            "100.127.255.255",
            "0.1.2.3",
        ] {
            assert_eq!(
                class_of(&format!("https://{private}/x")),
                Some(HostClass::Private),
                "{private} must be private"
            );
        }

        for public in [
            "8.8.8.8",
            "172.15.255.255",
            "172.32.0.1",
            "192.169.1.1",
            "100.63.255.255",
            "100.128.0.1",
        ] {
            assert_eq!(
                class_of(&format!("https://{public}/x")),
                Some(HostClass::Public),
                "{public} must be public"
            );
        }

        for metadata in ["169.254.169.254", "169.254.169.250", "169.254.169.251"] {
            assert_eq!(
                class_of(&format!("https://{metadata}/x")),
                Some(HostClass::Metadata),
                "{metadata} must be metadata"
            );
        }
    }

    #[test]
    fn classifies_ipv6_ranges() {
        assert_eq!(class_of("https://[::1]/x"), Some(HostClass::Private));
        assert_eq!(class_of("https://[fc00::1]/x"), Some(HostClass::Private));
        assert_eq!(
            class_of("https://[fd12:3456::1]/x"),
            Some(HostClass::Private)
        );
        assert_eq!(class_of("https://[fe80::1]/x"), Some(HostClass::Metadata));
        assert_eq!(class_of("https://[febf::1]/x"), Some(HostClass::Metadata));
        assert_eq!(
            class_of("https://[fd00:ec2::254]/x"),
            Some(HostClass::Metadata)
        );
        assert_eq!(class_of("https://[2001:db8::1]/x"), Some(HostClass::Public));
    }

    #[test]
    fn classifies_ipv4_mapped_ipv6_by_the_embedded_address() {
        assert_eq!(
            class_of("https://[::ffff:10.0.0.1]/x"),
            Some(HostClass::Private)
        );
        assert_eq!(
            class_of("https://[::ffff:169.254.169.254]/x"),
            Some(HostClass::Metadata)
        );
        assert_eq!(
            class_of("https://[::ffff:8.8.8.8]/x"),
            Some(HostClass::Public)
        );
    }

    #[test]
    fn whatwg_canonicalization_feeds_classification() {
        let facts = web_url_facts("https://0x7f000001/x").unwrap();
        assert_eq!(facts.host.as_deref(), Some("127.0.0.1"));
        assert_eq!(facts.host_class, Some(HostClass::Private));

        let facts = web_url_facts("https://LOCALHOST/x").unwrap();
        assert_eq!(facts.host.as_deref(), Some("localhost"));
        assert_eq!(facts.host_class, Some(HostClass::Private));

        let facts = web_url_facts("  https://Example.COM/x  ").unwrap();
        assert_eq!(facts.host.as_deref(), Some("example.com"));
        assert_eq!(facts.host_class, Some(HostClass::Public));
    }

    #[test]
    fn reports_scheme_and_hostless_urls() {
        let facts = web_url_facts("data:text/plain,hi").unwrap();
        assert_eq!(facts.scheme, "data");
        assert_eq!(facts.host, None);
        assert_eq!(facts.host_class, None);

        let facts = web_url_facts("about:blank").unwrap();
        assert_eq!(facts.scheme, "about");
        assert_eq!(facts.host, None);

        assert_eq!(web_url_facts("ftp://example.com/x").unwrap().scheme, "ftp");
        assert!(web_url_facts("not a url").is_err());
        assert!(web_url_facts("/relative/path").is_err());
    }

    #[test]
    fn shared_host_classification_vectors_hold() {
        let text = std::fs::read_to_string(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/test/vectors/web_url_host_classification.json"
        ))
        .unwrap();
        let vectors: serde_json::Value = serde_json::from_str(&text).unwrap();

        for vector in vectors["addresses"].as_array().unwrap() {
            let input = vector["input"].as_str().unwrap();
            let expected = vector["class"].as_str().unwrap();
            let url = if input.contains(':') {
                format!("https://[{input}]/")
            } else {
                format!("https://{input}/")
            };

            assert_eq!(
                web_url_facts(&url)
                    .unwrap()
                    .host_class
                    .map(HostClass::as_str),
                Some(expected),
                "{input} must classify as {expected}"
            );
        }
        for vector in vectors["urls"].as_array().unwrap() {
            let input = vector["input"].as_str().unwrap();
            assert_eq!(
                web_url_facts(input).unwrap().host_class.unwrap().as_str(),
                vector["class"].as_str().unwrap(),
                "{input}"
            );
        }
        for input in vectors["invalid_urls"].as_array().unwrap() {
            assert_eq!(
                validate_web_url(input.as_str().unwrap(), &["http", "https"], false),
                Err(WebURLRejection::Invalid)
            );
        }
    }

    #[test]
    fn admission_keeps_scheme_and_network_policy_in_one_owner() {
        assert_eq!(
            validate_web_url("https://example.com/", &["https"], true),
            Ok(())
        );
        assert_eq!(
            validate_web_url("http://example.com/", &["https"], false),
            Err(WebURLRejection::Invalid)
        );
        assert_eq!(
            validate_web_url("http://10.0.0.1/", &["http"], true),
            Err(WebURLRejection::Private)
        );
        assert_eq!(
            validate_web_url("http://10.0.0.1/", &["http"], false),
            Ok(())
        );
        assert_eq!(
            validate_web_url("ftp://10.0.0.1/", &["https"], false),
            Err(WebURLRejection::Private)
        );
        assert_eq!(
            validate_web_url("https://metadata./", &["https"], false),
            Err(WebURLRejection::Metadata)
        );
        assert_eq!(
            validate_web_url("data:text/plain,hello", &["data"], false),
            Err(WebURLRejection::Invalid)
        );
    }

    #[test]
    fn dns_validation_rejects_empty_answers_and_checks_all_families() {
        assert_eq!(
            validate_ip_addresses(&[], false),
            Err(WebURLRejection::Invalid)
        );
        let addresses = [
            "8.8.8.8".parse().unwrap(),
            "::ffff:169.254.169.254".parse().unwrap(),
        ];
        assert_eq!(
            validate_ip_addresses(&addresses, false),
            Err(WebURLRejection::Metadata)
        );
        let addresses = [
            "8.8.8.8".parse().unwrap(),
            "::ffff:10.0.0.1".parse().unwrap(),
        ];
        assert_eq!(
            validate_ip_addresses(&addresses, true),
            Err(WebURLRejection::Private)
        );
        assert_eq!(validate_ip_addresses(&addresses, false), Ok(()));
    }
}
