use std::path::PathBuf;
use std::sync::mpsc;
use std::time::Duration;

use super::*;

fn temp_root(label: &str) -> PathBuf {
    let root = std::env::temp_dir().join(format!(
        "ankole-object-store-{label}-{}",
        uuid::Uuid::new_v4()
    ));
    std::fs::create_dir_all(&root).expect("create temp root");
    root
}

fn fs_store(root: &Path) -> Store {
    let spec = serde_json::json!({"scheme": "fs", "root": root.to_string_lossy()}).to_string();
    open(&spec).expect("open fs store")
}

/// An outcome with the bytes of a read in one vector, so that tests can compare it.
#[derive(Debug, PartialEq, Eq)]
enum Seen {
    Done,
    Bytes(Vec<u8>),
}

fn run_operation(store: &Store, operation: Operation) -> Result<Seen, StoreError> {
    let (sender, receiver) = mpsc::channel();
    start(
        store,
        operation,
        Box::new(move |result| {
            let _ = sender.send(result);
        }),
    )
    .expect("start operation");
    let result = receiver
        .recv_timeout(Duration::from_secs(30))
        .expect("operation result");
    result.map(|outcome| match outcome {
        Outcome::Done => Seen::Done,
        Outcome::Bytes(buffer) => Seen::Bytes(buffer.to_vec()),
    })
}

#[test]
fn fs_store_writes_reads_and_deletes_an_object() {
    let root = temp_root("round-trip");
    let store = fs_store(&root);
    let key = "blobs/0123abcd";

    assert_eq!(
        run_operation(
            &store,
            Operation::Write {
                key: key.to_string(),
                bytes: b"hello \0 bytes".to_vec(),
            },
        ),
        Ok(Seen::Done)
    );
    assert_eq!(
        run_operation(
            &store,
            Operation::Read {
                key: key.to_string()
            }
        ),
        Ok(Seen::Bytes(b"hello \0 bytes".to_vec()))
    );
    assert!(root.join(key).is_file());

    assert_eq!(
        run_operation(
            &store,
            Operation::Delete {
                key: key.to_string()
            }
        ),
        Ok(Seen::Done)
    );
    assert!(!root.join(key).exists());

    // Deleting an object that does not exist is a success, so a retried
    // collection step can repeat a delete.
    assert_eq!(
        run_operation(
            &store,
            Operation::Delete {
                key: key.to_string()
            }
        ),
        Ok(Seen::Done)
    );
    std::fs::remove_dir_all(root).ok();
}

#[test]
fn fs_store_reports_missing_objects_as_not_found() {
    let root = temp_root("missing");
    let store = fs_store(&root);

    let read = run_operation(
        &store,
        Operation::Read {
            key: "blobs/missing".into(),
        },
    );
    assert_eq!(read.map_err(|reason| reason.code), Err("not_found"));
    std::fs::remove_dir_all(root).ok();
}

#[test]
fn fs_store_moves_large_objects_through_local_files() {
    let root = temp_root("files");
    let store = fs_store(&root);
    let work = temp_root("files-work");
    let source = work.join("source.bin");
    let target = work.join("target.bin");
    // Larger than one write chunk, so the writer sends more than one part.
    let payload: Vec<u8> = (0..(WRITE_CHUNK_BYTES + 12_345))
        .map(|index| (index % 251) as u8)
        .collect();
    std::fs::write(&source, &payload).expect("write source");

    assert_eq!(
        run_operation(
            &store,
            Operation::WriteFromFile {
                key: "blobs/large".into(),
                path: source.clone(),
            },
        ),
        Ok(Seen::Done)
    );
    assert_eq!(
        run_operation(
            &store,
            Operation::ReadToFile {
                key: "blobs/large".into(),
                path: target.clone(),
            },
        ),
        Ok(Seen::Done)
    );
    assert_eq!(std::fs::read(&target).expect("read target"), payload);

    // The atomic write directory holds no leftover temporary file.
    let leftovers: Vec<_> = std::fs::read_dir(root.join(".tmp"))
        .expect("read temp dir")
        .collect();
    assert!(leftovers.is_empty());

    std::fs::remove_dir_all(root).ok();
    std::fs::remove_dir_all(work).ok();
}

#[test]
fn fs_store_writes_bytes_larger_than_one_part() {
    let root = temp_root("bytes");
    let store = fs_store(&root);
    let payload: Vec<u8> = (0..(2 * WRITE_CHUNK_BYTES + 7))
        .map(|index| (index % 249) as u8)
        .collect();

    assert_eq!(
        run_operation(
            &store,
            Operation::Write {
                key: "blobs/bytes".into(),
                bytes: payload.clone(),
            },
        ),
        Ok(Seen::Done)
    );
    assert_eq!(
        run_operation(
            &store,
            Operation::Read {
                key: "blobs/bytes".into(),
            },
        ),
        Ok(Seen::Bytes(payload))
    );

    std::fs::remove_dir_all(root).ok();
}

#[test]
fn fs_open_removes_stale_temporary_files() {
    let root = temp_root("stale-temp");
    let temporary = root.join(".tmp");
    std::fs::create_dir_all(&temporary).expect("create temp dir");
    let stale = temporary.join("0123abcd.stale");
    let fresh = temporary.join("4567cdef.fresh");
    std::fs::write(&stale, b"left by a stopped write").expect("write stale file");
    std::fs::write(&fresh, b"a running write").expect("write fresh file");
    let two_days_ago = std::time::SystemTime::now() - Duration::from_secs(2 * 24 * 60 * 60);
    std::fs::File::options()
        .write(true)
        .open(&stale)
        .and_then(|file| file.set_modified(two_days_ago))
        .expect("age stale file");

    fs_store(&root);

    assert!(!stale.exists());
    assert!(fresh.exists());
    std::fs::remove_dir_all(root).ok();
}

#[test]
fn read_to_file_removes_the_target_when_the_object_is_missing() {
    let root = temp_root("partial");
    let store = fs_store(&root);
    let target = root.join("target.bin");

    let result = run_operation(
        &store,
        Operation::ReadToFile {
            key: "blobs/missing".into(),
            path: target.clone(),
        },
    );

    assert_eq!(result.map_err(|reason| reason.code), Err("not_found"));
    assert!(!target.exists());
    std::fs::remove_dir_all(root).ok();
}

#[test]
fn write_from_file_reports_a_missing_local_file() {
    let root = temp_root("local-missing");
    let store = fs_store(&root);

    let result = run_operation(
        &store,
        Operation::WriteFromFile {
            key: "blobs/x".into(),
            path: root.join("does-not-exist"),
        },
    );

    assert_eq!(
        result.map_err(|reason| reason.code),
        Err("local_file_not_found")
    );
    std::fs::remove_dir_all(root).ok();
}

#[test]
fn open_rejects_invalid_specs() {
    let unknown = open(r#"{"scheme":"oss","bucket":"b"}"#)
        .err()
        .expect("unknown scheme");
    assert_eq!(unknown.code, "invalid_spec");

    let extra = open(r#"{"scheme":"fs","root":"/tmp/x","bucket":"b"}"#)
        .err()
        .expect("unknown field");
    assert_eq!(extra.code, "invalid_spec");

    let half_credentials =
        open(r#"{"scheme":"s3","bucket":"b","region":"auto","access_key_id":"id"}"#)
            .err()
            .expect("half credentials");
    assert_eq!(half_credentials.code, "invalid_spec");
}

#[test]
fn open_accepts_an_s3_compatible_spec_without_network_io() {
    let spec = serde_json::json!({
        "scheme": "s3",
        "bucket": "ankole-files",
        "region": "auto",
        "endpoint": "https://account.r2.cloudflarestorage.com",
        "root": "/installation",
        "access_key_id": "key",
        "secret_access_key": "secret"
    })
    .to_string();

    assert!(open(&spec).is_ok());
}
