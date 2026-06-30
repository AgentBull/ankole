use std::collections::HashMap;
use std::sync::{Mutex, OnceLock};
use std::time::{Duration, Instant};

use bytes::Bytes;
use futures_util::{StreamExt, stream::BoxStream};
use reqwest::Method;
use reqwest::Url;
use reqwest::header::HeaderMap;
use tokio::net::TcpStream;
use tokio::time::timeout;
use tokio_tungstenite::tungstenite::client::IntoClientRequest;
use tokio_tungstenite::tungstenite::http::HeaderValue;
use tokio_tungstenite::tungstenite::http::header::HeaderName;
use tokio_tungstenite::{MaybeTlsStream, WebSocketStream, connect_async};

use super::error::StreamError;
use super::spec::{
    CompressionPreference, HttpVersionPreference, StreamSpec, TransportSpec, UpstreamSpec,
};

pub type UpstreamWebSocket = WebSocketStream<MaybeTlsStream<TcpStream>>;

static HTTP_CLIENTS: OnceLock<Mutex<HashMap<ClientKey, reqwest::Client>>> = OnceLock::new();
static ALT_SVC_CACHE: OnceLock<Mutex<HashMap<String, AltSvcEntry>>> = OnceLock::new();

const MAX_HTTP_CLIENT_CACHE_ENTRIES: usize = 64;
const MAX_ALT_SVC_CACHE_ENTRIES: usize = 256;

pub struct HttpStream {
    pub status: u16,
    pub version: String,
    pub negotiation: String,
    pub headers: Vec<(String, String)>,
    pub body: BoxStream<'static, Result<Bytes, reqwest::Error>>,
}

pub struct HttpResponse {
    pub status: u16,
    pub version: String,
    pub negotiation: String,
    pub headers: Vec<(String, String)>,
    pub body: Vec<u8>,
}

pub async fn open_http_stream(spec: &StreamSpec) -> Result<HttpStream, StreamError> {
    open_http_stream_for_upstream(&spec.upstream).await
}

pub async fn send_http_request(
    upstream: &UpstreamSpec,
    max_response_bytes: usize,
) -> Result<HttpResponse, StreamError> {
    let mut stream = open_http_stream_for_upstream(upstream).await?;
    let body = collect_http_body(
        &mut stream.body,
        upstream.timeout.idle_duration(),
        upstream.timeout.total_duration(),
        max_response_bytes,
    )
    .await?;

    Ok(HttpResponse {
        status: stream.status,
        version: stream.version,
        negotiation: stream.negotiation,
        headers: stream.headers,
        body,
    })
}

async fn open_http_stream_for_upstream(upstream: &UpstreamSpec) -> Result<HttpStream, StreamError> {
    let preferences = if upstream.transport.http_versions.is_empty() {
        vec![
            HttpVersionPreference::H3,
            HttpVersionPreference::H2,
            HttpVersionPreference::H1,
        ]
    } else {
        upstream.transport.http_versions.clone()
    };
    let origin = origin_key(&upstream.url);
    let alt_svc_h3 = origin.as_deref().and_then(cached_alt_svc_h3).is_some();
    let modes = http_attempt_modes(&preferences, alt_svc_h3);

    let mut last_error = None;
    for mode in modes {
        match open_http_stream_with_mode(upstream, mode).await {
            Ok(stream) => return Ok(stream),
            Err(error) if error.retryable => last_error = Some(error.error),
            Err(error) => return Err(error.error),
        }
    }

    Err(last_error.unwrap_or_else(|| {
        StreamError::new(
            "transport_failed",
            "connect",
            "no HTTP transport preference could be attempted",
        )
    }))
}

async fn open_http_stream_with_mode(
    upstream: &UpstreamSpec,
    attempt: HttpAttempt,
) -> Result<HttpStream, TransportAttemptError> {
    let client = client_for(upstream, attempt.mode).map_err(TransportAttemptError::retryable)?;
    let mut request = client.request(
        method_from_spec(&upstream.method).map_err(TransportAttemptError::terminal)?,
        upstream.url.as_str(),
    );

    for (name, value) in &upstream.headers {
        request = request.header(name.as_str(), value.as_str());
    }

    if let Some(body) = &upstream.body {
        request = request.body(body.clone());
    }

    let response = timeout(upstream.timeout.first_byte_duration(), request.send())
        .await
        .map_err(|_| {
            TransportAttemptError::terminal(StreamError::new(
                "first_byte_timeout",
                "connect",
                "upstream first byte timeout",
            ))
        })?
        .map_err(|reason| {
            let error = StreamError::new(
                "transport_failed",
                "connect",
                format!(
                    "upstream {} request failed: {reason}",
                    attempt.mode.as_str()
                ),
            );
            if reason.is_connect() {
                TransportAttemptError::retryable(error)
            } else {
                TransportAttemptError::terminal(error)
            }
        })?;

    let status = response.status().as_u16();
    let version = format!("{:?}", response.version()).to_ascii_lowercase();
    record_alt_svc(&upstream.url, response.headers());
    let headers = response
        .headers()
        .iter()
        .map(|(name, value)| {
            (
                name.as_str().to_string(),
                value.to_str().unwrap_or_default().to_string(),
            )
        })
        .collect();
    let body = response.bytes_stream().boxed();

    Ok(HttpStream {
        status,
        version,
        negotiation: attempt.negotiation.to_string(),
        headers,
        body,
    })
}

async fn collect_http_body(
    body: &mut BoxStream<'static, Result<Bytes, reqwest::Error>>,
    idle_timeout: Duration,
    total_timeout: Option<Duration>,
    max_response_bytes: usize,
) -> Result<Vec<u8>, StreamError> {
    let collect = collect_http_body_until_idle(body, idle_timeout, max_response_bytes);

    match total_timeout {
        Some(total_timeout) => timeout(total_timeout, collect).await.map_err(|_| {
            StreamError::new(
                "total_timeout",
                "read",
                "upstream response body total timeout",
            )
        })?,
        None => collect.await,
    }
}

async fn collect_http_body_until_idle(
    body: &mut BoxStream<'static, Result<Bytes, reqwest::Error>>,
    idle_timeout: Duration,
    max_response_bytes: usize,
) -> Result<Vec<u8>, StreamError> {
    let mut collected = Vec::new();

    loop {
        let next = timeout(idle_timeout, body.next()).await.map_err(|_| {
            StreamError::new(
                "idle_timeout",
                "read",
                "upstream response body idle timeout",
            )
        })?;

        let Some(next) = next else {
            return Ok(collected);
        };

        let bytes = next.map_err(|reason| {
            StreamError::new(
                "response_body_read_failed",
                "read",
                format!("upstream response body read failed: {reason}"),
            )
        })?;

        if collected.len().saturating_add(bytes.len()) > max_response_bytes {
            return Err(StreamError::new(
                "response_body_too_large",
                "read",
                "upstream response body exceeded configured response byte limit",
            ));
        }

        collected.extend_from_slice(&bytes);
    }
}

#[derive(Debug)]
struct TransportAttemptError {
    error: StreamError,
    retryable: bool,
}

impl TransportAttemptError {
    fn retryable(error: StreamError) -> Self {
        Self {
            error,
            retryable: true,
        }
    }

    fn terminal(error: StreamError) -> Self {
        Self {
            error,
            retryable: false,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
struct ClientKey {
    mode: ClientMode,
    compression: Vec<CompressionPreference>,
    proxy: Option<String>,
    connect_ms: u64,
}

impl ClientKey {
    fn from_upstream(upstream: &UpstreamSpec, mode: ClientMode) -> Self {
        Self {
            mode,
            compression: upstream.transport.compression.clone(),
            proxy: upstream.transport.proxy.clone(),
            connect_ms: upstream.timeout.connect_ms,
        }
    }
}

fn client_for(upstream: &UpstreamSpec, mode: ClientMode) -> Result<reqwest::Client, StreamError> {
    let key = ClientKey::from_upstream(upstream, mode);
    let clients = HTTP_CLIENTS.get_or_init(|| Mutex::new(HashMap::new()));
    let mut clients = match clients.lock() {
        Ok(clients) => clients,
        Err(poisoned) => poisoned.into_inner(),
    };

    if let Some(client) = clients.get(&key).cloned() {
        return Ok(client);
    }

    let client = build_client(upstream, mode)?;
    if clients.len() >= MAX_HTTP_CLIENT_CACHE_ENTRIES {
        if let Some(old_key) = clients.keys().next().cloned() {
            clients.remove(&old_key);
        }
    }
    clients.insert(key, client.clone());

    Ok(client)
}

pub async fn open_websocket(spec: &StreamSpec) -> Result<(UpstreamWebSocket, u16), StreamError> {
    let mut request = spec
        .upstream
        .url
        .as_str()
        .into_client_request()
        .map_err(|reason| StreamError::new("invalid_url", "connect", reason.to_string()))?;

    for (name, value) in &spec.upstream.headers {
        let header_name: HeaderName = name.parse().map_err(|reason| {
            StreamError::new(
                "invalid_header",
                "connect",
                format!("invalid WebSocket header {name}: {reason}"),
            )
        })?;
        let header_value = HeaderValue::from_str(value).map_err(|reason| {
            StreamError::new(
                "invalid_header",
                "connect",
                format!("invalid WebSocket header value for {name}: {reason}"),
            )
        })?;
        request.headers_mut().insert(header_name, header_value);
    }

    let (websocket, response) = timeout(
        spec.upstream.timeout.first_byte_duration(),
        connect_async(request),
    )
    .await
    .map_err(|_| {
        StreamError::new(
            "first_byte_timeout",
            "connect",
            "upstream WebSocket timeout",
        )
    })?
    .map_err(|reason| {
        StreamError::new(
            "websocket_connect_failed",
            "connect",
            format!("upstream WebSocket connection failed: {reason}"),
        )
    })?;

    Ok((websocket, response.status().as_u16()))
}

fn build_client(upstream: &UpstreamSpec, mode: ClientMode) -> Result<reqwest::Client, StreamError> {
    let mut builder = reqwest::Client::builder()
        .use_rustls_tls()
        .connect_timeout(upstream.timeout.connect_duration())
        .gzip(has_compression(
            &upstream.transport,
            CompressionPreference::Gzip,
        ))
        .brotli(has_compression(
            &upstream.transport,
            CompressionPreference::Br,
        ))
        .zstd(has_compression(
            &upstream.transport,
            CompressionPreference::Zstd,
        ));

    if let Some(proxy) = &upstream.transport.proxy {
        builder = builder.proxy(reqwest::Proxy::all(proxy).map_err(|reason| {
            StreamError::new(
                "invalid_proxy",
                "connect",
                format!("invalid proxy URL: {reason}"),
            )
        })?);
    }

    builder = match mode {
        ClientMode::H3PriorKnowledge => builder.http3_prior_knowledge(),
        ClientMode::AutoAlpn => builder,
        ClientMode::H1Only => builder.http1_only(),
    };

    builder.build().map_err(|reason| {
        StreamError::new(
            "client_build_failed",
            "connect",
            format!("failed to build reqwest client: {reason}"),
        )
    })
}

fn method_from_spec(method: &str) -> Result<Method, StreamError> {
    Method::from_bytes(method.as_bytes()).map_err(|reason| {
        StreamError::new(
            "invalid_method",
            "request",
            format!("invalid upstream method {method}: {reason}"),
        )
    })
}

fn has_compression(transport: &TransportSpec, preference: CompressionPreference) -> bool {
    transport
        .compression
        .iter()
        .any(|value| *value == preference)
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
enum ClientMode {
    H3PriorKnowledge,
    AutoAlpn,
    H1Only,
}

impl ClientMode {
    fn as_str(self) -> &'static str {
        match self {
            Self::H3PriorKnowledge => "h3_prior_knowledge",
            Self::AutoAlpn => "h2_h1_alpn",
            Self::H1Only => "h1_only",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct HttpAttempt {
    mode: ClientMode,
    negotiation: &'static str,
}

fn http_attempt_modes(preferences: &[HttpVersionPreference], alt_svc_h3: bool) -> Vec<HttpAttempt> {
    let has_h1 = preferences
        .iter()
        .any(|preference| *preference == HttpVersionPreference::H1);
    let has_h2 = preferences
        .iter()
        .any(|preference| *preference == HttpVersionPreference::H2);
    let has_h3 = preferences
        .iter()
        .any(|preference| *preference == HttpVersionPreference::H3);
    let h3_only = has_h3 && !has_h2 && !has_h1;
    let mut modes = Vec::new();
    let mut added_auto = false;
    let mut added_h1 = false;
    let mut added_h3 = false;

    if alt_svc_h3 && has_h3 {
        modes.push(HttpAttempt {
            mode: ClientMode::H3PriorKnowledge,
            negotiation: "alt_svc_h3",
        });
        added_h3 = true;
    }

    for preference in preferences {
        match preference {
            HttpVersionPreference::H3 => {
                if h3_only && !added_h3 {
                    modes.push(HttpAttempt {
                        mode: ClientMode::H3PriorKnowledge,
                        negotiation: "h3_prior_knowledge",
                    });
                    added_h3 = true;
                }
            }
            HttpVersionPreference::H2 => {
                if !added_auto {
                    modes.push(HttpAttempt {
                        mode: ClientMode::AutoAlpn,
                        negotiation: "alpn_h2_h1",
                    });
                    added_auto = true;
                }
            }
            HttpVersionPreference::H1 => {
                if has_h2 {
                    if !added_auto {
                        modes.push(HttpAttempt {
                            mode: ClientMode::AutoAlpn,
                            negotiation: "alpn_h2_h1",
                        });
                        added_auto = true;
                    }
                } else if !added_h1 {
                    modes.push(HttpAttempt {
                        mode: ClientMode::H1Only,
                        negotiation: "h1_only",
                    });
                    added_h1 = true;
                }
            }
        }
    }

    if has_h3 && !h3_only && !added_h3 {
        modes.push(HttpAttempt {
            mode: ClientMode::H3PriorKnowledge,
            negotiation: "h3_prior_knowledge",
        });
    }

    if modes.is_empty() {
        if has_h1 && !has_h2 {
            modes.push(HttpAttempt {
                mode: ClientMode::H1Only,
                negotiation: "h1_only",
            });
        } else {
            modes.push(HttpAttempt {
                mode: ClientMode::AutoAlpn,
                negotiation: "alpn_h2_h1",
            });
        }
    }

    modes
}

#[derive(Debug, Clone)]
struct AltSvcEntry {
    expires_at: Instant,
}

fn cached_alt_svc_h3(origin: &str) -> Option<AltSvcEntry> {
    let cache = ALT_SVC_CACHE.get_or_init(|| Mutex::new(HashMap::new()));
    let mut cache = cache.try_lock().ok()?;
    let entry = cache.get(origin).cloned()?;
    if Instant::now() < entry.expires_at {
        Some(entry)
    } else {
        cache.remove(origin);
        None
    }
}

fn record_alt_svc(url: &str, headers: &HeaderMap) {
    let Some(origin) = origin_key(url) else {
        return;
    };
    let Some(header) = headers.get(reqwest::header::ALT_SVC) else {
        return;
    };
    let Ok(header) = header.to_str() else {
        return;
    };
    let cache = ALT_SVC_CACHE.get_or_init(|| Mutex::new(HashMap::new()));
    let Ok(mut cache) = cache.try_lock() else {
        return;
    };

    if header.trim().eq_ignore_ascii_case("clear") {
        cache.remove(&origin);
        return;
    }

    if let Some(max_age) = parse_same_authority_h3_alt_svc(header) {
        if !cache.contains_key(&origin) && cache.len() >= MAX_ALT_SVC_CACHE_ENTRIES {
            if let Some(old_origin) = cache.keys().next().cloned() {
                cache.remove(&old_origin);
            }
        }
        cache.insert(
            origin,
            AltSvcEntry {
                expires_at: Instant::now() + Duration::from_secs(max_age),
            },
        );
    }
}

fn origin_key(url: &str) -> Option<String> {
    let url = Url::parse(url).ok()?;
    let scheme = url.scheme();
    if scheme != "http" && scheme != "https" {
        return None;
    }
    let host = url.host_str()?;
    let port = url
        .port_or_known_default()
        .unwrap_or(if scheme == "https" { 443 } else { 80 });
    Some(format!("{scheme}://{host}:{port}"))
}

fn parse_same_authority_h3_alt_svc(value: &str) -> Option<u64> {
    value.split(',').find_map(|alternative| {
        let mut parts = alternative.split(';').map(str::trim);
        let protocol = parts.next()?;
        let (name, authority) = protocol.split_once('=')?;
        if !name.trim().trim_matches('"').starts_with("h3") {
            return None;
        }

        let authority = authority.trim().trim_matches('"');
        if !authority.starts_with(':') {
            return None;
        }

        let mut max_age = 86_400;
        for param in parts {
            let Some((key, value)) = param.split_once('=') else {
                continue;
            };
            if key.trim().eq_ignore_ascii_case("ma") {
                max_age = value.trim().trim_matches('"').parse().ok()?;
            }
        }

        (max_age > 0).then_some(max_age)
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn alt_svc_parser_accepts_same_authority_h3() {
        assert_eq!(
            parse_same_authority_h3_alt_svc(r#"h3=":443"; ma=3600, h2=":443""#),
            Some(3600)
        );
        assert_eq!(
            parse_same_authority_h3_alt_svc(r#"h3-29=":443""#),
            Some(86_400)
        );
    }

    #[test]
    fn alt_svc_parser_ignores_cross_authority_h3() {
        assert_eq!(
            parse_same_authority_h3_alt_svc(r#"h3="alt.example.com:443"; ma=3600"#),
            None
        );
    }

    #[test]
    fn http_attempts_prefer_cached_alt_svc_h3_when_available() {
        let attempts = http_attempt_modes(
            &[
                HttpVersionPreference::H3,
                HttpVersionPreference::H2,
                HttpVersionPreference::H1,
            ],
            true,
        );

        assert_eq!(attempts[0].mode, ClientMode::H3PriorKnowledge);
        assert_eq!(attempts[0].negotiation, "alt_svc_h3");
        assert!(
            attempts
                .iter()
                .any(|attempt| attempt.negotiation == "alpn_h2_h1")
        );
    }

    #[test]
    fn http_attempts_use_alpn_before_h3_prior_knowledge_without_alt_svc() {
        let attempts = http_attempt_modes(
            &[
                HttpVersionPreference::H3,
                HttpVersionPreference::H2,
                HttpVersionPreference::H1,
            ],
            false,
        );

        assert_eq!(attempts[0].mode, ClientMode::AutoAlpn);
        assert_eq!(attempts[0].negotiation, "alpn_h2_h1");
        assert_eq!(attempts[1].mode, ClientMode::H3PriorKnowledge);
        assert_eq!(attempts[1].negotiation, "h3_prior_knowledge");
    }

    #[test]
    fn http_attempts_allow_explicit_h3_only_prior_knowledge() {
        let attempts = http_attempt_modes(&[HttpVersionPreference::H3], false);

        assert_eq!(attempts.len(), 1);
        assert_eq!(attempts[0].mode, ClientMode::H3PriorKnowledge);
        assert_eq!(attempts[0].negotiation, "h3_prior_knowledge");
    }
}
