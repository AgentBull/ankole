use std::future::Future;
use std::sync::LazyLock;
use std::time::{Duration, Instant};

use bytes::Bytes;
use futures_util::{StreamExt, stream::BoxStream};
use reqwest::Method;
use reqwest::Url as URL;
use reqwest::header::HeaderMap;
use tokio::io::{AsyncRead, AsyncWrite};
use tokio::time::{error::Elapsed, timeout};
use tokio_tungstenite::tungstenite::Error as WebSocketError;
use tokio_tungstenite::tungstenite::client::IntoClientRequest;
use tokio_tungstenite::tungstenite::http::HeaderValue;
use tokio_tungstenite::tungstenite::http::header::HeaderName;
use tokio_tungstenite::{
    MaybeTlsStream as MaybeTLSStream, WebSocketStream, client_async_tls_with_config,
};

use super::error::StreamError;
use super::spec::{StreamSpec, UpstreamSpec};
use crate::common::bounded_cache::BoundedCache;

mod proxy;
use proxy::{parse_upstream_url, resolved_proxy, websocket_transport_stream};

/// Idle budget that only complete provider events reset.
///
/// Callers start each wait after downstream read capacity is available, so
/// downstream backpressure does not use this budget.
pub(crate) struct SemanticIdle {
    budget: Duration,
    spent: Duration,
}

impl SemanticIdle {
    pub(crate) fn new(budget: Duration) -> Self {
        Self {
            budget,
            spent: Duration::ZERO,
        }
    }

    pub(crate) async fn wait<F: Future>(&mut self, future: F) -> Result<F::Output, Elapsed> {
        let started = Instant::now();
        let result = timeout(self.budget.saturating_sub(self.spent), future).await;
        self.spent = self.spent.saturating_add(started.elapsed());
        result
    }

    pub(crate) fn progressed(&mut self) {
        self.spent = Duration::ZERO;
    }
}

pub(crate) trait AsyncIO: AsyncRead + AsyncWrite + Send + Unpin {}

impl<T> AsyncIO for T where T: AsyncRead + AsyncWrite + Send + Unpin {}

pub(crate) type BoxedIO = Box<dyn AsyncIO>;

pub type UpstreamWebSocket = WebSocketStream<MaybeTLSStream<BoxedIO>>;

static HTTP_CLIENTS: LazyLock<BoundedCache<ClientKey, reqwest::Client>> =
    LazyLock::new(|| BoundedCache::new(MAX_HTTP_CLIENT_CACHE_ENTRIES));

const MAX_HTTP_CLIENT_CACHE_ENTRIES: usize = 64;

pub struct HTTPStream {
    pub status: u16,
    pub headers: Vec<(String, String)>,
    pub body: BoxStream<'static, Result<Bytes, reqwest::Error>>,
}

pub struct HTTPResponse {
    pub status: u16,
    pub headers: Vec<(String, String)>,
    pub body: Vec<u8>,
}

pub fn safe_response_headers(headers: &[(String, String)]) -> Vec<(String, String)> {
    headers
        .iter()
        .filter(|(name, _value)| safe_provider_header(name))
        .cloned()
        .collect()
}

fn safe_header_map(headers: &HeaderMap) -> Vec<(String, String)> {
    headers
        .iter()
        .filter(|(name, _value)| safe_provider_header(name.as_str()))
        .map(|(name, value)| {
            (
                name.as_str().to_string(),
                value.to_str().unwrap_or_default().to_string(),
            )
        })
        .collect()
}

fn safe_provider_header(name: &str) -> bool {
    let name = name.to_ascii_lowercase();
    name.starts_with("x-codex-") || name == "cf-mitigated" || name == "retry-after"
}

pub async fn open_http_stream(spec: &StreamSpec) -> Result<HTTPStream, StreamError> {
    open_http_stream_for_upstream(&spec.upstream).await
}

pub async fn send_http_request(
    upstream: &UpstreamSpec,
    max_response_bytes: usize,
) -> Result<HTTPResponse, StreamError> {
    let mut stream = open_http_stream_for_upstream(upstream).await?;
    let body = collect_http_body(
        &mut stream.body,
        upstream.timeout.idle_duration(),
        upstream.timeout.total_duration(),
        max_response_bytes,
    )
    .await?;

    Ok(HTTPResponse {
        status: stream.status,
        headers: stream.headers,
        body,
    })
}

pub(super) async fn open_http_stream_for_upstream(
    upstream: &UpstreamSpec,
) -> Result<HTTPStream, StreamError> {
    let client = client_for(upstream)?;
    let mut request = client.request(method_from_spec(&upstream.method)?, upstream.url.as_str());
    for (name, value) in &upstream.headers {
        request = request.header(name.as_str(), value.as_str());
    }
    if let Some(body) = &upstream.body {
        request = request.body(body.clone());
    }
    let response = timeout(upstream.timeout.first_byte_duration(), request.send())
        .await
        .map_err(|_| {
            StreamError::new(
                "first_byte_timeout",
                "connect",
                "upstream first byte timeout",
            )
        })?
        .map_err(|reason| {
            StreamError::new(
                "transport_failed",
                "connect",
                format!("upstream request failed: {reason}"),
            )
        })?;
    let status = response.status().as_u16();
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
    Ok(HTTPStream {
        status,
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

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
struct ClientKey {
    proxy: Option<String>,
    connect_ms: u64,
}

impl ClientKey {
    fn from_upstream(upstream: &UpstreamSpec, proxy: Option<&URL>) -> Self {
        Self {
            proxy: proxy.map(URL::to_string),
            connect_ms: upstream.timeout.connect_ms,
        }
    }
}

fn client_for(upstream: &UpstreamSpec) -> Result<reqwest::Client, StreamError> {
    let proxy = resolved_proxy(upstream)?;
    let key = ClientKey::from_upstream(upstream, proxy.as_ref());

    if let Some(client) = HTTP_CLIENTS.get_cloned(&key) {
        return Ok(client);
    }

    let client = build_client(upstream, proxy.as_ref())?;
    HTTP_CLIENTS.insert(key, client.clone());

    Ok(client)
}

pub async fn open_websocket(
    spec: &StreamSpec,
) -> Result<(UpstreamWebSocket, u16, Vec<(String, String)>), StreamError> {
    let proxy = resolved_proxy(&spec.upstream)?;
    let target = parse_upstream_url(&spec.upstream.url)?;

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

    // TCP, TLS, and the WebSocket upgrade are the connect phase. The first-byte
    // and idle budgets start only after the upgrade returns 101, so a stalled
    // open must fail on the connect budget, not on the model output budget.
    let connect = async {
        let stream = websocket_transport_stream(&target, proxy.as_ref()).await?;
        client_async_tls_with_config(request, stream, None, None)
            .await
            .map_err(websocket_connect_error)
    };
    let (websocket, response) = timeout(spec.upstream.timeout.connect_duration(), connect)
        .await
        .map_err(|_| {
            StreamError::new(
                "connect_timeout",
                "connect",
                "upstream WebSocket connect timeout",
            )
        })??;

    Ok((
        websocket,
        response.status().as_u16(),
        safe_header_map(response.headers()),
    ))
}

fn websocket_connect_error(reason: WebSocketError) -> StreamError {
    match reason {
        WebSocketError::Http(response) => {
            let status = response.status().as_u16();
            let headers = safe_header_map(response.headers());

            StreamError::new(
                "websocket_status_rejected",
                "connect",
                format!("upstream WebSocket returned status {status}"),
            )
            .provider_status(status)
            .provider_headers(&headers)
        }
        reason => StreamError::new(
            "websocket_connect_failed",
            "connect",
            format!("upstream WebSocket connection failed: {reason}"),
        ),
    }
}

fn build_client(
    upstream: &UpstreamSpec,
    proxy: Option<&URL>,
) -> Result<reqwest::Client, StreamError> {
    let mut builder = reqwest::Client::builder()
        .no_proxy()
        .use_rustls_tls()
        .connect_timeout(upstream.timeout.connect_duration())
        .http1_only();

    if let Some(proxy) = proxy {
        builder = builder.proxy(reqwest::Proxy::all(proxy.as_str()).map_err(|_reason| {
            StreamError::new("invalid_proxy", "connect", "proxy URL is invalid")
        })?);
    }

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

#[cfg(test)]
mod tests {
    use super::super::spec::TransportSpec;
    use super::*;
    use crate::universal_ai_client::spec::{TimeoutSpec, UpstreamKind};

    #[tokio::test]
    async fn client_cache_stays_bounded_when_connection_settings_change() {
        let mut upstream = UpstreamSpec {
            kind: UpstreamKind::HTTPSSE,
            method: "GET".to_string(),
            url: "http://127.0.0.1/cache-test".to_string(),
            headers: Vec::new(),
            body: None,
            websocket_initial_messages: Vec::new(),
            timeout: TimeoutSpec {
                connect_ms: 1,
                first_byte_ms: 100,
                idle_ms: 100,
                total_ms: None,
            },
            transport: TransportSpec { proxy: None },
        };

        for connect_ms in 1..=MAX_HTTP_CLIENT_CACHE_ENTRIES as u64 + 16 {
            upstream.timeout.connect_ms = connect_ms;
            client_for(&upstream).unwrap();
        }

        assert!(HTTP_CLIENTS.len() <= MAX_HTTP_CLIENT_CACHE_ENTRIES);
    }

    #[test]
    fn websocket_http_rejection_keeps_provider_status_without_body() {
        let response = tokio_tungstenite::tungstenite::http::Response::builder()
            .status(429)
            .header("retry-after", "2")
            .header("x-codex-primary-reset-at", "1785319200")
            .header("authorization", "Bearer private")
            .body(Some(b"provider secret".to_vec()))
            .expect("HTTP response should build");

        let error = websocket_connect_error(WebSocketError::Http(Box::new(response)));

        assert_eq!(error.code, "websocket_status_rejected");
        assert_eq!(error.stage, "connect");
        assert_eq!(error.provider_status, Some(429));
        assert_eq!(error.provider_body_excerpt, None);
        assert_eq!(
            error.provider_headers.to_vec(),
            vec![
                ("retry-after".to_string(), "2".to_string()),
                (
                    "x-codex-primary-reset-at".to_string(),
                    "1785319200".to_string()
                )
            ]
        );
        assert!(!error.message.contains("provider secret"));
    }

    #[test]
    fn safe_response_headers_exclude_unrelated_and_secret_headers() {
        let headers = vec![
            ("X-Codex-Primary-Used-Percent".to_string(), "42".to_string()),
            ("cf-mitigated".to_string(), "challenge".to_string()),
            ("Retry-After".to_string(), "2".to_string()),
            ("content-type".to_string(), "application/json".to_string()),
            ("authorization".to_string(), "Bearer private".to_string()),
            ("set-cookie".to_string(), "private=value".to_string()),
        ];

        assert_eq!(
            safe_response_headers(&headers),
            vec![
                ("X-Codex-Primary-Used-Percent".to_string(), "42".to_string()),
                ("cf-mitigated".to_string(), "challenge".to_string()),
                ("Retry-After".to_string(), "2".to_string())
            ]
        );
    }
}
