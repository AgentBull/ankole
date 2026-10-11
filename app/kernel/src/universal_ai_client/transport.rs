use std::collections::HashMap;
use std::env;
use std::sync::{Mutex, OnceLock};
use std::time::Duration;

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
use super::spec::{StreamSpec, UpstreamSpec};

pub(crate) trait AsyncIO: AsyncRead + AsyncWrite + Send + Unpin {}

impl<T> AsyncIO for T where T: AsyncRead + AsyncWrite + Send + Unpin {}

pub(crate) type BoxedIO = Box<dyn AsyncIO>;

pub type UpstreamWebSocket = WebSocketStream<MaybeTLSStream<BoxedIO>>;

static HTTP_CLIENTS: OnceLock<Mutex<HashMap<ClientKey, reqwest::Client>>> = OnceLock::new();

const MAX_HTTP_CLIENT_CACHE_ENTRIES: usize = 64;
const MAX_PROXY_RESPONSE_HEADER_BYTES: usize = 16 * 1_024;

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
            .retry_through_credential_pool()
        })?
        .map_err(|reason| {
            let error = StreamError::new(
                "transport_failed",
                "connect",
                format!("upstream request failed: {reason}"),
            );
            if reason.is_connect() {
                error.retry_through_credential_pool()
            } else {
                error
            }
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
    let clients = HTTP_CLIENTS.get_or_init(|| Mutex::new(HashMap::new()));
    let mut clients = match clients.lock() {
        Ok(clients) => clients,
        Err(poisoned) => poisoned.into_inner(),
    };

    if let Some(client) = clients.get(&key).cloned() {
        return Ok(client);
    }

    let client = build_client(upstream, proxy.as_ref())?;
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
        safe_header_map(response.headers()),
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
        )
        .retry_through_credential_pool(),
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
    use crate::universal_ai_client::spec::{APIResolverKind, TimeoutSpec, UpstreamKind};
    use std::time::Instant;

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

        assert!(HTTP_CLIENTS.get().unwrap().lock().unwrap().len() <= MAX_HTTP_CLIENT_CACHE_ENTRIES);
    }

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
            transport: TransportSpec { proxy: None },
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
                transport: TransportSpec { proxy: None },
            },
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
