//! Host-neutral `rustls` HTTP transport and header sanitization for the Ankole desktop client.

use std::fmt;
use std::net::{IpAddr, Ipv4Addr, SocketAddr, ToSocketAddrs};
use std::sync::Arc;
use std::time::Duration;

use reqwest::Method;
use reqwest::dns::{Addrs, Name, Resolve, Resolving};
use serde::de::DeserializeOwned;
use tokio::time::timeout;
use url::Url;

#[derive(Debug, Default)]
struct Rfc6761DnsResolver;

impl Resolve for Rfc6761DnsResolver {
    fn resolve(&self, name: Name) -> Resolving {
        let host = name.as_str().trim_end_matches('.').to_ascii_lowercase();
        if host == "localhost" || host.ends_with(".localhost") {
            let loopback = SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), 0);
            let addrs: Addrs = Box::new(std::iter::once(loopback));
            return Box::pin(async move { Ok(addrs) });
        }
        Box::pin(async move {
            let resolved =
                tokio::task::spawn_blocking(move || (host.as_str(), 0).to_socket_addrs())
                    .await
                    .map_err(|err| -> Box<dyn std::error::Error + Send + Sync> { Box::new(err) })?
                    .map_err(|err| -> Box<dyn std::error::Error + Send + Sync> { Box::new(err) })?;
            let addrs: Addrs = Box::new(resolved.collect::<Vec<_>>().into_iter());
            Ok(addrs)
        })
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DesktopHttpError {
    InvalidUrl(String),
    InvalidMethod(String),
    ClientInit(String),
    Timeout(String),
    Transport(String),
    InvalidJson(String),
}

impl fmt::Display for DesktopHttpError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::InvalidUrl(reason) => write!(f, "invalid URL: {reason}"),
            Self::InvalidMethod(reason) => write!(f, "invalid HTTP method: {reason}"),
            Self::ClientInit(reason) => write!(f, "HTTP client initialization failed: {reason}"),
            Self::Timeout(reason) => write!(f, "HTTP request timed out: {reason}"),
            Self::Transport(reason) => write!(f, "HTTP transport failed: {reason}"),
            Self::InvalidJson(reason) => write!(f, "invalid JSON payload: {reason}"),
        }
    }
}

impl std::error::Error for DesktopHttpError {}

#[derive(Debug, Clone)]
pub struct DesktopHttpRequest {
    pub method: String,
    pub url: String,
    pub headers: Vec<(String, String)>,
    pub body: Vec<u8>,
    pub timeout: Duration,
}

#[derive(Debug, Clone)]
pub struct DesktopHttpResponse {
    pub status: u16,
    pub headers: Vec<(String, String)>,
    pub body: Vec<u8>,
}

impl DesktopHttpResponse {
    pub fn header(&self, target: &str) -> Option<&str> {
        self.headers
            .iter()
            .find(|(name, _)| name.eq_ignore_ascii_case(target))
            .map(|(_, value)| value.as_str())
    }

    pub fn json<T: DeserializeOwned>(&self) -> Result<T, DesktopHttpError> {
        serde_json::from_slice(&self.body)
            .map_err(|reason| DesktopHttpError::InvalidJson(reason.to_string()))
    }
}

#[derive(Debug)]
pub struct DesktopHttpStream {
    pub status: u16,
    pub headers: Vec<(String, String)>,
    inner: reqwest::Response,
}

impl DesktopHttpStream {
    pub async fn next_chunk(
        &mut self,
        idle_timeout: Duration,
    ) -> Result<Option<Vec<u8>>, DesktopHttpError> {
        let maybe_chunk = timeout(idle_timeout, self.inner.chunk())
            .await
            .map_err(|_| DesktopHttpError::Timeout("upstream SSE stream idle timeout".into()))?
            .map_err(|reason| DesktopHttpError::Transport(reason.to_string()))?;
        Ok(maybe_chunk.map(|bytes| bytes.to_vec()))
    }
}

#[derive(Clone, Debug)]
pub struct DesktopHttpClient {
    proxied: reqwest::Client,
    direct: reqwest::Client,
}

impl DesktopHttpClient {
    pub fn new(connect_timeout: Duration) -> Result<Self, DesktopHttpError> {
        let _ = rustls::crypto::aws_lc_rs::default_provider().install_default();
        let resolver = Arc::new(Rfc6761DnsResolver);
        let proxied = reqwest::Client::builder()
            .use_rustls_tls()
            .dns_resolver(resolver.clone())
            .redirect(reqwest::redirect::Policy::none())
            .connect_timeout(connect_timeout)
            .build()
            .map_err(|reason| DesktopHttpError::ClientInit(reason.to_string()))?;
        let direct = reqwest::Client::builder()
            .use_rustls_tls()
            .no_proxy()
            .dns_resolver(resolver)
            .redirect(reqwest::redirect::Policy::none())
            .connect_timeout(connect_timeout)
            .build()
            .map_err(|reason| DesktopHttpError::ClientInit(reason.to_string()))?;
        Ok(Self { proxied, direct })
    }

    fn client_for(&self, url: &Url) -> &reqwest::Client {
        if should_bypass_system_proxy(url) {
            &self.direct
        } else {
            &self.proxied
        }
    }

    pub async fn open_stream(
        &self,
        spec: DesktopHttpRequest,
    ) -> Result<DesktopHttpStream, DesktopHttpError> {
        let parsed_url = Url::parse(&spec.url)
            .map_err(|reason| DesktopHttpError::InvalidUrl(reason.to_string()))?;
        if !matches!(parsed_url.scheme(), "http" | "https") {
            return Err(DesktopHttpError::InvalidUrl(format!(
                "unsupported scheme {}",
                parsed_url.scheme()
            )));
        }
        let method = Method::from_bytes(spec.method.as_bytes())
            .map_err(|reason| DesktopHttpError::InvalidMethod(reason.to_string()))?;

        let client = self.client_for(&parsed_url);
        let mut builder = client.request(method, parsed_url);
        for (name, value) in &spec.headers {
            builder = builder.header(name.as_str(), value.as_str());
        }
        if !spec.body.is_empty() {
            builder = builder.body(spec.body);
        }

        let response = timeout(spec.timeout, builder.send())
            .await
            .map_err(|_| DesktopHttpError::Timeout("upstream response headers timed out".into()))?
            .map_err(|reason| DesktopHttpError::Transport(reason.to_string()))?;

        let status = response.status().as_u16();
        let headers = response
            .headers()
            .iter()
            .filter_map(|(name, value)| {
                value
                    .to_str()
                    .ok()
                    .map(|val| (name.as_str().to_string(), val.to_string()))
            })
            .collect();

        Ok(DesktopHttpStream {
            status,
            headers,
            inner: response,
        })
    }

    pub async fn send(
        &self,
        spec: DesktopHttpRequest,
    ) -> Result<DesktopHttpResponse, DesktopHttpError> {
        let parsed_url = Url::parse(&spec.url)
            .map_err(|reason| DesktopHttpError::InvalidUrl(reason.to_string()))?;
        if !matches!(parsed_url.scheme(), "http" | "https") {
            return Err(DesktopHttpError::InvalidUrl(format!(
                "unsupported scheme {}",
                parsed_url.scheme()
            )));
        }
        let method = Method::from_bytes(spec.method.as_bytes())
            .map_err(|reason| DesktopHttpError::InvalidMethod(reason.to_string()))?;

        let client = self.client_for(&parsed_url);
        let mut builder = client.request(method, parsed_url);
        for (name, value) in &spec.headers {
            builder = builder.header(name.as_str(), value.as_str());
        }
        if !spec.body.is_empty() {
            builder = builder.body(spec.body);
        }

        let response = timeout(spec.timeout, builder.send())
            .await
            .map_err(|_| DesktopHttpError::Timeout("upstream response headers timed out".into()))?
            .map_err(|reason| DesktopHttpError::Transport(reason.to_string()))?;

        let status = response.status().as_u16();
        let headers = response
            .headers()
            .iter()
            .filter_map(|(name, value)| {
                value
                    .to_str()
                    .ok()
                    .map(|val| (name.as_str().to_string(), val.to_string()))
            })
            .collect();
        let body = timeout(spec.timeout, response.bytes())
            .await
            .map_err(|_| DesktopHttpError::Timeout("upstream response body timed out".into()))?
            .map_err(|reason| DesktopHttpError::Transport(reason.to_string()))?
            .to_vec();

        Ok(DesktopHttpResponse {
            status,
            headers,
            body,
        })
    }

    pub async fn post_form(
        &self,
        url: &str,
        pairs: &[(&str, &str)],
        request_timeout: Duration,
    ) -> Result<DesktopHttpResponse, DesktopHttpError> {
        self.send(DesktopHttpRequest {
            method: "POST".to_string(),
            url: url.to_string(),
            headers: vec![
                (
                    "content-type".to_string(),
                    "application/x-www-form-urlencoded".to_string(),
                ),
                ("accept".to_string(), "application/json".to_string()),
            ],
            body: form_urlencoded_body(pairs),
            timeout: request_timeout,
        })
        .await
    }
}

/// Normalizes a user-entered workspace URL or hostname into a canonical `http(s)://host[:port]` origin.
pub fn normalize_pod_origin(raw: &str) -> Result<String, DesktopHttpError> {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return Err(DesktopHttpError::InvalidUrl(
            "workspace URL must not be empty".to_string(),
        ));
    }
    let candidate = if trimmed.contains("://") {
        trimmed.to_string()
    } else {
        format!("https://{trimmed}")
    };
    let parsed = Url::parse(&candidate)
        .map_err(|reason| DesktopHttpError::InvalidUrl(reason.to_string()))?;
    if !matches!(parsed.scheme(), "http" | "https") {
        return Err(DesktopHttpError::InvalidUrl(format!(
            "unsupported URL scheme {}",
            parsed.scheme()
        )));
    }
    if !parsed.username().is_empty() || parsed.password().is_some() {
        return Err(DesktopHttpError::InvalidUrl(
            "workspace URL must not contain embedded credentials".to_string(),
        ));
    }
    let Some(host) = parsed.host_str() else {
        return Err(DesktopHttpError::InvalidUrl(
            "workspace URL is missing a host".to_string(),
        ));
    };
    let mut origin = format!("{}://{}", parsed.scheme(), host);
    if let Some(port) = parsed.port() {
        origin.push(':');
        origin.push_str(&port.to_string());
    }
    Ok(origin)
}

/// Parses a user-entered workspace URL into a canonical `http(s)://host[:port]` origin plus an
/// optional workspace slug extracted from `?slug=<slug>` or `/pods/<slug>`.
pub fn parse_discovery_target(raw: &str) -> Result<(String, Option<String>), DesktopHttpError> {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return Err(DesktopHttpError::InvalidUrl(
            "workspace URL must not be empty".to_string(),
        ));
    }
    let candidate = if trimmed.contains("://") {
        trimmed.to_string()
    } else if trimmed.contains("localhost") || trimmed.starts_with("127.0.0.1") {
        format!("http://{trimmed}")
    } else {
        format!("https://{trimmed}")
    };
    let parsed = Url::parse(&candidate)
        .map_err(|reason| DesktopHttpError::InvalidUrl(reason.to_string()))?;
    let origin = normalize_pod_origin(parsed.as_str())?;
    let query_slug = parsed
        .query_pairs()
        .find(|(k, v)| k == "slug" && !v.trim().is_empty())
        .map(|(_, v)| v.trim().to_string());
    let path_slug = parsed.path_segments().and_then(|mut segments| {
        let first = segments.next()?;
        let second = segments.next()?;
        if first == "pods" && !second.trim().is_empty() {
            Some(second.trim().to_string())
        } else {
            None
        }
    });
    Ok((origin, query_slug.or(path_slug)))
}

/// Resolves a root-relative request path and optional query against a canonical `pod_origin`,
/// rejecting scheme-relative (`//evil`) or cross-origin escapes.
pub fn resolve_upstream_url(
    pod_origin: &str,
    path_and_query: &str,
) -> Result<String, DesktopHttpError> {
    let normalized_origin = normalize_pod_origin(pod_origin)?;
    if !path_and_query.starts_with('/') || path_and_query.starts_with("//") {
        return Err(DesktopHttpError::InvalidUrl(
            "proxied path must be a single-slash root-relative path".to_string(),
        ));
    }
    let combined = format!("{normalized_origin}{path_and_query}");
    let parsed =
        Url::parse(&combined).map_err(|reason| DesktopHttpError::InvalidUrl(reason.to_string()))?;
    let resolved_origin = normalize_pod_origin(parsed.as_str())?;
    if resolved_origin != normalized_origin {
        return Err(DesktopHttpError::InvalidUrl(
            "proxied path attempted to change upstream origin".to_string(),
        ));
    }
    Ok(parsed.to_string())
}

pub fn sanitize_proxy_request_headers(
    headers: &[(String, String)],
    bearer_token: Option<&str>,
) -> Vec<(String, String)> {
    let mut out: Vec<(String, String)> = headers
        .iter()
        .filter(|(name, _)| !is_blocked_request_header(name))
        .cloned()
        .collect();
    if let Some(token) = bearer_token {
        out.push(("authorization".to_string(), format!("Bearer {token}")));
    }
    out
}

pub fn sanitize_proxy_response_headers(headers: &[(String, String)]) -> Vec<(String, String)> {
    headers
        .iter()
        .filter(|(name, _)| !is_blocked_response_header(name))
        .cloned()
        .collect()
}

pub fn form_urlencoded_body(pairs: &[(&str, &str)]) -> Vec<u8> {
    let mut serializer = url::form_urlencoded::Serializer::new(String::new());
    for &(key, value) in pairs {
        serializer.append_pair(key, value);
    }
    serializer.finish().into_bytes()
}

fn should_bypass_system_proxy(url: &Url) -> bool {
    let Some(host) = url.host() else {
        return false;
    };
    match host {
        url::Host::Ipv4(ip) => ip.is_loopback(),
        url::Host::Ipv6(ip) => ip.is_loopback(),
        url::Host::Domain(domain) => {
            let lower = domain.trim_end_matches('.').to_ascii_lowercase();
            lower == "localhost" || lower.ends_with(".localhost") || lower.ends_with(".local")
        }
    }
}

fn is_hop_by_hop_header(name: &str) -> bool {
    name.eq_ignore_ascii_case("connection")
        || name.eq_ignore_ascii_case("keep-alive")
        || name.eq_ignore_ascii_case("proxy-authenticate")
        || name.eq_ignore_ascii_case("proxy-authorization")
        || name.eq_ignore_ascii_case("te")
        || name.eq_ignore_ascii_case("trailer")
        || name.eq_ignore_ascii_case("transfer-encoding")
        || name.eq_ignore_ascii_case("upgrade")
}

fn is_blocked_request_header(name: &str) -> bool {
    is_hop_by_hop_header(name)
        || name.eq_ignore_ascii_case("cookie")
        || name.eq_ignore_ascii_case("authorization")
        || name.eq_ignore_ascii_case("host")
        || name.eq_ignore_ascii_case("content-length")
        || name.eq_ignore_ascii_case("origin")
        || name.eq_ignore_ascii_case("referer")
}

fn is_blocked_response_header(name: &str) -> bool {
    is_hop_by_hop_header(name)
        || name.eq_ignore_ascii_case("set-cookie")
        || name.eq_ignore_ascii_case("content-encoding")
        || name.eq_ignore_ascii_case("content-length")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn normalizes_workspace_origins_and_rejects_invalid_urls() {
        assert_eq!(
            normalize_pod_origin("acme.ankole.cloud").unwrap(),
            "https://acme.ankole.cloud"
        );
        assert_eq!(
            normalize_pod_origin("https://acme.ankole.cloud/pages/123?tab=chat").unwrap(),
            "https://acme.ankole.cloud"
        );
        assert_eq!(
            normalize_pod_origin("http://127.0.0.1:4000/").unwrap(),
            "http://127.0.0.1:4000"
        );
        assert!(normalize_pod_origin("").is_err());
        assert!(normalize_pod_origin("ftp://acme.ankole.cloud").is_err());
        assert!(normalize_pod_origin("https://user:pass@acme.ankole.cloud").is_err());

        assert_eq!(
            parse_discovery_target("ankole.localhost:4000?slug=demo").unwrap(),
            (
                "http://ankole.localhost:4000".to_string(),
                Some("demo".to_string())
            )
        );
        assert_eq!(
            parse_discovery_target("https://ankole.cloud/pods/acme").unwrap(),
            ("https://ankole.cloud".to_string(), Some("acme".to_string()))
        );
    }

    #[test]
    fn resolves_root_relative_paths_without_origin_escape() {
        assert_eq!(
            resolve_upstream_url("https://acme.ankole.cloud", "/api/v2/pod/pages?cursor=next")
                .unwrap(),
            "https://acme.ankole.cloud/api/v2/pod/pages?cursor=next"
        );
        assert!(resolve_upstream_url("https://acme.ankole.cloud", "//evil.example/api").is_err());
        assert!(resolve_upstream_url("https://acme.ankole.cloud", "https://evil.example").is_err());
    }

    #[test]
    fn sanitizes_proxy_headers_and_injects_bearer_without_cookies() {
        let incoming = vec![
            ("Accept".to_string(), "application/vnd.api+json".to_string()),
            ("Cookie".to_string(), "ambient=secret".to_string()),
            ("Authorization".to_string(), "Bearer forged".to_string()),
            ("X-Ankole-Pod".to_string(), "pod-1".to_string()),
            ("Origin".to_string(), "tauri://localhost".to_string()),
        ];
        assert_eq!(
            sanitize_proxy_request_headers(&incoming, Some("valid-token")),
            vec![
                ("Accept".to_string(), "application/vnd.api+json".to_string()),
                ("X-Ankole-Pod".to_string(), "pod-1".to_string()),
                (
                    "authorization".to_string(),
                    "Bearer valid-token".to_string()
                ),
            ]
        );

        let upstream = vec![
            ("content-type".to_string(), "application/json".to_string()),
            ("content-encoding".to_string(), "gzip".to_string()),
            ("content-length".to_string(), "120".to_string()),
            ("set-cookie".to_string(), "_ankole=secret".to_string()),
        ];
        assert_eq!(
            sanitize_proxy_response_headers(&upstream),
            vec![("content-type".to_string(), "application/json".to_string())]
        );
    }

    #[test]
    fn builds_rustls_client_and_encodes_form_bodies() {
        let client = DesktopHttpClient::new(Duration::from_secs(5));
        assert!(client.is_ok());
        let encoded = form_urlencoded_body(&[
            ("grant_type", "authorization_code"),
            ("redirect_uri", "ankole://oauth/callback"),
        ]);
        assert_eq!(
            String::from_utf8(encoded).unwrap(),
            "grant_type=authorization_code&redirect_uri=ankole%3A%2F%2Foauth%2Fcallback"
        );
    }
}
