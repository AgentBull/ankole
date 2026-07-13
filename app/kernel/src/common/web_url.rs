//! WHATWG URL facts for the shared web tools URL policy.
//!
//! AIGateway `web_fetch` validation and the Agent Computer browser guard used
//! to parse and classify URLs separately (Elixir `URI` + `:inet`, Bun
//! `new URL` + `node:net`), leaving the policy a comment-level "mirror". This
//! module owns the parse and the host classification once; runtime bindings
//! keep only scheme rules, the `web_tools.block_private_network` toggle, and
//! error shapes.

use std::net::{Ipv4Addr, Ipv6Addr};

use url::{Host, Url as URL};

use crate::common::{KernelError, KernelResult};

/// Host classification for the web tools URL policy.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum HostClass {
    /// Cloud metadata endpoints; rejected regardless of policy.
    Metadata,
    /// Localhost names and non-public literal IP addresses; rejected only when
    /// `web_tools.block_private_network` is enabled.
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

/// Parsed facts about one web URL.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct WebURLFacts {
    /// Lowercase URL scheme without the trailing colon.
    pub scheme: String,
    /// WHATWG-normalized host (lowercased, canonical IP text, no brackets),
    /// or `None` for host-less URLs such as `data:` and `about:`.
    pub host: Option<String>,
    /// Host classification; `None` exactly when `host` is `None`.
    pub host_class: Option<HostClass>,
}

/// Parses an absolute web URL with WHATWG semantics and classifies its host.
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

fn classify_host(host: &Host<&str>) -> HostClass {
    match host {
        Host::Domain(domain) => classify_domain(domain),
        Host::Ipv4(ip) => classify_ipv4(*ip),
        Host::Ipv6(ip) => classify_ipv6(*ip),
    }
}

fn classify_domain(domain: &str) -> HostClass {
    // WHATWG parsing already lowercased the domain.
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
        // Hex, octal, and integer IPv4 forms canonicalize before classification.
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
}
