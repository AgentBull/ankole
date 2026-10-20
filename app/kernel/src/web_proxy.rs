//! Loopback SOCKS5 CONNECT transport for Chromium. DNS validation and the TCP
//! connection use the same resolved addresses. TLS stays end-to-end in Chromium.

use std::io;
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr};
use std::sync::Mutex;
use std::time::Duration;

use tokio::io::{AsyncReadExt, AsyncWriteExt, copy_bidirectional};
use tokio::net::{TcpListener, TcpSocket, TcpStream, lookup_host};
use tokio::task::{JoinHandle, JoinSet};
use tokio::time::timeout;
use url::Host;

use crate::common::{self, KernelError, KernelResult};

const HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(15);
const CONNECT_TIMEOUT: Duration = Duration::from_secs(5);
const MAX_CONNECTIONS: usize = 256;

pub struct WebProxy {
    port: u16,
    task: Mutex<Option<JoinHandle<()>>>,
}

impl WebProxy {
    /// A saved Chromium process can reconnect to a proxy on its original port.
    pub fn start(port: u16, ssrf_filter: bool) -> KernelResult<Self> {
        let runtime = common::io_runtime::runtime()?;
        let _entered = runtime.enter();
        let socket = TcpSocket::new_v4().map_err(kernel_error)?;
        socket.set_reuseaddr(true).map_err(kernel_error)?;
        socket
            .bind((Ipv4Addr::LOCALHOST, port).into())
            .map_err(kernel_error)?;
        let listener = socket.listen(128).map_err(kernel_error)?;
        let port = listener.local_addr().map_err(kernel_error)?.port();
        let task = runtime.spawn(serve(listener, ssrf_filter));
        Ok(Self {
            port,
            task: Mutex::new(Some(task)),
        })
    }

    pub fn port(&self) -> u16 {
        self.port
    }

    /// Abort the listener and all tunnels. The caller can await the returned task.
    pub fn stop(&self) -> Option<JoinHandle<()>> {
        let task = self.task.lock().unwrap_or_else(|e| e.into_inner()).take();
        if let Some(task) = &task {
            task.abort();
        }
        task
    }
}

impl Drop for WebProxy {
    fn drop(&mut self) {
        self.stop();
    }
}

fn kernel_error(error: io::Error) -> KernelError {
    KernelError::new(format!("browser proxy failed: {error}"))
}

async fn serve(listener: TcpListener, ssrf_filter: bool) {
    let mut connections = JoinSet::new();
    loop {
        tokio::select! {
            incoming = listener.accept() => {
                let Ok((client, _)) = incoming else { break };
                if connections.len() < MAX_CONNECTIONS {
                    connections.spawn(tunnel(client, ssrf_filter));
                }
            }
            _ = connections.join_next(), if !connections.is_empty() => {}
        }
    }
}

async fn tunnel(mut client: TcpStream, ssrf_filter: bool) -> io::Result<()> {
    let upstream = timeout(HANDSHAKE_TIMEOUT, handshake(&mut client, ssrf_filter)).await;
    let mut upstream = match upstream {
        Ok(Ok(upstream)) => upstream,
        Ok(Err(error)) => {
            let reply = if error.kind() == io::ErrorKind::PermissionDenied {
                2
            } else {
                1
            };
            client
                .write_all(&[5, reply, 0, 1, 0, 0, 0, 0, 0, 0])
                .await?;
            return Err(error);
        }
        Err(_) => return Err(io::Error::from(io::ErrorKind::TimedOut)),
    };
    client.write_all(&[5, 0, 0, 1, 0, 0, 0, 0, 0, 0]).await?;
    copy_bidirectional(&mut client, &mut upstream).await?;
    Ok(())
}

async fn handshake(client: &mut TcpStream, ssrf_filter: bool) -> io::Result<TcpStream> {
    let mut greeting = [0; 2];
    client.read_exact(&mut greeting).await?;
    if greeting[0] != 5 {
        return Err(io::Error::other("SOCKS5 is required"));
    }
    let mut methods = vec![0; usize::from(greeting[1])];
    client.read_exact(&mut methods).await?;
    if !methods.contains(&0) {
        client.write_all(&[5, 255]).await?;
        return Err(io::Error::other(
            "SOCKS5 authentication method is unsupported",
        ));
    }
    client.write_all(&[5, 0]).await?;

    let mut request = [0; 4];
    client.read_exact(&mut request).await?;
    if request[..3] != [5, 1, 0] {
        return Err(io::Error::other("only SOCKS5 TCP CONNECT is supported"));
    }
    let host = match request[3] {
        1 => {
            let mut address = [0; 4];
            client.read_exact(&mut address).await?;
            Host::Ipv4(Ipv4Addr::from(address))
        }
        4 => {
            let mut address = [0; 16];
            client.read_exact(&mut address).await?;
            Host::Ipv6(Ipv6Addr::from(address))
        }
        3 => {
            let length = client.read_u8().await?;
            let mut domain = vec![0; usize::from(length)];
            client.read_exact(&mut domain).await?;
            let domain = std::str::from_utf8(&domain).map_err(io::Error::other)?;
            Host::parse(domain).map_err(io::Error::other)?
        }
        _ => return Err(io::Error::other("invalid SOCKS5 address type")),
    };
    let port = client.read_u16().await?;
    common::validate_host(&host, ssrf_filter).map_err(policy_error)?;
    let addresses = match host {
        Host::Ipv4(ip) => vec![SocketAddr::new(IpAddr::V4(ip), port)],
        Host::Ipv6(ip) => vec![SocketAddr::new(IpAddr::V6(ip), port)],
        Host::Domain(domain) => lookup_host((domain.as_str(), port)).await?.collect(),
    };
    connect_addresses(&addresses, ssrf_filter).await
}

fn policy_error(reason: common::WebURLRejection) -> io::Error {
    io::Error::new(io::ErrorKind::PermissionDenied, reason.as_str())
}

async fn connect_addresses(addresses: &[SocketAddr], ssrf_filter: bool) -> io::Result<TcpStream> {
    let ips: Vec<_> = addresses.iter().map(SocketAddr::ip).collect();
    common::validate_ip_addresses(&ips, ssrf_filter).map_err(policy_error)?;
    let mut last_error = io::Error::other("no browser destination addresses");
    for address in addresses {
        // A SocketAddr cannot trigger another DNS lookup.
        match timeout(CONNECT_TIMEOUT, TcpStream::connect(address)).await {
            Ok(Ok(stream)) => return Ok(stream),
            Ok(Err(error)) => last_error = error,
            Err(_) => last_error = io::Error::from(io::ErrorKind::TimedOut),
        }
    }
    Err(last_error)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn checks_every_answer_before_connecting_to_any_address() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let allowed = listener.local_addr().unwrap();
        let metadata = "169.254.169.254:80".parse().unwrap();
        let error = connect_addresses(&[allowed, metadata], false)
            .await
            .unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::PermissionDenied);
        assert!(
            timeout(Duration::from_millis(30), listener.accept())
                .await
                .is_err()
        );
        assert!(connect_addresses(&[allowed], true).await.is_err());
        assert!(connect_addresses(&[], false).await.is_err());
    }

    #[tokio::test]
    async fn connects_to_the_checked_ip_without_resolving_the_hostname_again() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let mut stream = connect_addresses(&[address], false).await.unwrap();
        let (mut received, _) = listener.accept().await.unwrap();
        stream.write_all(b"pinned").await.unwrap();
        let mut bytes = [0; 6];
        received.read_exact(&mut bytes).await.unwrap();
        assert_eq!(&bytes, b"pinned");
        assert_eq!(stream.peer_addr().unwrap(), address);
    }

    #[tokio::test]
    async fn socks_denies_metadata_names_and_mapped_addresses_with_filter_off() {
        let proxy = WebProxy::start(0, false).unwrap();
        for host in [
            "metadata",
            "metadata.google.internal.",
            "[::ffff:169.254.169.254]",
        ] {
            let mut client = TcpStream::connect((Ipv4Addr::LOCALHOST, proxy.port()))
                .await
                .unwrap();
            client.write_all(&[5, 1, 0]).await.unwrap();
            let mut method = [0; 2];
            client.read_exact(&mut method).await.unwrap();
            assert_eq!(method, [5, 0]);
            let mut request = vec![5, 1, 0, 3, u8::try_from(host.len()).unwrap()];
            request.extend_from_slice(host.as_bytes());
            request.extend_from_slice(&80_u16.to_be_bytes());
            client.write_all(&request).await.unwrap();
            let mut reply = [0; 10];
            client.read_exact(&mut reply).await.unwrap();
            assert_eq!(reply[1], 2, "{host}");
        }
        proxy.stop().unwrap().await.unwrap_err();
    }

    #[tokio::test]
    async fn stopping_proxy_closes_tunnels_and_releases_the_saved_port() {
        let proxy = WebProxy::start(0, false).unwrap();
        let port = proxy.port();
        let mut client = TcpStream::connect((Ipv4Addr::LOCALHOST, port))
            .await
            .unwrap();
        client.write_all(&[5, 1, 0]).await.unwrap();
        let mut method = [0; 2];
        client.read_exact(&mut method).await.unwrap();
        proxy.stop().unwrap().await.unwrap_err();
        assert!(client.read_u8().await.is_err());
        let restored = WebProxy::start(port, true).unwrap();
        assert_eq!(restored.port(), port);
    }
}
