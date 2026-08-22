use std::collections::HashMap;
use std::env;
use std::sync::{Mutex, OnceLock};
use std::time::{Duration, Instant};

use base64_simd::STANDARD;
use bytes::Bytes;
use futures_util::{StreamExt, stream::BoxStream};
use no_proxy::NoProxy;
use reqwest::Method;
use reqwest::Url as URL;
use reqwest::header::HeaderMap;
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};
use tokio::net::TcpStream as TCPStream;
use tokio::time::timeout;
use tokio_socks::tcp::Socks5Stream;
use tokio_tungstenite::tungstenite::Error as WebSocketError;
use tokio_tungstenite::tungstenite::client::IntoClientRequest;
use tokio_tungstenite::tungstenite::http::HeaderValue;
use tokio_tungstenite::tungstenite::http::header::HeaderName;
use tokio_tungstenite::{
    MaybeTlsStream as MaybeTLSStream, WebSocketStream, client_async_tls_with_config,
};

use super::error::StreamError;
use super::spec::{
    CompressionPreference, HTTPVersionPreference, StreamSpec, TransportSpec, UpstreamSpec,
};

pub(crate) trait AsyncIO: AsyncRead + AsyncWrite + Send + Unpin {}

impl<T> AsyncIO for T where T: AsyncRead + AsyncWrite + Send + Unpin {}

pub(crate) type BoxedIO = Box<dyn AsyncIO>;

pub type UpstreamWebSocket = WebSocketStream<MaybeTLSStream<BoxedIO>>;

static HTTP_CLIENTS: OnceLock<Mutex<HashMap<ClientKey, reqwest::Client>>> = OnceLock::new();
static ALT_SVC_CACHE: OnceLock<Mutex<HashMap<String, AltSvcEntry>>> = OnceLock::new();

const MAX_HTTP_CLIENT_CACHE_ENTRIES: usize = 64;
const MAX_ALT_SVC_CACHE_ENTRIES: usize = 256;
const MAX_PROXY_RESPONSE_HEADER_BYTES: usize = 16 * 1_024;
const HTTP3_AVAILABLE: bool = cfg!(feature = "universal_ai_client_http3");

pub struct HTTPStream {
    pub status: u16,
    pub version: String,
    pub negotiation: String,
    pub headers: Vec<(String, String)>,
    pub body: BoxStream<'static, Result<Bytes, reqwest::Error>>,
}

pub struct HTTPResponse {
    pub status: u16,
    pub version: String,
    pub negotiation: String,
    pub headers: Vec<(String, String)>,
    pub body: Vec<u8>,
}

pub fn codex_response_headers(headers: &[(String, String)]) -> Vec<(String, String)> {
    headers
        .iter()
        .filter(|(name, _value)| safe_provider_header(name))
        .cloned()
        .collect()
}

fn codex_header_map(headers: &HeaderMap) -> Vec<(String, String)> {
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
    name.starts_with("x-codex-") || name == "cf-mitigated"
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
        version: stream.version,
        negotiation: stream.negotiation,
        headers: stream.headers,
        body,
    })
}

pub(super) async fn open_http_stream_for_upstream(
    upstream: &UpstreamSpec,
) -> Result<HTTPStream, StreamError> {
    let preferences = if upstream.transport.http_versions.is_empty() {
        vec![
            HTTPVersionPreference::H3,
            HTTPVersionPreference::H2,
            HTTPVersionPreference::H1,
        ]
    } else {
        upstream.transport.http_versions.clone()
    };
    let origin = origin_key(&upstream.url);
    let alt_svc_h3 = HTTP3_AVAILABLE && origin.as_deref().and_then(cached_alt_svc_h3).is_some();
    let modes = http_attempt_modes(&preferences, alt_svc_h3, HTTP3_AVAILABLE);

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
    attempt: HTTPAttempt,
) -> Result<HTTPStream, TransportAttemptError> {
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
            TransportAttemptError::terminal(
                StreamError::new(
                    "first_byte_timeout",
                    "connect",
                    "upstream first byte timeout",
                )
                .retry_through_credential_pool(),
            )
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
                TransportAttemptError::retryable(error.retry_through_credential_pool())
            } else {
                TransportAttemptError::terminal(error)
            }
        })?;

    let status = response.status().as_u16();
    let version = format!("{:?}", response.version()).to_ascii_lowercase();
    if HTTP3_AVAILABLE {
        record_alt_svc(&upstream.url, response.headers());
    }
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
            .retry_through_credential_pool()
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
            .retry_through_credential_pool()
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
            .retry_through_credential_pool()
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

#[derive(Debug, Clone, Default)]
struct ProxyEnvironment {
    https_proxy: Option<String>,
    http_proxy: Option<String>,
    all_proxy: Option<String>,
    no_proxy: NoProxy,
}

impl ProxyEnvironment {
    fn from_process() -> Self {
        Self {
            https_proxy: environment_value(&["HTTPS_PROXY", "https_proxy"]),
            http_proxy: environment_value(&["HTTP_PROXY", "http_proxy"]),
            all_proxy: environment_value(&["ALL_PROXY", "all_proxy"]),
            no_proxy: environment_value(&["NO_PROXY", "no_proxy"])
                .map(NoProxy::from)
                .unwrap_or_default(),
        }
    }

    fn resolve(
        &self,
        target: &URL,
        explicit_proxy: Option<&str>,
    ) -> Result<Option<URL>, StreamError> {
        let Some(host) = target.host_str() else {
            return Err(StreamError::new(
                "invalid_url",
                "connect",
                "upstream URL does not contain a host",
            ));
        };

        if self.no_proxy.matches(host) {
            return Ok(None);
        }

        let environment_proxy = match target.scheme() {
            "https" | "wss" => self
                .https_proxy
                .as_deref()
                .or(self.all_proxy.as_deref())
                .or(self.http_proxy.as_deref()),
            "http" | "ws" => self.http_proxy.as_deref().or(self.all_proxy.as_deref()),
            _ => None,
        };
        let Some(raw_proxy) = nonempty(explicit_proxy).or_else(|| nonempty(environment_proxy))
        else {
            return Ok(None);
        };

        let proxy =
            URL::parse(raw_proxy).map_err(|_reason| invalid_proxy("proxy URL is invalid"))?;
        match proxy.scheme() {
            "http" | "https" | "socks5" | "socks5h" => Ok(Some(proxy)),
            _ => Err(invalid_proxy("proxy URL scheme is unsupported")),
        }
    }
}

fn environment_value(names: &[&str]) -> Option<String> {
    names
        .iter()
        .filter_map(|name| env::var(name).ok())
        .find_map(|value| nonempty(Some(value.as_str())).map(str::to_owned))
}

fn nonempty(value: Option<&str>) -> Option<&str> {
    value.map(str::trim).filter(|value| !value.is_empty())
}

fn resolved_proxy(upstream: &UpstreamSpec) -> Result<Option<URL>, StreamError> {
    let target = parse_upstream_url(&upstream.url)?;
    ProxyEnvironment::from_process().resolve(&target, upstream.transport.proxy.as_deref())
}

fn parse_upstream_url(value: &str) -> Result<URL, StreamError> {
    URL::parse(value)
        .map_err(|_reason| StreamError::new("invalid_url", "connect", "upstream URL is invalid"))
}

fn invalid_proxy(message: &str) -> StreamError {
    StreamError::new("invalid_proxy", "connect", message)
}

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
struct ClientKey {
    mode: ClientMode,
    compression: Vec<CompressionPreference>,
    proxy: Option<String>,
    connect_ms: u64,
}

impl ClientKey {
    fn from_upstream(upstream: &UpstreamSpec, mode: ClientMode, proxy: Option<&URL>) -> Self {
        Self {
            mode,
            compression: upstream.transport.compression.clone(),
            proxy: proxy.map(URL::to_string),
            connect_ms: upstream.timeout.connect_ms,
        }
    }
}

fn client_for(upstream: &UpstreamSpec, mode: ClientMode) -> Result<reqwest::Client, StreamError> {
    let proxy = resolved_proxy(upstream)?;
    let key = ClientKey::from_upstream(upstream, mode, proxy.as_ref());
    let clients = HTTP_CLIENTS.get_or_init(|| Mutex::new(HashMap::new()));
    let mut clients = match clients.lock() {
        Ok(clients) => clients,
        Err(poisoned) => poisoned.into_inner(),
    };

    if let Some(client) = clients.get(&key).cloned() {
        return Ok(client);
    }

    let client = build_client(upstream, mode, proxy.as_ref())?;
    if clients.len() >= MAX_HTTP_CLIENT_CACHE_ENTRIES
        && let Some(old_key) = clients.keys().next().cloned()
    {
        clients.remove(&old_key);
    }
    clients.insert(key, client.clone());

    Ok(client)
}

pub async fn open_websocket(
    spec: &StreamSpec,
) -> Result<(UpstreamWebSocket, u16, Vec<(String, String)>), StreamError> {
    ensure_rustls_crypto_provider()?;
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
            .retry_through_credential_pool()
        })??;

    Ok((
        websocket,
        response.status().as_u16(),
        codex_header_map(response.headers()),
    ))
}

async fn websocket_transport_stream(
    target: &URL,
    proxy: Option<&URL>,
) -> Result<BoxedIO, StreamError> {
    let (target_host, target_port) = url_host_and_port(target, false)?;
    let Some(proxy) = proxy else {
        return TCPStream::connect((target_host.as_str(), target_port))
            .await
            .map(|stream| Box::new(stream) as BoxedIO)
            .map_err(|reason| websocket_transport_error("direct connection failed", reason));
    };

    match proxy.scheme() {
        "http" => open_http_proxy_tunnel(proxy, &target_host, target_port).await,
        "socks5" | "socks5h" => open_socks5_proxy_tunnel(proxy, &target_host, target_port).await,
        "https" => Err(invalid_proxy(
            "HTTPS proxies are not supported for upstream WebSocket connections",
        )),
        _ => Err(invalid_proxy("proxy URL scheme is unsupported")),
    }
}

async fn open_http_proxy_tunnel(
    proxy: &URL,
    target_host: &str,
    target_port: u16,
) -> Result<BoxedIO, StreamError> {
    let (proxy_host, proxy_port) = url_host_and_port(proxy, true)?;
    let mut stream = TCPStream::connect((proxy_host.as_str(), proxy_port))
        .await
        .map_err(|reason| websocket_transport_error("proxy connection failed", reason))?;
    let authority = host_authority(target_host, target_port);
    let mut request = format!(
        "CONNECT {authority} HTTP/1.1\r\nHost: {authority}\r\nProxy-Connection: Keep-Alive\r\n"
    );

    if let Some(authorization) = proxy_basic_authorization(proxy)? {
        request.push_str("Proxy-Authorization: Basic ");
        request.push_str(&authorization);
        request.push_str("\r\n");
    }
    request.push_str("\r\n");
    stream
        .write_all(request.as_bytes())
        .await
        .map_err(|reason| websocket_transport_error("proxy CONNECT write failed", reason))?;

    let response = read_proxy_response_header(&mut stream).await?;
    let status = proxy_response_status(&response)?;
    if status != 200 {
        let message = if status == 407 {
            "upstream WebSocket proxy requires authentication"
        } else {
            "upstream WebSocket proxy rejected CONNECT"
        };
        return Err(StreamError::new(
            "websocket_proxy_rejected",
            "connect",
            message,
        ));
    }

    Ok(Box::new(stream))
}

async fn open_socks5_proxy_tunnel(
    proxy: &URL,
    target_host: &str,
    target_port: u16,
) -> Result<BoxedIO, StreamError> {
    let (proxy_host, proxy_port) = url_host_and_port(proxy, true)?;
    let username = decode_userinfo(proxy.username())?;
    let password = proxy
        .password()
        .map(decode_userinfo)
        .transpose()?
        .unwrap_or_default();
    let result = if username.is_empty() && password.is_empty() {
        Socks5Stream::connect(
            (proxy_host.as_str(), proxy_port),
            (target_host, target_port),
        )
        .await
    } else {
        Socks5Stream::connect_with_password(
            (proxy_host.as_str(), proxy_port),
            (target_host, target_port),
            &username,
            &password,
        )
        .await
    };

    result
        .map(|stream| Box::new(stream) as BoxedIO)
        .map_err(|reason| websocket_transport_error("SOCKS5 connection failed", reason))
}

async fn read_proxy_response_header(stream: &mut TCPStream) -> Result<Vec<u8>, StreamError> {
    let mut response = Vec::new();
    let mut byte = [0_u8; 1];

    while response.len() < MAX_PROXY_RESPONSE_HEADER_BYTES {
        let read = stream
            .read(&mut byte)
            .await
            .map_err(|reason| websocket_transport_error("proxy CONNECT read failed", reason))?;
        if read == 0 {
            return Err(StreamError::new(
                "websocket_connect_failed",
                "connect",
                "upstream WebSocket proxy closed during CONNECT",
            )
            .retry_through_credential_pool());
        }
        response.push(byte[0]);
        if response.ends_with(b"\r\n\r\n") {
            return Ok(response);
        }
    }

    Err(StreamError::new(
        "websocket_connect_failed",
        "connect",
        "upstream WebSocket proxy response header is too large",
    ))
}

fn proxy_response_status(response: &[u8]) -> Result<u16, StreamError> {
    let response = std::str::from_utf8(response).map_err(|_reason| {
        StreamError::new(
            "websocket_connect_failed",
            "connect",
            "upstream WebSocket proxy returned an invalid response",
        )
    })?;
    let status = response
        .lines()
        .next()
        .and_then(|line| line.split_whitespace().nth(1))
        .and_then(|value| value.parse().ok())
        .ok_or_else(|| {
            StreamError::new(
                "websocket_connect_failed",
                "connect",
                "upstream WebSocket proxy returned an invalid status",
            )
        })?;
    Ok(status)
}

fn proxy_basic_authorization(proxy: &URL) -> Result<Option<String>, StreamError> {
    let username = decode_userinfo(proxy.username())?;
    let password = proxy.password().map(decode_userinfo).transpose()?;
    if username.is_empty() && password.is_none() {
        return Ok(None);
    }

    Ok(Some(STANDARD.encode_to_string(format!(
        "{username}:{}",
        password.unwrap_or_default()
    ))))
}

fn decode_userinfo(value: &str) -> Result<String, StreamError> {
    let mut decoded = Vec::with_capacity(value.len());
    let bytes = value.as_bytes();
    let mut index = 0;
    while index < bytes.len() {
        if bytes[index] == b'%' {
            let Some(high) = bytes.get(index + 1).and_then(|value| hex_digit(*value)) else {
                return Err(invalid_proxy(
                    "proxy credentials contain invalid percent encoding",
                ));
            };
            let Some(low) = bytes.get(index + 2).and_then(|value| hex_digit(*value)) else {
                return Err(invalid_proxy(
                    "proxy credentials contain invalid percent encoding",
                ));
            };
            decoded.push((high << 4) | low);
            index += 3;
        } else {
            decoded.push(bytes[index]);
            index += 1;
        }
    }

    String::from_utf8(decoded)
        .map_err(|_reason| invalid_proxy("proxy credentials are not valid UTF-8"))
}

fn hex_digit(value: u8) -> Option<u8> {
    match value {
        b'0'..=b'9' => Some(value - b'0'),
        b'a'..=b'f' => Some(value - b'a' + 10),
        b'A'..=b'F' => Some(value - b'A' + 10),
        _ => None,
    }
}

fn url_host_and_port(url: &URL, proxy: bool) -> Result<(String, u16), StreamError> {
    let host = url.host_str().ok_or_else(|| {
        if proxy {
            invalid_proxy("proxy URL does not contain a host")
        } else {
            StreamError::new(
                "invalid_url",
                "connect",
                "upstream URL does not contain a host",
            )
        }
    })?;
    let port = url.port().or_else(|| match url.scheme() {
        "http" | "ws" => Some(80),
        "https" | "wss" => Some(443),
        "socks5" | "socks5h" => Some(1080),
        _ => None,
    });
    let port = port.ok_or_else(|| {
        if proxy {
            invalid_proxy("proxy URL does not contain a port")
        } else {
            StreamError::new(
                "invalid_url",
                "connect",
                "upstream URL does not contain a port",
            )
        }
    })?;
    Ok((host.to_owned(), port))
}

fn host_authority(host: &str, port: u16) -> String {
    if host.contains(':') && !host.starts_with('[') {
        format!("[{host}]:{port}")
    } else {
        format!("{host}:{port}")
    }
}

fn websocket_transport_error(message: &str, reason: impl std::fmt::Display) -> StreamError {
    StreamError::new(
        "websocket_connect_failed",
        "connect",
        format!("upstream WebSocket {message}: {reason}"),
    )
    .retry_through_credential_pool()
}

fn websocket_connect_error(reason: WebSocketError) -> StreamError {
    match reason {
        WebSocketError::Http(response) => {
            let status = response.status().as_u16();
            let headers = codex_header_map(response.headers());

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
        )
        .retry_through_credential_pool(),
    }
}

fn build_client(
    upstream: &UpstreamSpec,
    mode: ClientMode,
    proxy: Option<&URL>,
) -> Result<reqwest::Client, StreamError> {
    ensure_rustls_crypto_provider()?;

    let mut builder = reqwest::Client::builder()
        .no_proxy()
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

    if let Some(proxy) = proxy {
        builder = builder.proxy(reqwest::Proxy::all(proxy.as_str()).map_err(|_reason| {
            StreamError::new("invalid_proxy", "connect", "proxy URL is invalid")
        })?);
    }

    builder = match mode {
        #[cfg(feature = "universal_ai_client_http3")]
        ClientMode::H3PriorKnowledge => builder.http3_prior_knowledge(),
        #[cfg(not(feature = "universal_ai_client_http3"))]
        ClientMode::H3PriorKnowledge => builder,
        ClientMode::AutoALPN => builder,
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

fn ensure_rustls_crypto_provider() -> Result<(), StreamError> {
    #[cfg(feature = "universal_ai_client_ring")]
    if rustls::crypto::CryptoProvider::get_default().is_none()
        && rustls::crypto::ring::default_provider()
            .install_default()
            .is_err()
        && rustls::crypto::CryptoProvider::get_default().is_none()
    {
        return Err(StreamError::new(
            "tls_provider_initialization_failed",
            "connect",
            "failed to install the rustls ring crypto provider",
        ));
    }

    Ok(())
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
    transport.compression.contains(&preference)
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
enum ClientMode {
    H3PriorKnowledge,
    AutoALPN,
    H1Only,
}

impl ClientMode {
    fn as_str(self) -> &'static str {
        match self {
            Self::H3PriorKnowledge => "h3_prior_knowledge",
            Self::AutoALPN => "h2_h1_alpn",
            Self::H1Only => "h1_only",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct HTTPAttempt {
    mode: ClientMode,
    negotiation: &'static str,
}

fn http_attempt_modes(
    preferences: &[HTTPVersionPreference],
    alt_svc_h3: bool,
    http3_available: bool,
) -> Vec<HTTPAttempt> {
    let has_h1 = preferences.contains(&HTTPVersionPreference::H1);
    let has_h2 = preferences.contains(&HTTPVersionPreference::H2);
    let has_h3 = http3_available && preferences.contains(&HTTPVersionPreference::H3);
    let h3_only = has_h3 && !has_h2 && !has_h1;
    let mut modes = Vec::new();
    let mut added_auto = false;
    let mut added_h1 = false;
    let mut added_h3 = false;

    if alt_svc_h3 && has_h3 {
        modes.push(HTTPAttempt {
            mode: ClientMode::H3PriorKnowledge,
            negotiation: "alt_svc_h3",
        });
        added_h3 = true;
    }

    for preference in preferences {
        match preference {
            HTTPVersionPreference::H3 => {
                if h3_only && !added_h3 {
                    modes.push(HTTPAttempt {
                        mode: ClientMode::H3PriorKnowledge,
                        negotiation: "h3_prior_knowledge",
                    });
                    added_h3 = true;
                }
            }
            HTTPVersionPreference::H2 => {
                if !added_auto {
                    modes.push(HTTPAttempt {
                        mode: ClientMode::AutoALPN,
                        negotiation: "alpn_h2_h1",
                    });
                    added_auto = true;
                }
            }
            HTTPVersionPreference::H1 => {
                if has_h2 {
                    if !added_auto {
                        modes.push(HTTPAttempt {
                            mode: ClientMode::AutoALPN,
                            negotiation: "alpn_h2_h1",
                        });
                        added_auto = true;
                    }
                } else if !added_h1 {
                    modes.push(HTTPAttempt {
                        mode: ClientMode::H1Only,
                        negotiation: "h1_only",
                    });
                    added_h1 = true;
                }
            }
        }
    }

    if has_h3 && !h3_only && !added_h3 {
        modes.push(HTTPAttempt {
            mode: ClientMode::H3PriorKnowledge,
            negotiation: "h3_prior_knowledge",
        });
    }

    if modes.is_empty() {
        if has_h1 && !has_h2 {
            modes.push(HTTPAttempt {
                mode: ClientMode::H1Only,
                negotiation: "h1_only",
            });
        } else {
            modes.push(HTTPAttempt {
                mode: ClientMode::AutoALPN,
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
        // `ma` is remote-controlled; an overflowing expiry must not panic.
        let Some(expires_at) = Instant::now().checked_add(Duration::from_secs(max_age)) else {
            return;
        };
        if !cache.contains_key(&origin)
            && cache.len() >= MAX_ALT_SVC_CACHE_ENTRIES
            && let Some(old_origin) = cache.keys().next().cloned()
        {
            cache.remove(&old_origin);
        }
        cache.insert(origin, AltSvcEntry { expires_at });
    }
}

fn origin_key(url: &str) -> Option<String> {
    let url = URL::parse(url).ok()?;
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
    use crate::universal_ai_client::spec::{
        APIResolverKind, DownstreamKind, TimeoutSpec, UpstreamKind,
    };

    #[test]
    fn proxy_resolution_prefers_explicit_then_scheme_specific_then_all() {
        let environment = ProxyEnvironment {
            https_proxy: Some("http://https-proxy.test:8443".to_string()),
            http_proxy: Some("http://http-proxy.test:8080".to_string()),
            all_proxy: Some("socks5://all-proxy.test:1080".to_string()),
            no_proxy: NoProxy::default(),
        };
        let secure_target = URL::parse("wss://provider.test/responses").unwrap();
        let plain_target = URL::parse("ws://provider.test/responses").unwrap();

        assert_eq!(
            environment
                .resolve(&secure_target, Some("socks5://explicit.test:1080"))
                .unwrap()
                .unwrap()
                .as_str(),
            "socks5://explicit.test:1080"
        );
        assert_eq!(
            environment
                .resolve(&secure_target, None)
                .unwrap()
                .unwrap()
                .as_str(),
            "http://https-proxy.test:8443/"
        );
        assert_eq!(
            environment
                .resolve(&plain_target, None)
                .unwrap()
                .unwrap()
                .as_str(),
            "http://http-proxy.test:8080/"
        );

        let all_only = ProxyEnvironment {
            https_proxy: None,
            http_proxy: None,
            all_proxy: environment.all_proxy,
            no_proxy: NoProxy::default(),
        };
        assert_eq!(
            all_only
                .resolve(&secure_target, None)
                .unwrap()
                .unwrap()
                .as_str(),
            "socks5://all-proxy.test:1080"
        );
    }

    #[test]
    fn no_proxy_bypasses_explicit_and_environment_proxies() {
        let environment = ProxyEnvironment {
            https_proxy: Some("http://proxy.test:8080".to_string()),
            http_proxy: None,
            all_proxy: None,
            no_proxy: NoProxy::from("provider.test,127.0.0.1"),
        };
        let target = URL::parse("wss://api.provider.test/responses").unwrap();

        assert!(
            environment
                .resolve(&target, Some("http://explicit.test:8080"))
                .unwrap()
                .is_none()
        );
    }

    #[tokio::test]
    async fn websocket_http_proxy_uses_connect_tunnel_and_basic_auth() {
        let target_listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let target_address = target_listener.local_addr().unwrap();
        let target_task = tokio::spawn(async move {
            let (mut stream, _) = target_listener.accept().await.unwrap();
            let mut request = [0_u8; 4];
            stream.read_exact(&mut request).await.unwrap();
            assert_eq!(&request, b"ping");
            stream.write_all(b"pong").await.unwrap();
        });

        let proxy_listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let proxy_address = proxy_listener.local_addr().unwrap();
        let (connect_tx, connect_rx) = tokio::sync::oneshot::channel();
        let proxy_task = tokio::spawn(async move {
            let (mut client, _) = proxy_listener.accept().await.unwrap();
            let request = read_test_header(&mut client).await;
            connect_tx.send(request).unwrap();
            let mut target = TCPStream::connect(target_address).await.unwrap();
            client
                .write_all(b"HTTP/1.1 200 Connection Established\r\n\r\n")
                .await
                .unwrap();
            tokio::io::copy_bidirectional(&mut client, &mut target)
                .await
                .unwrap();
        });

        let target = URL::parse(&format!("ws://{target_address}/responses")).unwrap();
        let proxy = URL::parse(&format!("http://user:pass@{proxy_address}")).unwrap();
        let mut stream = websocket_transport_stream(&target, Some(&proxy))
            .await
            .unwrap();
        stream.write_all(b"ping").await.unwrap();
        let mut response = [0_u8; 4];
        stream.read_exact(&mut response).await.unwrap();
        assert_eq!(&response, b"pong");
        drop(stream);

        let connect_request = String::from_utf8(connect_rx.await.unwrap()).unwrap();
        assert!(connect_request.starts_with(&format!("CONNECT {target_address} HTTP/1.1\r\n")));
        assert!(connect_request.contains("Proxy-Authorization: Basic dXNlcjpwYXNz\r\n"));
        target_task.await.unwrap();
        proxy_task.await.unwrap();
    }

    async fn read_test_header(stream: &mut TCPStream) -> Vec<u8> {
        let mut response = Vec::new();
        let mut byte = [0_u8; 1];
        while !response.ends_with(b"\r\n\r\n") {
            stream.read_exact(&mut byte).await.unwrap();
            response.push(byte[0]);
        }
        response
    }

    #[tokio::test]
    async fn exhausted_connect_failure_stays_retryable_for_the_credential_pool() {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        drop(listener);
        let upstream = UpstreamSpec {
            kind: UpstreamKind::HTTPSSE,
            method: "GET".to_string(),
            url: format!("http://{address}/unavailable"),
            headers: Vec::new(),
            body: None,
            websocket_initial_messages: Vec::new(),
            timeout: TimeoutSpec {
                connect_ms: 100,
                first_byte_ms: 100,
                idle_ms: 100,
                total_ms: None,
            },
            transport: TransportSpec {
                http_versions: vec![HTTPVersionPreference::H1],
                compression: Vec::new(),
                proxy: None,
            },
        };

        let Err(error) = open_http_stream_for_upstream(&upstream).await else {
            panic!("closed local port must reject the connection");
        };

        assert_eq!(error.code, "transport_failed");
        assert!(error.can_retry_through_credential_pool());
    }

    #[tokio::test]
    async fn websocket_open_fails_on_the_connect_budget_when_the_upgrade_stalls() {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        // Accept the TCP connection and read the upgrade request, but never
        // answer with 101. Only the connect budget may bound this stall.
        let server = tokio::spawn(async move {
            let (mut stream, _) = listener.accept().await.unwrap();
            let mut sink = [0_u8; 1_024];
            while matches!(stream.read(&mut sink).await, Ok(read) if read > 0) {}
        });

        let spec = StreamSpec {
            api_resolver: APIResolverKind::OpenAIResponses,
            upstream: UpstreamSpec {
                kind: UpstreamKind::WebSocketText,
                method: "GET".to_string(),
                url: format!("ws://{address}/responses"),
                headers: Vec::new(),
                body: None,
                websocket_initial_messages: Vec::new(),
                timeout: TimeoutSpec {
                    connect_ms: 200,
                    first_byte_ms: 600_000,
                    idle_ms: 600_000,
                    total_ms: None,
                },
                transport: TransportSpec {
                    http_versions: vec![HTTPVersionPreference::H1],
                    compression: Vec::new(),
                    proxy: None,
                },
            },
            downstream: DownstreamKind::WebSocketText,
            response_context: Default::default(),
            limits: Default::default(),
            hosted_tools: None,
        };

        let started = Instant::now();
        let Err(error) = open_websocket(&spec).await else {
            panic!("a WebSocket upgrade that never returns 101 must not open");
        };

        assert_eq!(error.code, "connect_timeout");
        assert_eq!(error.stage, "connect");
        assert!(error.can_retry_through_credential_pool());
        assert!(started.elapsed() < Duration::from_secs(5));
        server.abort();
    }

    #[test]
    fn terminal_transport_failure_does_not_enter_the_credential_pool() {
        let error = TransportAttemptError::terminal(StreamError::new(
            "transport_failed",
            "connect",
            "request construction failed",
        ))
        .error;

        assert!(!error.can_retry_through_credential_pool());
    }

    #[test]
    fn websocket_http_rejection_keeps_provider_status_without_body() {
        let response = tokio_tungstenite::tungstenite::http::Response::builder()
            .status(429)
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
            error.provider_headers,
            vec![(
                "x-codex-primary-reset-at".to_string(),
                "1785319200".to_string()
            )]
        );
        assert!(!error.message.contains("provider secret"));
    }

    #[test]
    fn codex_response_headers_exclude_unrelated_and_secret_headers() {
        let headers = vec![
            ("X-Codex-Primary-Used-Percent".to_string(), "42".to_string()),
            ("cf-mitigated".to_string(), "challenge".to_string()),
            ("content-type".to_string(), "application/json".to_string()),
            ("authorization".to_string(), "Bearer private".to_string()),
            ("set-cookie".to_string(), "private=value".to_string()),
        ];

        assert_eq!(
            codex_response_headers(&headers),
            vec![
                ("X-Codex-Primary-Used-Percent".to_string(), "42".to_string()),
                ("cf-mitigated".to_string(), "challenge".to_string())
            ]
        );
    }

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
    fn alt_svc_overflowing_ma_is_dropped_without_panic() {
        let mut headers = HeaderMap::new();
        headers.insert(
            reqwest::header::ALT_SVC,
            r#"h3=":443"; ma=18446744073709551615"#.parse().unwrap(),
        );

        record_alt_svc("https://alt-svc-overflow.test/v1/responses", &headers);

        assert!(cached_alt_svc_h3("https://alt-svc-overflow.test:443").is_none());
    }

    #[test]
    fn http_attempts_prefer_cached_alt_svc_h3_when_available() {
        let attempts = http_attempt_modes(
            &[
                HTTPVersionPreference::H3,
                HTTPVersionPreference::H2,
                HTTPVersionPreference::H1,
            ],
            true,
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
                HTTPVersionPreference::H3,
                HTTPVersionPreference::H2,
                HTTPVersionPreference::H1,
            ],
            false,
            true,
        );

        assert_eq!(attempts[0].mode, ClientMode::AutoALPN);
        assert_eq!(attempts[0].negotiation, "alpn_h2_h1");
        assert_eq!(attempts[1].mode, ClientMode::H3PriorKnowledge);
        assert_eq!(attempts[1].negotiation, "h3_prior_knowledge");
    }

    #[test]
    fn http_attempts_allow_explicit_h3_only_prior_knowledge() {
        let attempts = http_attempt_modes(&[HTTPVersionPreference::H3], false, true);

        assert_eq!(attempts.len(), 1);
        assert_eq!(attempts[0].mode, ClientMode::H3PriorKnowledge);
        assert_eq!(attempts[0].negotiation, "h3_prior_knowledge");
    }

    #[test]
    fn http_attempts_skip_h3_when_the_build_does_not_support_it() {
        let attempts = http_attempt_modes(
            &[
                HTTPVersionPreference::H3,
                HTTPVersionPreference::H2,
                HTTPVersionPreference::H1,
            ],
            true,
            false,
        );

        assert_eq!(attempts.len(), 1);
        assert_eq!(attempts[0].mode, ClientMode::AutoALPN);
        assert_eq!(attempts[0].negotiation, "alpn_h2_h1");
    }

    #[test]
    fn http_attempts_fall_back_to_alpn_when_only_h3_was_requested() {
        let attempts = http_attempt_modes(&[HTTPVersionPreference::H3], false, false);

        assert_eq!(attempts.len(), 1);
        assert_eq!(attempts[0].mode, ClientMode::AutoALPN);
        assert_eq!(attempts[0].negotiation, "alpn_h2_h1");
    }

    #[cfg(feature = "universal_ai_client_ring")]
    #[test]
    fn ring_crypto_provider_initialization_is_concurrent_and_idempotent() {
        let workers = (0..8)
            .map(|_| std::thread::spawn(ensure_rustls_crypto_provider))
            .collect::<Vec<_>>();

        for worker in workers {
            assert!(worker.join().expect("provider worker panicked").is_ok());
        }

        assert!(rustls::crypto::CryptoProvider::get_default().is_some());
    }
}
