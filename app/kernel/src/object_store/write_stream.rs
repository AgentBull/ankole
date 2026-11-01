//! One native writer consumes acknowledged chunks from its BEAM owner.

use tokio::sync::{mpsc, watch};

use super::*;

pub struct WriteHandle {
    commands: mpsc::Sender<Command>,
    cancelled: watch::Sender<bool>,
}

enum Command {
    Write(Bytes, ResultSink),
    Finish(ResultSink),
}

impl WriteHandle {
    pub fn write(&self, bytes: Bytes, sink: ResultSink) -> Result<(), StoreError> {
        if bytes.len() > WRITE_CHUNK_BYTES {
            return Err(StoreError::new(
                "invalid_chunk",
                "chunks must not exceed 8 MiB",
            ));
        }
        self.send(Command::Write(bytes, sink))
    }

    pub fn finish(&self, sink: ResultSink) -> Result<(), StoreError> {
        self.send(Command::Finish(sink))
    }

    pub fn cancel(&self) {
        let _ = self.cancelled.send(true);
    }

    fn send(&self, command: Command) -> Result<(), StoreError> {
        self.commands
            .try_send(command)
            .map_err(|error| match error {
                mpsc::error::TrySendError::Full(_) => {
                    StoreError::new("writer_busy", "wait for the previous write acknowledgement")
                }
                mpsc::error::TrySendError::Closed(_) => {
                    StoreError::new("writer_closed", "the object writer has stopped")
                }
            })
    }
}

impl Drop for WriteHandle {
    fn drop(&mut self) {
        self.cancel();
    }
}

pub fn start_write(
    store: &Store,
    key: String,
    opened: ResultSink,
) -> Result<WriteHandle, StoreError> {
    let runtime = io_runtime::runtime()
        .map_err(|reason| StoreError::new("runtime_unavailable", reason.to_string()))?;
    let (sender, mut commands) = mpsc::channel(1);
    let (cancelled, mut cancellation) = watch::channel(false);
    let operator = store.operator.clone();

    runtime.spawn(async move {
        let result = tokio::select! {
            biased;
            _ = cancellation.changed() => Err(cancelled_error()),
            result = catch_panic(ObjectWriter::open(&operator, &key)) => result,
        };
        let mut writer = match result {
            Ok(writer) => writer,
            Err(reason) => {
                opened(Err(reason));
                return;
            }
        };
        opened(Ok(Outcome::Done));

        loop {
            let command = tokio::select! {
                biased;
                _ = cancellation.changed() => None,
                command = commands.recv() => command,
            };
            let Some(command) = command else {
                writer.abort().await;
                return;
            };
            let (result, sink, finished) = match command {
                Command::Write(bytes, sink) => {
                    let result = tokio::select! {
                        biased;
                        _ = cancellation.changed() => Err(cancelled_error()),
                        result = catch_panic(writer.write(bytes)) => result,
                    };
                    (result, sink, false)
                }
                Command::Finish(sink) => {
                    let result = tokio::select! {
                        biased;
                        _ = cancellation.changed() => Err(cancelled_error()),
                        result = catch_panic(writer.close()) => result,
                    };
                    (result, sink, true)
                }
            };
            let failed = result.is_err();
            if failed {
                writer.abort().await;
            }
            sink(result.map(|()| Outcome::Done));
            if failed || finished {
                return;
            }
        }
    });

    Ok(WriteHandle {
        commands: sender,
        cancelled,
    })
}

fn cancelled_error() -> StoreError {
    StoreError::new(
        "cancelled",
        "the object writer's owner cancelled the upload",
    )
}

async fn catch_panic<T>(
    future: impl std::future::Future<Output = Result<T, StoreError>>,
) -> Result<T, StoreError> {
    AssertUnwindSafe(future)
        .catch_unwind()
        .await
        .unwrap_or_else(|_| {
            Err(StoreError::new(
                "panic",
                "the object store operation panicked",
            ))
        })
}

/// File and Enumerable uploads share completion and failure cleanup. Backends
/// without multipart support receive one value buffered in native memory.
pub(super) struct ObjectWriter {
    operator: Operator,
    key: String,
    temporary_key: Option<String>,
    writer: Option<opendal::Writer>,
    buffer: Vec<u8>,
    written_bytes: u64,
}

impl ObjectWriter {
    pub(super) async fn open(operator: &Operator, key: &str) -> Result<Self, StoreError> {
        let temporary_key = (operator.info().scheme() == "sftp")
            .then(|| format!("{key}.{}.tmp", uuid::Uuid::new_v4()));
        let writer = if operator.info().capability().write_can_multi {
            Some(
                operator
                    .writer_with(temporary_key.as_deref().unwrap_or(key))
                    .chunk(WRITE_CHUNK_BYTES)
                    .await?,
            )
        } else {
            None
        };
        Ok(Self {
            operator: operator.clone(),
            key: key.to_owned(),
            temporary_key,
            writer,
            buffer: Vec::new(),
            written_bytes: 0,
        })
    }

    pub(super) async fn write(&mut self, bytes: Bytes) -> Result<(), StoreError> {
        let size = self
            .written_bytes
            .checked_add(bytes.len() as u64)
            .ok_or_else(|| StoreError::new("file_too_large", "object size overflow"))?;
        check_write_size(&self.operator, size)?;
        if let Some(writer) = &mut self.writer {
            writer.write(bytes).await?;
        } else {
            self.buffer.extend_from_slice(&bytes);
        }
        self.written_bytes = size;
        Ok(())
    }

    pub(super) async fn close(&mut self) -> Result<(), StoreError> {
        if let Some(writer) = &mut self.writer {
            writer.close().await?;
            if let Some(temporary_key) = &self.temporary_key {
                self.operator.rename(temporary_key, &self.key).await?;
            }
        } else {
            self.operator
                .write(&self.key, std::mem::take(&mut self.buffer))
                .await?;
        }
        Ok(())
    }

    pub(super) async fn abort(&mut self) {
        if let Some(writer) = &mut self.writer {
            let _ = AssertUnwindSafe(writer.abort()).catch_unwind().await;
        }
        if let Some(temporary_key) = &self.temporary_key {
            let _ = self.operator.delete(temporary_key).await;
        }
    }
}
