use super::super::error::StreamError;
use super::super::spec::UpstreamSpec;
use super::BoxedIO;
use base64_simd::STANDARD;
use no_proxy::NoProxy;
use reqwest::Url as URL;
use std::env;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream as TCPStream;
use tokio_socks::tcp::Socks5Stream;

const MAX_PROXY_RESPONSE_HEADER_BYTES: usize = 16 * 1_024;

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

pub(super) fn resolved_proxy(upstream: &UpstreamSpec) -> Result<Option<URL>, StreamError> {
    let target = parse_upstream_url(&upstream.url)?;
    ProxyEnvironment::from_process().resolve(&target, upstream.transport.proxy.as_deref())
}

pub(super) fn parse_upstream_url(value: &str) -> Result<URL, StreamError> {
    URL::parse(value)
        .map_err(|_reason| StreamError::new("invalid_url", "connect", "upstream URL is invalid"))
}

fn invalid_proxy(message: &str) -> StreamError {
    StreamError::new("invalid_proxy", "connect", message)
}

pub(super) async fn websocket_transport_stream(
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
    if !(200..300).contains(&status) {
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
            ));
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
}

#[cfg(test)]
mod tests {
    use super::super::super::spec::{
        APIResolverKind, StreamSpec, TimeoutSpec, TransportSpec, UpstreamKind,
    };
    use super::super::{open_http_stream_for_upstream, open_websocket};
    use super::*;
    use std::time::{Duration, Instant};
    #[tokio::test]
    async fn connect_accepts_all_success_statuses_without_consuming_tunnel_bytes() {
        use tokio::io::{AsyncReadExt, AsyncWriteExt};
        for status in [200, 201, 204, 299, 407, 500] {
            let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
            let address = listener.local_addr().unwrap();
            let server = tokio::spawn(async move {
                let (mut stream, _) = listener.accept().await.unwrap();
                let mut request = [0; 4096];
                stream.read(&mut request).await.unwrap();
                stream
                    .write_all(format!("HTTP/1.1 {status} Fixture\r\n\r\ntunnel").as_bytes())
                    .await
                    .unwrap();
            });
            let result = open_http_proxy_tunnel(
                &URL::parse(&format!("http://{address}")).unwrap(),
                "fixture",
                443,
            )
            .await;
            if status < 300 {
                let mut stream = result.unwrap();
                let mut bytes = [0; 6];
                stream.read_exact(&mut bytes).await.unwrap();
                assert_eq!(&bytes, b"tunnel");
            } else {
                assert_eq!(result.err().unwrap().code, "websocket_proxy_rejected");
            }
            server.await.unwrap();
        }
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
    async fn connect_failure_reports_transport_facts() {
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
        assert!(started.elapsed() < Duration::from_secs(5));
        server.abort();
    }
}
