//! Safe command discovery and confined headless batch execution for Agents and editors.

use std::collections::HashSet;
use std::sync::Arc;
#[cfg(not(target_arch = "wasm32"))]
use std::sync::atomic::{AtomicU64, Ordering};

use deckcraft_engine::{DocState, Session, command_specs};
use deckcraft_model::MediaId;
use serde::Deserialize;
use serde_json::{Value, json};

use crate::derive::derive;
use crate::rebase::{stamp_changeset_comments, stamp_presentation_comments};
use crate::{ChangeSet, Error, MAX_PICTURE_BYTES, PresentationDoc};

/// Command prefixes blocked from Agent and browser execution because they touch host files,
/// application lifecycle, auto-recovery folders, or unmodelled external state.
const BLOCKED_PREFIXES: &[&str] = &[
    "file.",
    "export.",
    "import.",
    "print.",
    "app.",
    "window.",
    "recovery.",
    "macro.",
];

/// Individual commands blocked in addition to [`BLOCKED_PREFIXES`].
const BLOCKED_EXACT: &[&str] = &[
    // Writes directly to the host user spelling dictionary outside `deckcraft_engine::io`.
    "review.addToDictionary",
    // Exposes host dictionary folder paths.
    "review.dictionary",
    // Mutates the process-wide font database or scans host system font directories.
    "font.add",
    "font.rescan",
];

/// Reports whether `command_id` is forbidden in Ankole's sandboxed presentation sessions.
#[must_use]
pub(crate) fn is_blocked_command(command_id: &str) -> bool {
    let trimmed = command_id.trim();
    if trimmed.is_empty() {
        return true;
    }
    BLOCKED_PREFIXES
        .iter()
        .any(|prefix| trimmed.starts_with(prefix))
        || BLOCKED_EXACT.contains(&trimmed)
}

/// Lists safe DeckCraft commands available to Agents and the browser command palette, filtered by
/// an optional case-insensitive substring `query`.
#[must_use]
pub fn commands(query: Option<&str>) -> Value {
    let needle = query
        .map(str::trim)
        .filter(|q| !q.is_empty())
        .map(str::to_lowercase);

    let items: Vec<Value> = command_specs()
        .iter()
        .filter(|spec| !is_blocked_command(spec.id))
        .filter(|spec| {
            let Some(ref q) = needle else {
                return true;
            };
            spec.id.to_lowercase().contains(q)
                || spec.label.to_lowercase().contains(q)
                || spec.params.to_lowercase().contains(q)
                || spec
                    .menu
                    .iter()
                    .any(|segment| segment.to_lowercase().contains(q))
        })
        .map(|spec| {
            json!({
                "id": spec.id,
                "label": spec.label,
                "menu": spec.menu,
                "shortcut": spec.shortcut,
                "params": spec.params,
            })
        })
        .collect();

    Value::Array(items)
}

#[derive(Deserialize)]
struct RawCommandCall {
    #[serde(default)]
    command: Option<String>,
    #[serde(default)]
    id: Option<String>,
    #[serde(default = "empty_object")]
    params: Value,
}

fn empty_object() -> Value {
    Value::Object(serde_json::Map::new())
}

/// Executes a non-empty JSON array of DeckCraft commands atomically on a headless [`Session`]
/// confined away from the host filesystem, stamps new comments with `actor_name`, and derives the
/// resulting canonical [`ChangeSet`].
///
/// # Errors
///
/// Returns [`Error::Invalid`] if `commands_json` is empty or malformed, if any command is blocked
/// or fails during execution, or if a command adds media exceeding [`MAX_PICTURE_BYTES`].
pub fn apply_commands(
    doc: &PresentationDoc,
    commands_json: &str,
    actor_name: &str,
) -> Result<(PresentationDoc, Option<ChangeSet>, Vec<Value>), Error> {
    let raw_calls: Vec<RawCommandCall> = serde_json::from_str(commands_json)
        .map_err(|err| Error::Invalid(format!("commands_json must be a JSON array: {err}")))?;
    if raw_calls.is_empty() {
        return Err(Error::Invalid(
            "commands_json must contain at least one command".into(),
        ));
    }

    let mut calls = Vec::with_capacity(raw_calls.len());
    for raw in raw_calls {
        let cmd_id = raw
            .command
            .or(raw.id)
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty())
            .ok_or_else(|| {
                Error::Invalid(
                    "each command entry must specify a non-empty `command` or `id`".into(),
                )
            })?;
        if is_blocked_command(&cmd_id) {
            return Err(Error::Invalid(format!(
                "command `{cmd_id}` is not permitted"
            )));
        }
        let params = if raw.params.is_null() {
            empty_object()
        } else {
            raw.params
        };
        calls.push((cmd_id, params));
    }

    let before_pres = doc.presentation();
    let existing_media_ids: HashSet<MediaId> = before_pres.media.iter().map(|m| m.id).collect();

    crate::ensure_isolated_fonts();
    let mut session = Session::new();
    session.prefs.author = actor_name.to_string();
    session.add_document(DocState::new(
        before_pres.clone(),
        None,
        before_pres.props.title.clone(),
    ));

    let results = run_confined(|| {
        let mut out = Vec::with_capacity(calls.len());
        for (cmd_id, params) in &calls {
            let res = session
                .execute(cmd_id, params)
                .map_err(|err| Error::Invalid(format!("command `{cmd_id}` failed: {err}")))?;
            out.push(res);
        }
        Ok(out)
    })?;

    let st = session
        .active()
        .ok_or_else(|| Error::Invalid("headless session closed active document".into()))?;
    let mut after_pres = (*st.doc).clone();

    for item in &after_pres.media {
        if (!existing_media_ids.contains(&item.id)
            || before_pres
                .media(item.id)
                .is_some_and(|old| !Arc::ptr_eq(&old.data, &item.data) && *old.data != *item.data))
            && item.data.len() > MAX_PICTURE_BYTES
        {
            return Err(Error::Invalid(format!(
                "media item {} ({} bytes) exceeds maximum {} bytes",
                item.id.0,
                item.data.len(),
                MAX_PICTURE_BYTES
            )));
        }
    }

    stamp_presentation_comments(before_pres, &mut after_pres, actor_name);
    after_pres.fix_next_id();

    let next_doc =
        PresentationDoc::from_parts(Arc::new(after_pres), Arc::clone(doc.warnings_arc()));
    let mut changeset = derive(doc, &next_doc)?;
    if let Some(ref mut cs) = changeset {
        stamp_changeset_comments(before_pres, cs, actor_name);
    }

    Ok((next_doc, changeset, results))
}

#[cfg(not(target_arch = "wasm32"))]
fn run_confined<T>(f: impl FnOnce() -> Result<T, Error>) -> Result<T, Error> {
    static COUNTER: AtomicU64 = AtomicU64::new(0);

    struct EmptyTempDir(std::path::PathBuf);
    impl Drop for EmptyTempDir {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    let seq = COUNTER.fetch_add(1, Ordering::Relaxed);
    let dir_path =
        std::env::temp_dir().join(format!("ankole-pres-confine-{}-{seq}", std::process::id()));
    std::fs::create_dir_all(&dir_path).map_err(|err| {
        Error::Invalid(format!(
            "failed to create empty confinement directory: {err}"
        ))
    })?;
    let guard = EmptyTempDir(dir_path);

    let roots =
        deckcraft_engine::file_access::AutomationRoots::new(std::slice::from_ref(&guard.0), &[])
            .map_err(|err| {
                Error::Invalid(format!("failed to configure file confinement: {err}"))
            })?;

    deckcraft_engine::file_access::confine(roots.as_ref(), f)
}

#[cfg(target_arch = "wasm32")]
fn run_confined<T>(f: impl FnOnce() -> Result<T, Error>) -> Result<T, Error> {
    f()
}
