use std::collections::HashSet;
use std::env;
use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStderr, ChildStdin, ChildStdout, Command, Stdio};
use std::sync::{Arc, Mutex, mpsc};
use std::thread;
use std::time::{Duration, Instant};

use ankole_kernel::actor_bus;
use ankole_kernel::actor_bus::transport::{DealerConfig, DealerEvent, DealerHandle};
use postgres::{Client, NoTls};
use serde_json::{Value, json};
use uuid::Uuid;

const HEARTBEAT_INTERVAL: Duration = Duration::from_secs(15);
const CREDENTIAL_TIMEOUT: Duration = Duration::from_secs(120);

#[derive(Clone, Debug)]
struct WorkerConfig {
    endpoint: String,
    database_url: String,
    worker_id: String,
    worker_instance_id: String,
    workspace_root: String,
    bun_workdir: String,
    bun_script: String,
}

#[derive(Debug)]
struct TurnChildReply {
    proposal: Value,
    turn: Value,
}

fn main() {
    if let Err(error) = run() {
        eprintln!(
            "{}",
            json!({
                "event": "worker.error",
                "runtime": "rust-daemon",
                "error": error,
            })
        );
        std::process::exit(1);
    }
}

fn run() -> Result<(), String> {
    let config = parse_env()?;
    let pre_auth_key = bootstrap_worker_key(&config.database_url, &config.worker_id)?;
    let dealer = start_dealer(&config, pre_auth_key)?;

    dealer
        .send_envelope(worker_ready_envelope(&config))
        .map_err(|error| error.to_string())?;
    dealer
        .send_envelope(worker_capacity_envelope(&config))
        .map_err(|error| error.to_string())?;

    println!(
        "{}",
        json!({
            "event": "worker.ready_sent",
            "runtime": "rust-daemon",
            "endpoint": config.endpoint,
            "worker_id": config.worker_id,
            "worker_instance_id": config.worker_instance_id,
        })
    );

    let mut next_heartbeat = Instant::now() + HEARTBEAT_INTERVAL;

    loop {
        if Instant::now() >= next_heartbeat {
            dealer
                .send_envelope(worker_heartbeat_envelope(&config))
                .map_err(|error| error.to_string())?;
            next_heartbeat = Instant::now() + HEARTBEAT_INTERVAL;
        }

        match dealer
            .recv(Duration::from_millis(500))
            .map_err(|error| error.to_string())?
        {
            Some(DealerEvent::Received(payload)) => {
                let envelope =
                    actor_bus::decode_envelope_json(&payload).map_err(|error| error.to_string())?;
                handle_envelope(&dealer, &config, envelope)?;
            }
            Some(DealerEvent::DecodeFailed(reason)) | Some(DealerEvent::SocketError(reason)) => {
                return Err(reason);
            }
            None => {}
        }
    }
}

fn parse_env() -> Result<WorkerConfig, String> {
    for key in [
        "ANKOLE_AGENT_UID",
        "ANKOLE_SESSION_ID",
        "ANKOLE_ACTOR_EPOCH",
        "ANKOLE_LLM_TURN_ID",
    ] {
        if env::var_os(key).is_some() {
            return Err(format!("{key} must not be set on an agent computer worker"));
        }
    }

    Ok(WorkerConfig {
        endpoint: required_env("ANKOLE_ACTOR_BUS_ENDPOINT")?,
        database_url: required_env("DATABASE_URL")?,
        worker_id: normalize_worker_id(&required_env("ANKOLE_AGENT_COMPUTER_WORKER_ID")?)?,
        worker_instance_id: env::var("ANKOLE_AGENT_COMPUTER_WORKER_INSTANCE_ID")
            .unwrap_or_else(|_| format!("worker-instance-{}", Uuid::new_v4())),
        workspace_root: env::var("ANKOLE_WORKSPACE_ROOT").unwrap_or_else(|_| "/workspace".into()),
        bun_workdir: env::var("ANKOLE_AGENT_COMPUTER_BUN_WORKDIR")
            .unwrap_or_else(|_| "/repo/app/agent_computer".into()),
        bun_script: env::var("ANKOLE_AGENT_COMPUTER_BUN_SCRIPT")
            .unwrap_or_else(|_| "src/turn_child.ts".into()),
    })
}

fn required_env(key: &str) -> Result<String, String> {
    env::var(key)
        .map(|value| value.trim().to_string())
        .ok()
        .filter(|value| !value.is_empty())
        .ok_or_else(|| format!("{key} is required"))
}

fn normalize_worker_id(worker_id: &str) -> Result<String, String> {
    let normalized = worker_id.trim().to_ascii_lowercase();
    let valid = normalized.chars().enumerate().all(|(index, ch)| {
        if index == 0 {
            ch.is_ascii_lowercase()
        } else {
            ch.is_ascii_lowercase() || ch.is_ascii_digit() || ch == '_' || ch == '-'
        }
    }) && normalized.len() <= 63;

    if valid {
        Ok(normalized)
    } else {
        Err("ANKOLE_AGENT_COMPUTER_WORKER_ID must match ^[a-z][a-z0-9_-]{0,62}$".into())
    }
}

fn bootstrap_worker_key(database_url: &str, worker_id: &str) -> Result<String, String> {
    let mut client = Client::connect(database_url, NoTls)
        .map_err(|error| format!("failed to connect database for worker bootstrap: {error}"))?;
    let mut tx = client
        .transaction()
        .map_err(|error| format!("failed to start worker bootstrap transaction: {error}"))?;

    tx.execute(
        "select pg_advisory_xact_lock(hashtext($1))",
        &[&format!("agent_computer_worker_auth_keys:{worker_id}")],
    )
    .map_err(|error| format!("failed to lock worker auth key: {error}"))?;

    if let Some(row) = tx
        .query_opt(
            "select pre_auth_key, disabled_at is not null from agent_computer_worker_auth_keys where worker_id = $1 for update",
            &[&worker_id],
        )
        .map_err(|error| format!("failed to read worker auth key: {error}"))?
    {
        let disabled: bool = row.get(1);
        if disabled {
            return Err("worker auth key is disabled".into());
        }

        let pre_auth_key: String = row.get(0);
        tx.execute(
            "update agent_computer_worker_auth_keys set last_bootstrap_at = now(), updated_at = now() where worker_id = $1",
            &[&worker_id],
        )
        .map_err(|error| format!("failed to update worker bootstrap timestamp: {error}"))?;
        tx.commit()
            .map_err(|error| format!("failed to commit worker bootstrap transaction: {error}"))?;
        return Ok(pre_auth_key);
    }

    let pre_auth_key = format!("ak_{}{}", Uuid::new_v4().simple(), Uuid::new_v4().simple());

    tx.execute(
        "insert into agent_computer_worker_auth_keys (worker_id, pre_auth_key, key_revision, last_bootstrap_at, inserted_at, updated_at) values ($1, $2, 1, now(), now(), now())",
        &[&worker_id, &pre_auth_key],
    )
    .map_err(|error| format!("failed to insert worker auth key: {error}"))?;
    tx.commit()
        .map_err(|error| format!("failed to commit worker bootstrap transaction: {error}"))?;

    Ok(pre_auth_key)
}

fn start_dealer(config: &WorkerConfig, pre_auth_key: String) -> Result<DealerHandle, String> {
    actor_bus::transport::start_dealer(DealerConfig {
        endpoint: config.endpoint.clone(),
        identity: config.worker_instance_id.clone(),
        username: config.worker_id.clone(),
        password: pre_auth_key,
        sndhwm: None,
        rcvhwm: None,
        linger_ms: None,
        sndtimeo_ms: None,
        rcvtimeo_ms: None,
        poll_interval_ms: Some(10),
        command_timeout_ms: Some(1_000),
    })
    .map_err(|error| error.to_string())
}

fn handle_envelope(
    dealer: &DealerHandle,
    config: &WorkerConfig,
    envelope: Value,
) -> Result<(), String> {
    let body_type = envelope
        .pointer("/body/type")
        .and_then(Value::as_str)
        .unwrap_or_default();

    if body_type != "turn_start" {
        return Ok(());
    }

    let turn_start = envelope
        .pointer("/body/turn_start")
        .cloned()
        .ok_or_else(|| "turn_start body is missing".to_string())?;
    let turn = turn_start
        .get("turn")
        .cloned()
        .ok_or_else(|| "turn_start.turn is missing".to_string())?;
    let input_ids = turn_start
        .get("inputs")
        .and_then(Value::as_array)
        .map(|inputs| {
            inputs
                .iter()
                .filter_map(|input| input.get("actor_input_id").and_then(Value::as_str))
                .map(Value::from)
                .collect::<Vec<_>>()
        })
        .unwrap_or_default();
    let correlation_id = envelope
        .get("message_id")
        .and_then(Value::as_str)
        .map(str::to_string);

    dealer
        .send_envelope(turn_accepted_envelope(
            &turn,
            input_ids,
            correlation_id.as_deref(),
        ))
        .map_err(|error| error.to_string())?;

    let reply = if is_placeholder_turn(&turn_start) {
        TurnChildReply {
            proposal: visible_reply_proposal("PONG"),
            turn: turn.clone(),
        }
    } else {
        materialize_conversation_store(&config.database_url, &config.workspace_root, &turn_start)?;
        materialize_library_container(&config.database_url, &config.workspace_root, &turn_start)?;
        let reply = run_bun_turn_child(dealer, config, turn_start.clone(), correlation_id.clone())?;
        persist_library_container(&config.database_url, &config.workspace_root, &turn_start)?;
        reply
    };

    dealer
        .send_envelope(final_proposal_envelope(
            &reply.turn,
            &reply.proposal,
            correlation_id.as_deref(),
        ))
        .map_err(|error| error.to_string())?;
    Ok(())
}

fn is_placeholder_turn(turn_start: &Value) -> bool {
    turn_start
        .pointer("/model_ref/provider_id")
        .and_then(Value::as_str)
        .map(|provider_id| provider_id == "ankole-placeholder")
        .unwrap_or(true)
}

fn materialize_conversation_store(
    database_url: &str,
    workspace_root: &str,
    turn_start: &Value,
) -> Result<(), String> {
    let agent_uid = turn_start
        .pointer("/turn/actor/agent_uid")
        .and_then(Value::as_str)
        .ok_or_else(|| "turn_start.turn.actor.agent_uid is missing".to_string())?;
    let session_id = turn_start
        .pointer("/turn/actor/session_id")
        .and_then(Value::as_str)
        .ok_or_else(|| "turn_start.turn.actor.session_id is missing".to_string())?;
    let conversation_dir = Path::new(workspace_root)
        .join("actors")
        .join(path_segment(agent_uid))
        .join(path_segment(session_id))
        .join("conversation");

    fs::create_dir_all(&conversation_dir).map_err(|error| {
        format!(
            "failed to create conversation store {}: {error}",
            conversation_dir.display()
        )
    })?;

    let mut client = Client::connect(database_url, NoTls).map_err(|error| {
        format!("failed to connect database for conversation materialization: {error}")
    })?;

    let rows = client
        .query(
            r#"
            select
              message.id::text,
              message.role,
              message.kind,
              message.content::text,
              coalesce(message.metadata::text, '{}'),
              message.inserted_at::text
            from ai_agent_messages message
            join ai_agent_conversations conversation
              on conversation.id = message.conversation_id
            where conversation.agent_uid = $1
              and conversation.conversation_key = $2
              and conversation.ended_at is null
              and message.status = 'complete'
            order by message.inserted_at asc, message.id asc
            "#,
            &[&agent_uid, &session_id],
        )
        .map_err(|error| format!("failed to read conversation messages: {error}"))?;

    let mut jsonl = String::new();
    for row in rows {
        let id: String = row.get(0);
        let role: String = row.get(1);
        let kind: String = row.get(2);
        let content_text: String = row.get(3);
        let metadata_text: String = row.get(4);
        let inserted_at: String = row.get(5);
        let content = serde_json::from_str::<Value>(&content_text)
            .unwrap_or_else(|_| Value::String(content_text));
        let metadata = serde_json::from_str::<Value>(&metadata_text).unwrap_or_else(|_| json!({}));

        jsonl.push_str(
            &json!({
                "id": id,
                "role": role,
                "kind": kind,
                "content": content,
                "metadata": metadata,
                "inserted_at": inserted_at
            })
            .to_string(),
        );
        jsonl.push('\n');
    }

    fs::write(conversation_dir.join("messages.jsonl"), jsonl).map_err(|error| {
        format!(
            "failed to write conversation store {}: {error}",
            conversation_dir.join("messages.jsonl").display()
        )
    })
}

fn materialize_library_container(
    database_url: &str,
    workspace_root: &str,
    turn_start: &Value,
) -> Result<(), String> {
    let agent_uid = turn_start
        .pointer("/turn/actor/agent_uid")
        .and_then(Value::as_str)
        .ok_or_else(|| "turn_start.turn.actor.agent_uid is missing".to_string())?;
    let root = Path::new(workspace_root).join("library-containers");

    if root.exists() {
        fs::remove_dir_all(&root).map_err(|error| {
            format!(
                "failed to clear library container {}: {error}",
                root.display()
            )
        })?;
    }
    fs::create_dir_all(&root).map_err(|error| {
        format!(
            "failed to create library container {}: {error}",
            root.display()
        )
    })?;

    let mut client = Client::connect(database_url, NoTls).map_err(|error| {
        format!("failed to connect database for library materialization: {error}")
    })?;

    let rows = client
        .query(
            r#"
            select path, content
            from agent_library_container_entries
            where agent_uid = $1
              and deleted_at is null
              and (
                path in ('SOUL.md', 'MISSION.md')
                or path like 'skills/%/AGENT_APPEND.md'
              )
              and content is not null
            union all
            select 'skills/' || skill.skill_name || '/' || file.path, file.content
            from library_skills skill
            join library_skill_files file on file.skill_name = skill.skill_name
            left join agent_skill_assignments assignment
              on assignment.agent_uid = $1
             and assignment.skill_name = skill.skill_name
            where coalesce(assignment.enabled, skill.default_enabled) = true
            order by path
            "#,
            &[&agent_uid],
        )
        .map_err(|error| format!("failed to read effective library files: {error}"))?;

    for row in rows {
        let path: String = row.get(0);
        let content: String = row.get(1);
        let target = safe_library_path(&root, &path)?;
        if let Some(parent) = target.parent() {
            fs::create_dir_all(parent).map_err(|error| {
                format!(
                    "failed to create library container directory {}: {error}",
                    parent.display()
                )
            })?;
        }
        fs::write(&target, content).map_err(|error| {
            format!(
                "failed to write library container file {}: {error}",
                target.display()
            )
        })?;
    }

    Ok(())
}

fn path_segment(value: &str) -> String {
    let mut out = String::new();
    for byte in value.as_bytes() {
        match *byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' => out.push(*byte as char),
            byte => out.push_str(&format!("%{byte:02X}")),
        }
    }
    out
}

fn safe_library_path(root: &Path, virtual_path: &str) -> Result<PathBuf, String> {
    let clean = virtual_path.trim_start_matches('/');
    if clean.is_empty()
        || clean.split('/').any(|segment| {
            segment.is_empty() || segment == "." || segment == ".." || segment.contains('\\')
        })
    {
        return Err(format!("invalid library container path: {virtual_path}"));
    }

    Ok(root.join(clean))
}

fn persist_library_container(
    database_url: &str,
    workspace_root: &str,
    turn_start: &Value,
) -> Result<(), String> {
    let agent_uid = turn_start
        .pointer("/turn/actor/agent_uid")
        .and_then(Value::as_str)
        .ok_or_else(|| "turn_start.turn.actor.agent_uid is missing".to_string())?;
    let root = Path::new(workspace_root).join("library-containers");
    if !root.exists() {
        return Ok(());
    }

    let mut files = Vec::new();
    collect_persistable_library_files(&root, &root, &mut files)?;
    let present_skill_appends = present_skill_append_paths(&files);

    let mut client = Client::connect(database_url, NoTls)
        .map_err(|error| format!("failed to connect database for library persistence: {error}"))?;
    let mut tx = client
        .transaction()
        .map_err(|error| format!("failed to start library persistence transaction: {error}"))?;

    for (path, source_kind, metadata, content) in files {
        tx.execute(
            r#"
            insert into agent_library_container_entries
              (agent_uid, path, source_kind, content, content_hash, metadata, deleted_at, inserted_at, updated_at)
            values
              ($1, $2, $3, $4, encode(digest($4, 'sha256'), 'hex'), $5::text::jsonb, null, now(), now())
            on conflict (agent_uid, path) where deleted_at is null
            do update set
              source_kind = excluded.source_kind,
              content = excluded.content,
              content_hash = excluded.content_hash,
              metadata = excluded.metadata,
              deleted_at = null,
              updated_at = now()
            "#,
            &[&agent_uid, &path, &source_kind, &content, &metadata],
        )
        .map_err(|error| format!("failed to persist library file {path}: {error}"))?;
    }

    tombstone_deleted_skill_appends(&mut tx, agent_uid, &present_skill_appends)?;

    tx.commit()
        .map_err(|error| format!("failed to commit library persistence transaction: {error}"))
}

fn present_skill_append_paths(files: &[(String, String, String, String)]) -> HashSet<String> {
    files
        .iter()
        .filter_map(|(path, source_kind, _metadata, _content)| {
            (source_kind == "skill_append").then(|| path.clone())
        })
        .collect()
}

fn tombstone_deleted_skill_appends(
    tx: &mut postgres::Transaction<'_>,
    agent_uid: &str,
    present_skill_appends: &HashSet<String>,
) -> Result<(), String> {
    let rows = tx
        .query(
            r#"
            select path
            from agent_library_container_entries
            where agent_uid = $1
              and source_kind = 'skill_append'
              and deleted_at is null
            "#,
            &[&agent_uid],
        )
        .map_err(|error| format!("failed to read active skill append entries: {error}"))?;

    for row in rows {
        let path: String = row.get(0);
        if present_skill_appends.contains(&path) {
            continue;
        }

        tx.execute(
            r#"
            update agent_library_container_entries
            set
              content = null,
              content_hash = null,
              metadata = metadata || '{"source":"agent_computer","tombstone":true}'::jsonb,
              deleted_at = now(),
              updated_at = now()
            where agent_uid = $1
              and path = $2
              and source_kind = 'skill_append'
              and deleted_at is null
            "#,
            &[&agent_uid, &path],
        )
        .map_err(|error| format!("failed to tombstone deleted skill append {path}: {error}"))?;
    }

    Ok(())
}

fn collect_persistable_library_files(
    root: &Path,
    dir: &Path,
    files: &mut Vec<(String, String, String, String)>,
) -> Result<(), String> {
    for entry in fs::read_dir(dir).map_err(|error| {
        format!(
            "failed to read library directory {}: {error}",
            dir.display()
        )
    })? {
        let entry =
            entry.map_err(|error| format!("failed to read library directory entry: {error}"))?;
        let path = entry.path();
        if path.is_dir() {
            collect_persistable_library_files(root, &path, files)?;
            continue;
        }

        let relative = path
            .strip_prefix(root)
            .map_err(|error| {
                format!(
                    "failed to relativize library path {}: {error}",
                    path.display()
                )
            })?
            .to_string_lossy()
            .replace('\\', "/");
        let Some((source_kind, metadata)) = persistable_library_metadata(&relative) else {
            continue;
        };
        let content = fs::read_to_string(&path)
            .map_err(|error| format!("failed to read library file {}: {error}", path.display()))?;
        files.push((relative, source_kind, metadata, content));
    }

    Ok(())
}

fn persistable_library_metadata(relative: &str) -> Option<(String, String)> {
    match relative {
        "SOUL.md" => Some(("soul".into(), r#"{"source":"agent_computer"}"#.into())),
        "MISSION.md" => Some(("mission".into(), r#"{"source":"agent_computer"}"#.into())),
        path if path.starts_with("skills/") && path.ends_with("/AGENT_APPEND.md") => {
            let skill_name = path
                .trim_start_matches("skills/")
                .trim_end_matches("/AGENT_APPEND.md");
            if skill_name.is_empty() || skill_name.contains('/') {
                None
            } else {
                Some((
                    "skill_append".into(),
                    json!({"source": "agent_computer", "skill_name": skill_name}).to_string(),
                ))
            }
        }
        _ => None,
    }
}

fn run_bun_turn_child(
    dealer: &DealerHandle,
    config: &WorkerConfig,
    turn_start: Value,
    correlation_id: Option<String>,
) -> Result<TurnChildReply, String> {
    let mut child = Command::new("bun")
        .arg(&config.bun_script)
        .current_dir(&config.bun_workdir)
        .env("ANKOLE_WORKSPACE_ROOT", &config.workspace_root)
        .env_remove("ANKOLE_AGENT_COMPUTER_WORKER_PRE_AUTH_TOKEN")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|error| format!("failed to spawn Bun turn child: {error}"))?;

    let mut stdin = child
        .stdin
        .take()
        .ok_or_else(|| "failed to open Bun child stdin".to_string())?;
    let stdout = child
        .stdout
        .take()
        .ok_or_else(|| "failed to open Bun child stdout".to_string())?;
    let stderr = child
        .stderr
        .take()
        .ok_or_else(|| "failed to open Bun child stderr".to_string())?;
    let line_rx = spawn_child_stdout_reader(stdout);
    let stderr_capture = spawn_child_stderr_capture(stderr);
    let mut current_turn = turn_start
        .get("turn")
        .cloned()
        .ok_or_else(|| "turn_start.turn is missing".to_string())?;

    write_child_line(
        &mut stdin,
        json!({
            "type": "turn_start",
            "turn_start": turn_start,
            "correlation_id": correlation_id,
            "workspace_root": config.workspace_root,
        }),
    )?;

    let result = read_child_until_final(
        dealer,
        config,
        &mut child,
        &mut stdin,
        &line_rx,
        &stderr_capture,
        &mut current_turn,
    );
    let _ = child.kill();
    result
}

fn spawn_child_stdout_reader(stdout: ChildStdout) -> mpsc::Receiver<Result<String, String>> {
    let (tx, rx) = mpsc::channel();

    thread::spawn(move || {
        let mut reader = BufReader::new(stdout);

        loop {
            let mut line = String::new();
            match reader.read_line(&mut line) {
                Ok(0) => break,
                Ok(_) => {
                    if tx.send(Ok(line)).is_err() {
                        break;
                    }
                }
                Err(error) => {
                    let _ = tx.send(Err(format!("failed to read Bun child line: {error}")));
                    break;
                }
            }
        }
    });

    rx
}

fn spawn_child_stderr_capture(stderr: ChildStderr) -> Arc<Mutex<String>> {
    let capture = Arc::new(Mutex::new(String::new()));
    let capture_for_thread = Arc::clone(&capture);

    thread::spawn(move || {
        let mut reader = BufReader::new(stderr);

        loop {
            let mut line = String::new();
            match reader.read_line(&mut line) {
                Ok(0) => break,
                Ok(_) => {
                    if let Ok(mut buffer) = capture_for_thread.lock() {
                        buffer.push_str(&line);
                        let keep_from = buffer.len().saturating_sub(12_000);
                        if keep_from > 0 {
                            *buffer = buffer[keep_from..].to_string();
                        }
                    }
                }
                Err(error) => {
                    if let Ok(mut buffer) = capture_for_thread.lock() {
                        buffer.push_str(&format!("failed to read Bun child stderr: {error}\n"));
                    }
                    break;
                }
            }
        }
    });

    capture
}

fn read_child_until_final(
    dealer: &DealerHandle,
    config: &WorkerConfig,
    child: &mut Child,
    stdin: &mut ChildStdin,
    line_rx: &mpsc::Receiver<Result<String, String>>,
    stderr_capture: &Arc<Mutex<String>>,
    current_turn: &mut Value,
) -> Result<TurnChildReply, String> {
    loop {
        match line_rx.recv_timeout(Duration::from_millis(100)) {
            Ok(Ok(line)) => {
                match handle_child_protocol_line(dealer, config, stdin, current_turn, line.trim()) {
                    Ok(Some(reply)) => return Ok(reply),
                    Ok(None) => {}
                    Err(error) => return Err(with_child_stderr(error, stderr_capture)),
                }
            }
            Ok(Err(error)) => return Err(with_child_stderr(error, stderr_capture)),
            Err(mpsc::RecvTimeoutError::Timeout) => {}
            Err(mpsc::RecvTimeoutError::Disconnected) => {
                let status = child
                    .try_wait()
                    .map_err(|error| format!("failed to inspect Bun child: {error}"))?;
                return Err(with_child_stderr(
                    format!("Bun turn child exited before final response: {status:?}"),
                    stderr_capture,
                ));
            }
        }

        match dealer
            .recv(Duration::from_millis(10))
            .map_err(|error| error.to_string())?
        {
            Some(DealerEvent::Received(payload)) => {
                let envelope =
                    actor_bus::decode_envelope_json(&payload).map_err(|error| error.to_string())?;
                handle_dealer_event_during_turn(dealer, config, stdin, current_turn, envelope)?;
            }
            Some(DealerEvent::DecodeFailed(reason)) | Some(DealerEvent::SocketError(reason)) => {
                return Err(reason);
            }
            None => {}
        }
    }
}

fn with_child_stderr(error: String, stderr_capture: &Arc<Mutex<String>>) -> String {
    let stderr = stderr_capture
        .lock()
        .ok()
        .map(|buffer| buffer.trim().to_string())
        .unwrap_or_default();

    if stderr.is_empty() {
        error
    } else {
        format!("{error}; bun stderr: {stderr}")
    }
}

fn handle_child_protocol_line(
    dealer: &DealerHandle,
    config: &WorkerConfig,
    stdin: &mut ChildStdin,
    current_turn: &mut Value,
    line: &str,
) -> Result<Option<TurnChildReply>, String> {
    if line.is_empty() {
        return Ok(None);
    }

    let event: Value = serde_json::from_str(line)
        .map_err(|error| format!("invalid Bun child protocol line: {error}: {line}"))?;

    match event.get("type").and_then(Value::as_str) {
        Some("credential_request") => {
            let request = event
                .get("request")
                .cloned()
                .ok_or_else(|| "credential_request missing request".to_string())?;
            let response = request_credential(dealer, config, stdin, current_turn, request)?;
            write_child_line(
                stdin,
                json!({
                    "type": "credential_response",
                    "response": response,
                }),
            )?;
            Ok(None)
        }
        Some("final") => {
            let turn = event
                .get("turn")
                .cloned()
                .unwrap_or_else(|| current_turn.clone());
            *current_turn = turn.clone();
            Ok(Some(TurnChildReply {
                proposal: child_final_proposal(&event),
                turn,
            }))
        }
        Some("error") => Err(event
            .get("error")
            .and_then(Value::as_str)
            .unwrap_or("Bun child failed")
            .to_string()),
        other => Err(format!("unexpected Bun child protocol event: {other:?}")),
    }
}

fn request_credential(
    dealer: &DealerHandle,
    config: &WorkerConfig,
    stdin: &mut ChildStdin,
    current_turn: &mut Value,
    request: Value,
) -> Result<Value, String> {
    let request_id = request
        .get("request_id")
        .and_then(Value::as_str)
        .ok_or_else(|| "credential request missing request_id".to_string())?
        .to_string();

    dealer
        .send_envelope(credential_request_envelope(&request))
        .map_err(|error| error.to_string())?;

    let deadline = Instant::now() + CREDENTIAL_TIMEOUT;
    while Instant::now() < deadline {
        match dealer
            .recv(Duration::from_millis(500))
            .map_err(|error| error.to_string())?
        {
            Some(DealerEvent::Received(payload)) => {
                let envelope =
                    actor_bus::decode_envelope_json(&payload).map_err(|error| error.to_string())?;
                if envelope.get("correlation_id").and_then(Value::as_str) != Some(&request_id) {
                    handle_dealer_event_during_turn(dealer, config, stdin, current_turn, envelope)?;
                    continue;
                }

                match envelope.pointer("/body/type").and_then(Value::as_str) {
                    Some("llm_provider_credential_response") => {
                        return envelope
                            .pointer("/body/llm_provider_credential_response")
                            .cloned()
                            .ok_or_else(|| "credential response body missing".to_string());
                    }
                    Some("llm_provider_credential_rejected") => {
                        return envelope
                            .pointer("/body/llm_provider_credential_rejected")
                            .cloned()
                            .ok_or_else(|| "credential rejected body missing".to_string());
                    }
                    _ => {}
                }
            }
            Some(DealerEvent::DecodeFailed(reason)) | Some(DealerEvent::SocketError(reason)) => {
                return Err(reason);
            }
            None => {}
        }
    }

    Err(format!(
        "timed out waiting for credential response {request_id}"
    ))
}

fn handle_dealer_event_during_turn(
    dealer: &DealerHandle,
    config: &WorkerConfig,
    stdin: &mut ChildStdin,
    current_turn: &mut Value,
    envelope: Value,
) -> Result<(), String> {
    match envelope.pointer("/body/type").and_then(Value::as_str) {
        Some("mailbox_updated") => {
            let mailbox = envelope
                .pointer("/body/mailbox_updated")
                .ok_or_else(|| "mailbox_updated body missing".to_string())?;

            if !mailbox_matches_turn(mailbox, current_turn) {
                return Ok(());
            }

            if let Some((turn, inputs)) = pending_steer_update(&config.database_url, current_turn)?
            {
                let input_ids = inputs
                    .iter()
                    .filter_map(|input| input.get("actor_input_id").and_then(Value::as_str))
                    .map(Value::from)
                    .collect::<Vec<_>>();

                dealer
                    .send_envelope(turn_accepted_envelope(&turn, input_ids, None))
                    .map_err(|error| error.to_string())?;

                write_child_line(
                    stdin,
                    json!({
                        "type": "steer",
                        "turn": turn,
                        "inputs": inputs,
                    }),
                )?;
                *current_turn = turn;
            }
        }
        Some("control_shutdown") => return Err("control requested worker shutdown".into()),
        _ => {}
    }

    Ok(())
}

fn mailbox_matches_turn(mailbox: &Value, current_turn: &Value) -> bool {
    mailbox.pointer("/actor/agent_uid").and_then(Value::as_str)
        == current_turn
            .pointer("/actor/agent_uid")
            .and_then(Value::as_str)
        && mailbox.pointer("/actor/session_id").and_then(Value::as_str)
            == current_turn
                .pointer("/actor/session_id")
                .and_then(Value::as_str)
        && mailbox.get("activation_uid").and_then(Value::as_str)
            == current_turn.get("activation_uid").and_then(Value::as_str)
        && mailbox.get("actor_epoch").and_then(Value::as_u64)
            == current_turn.get("actor_epoch").and_then(Value::as_u64)
        && mailbox.get("reason").and_then(Value::as_str) == Some("command.steer")
}

fn pending_steer_update(
    database_url: &str,
    current_turn: &Value,
) -> Result<Option<(Value, Vec<Value>)>, String> {
    let llm_turn_id = current_turn
        .get("llm_turn_id")
        .and_then(Value::as_str)
        .ok_or_else(|| "current turn missing llm_turn_id".to_string())?;

    let mut client = Client::connect(database_url, NoTls)
        .map_err(|error| format!("failed to connect database for steer update: {error}"))?;

    let rows = client
        .query(
            r#"
            select
              input.id::text,
              input.broker_sequence,
              input.type,
              input.ingress_event_id,
              input.provider_entry_id,
              input.payload::text,
              delivery.revision
            from actor_input_deliveries delivery
            join actor_inputs input on input.id = delivery.actor_input_id
            where delivery.llm_turn_id = $1
              and delivery.state = 'sent'
              and input.input_state = 'open'
              and input.type = 'command.steer'
            order by input.broker_sequence asc
            "#,
            &[&llm_turn_id],
        )
        .map_err(|error| format!("failed to read pending steer input: {error}"))?;

    if rows.is_empty() {
        return Ok(None);
    }

    let mut max_revision = current_turn
        .get("revision")
        .and_then(Value::as_u64)
        .unwrap_or_default();
    let mut inputs = Vec::new();

    for row in rows {
        let actor_input_id: String = row.get(0);
        let broker_sequence: i64 = row.get(1);
        let input_type: String = row.get(2);
        let ingress_event_id: String = row.get(3);
        let provider_entry_id: Option<String> = row.get(4);
        let payload_text: String = row.get(5);
        let revision_i32: i32 = row.get(6);
        let revision = revision_i32.max(0) as u64;
        max_revision = max_revision.max(revision);

        let mut input = json!({
            "actor_input_id": actor_input_id,
            "broker_sequence": broker_sequence,
            "type": input_type,
            "ingress_event_id": ingress_event_id,
            "payload_json": serde_json::from_str::<Value>(&payload_text).unwrap_or_else(|_| json!({})),
        });

        if let (Some(provider_entry_id), Some(object)) = (provider_entry_id, input.as_object_mut())
        {
            object.insert("provider_entry_id".into(), Value::String(provider_entry_id));
        }

        inputs.push(input);
    }

    let mut turn = current_turn.clone();
    if let Some(object) = turn.as_object_mut() {
        object.insert("revision".into(), Value::from(max_revision));
    }

    Ok(Some((turn, inputs)))
}

fn write_child_line(stdin: &mut ChildStdin, value: Value) -> Result<(), String> {
    writeln!(stdin, "{value}")
        .map_err(|error| format!("failed to write Bun child line: {error}"))?;
    stdin
        .flush()
        .map_err(|error| format!("failed to flush Bun child line: {error}"))
}

fn worker_ready_envelope(config: &WorkerConfig) -> Value {
    json!({
        "protocol_version": 1,
        "message_id": format!("worker-ready-{}", Uuid::new_v4()),
        "lane": "LANE_CONTROL",
        "durability": "CONTROL_EPHEMERAL",
        "body": {
            "type": "worker_ready",
            "worker_ready": {
                "worker_id": config.worker_id,
                "worker_instance_id": config.worker_instance_id,
                "runtime": "rust-daemon+bun",
                "version": "0.1.0",
                "capacity_json": {"available_turn_slots": 1}
            }
        }
    })
}

fn worker_capacity_envelope(config: &WorkerConfig) -> Value {
    json!({
        "protocol_version": 1,
        "message_id": format!("worker-capacity-{}", Uuid::new_v4()),
        "lane": "LANE_CONTROL",
        "durability": "CONTROL_EPHEMERAL",
        "body": {
            "type": "worker_capacity",
            "worker_capacity": {
                "worker_id": config.worker_id,
                "worker_instance_id": config.worker_instance_id,
                "available_turn_slots": 1,
                "capacity_json": {"available_turn_slots": 1},
                "load_json": {"active_turns": 0}
            }
        }
    })
}

fn worker_heartbeat_envelope(config: &WorkerConfig) -> Value {
    json!({
        "protocol_version": 1,
        "message_id": format!("worker-heartbeat-{}", Uuid::new_v4()),
        "lane": "LANE_CONTROL",
        "durability": "CONTROL_EPHEMERAL",
        "body": {
            "type": "worker_heartbeat",
            "worker_heartbeat": {
                "worker_id": config.worker_id,
                "worker_instance_id": config.worker_instance_id,
                "monotonic_ms": 0,
                "load_json": {"active_turns": 0}
            }
        }
    })
}

fn turn_accepted_envelope(
    turn: &Value,
    input_ids: Vec<Value>,
    correlation_id: Option<&str>,
) -> Value {
    maybe_with_correlation(
        json!({
            "protocol_version": 1,
            "message_id": format!("turn-accepted-{}", Uuid::new_v4()),
            "lane": "LANE_TURN",
            "durability": "CONTROL_REPLAYABLE",
            "body": {
                "type": "turn_accepted",
                "turn_accepted": {
                    "turn": turn,
                    "accepted_actor_input_ids": input_ids
                }
            }
        }),
        correlation_id,
    )
}

fn child_final_proposal(event: &Value) -> Value {
    event.get("proposal").cloned().unwrap_or_else(|| {
        visible_reply_proposal(event.get("text").and_then(Value::as_str).unwrap_or("Done."))
    })
}

fn visible_reply_proposal(text: &str) -> Value {
    json!({
        "messages": [{
            "role": "assistant",
            "content_json": [{"type": "text", "text": text}],
            "metadata_json": {"placeholder": true}
        }],
        "reply": {
            "text": text,
            "content_json": [{"type": "text", "text": text}]
        }
    })
}

fn final_proposal_envelope(turn: &Value, proposal: &Value, correlation_id: Option<&str>) -> Value {
    let mut turn_final_proposal = json!({
        "turn": turn,
        "messages": proposal.get("messages").cloned().unwrap_or_else(|| json!([]))
    });

    if let Some(reply) = proposal.get("reply").filter(|reply| !reply.is_null()) {
        if let Some(object) = turn_final_proposal.as_object_mut() {
            object.insert("reply".into(), reply.clone());
        }
    }

    maybe_with_correlation(
        json!({
            "protocol_version": 1,
            "message_id": format!("turn-final-{}", Uuid::new_v4()),
            "lane": "LANE_TURN",
            "durability": "CONTROL_DURABLE",
            "body": {
                "type": "turn_final_proposal",
                "turn_final_proposal": turn_final_proposal
            }
        }),
        correlation_id,
    )
}

fn credential_request_envelope(request: &Value) -> Value {
    let request_id = request
        .get("request_id")
        .and_then(Value::as_str)
        .unwrap_or("llm-credential-missing-request-id");

    json!({
        "protocol_version": 1,
        "message_id": request_id,
        "correlation_id": request_id,
        "lane": "LANE_RPC",
        "durability": "CONTROL_EPHEMERAL",
        "body": {
            "type": "llm_provider_credential_request",
            "llm_provider_credential_request": request
        }
    })
}

fn maybe_with_correlation(mut envelope: Value, correlation_id: Option<&str>) -> Value {
    if let (Some(correlation_id), Some(object)) = (correlation_id, envelope.as_object_mut()) {
        object.insert(
            "correlation_id".to_string(),
            Value::String(correlation_id.to_string()),
        );
    }

    envelope
}

#[cfg(test)]
mod tests {
    use std::path::Path;

    use super::*;

    #[test]
    fn present_skill_append_paths_ignores_non_append_entries() {
        let files = vec![
            (
                "SOUL.md".to_string(),
                "soul".to_string(),
                "{}".to_string(),
                "soul".to_string(),
            ),
            (
                "skills/nano-pdf/AGENT_APPEND.md".to_string(),
                "skill_append".to_string(),
                "{}".to_string(),
                "append".to_string(),
            ),
        ];

        let paths = present_skill_append_paths(&files);

        assert!(paths.contains("skills/nano-pdf/AGENT_APPEND.md"));
        assert!(!paths.contains("SOUL.md"));
    }

    #[test]
    fn safe_library_path_rejects_escape_segments() {
        let root = Path::new("/workspace/library-containers");

        assert!(safe_library_path(root, "skills/nano-pdf/SKILL.md").is_ok());
        assert!(safe_library_path(root, "skills/nano-pdf/../SOUL.md").is_err());
        assert!(safe_library_path(root, "../SOUL.md").is_err());
    }
}
