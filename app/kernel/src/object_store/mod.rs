//! Object storage for the control-plane file service.
//!
//! The control plane opens one store from a JSON spec and starts one operation
//! at a time. Each operation runs on the shared Tokio runtime and reports
//! exactly one result through its sink. The retry and timeout layers bound every
//! storage call, so a caller can wait for the result without its own timer.
//!
//! Large objects move through local files on the control-plane host. The BEAM
//! receives a binary only from `Read`.

use std::panic::AssertUnwindSafe;
use std::path::{Path, PathBuf};
use std::time::Duration;

use bytes::Bytes;
use futures_util::{FutureExt, StreamExt};
use opendal::layers::{RetryLayer, TimeoutLayer};
use opendal::{Buffer, ErrorKind, HttpTransporter, OperationContext, Operator, services};
use opendal_http_transport_reqwest::ReqwestTransport;
use serde::Deserialize;
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWriteExt};

use crate::common::io_runtime;

#[cfg(test)]
mod tests;

/// Chunk size for streamed writes. S3 multipart parts must be at least 5 MiB.
const WRITE_CHUNK_BYTES: usize = 8 * 1024 * 1024;
/// Bound for one object deletion call.
const OPERATION_TIMEOUT: Duration = Duration::from_secs(60);
/// Bound for one I/O call inside a read or a write, so a stalled transfer fails
/// while a slow but progressing transfer of a large object continues.
const IO_TIMEOUT: Duration = Duration::from_secs(60);
const CONNECT_TIMEOUT: Duration = Duration::from_secs(10);
/// A running fs write changes its temporary file at least once per I/O timeout,
/// so a temporary file unchanged for this long belongs to a write that stopped
/// before its rename, for example because the control plane stopped.
const STALE_TEMPORARY_FILE_AGE: Duration = Duration::from_secs(24 * 60 * 60);

/// Storage location of one store, decoded from the control plane's JSON spec.
#[derive(Debug, Deserialize)]
#[serde(tag = "scheme", rename_all = "snake_case", deny_unknown_fields)]
pub enum StoreSpec {
    /// A directory on the control-plane host. Writes go through
    /// `<root>/.tmp` and a rename, so a reader never sees a partial object.
    Fs {
        root: String,
    },
    /// An S3 bucket or an S3-compatible service such as Cloudflare R2.
    S3 {
        bucket: String,
        region: String,
        #[serde(default)]
        endpoint: Option<String>,
        #[serde(default)]
        root: Option<String>,
        /// Static credentials. Without them the default AWS credential chain
        /// applies, which includes EKS Pod Identity.
        #[serde(default)]
        access_key_id: Option<String>,
        #[serde(default)]
        secret_access_key: Option<String>,
    },
    Azblob(services::AzblobConfig),
    D1(services::D1Config),
    Cos(services::CosConfig),
    Postgresql(services::PostgresqlConfig),
    Oss(services::OssConfig),
    Tos(services::TosConfig),
    Gcs(services::GcsConfig),
    Sftp(services::SftpConfig),
    Webdav(services::WebdavConfig),
}

/// An opened store. Cloning it is cheap and shares the same operator.
#[derive(Clone)]
pub struct Store {
    operator: Operator,
}

/// One storage operation on one object key.
#[derive(Debug)]
pub enum Operation {
    Read { key: String },
    ReadToFile { key: String, path: PathBuf },
    Write { key: String, bytes: Vec<u8> },
    WriteFromFile { key: String, path: PathBuf },
    Delete { key: String },
}

/// Successful result of one operation.
#[derive(Debug)]
pub enum Outcome {
    Done,
    /// The object of a `Read`, in the chunks that the store returned. The
    /// binding copies the chunks once, into the binary that it returns.
    Bytes(Buffer),
}

/// Failure with a stable code that the control plane can match on.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StoreError {
    pub code: &'static str,
    pub message: String,
}

impl StoreError {
    fn new(code: &'static str, message: impl Into<String>) -> Self {
        Self {
            code,
            message: message.into(),
        }
    }
}

impl From<opendal::Error> for StoreError {
    fn from(error: opendal::Error) -> Self {
        Self::from(&error)
    }
}

impl From<&opendal::Error> for StoreError {
    fn from(error: &opendal::Error) -> Self {
        let code = match error.kind() {
            ErrorKind::NotFound => "not_found",
            ErrorKind::PermissionDenied => "permission_denied",
            ErrorKind::RateLimited => "rate_limited",
            ErrorKind::ConfigInvalid => "config_invalid",
            ErrorKind::AlreadyExists => "already_exists",
            _ => "storage_error",
        };
        Self::new(code, error.to_string())
    }
}

/// Receives the single result of one started operation.
pub type ResultSink = Box<dyn FnOnce(Result<Outcome, StoreError>) + Send + 'static>;

/// Opens a store from its JSON spec. Opening does no network I/O. The fs
/// scheme creates the root and the temporary directory when they are missing
/// and removes stale temporary files.
pub fn open(spec_json: &str) -> Result<Store, StoreError> {
    let spec: StoreSpec = serde_json::from_str(spec_json)
        .map_err(|reason| StoreError::new("invalid_spec", reason.to_string()))?;

    let uses_http = !matches!(
        &spec,
        StoreSpec::Fs { .. } | StoreSpec::Postgresql(_) | StoreSpec::Sftp(_)
    );
    let operator = match spec {
        StoreSpec::Fs { root } => {
            let atomic_write_dir = Path::new(&root).join(".tmp");
            let builder = services::Fs::default()
                .root(&root)
                .atomic_write_dir(&atomic_write_dir.to_string_lossy());
            let operator = Operator::new(builder)?;
            remove_stale_temporary_files(&atomic_write_dir);
            operator
        }
        StoreSpec::S3 {
            bucket,
            region,
            endpoint,
            root,
            access_key_id,
            secret_access_key,
        } => {
            let mut builder = services::S3::default().bucket(&bucket).region(&region);
            if let Some(endpoint) = endpoint.as_deref() {
                builder = builder.endpoint(endpoint);
            }
            if let Some(root) = root.as_deref() {
                builder = builder.root(root);
            }
            match (access_key_id.as_deref(), secret_access_key.as_deref()) {
                (Some(key_id), Some(secret)) => {
                    builder = builder.access_key_id(key_id).secret_access_key(secret);
                }
                (None, None) => {}
                _ => {
                    return Err(StoreError::new(
                        "invalid_spec",
                        "access_key_id and secret_access_key must be set together",
                    ));
                }
            }
            Operator::new(builder)?
        }
        StoreSpec::Azblob(config) => Operator::from_config(config)?,
        StoreSpec::D1(config) => Operator::from_config(config)?,
        StoreSpec::Cos(config) => Operator::from_config(config)?,
        StoreSpec::Postgresql(config) => Operator::from_config(config)?,
        StoreSpec::Oss(config) => Operator::from_config(config)?,
        StoreSpec::Tos(config) => Operator::from_config(config)?,
        StoreSpec::Gcs(config) => Operator::from_config(config)?,
        StoreSpec::Sftp(config) => Operator::from_config(config)?,
        StoreSpec::Webdav(config) => Operator::from_config(config)?,
    };
    let operator = if uses_http {
        operator.with_context(OperationContext::new().with_http_transport(http_transport()?))
    } else {
        operator
    };

    Ok(Store {
        operator: operator
            .layer(
                TimeoutLayer::new()
                    .with_timeout(OPERATION_TIMEOUT)
                    .with_io_timeout(IO_TIMEOUT),
            )
            .layer(RetryLayer::new().with_jitter()),
    })
}

/// Starts one operation and returns at once. The sink receives exactly one
/// result: the outcome, a failure to start the runtime task, or a panic of the
/// operation, so a caller that waits for the result never waits forever.
pub fn start(store: &Store, operation: Operation, sink: ResultSink) -> Result<(), StoreError> {
    let runtime = io_runtime::runtime()
        .map_err(|reason| StoreError::new("runtime_unavailable", reason.to_string()))?;
    let operator = store.operator.clone();
    runtime.spawn(async move {
        let result = AssertUnwindSafe(run(&operator, operation))
            .catch_unwind()
            .await
            .unwrap_or_else(|_panic| {
                Err(StoreError::new(
                    "panic",
                    "the object store operation panicked",
                ))
            });
        sink(result);
    });
    Ok(())
}

async fn run(operator: &Operator, operation: Operation) -> Result<Outcome, StoreError> {
    match operation {
        Operation::Read { key } => Ok(Outcome::Bytes(operator.read(&key).await?)),
        Operation::ReadToFile { key, path } => read_to_file(operator, &key, &path).await,
        Operation::Write { key, bytes } => {
            write_parts(operator, &key, std::io::Cursor::new(bytes)).await
        }
        Operation::WriteFromFile { key, path } => {
            let file = tokio::fs::File::open(&path)
                .await
                .map_err(local_file_error)?;
            write_parts(operator, &key, file).await
        }
        Operation::Delete { key } => {
            operator.delete(&key).await?;
            Ok(Outcome::Done)
        }
    }
}

async fn read_to_file(operator: &Operator, key: &str, path: &Path) -> Result<Outcome, StoreError> {
    let result = copy_to_file(operator, key, path).await;
    if result.is_err() {
        let _ = tokio::fs::remove_file(path).await;
    }
    result
}

async fn copy_to_file(operator: &Operator, key: &str, path: &Path) -> Result<Outcome, StoreError> {
    let mut stream = operator.reader(key).await?.into_bytes_stream(..).await?;
    let mut file = tokio::fs::File::create(path)
        .await
        .map_err(local_file_error)?;
    while let Some(chunk) = stream.next().await {
        let chunk = chunk.map_err(stream_error)?;
        file.write_all(&chunk).await.map_err(local_file_error)?;
    }
    file.flush().await.map_err(local_file_error)?;
    file.sync_all().await.map_err(local_file_error)?;
    Ok(Outcome::Done)
}

/// Uses one write for backends that cannot accept multiple parts. Other
/// backends use `WRITE_CHUNK_BYTES` parts, so the I/O timeout bounds each part
/// while a slow but progressing transfer can continue.
async fn write_parts(
    operator: &Operator,
    key: &str,
    mut source: impl AsyncRead + Unpin,
) -> Result<Outcome, StoreError> {
    if !operator.info().capability().write_can_multi {
        // WebDAV requires one complete PUT. Database backends also store one
        // complete value, so keep this buffer in native memory.
        let mut bytes = Vec::new();
        source
            .read_to_end(&mut bytes)
            .await
            .map_err(local_file_error)?;
        operator.write(key, bytes).await?;
        return Ok(Outcome::Done);
    }

    // SFTP writes directly to its target. A sibling temporary file and rename
    // keep a failed replacement from truncating a referenced object.
    let temporary_key =
        (operator.info().scheme() == "sftp").then(|| format!("{key}.{}.tmp", uuid::Uuid::new_v4()));
    let write_key = temporary_key.as_deref().unwrap_or(key);
    let mut writer = operator
        .writer_with(write_key)
        .chunk(WRITE_CHUNK_BYTES)
        .await?;
    let mut buffer = vec![0_u8; WRITE_CHUNK_BYTES];

    let copied: Result<(), StoreError> = async {
        loop {
            let read = source.read(&mut buffer).await.map_err(local_file_error)?;
            if read == 0 {
                writer.close().await?;
                if let Some(temporary_key) = &temporary_key {
                    operator.rename(temporary_key, key).await?;
                }
                return Ok(());
            }
            writer
                .write(Bytes::copy_from_slice(&buffer[..read]))
                .await?;
        }
    }
    .await;

    match copied {
        Ok(()) => Ok(Outcome::Done),
        Err(reason) => {
            // An unfinished S3 multipart upload keeps its parts until it is
            // aborted, so a failed copy must not leave it open.
            let _ = writer.abort().await;
            if let Some(temporary_key) = &temporary_key {
                let _ = operator.delete(temporary_key).await;
            }
            Err(reason)
        }
    }
}

/// Removes the temporary files that stopped fs writes left. A file that cannot
/// be removed stays for the next open.
fn remove_stale_temporary_files(dir: &Path) {
    let Ok(entries) = std::fs::read_dir(dir) else {
        return;
    };
    for entry in entries.flatten() {
        let stale = entry
            .metadata()
            .and_then(|metadata| metadata.modified())
            .is_ok_and(|modified| {
                modified
                    .elapsed()
                    .is_ok_and(|age| age > STALE_TEMPORARY_FILE_AGE)
            });
        if stale {
            let _ = std::fs::remove_file(entry.path());
        }
    }
}

fn http_transport() -> Result<HttpTransporter, StoreError> {
    let client = reqwest::Client::builder()
        .connect_timeout(CONNECT_TIMEOUT)
        .build()
        .map_err(|reason| StoreError::new("client_build_failed", reason.to_string()))?;
    Ok(HttpTransporter::new(ReqwestTransport::new(client)))
}

/// Maps an error from a read stream. The stream reports storage failures,
/// including a missing object, as `std::io::Error` that wraps the OpenDAL error.
fn stream_error(reason: std::io::Error) -> StoreError {
    match reason
        .get_ref()
        .and_then(|inner| inner.downcast_ref::<opendal::Error>())
    {
        Some(inner) => StoreError::from(inner),
        None if reason.kind() == std::io::ErrorKind::NotFound => {
            StoreError::new("not_found", reason.to_string())
        }
        None => StoreError::new("storage_error", reason.to_string()),
    }
}

fn local_file_error(reason: std::io::Error) -> StoreError {
    let code = match reason.kind() {
        std::io::ErrorKind::NotFound => "local_file_not_found",
        _ => "local_file_error",
    };
    StoreError::new(code, reason.to_string())
}
