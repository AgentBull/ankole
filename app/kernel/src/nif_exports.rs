//! These functions validate BEAM terms, keep values binary-safe, and forward behavior to host-neutral modules.

use rustler::env::{OwnedEnv, SavedTerm};
use rustler::types::atom as rustler_atom;
use rustler::types::binary::{Binary, OwnedBinary};
use rustler::{Encoder, Env, Error, LocalPid, Monitor, NifResult as NIFResult, ResourceArc, Term};
use serde_json::Value as JSONValue;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, Once};

mod object_store;
mod vfs;

use ankole_presentation::PresentationDoc;
use ankole_spreadsheet::SpreadsheetDoc;
use ankole_word::WordDoc;

use crate::authz;
use crate::brain_chunker;
use crate::common;
use crate::signals;
use crate::universal_ai_client;

mod atoms {
    rustler::atoms! {
        ok,
        universal_ai_client,
        universal_ai_client_request,
        object_store,
        ready,
        chunk,
        provider,
        client,
        done,
        error,
        aborted,
        metadata,
        private,
        public,
        invalid,
        busy,
        conflict,
        target_deleted,
        overlapping_structural_edit,
        sheet_deleted,
        concurrent_sort_or_merge,
        block_changed,
        slide_changed,
        slide_deleted,
        slides_reordered,
        container_deleted,
        container_changed,
        field_changed,
        identifier_taken,
        concurrent_revision,
        unbalanced_markers,
        document_too_large,
        skipped,
        failed,
        text,
        document,
        unsupported,
    }
}

/// Lives across BEAM demand calls.
pub struct UniversalAIClientStreamResource(pub universal_ai_client::StreamHandle);

#[rustler::resource_impl]
impl rustler::Resource for UniversalAIClientStreamResource {
    const IMPLEMENTS_DESTRUCTOR: bool = true;
    const IMPLEMENTS_DOWN: bool = true;

    fn destructor(self, _env: Env<'_>) {
        let _ = self.0.cancel();
    }

    fn down<'a>(&'a self, _env: Env<'a>, _pid: LocalPid, _monitor: Monitor) {
        let _ = self.0.cancel();
    }
}

/// Retained by the completion sink until the native request ends. The monitor
/// cancels its I/O if the BEAM owner exits while waiting for a provider.
pub struct UniversalAIClientRequestResource {
    handle: Mutex<Option<universal_ai_client::RequestHandle>>,
    cancelled: AtomicBool,
}

impl UniversalAIClientRequestResource {
    fn new() -> Self {
        Self {
            handle: Mutex::new(None),
            cancelled: AtomicBool::new(false),
        }
    }

    fn install(&self, handle: universal_ai_client::RequestHandle) {
        let mut current = self
            .handle
            .lock()
            .unwrap_or_else(|error| error.into_inner());
        if self.cancelled.load(Ordering::SeqCst) {
            handle.cancel();
        }
        *current = Some(handle);
    }

    fn cancel(&self) {
        self.cancelled.store(true, Ordering::SeqCst);
        if let Some(handle) = self
            .handle
            .lock()
            .unwrap_or_else(|error| error.into_inner())
            .as_ref()
        {
            handle.cancel();
        }
    }
}

#[rustler::resource_impl]
impl rustler::Resource for UniversalAIClientRequestResource {
    const IMPLEMENTS_DESTRUCTOR: bool = true;
    const IMPLEMENTS_DOWN: bool = true;

    fn destructor(self, _env: Env<'_>) {
        self.cancel();
    }

    fn down<'a>(&'a self, _env: Env<'a>, _pid: LocalPid, _monitor: Monitor) {
        self.cancel();
    }
}

/// One immutable Office document version held by the kernel. Applying an operation returns a new
/// resource, so concurrent readers of an earlier version never need a lock.
pub enum OfficeDocResource {
    Spreadsheet(Box<SpreadsheetDoc>),
    Word(WordDoc),
    Presentation(PresentationDoc),
}

#[rustler::resource_impl]
impl rustler::Resource for OfficeDocResource {}

/// Holds the Elixir stream ref in an owned environment so Rust-owned async tasks
/// can tag messages without keeping a BEAM scheduler thread occupied.
struct BeamStreamRef {
    env: OwnedEnv,
    term: SavedTerm,
}

impl BeamStreamRef {
    fn new(term: Term<'_>) -> Self {
        let env = OwnedEnv::new();
        Self {
            term: env.save(term),
            env,
        }
    }
}

impl Encoder for BeamStreamRef {
    fn encode<'a>(&self, dest: Env<'a>) -> Term<'a> {
        self.env.run(|env| self.term.load(env).in_env(dest))
    }
}

#[rustler::nif(schedule = "DirtyCpu")]
pub fn aead_decrypt(ciphertext: Term<'_>, key: Term<'_>) -> NIFResult<OwnedBinary> {
    let ciphertext = decode_string(ciphertext, "ciphertext")?;
    let key = decode_string(key, "key")?;

    common::aead_decrypt(&ciphertext, &key)
        .map_err(error)
        .and_then(binary_from_vec)
}

/// Uses the shared AEAD token format.
#[rustler::nif(schedule = "DirtyCpu")]
pub fn aead_encrypt(plaintext: Term<'_>, key: Term<'_>) -> NIFResult<String> {
    let plaintext = decode_binary(plaintext, "plaintext")?;
    let key = decode_string(key, "key")?;

    common::aead_encrypt(plaintext.as_slice(), &key).map_err(error)
}

#[rustler::nif(schedule = "DirtyCpu")]
pub fn normalize_model_image_nif(bytes: Term<'_>) -> NIFResult<OwnedBinary> {
    let bytes = decode_binary(bytes, "image")?;
    crate::model_image::normalize(bytes.as_slice())
        .map_err(error)
        .and_then(binary_from_vec)
}

#[rustler::nif(schedule = "DirtyCpu")]
pub fn knowledge_parse_nif(source: Term<'_>) -> NIFResult<String> {
    let source = decode_string(source, "source")?;
    let page = stacker::grow(8 * 1024 * 1024, || {
        crate::page_document::knowledge::parse(&source)
    })
    .map_err(error_message)?;
    serde_json::to_string(&page).map_err(|error| error_message(error.to_string()))
}

#[rustler::nif(schedule = "DirtyCpu")]
pub fn knowledge_validate_nif(source: Term<'_>) -> NIFResult<(String, String)> {
    let source = decode_string(source, "source")?;
    let page = stacker::grow(8 * 1024 * 1024, || {
        crate::page_document::knowledge::validate(&source)
    })
    .map_err(error_message)?;
    Ok((page.xml, page.plain_text))
}

#[rustler::nif(schedule = "DirtyCpu")]
pub fn knowledge_export_nif(source: Term<'_>, metadata: Term<'_>) -> NIFResult<String> {
    let source = decode_string(source, "source")?;
    let metadata = decode_string(metadata, "metadata")?;
    let metadata =
        serde_json::from_str(&metadata).map_err(|error| error_message(error.to_string()))?;
    stacker::grow(8 * 1024 * 1024, || {
        crate::page_document::knowledge::export(&source, &metadata)
    })
    .map_err(error_message)
}

#[rustler::nif(schedule = "DirtyCpu")]
pub fn knowledge_overview_nif(source: Term<'_>, metadata: Term<'_>) -> NIFResult<String> {
    let source = decode_string(source, "source")?;
    let metadata = decode_string(metadata, "metadata")?;
    let metadata =
        serde_json::from_str(&metadata).map_err(|error| error_message(error.to_string()))?;
    stacker::grow(8 * 1024 * 1024, || {
        crate::page_document::knowledge::overview(&source, &metadata)
    })
    .map_err(error_message)
}

#[rustler::nif(schedule = "DirtyCpu")]
pub fn page_validate_nif(source: Term<'_>) -> NIFResult<(String, String)> {
    let source = decode_string(source, "source")?;
    // Page normalization is recursive up to the editor's declared depth limit.
    let page = stacker::grow(8 * 1024 * 1024, || crate::page_document::validate(&source))
        .map_err(error_message)?;
    Ok((page.xml, page.plain_text))
}

type PageSectionTuple = (u8, String, usize);

#[rustler::nif(schedule = "DirtyCpu")]
pub fn page_sections_nif(source: Term<'_>) -> NIFResult<(String, Vec<PageSectionTuple>)> {
    let source = decode_string(source, "source")?;
    let parsed = stacker::grow(8 * 1024 * 1024, || crate::page_document::sections(&source))
        .map_err(error_message)?;
    let sections = parsed
        .sections
        .into_iter()
        .map(|sec| (sec.level, sec.heading, sec.start_byte))
        .collect();
    Ok((parsed.plain_text, sections))
}

#[rustler::nif(schedule = "DirtyCpu")]
pub fn page_rename_principal_nif(
    source: Term<'_>,
    old: Term<'_>,
    new: Term<'_>,
) -> NIFResult<(String, String)> {
    let source = decode_string(source, "source")?;
    let old = decode_string(old, "old")?;
    let new = decode_string(new, "new")?;
    let page = stacker::grow(8 * 1024 * 1024, || {
        crate::page_document::rename_principal(&source, &old, &new)
    })
    .map_err(error_message)?;
    Ok((page.xml, page.plain_text))
}

#[rustler::nif(schedule = "DirtyCpu")]
pub fn page_apply_nif(source: Term<'_>, changes: Term<'_>) -> NIFResult<(String, String)> {
    let source = decode_string(source, "source")?;
    let changes = decode_string(changes, "changes")?;
    let page = stacker::grow(8 * 1024 * 1024, || {
        crate::page_document::apply(&source, &changes)
    })
    .map_err(error_message)?;
    Ok((page.xml, page.plain_text))
}

#[rustler::nif(schedule = "DirtyCpu")]
pub fn page_diff_nif(old: Term<'_>, new: Term<'_>) -> NIFResult<String> {
    let old = decode_string(old, "old")?;
    let new = decode_string(new, "new")?;
    stacker::grow(8 * 1024 * 1024, || crate::page_document::diff(&old, &new))
        .map(|changes| changes.to_string())
        .map_err(error_message)
}

#[rustler::nif(schedule = "DirtyCpu")]
pub fn page_identity_changes_nif(source: Term<'_>) -> NIFResult<String> {
    let source = decode_string(source, "source")?;
    stacker::grow(8 * 1024 * 1024, || {
        crate::page_document::identity_changes(&source)
    })
    .map_err(error_message)
}

#[rustler::nif(schedule = "DirtyCpu")]
pub fn page_comment_info_nif(source: Term<'_>) -> NIFResult<String> {
    let source = decode_string(source, "source")?;
    stacker::grow(8 * 1024 * 1024, || {
        crate::page_document::comment_info(&source)
    })
    .map(|info| info.to_string())
    .map_err(error_message)
}

#[rustler::nif(schedule = "DirtyCpu")]
pub fn page_comment_annotate_nif(
    source: Term<'_>,
    id: Term<'_>,
    from: usize,
    to: usize,
) -> NIFResult<(String, String, String)> {
    let source = decode_string(source, "source")?;
    let id = decode_string(id, "id")?;
    let page = stacker::grow(8 * 1024 * 1024, || {
        crate::page_document::annotate_comment(&source, &id, from, to)
    })
    .map_err(error_message)?;
    Ok((page.xml, page.plain_text, page.quote))
}

#[rustler::nif(schedule = "DirtyCpu")]
pub fn page_comment_remove_nif(source: Term<'_>, id: Term<'_>) -> NIFResult<(String, String)> {
    let source = decode_string(source, "source")?;
    let id = decode_string(id, "id")?;
    let page = stacker::grow(8 * 1024 * 1024, || {
        crate::page_document::remove_comment(&source, &id)
    })
    .map_err(error_message)?;
    Ok((page.xml, page.plain_text))
}

#[rustler::nif(schedule = "DirtyCpu")]
pub fn page_restore_comments_nif(
    current: Term<'_>,
    target: Term<'_>,
) -> NIFResult<(String, String)> {
    let current = decode_string(current, "current")?;
    let target = decode_string(target, "target")?;
    let page = stacker::grow(8 * 1024 * 1024, || {
        crate::page_document::restore_comments(&current, &target)
    })
    .map_err(error_message)?;
    Ok((page.xml, page.plain_text))
}

static WORD_SITE_FONTS_ONCE: Once = Once::new();
static PRESENTATION_SITE_FONTS_ONCE: Once = Once::new();

fn read_site_font_blobs(dir: &str) -> Vec<Vec<u8>> {
    let mut blobs = Vec::new();
    if !dir.is_empty()
        && let Ok(entries) = std::fs::read_dir(dir)
    {
        let mut paths: Vec<std::path::PathBuf> = entries
            .filter_map(Result::ok)
            .map(|entry| entry.path())
            .filter(|path| {
                path.extension()
                    .and_then(|ext| ext.to_str())
                    .is_some_and(|ext| {
                        matches!(ext.to_ascii_lowercase().as_str(), "ttf" | "otf" | "ttc")
                    })
            })
            .collect();
        paths.sort();
        for path in paths {
            if let Ok(bytes) = std::fs::read(&path)
                && !bytes.is_empty()
            {
                blobs.push(bytes);
            }
        }
    }
    blobs
}

fn ensure_word_site_fonts(fonts_dir: &str) {
    WORD_SITE_FONTS_ONCE.call_once(|| {
        let blobs = read_site_font_blobs(fonts_dir);
        ankole_word::init_site_fonts(&blobs);
    });
}

fn ensure_presentation_site_fonts(fonts_dir: &str) {
    PRESENTATION_SITE_FONTS_ONCE.call_once(|| {
        let blobs = read_site_font_blobs(fonts_dir);
        ankole_presentation::init_site_fonts(&blobs);
    });
}

// Formula parsing, OOXML reading, and page/slide layout recurse deeper than BEAM's default dirty
// CPU thread stack.
fn with_office_stack<R>(call: impl FnOnce() -> R) -> R {
    stacker::grow(8 * 1024 * 1024, call)
}

/// Returns `{doc_ref, bytes, plain_text | nil, metadata_json | nil}` for a blank Office document.
#[rustler::nif(schedule = "DirtyCpu")]
pub fn office_create_blank_nif<'a>(
    env: Env<'a>,
    format: Term<'a>,
    title: Term<'a>,
) -> NIFResult<Term<'a>> {
    let format = decode_string(format, "format")?;
    let title = decode_string(title, "title")?;
    match format.as_str() {
        "spreadsheet" => {
            let (doc, exported) = with_office_stack(|| ankole_spreadsheet::create_blank(&title))
                .map_err(office_display_error)?;
            let metadata = encode_serialized(&exported.metadata)?;
            Ok((
                ResourceArc::new(OfficeDocResource::Spreadsheet(Box::new(doc))),
                binary_term(env, exported.xlsx),
                Some(exported.plain_text),
                Some(metadata),
            )
                .encode(env))
        }
        "word" => {
            let (doc, bytes) = with_office_stack(|| ankole_word::create_blank(&title))
                .map_err(office_display_error)?;
            Ok((
                ResourceArc::new(OfficeDocResource::Word(doc)),
                binary_term(env, bytes),
                Option::<String>::None,
                Option::<String>::None,
            )
                .encode(env))
        }
        "presentation" => {
            let (doc, bytes) = with_office_stack(|| ankole_presentation::create_blank(&title))
                .map_err(office_display_error)?;
            Ok((
                ResourceArc::new(OfficeDocResource::Presentation(doc)),
                binary_term(env, bytes),
                Option::<String>::None,
                Option::<String>::None,
            )
                .encode(env))
        }
        other => Err(error_message(format!("unsupported office format: {other}"))),
    }
}

/// Opens Office file `bytes`, applies an optional compaction `checkpoint`, replays `tail_ops`, and
/// returns `{doc_ref, plain_text | nil, metadata_json | nil}` or `{:busy, reason}` when an
/// operation carries a newer `model_version`.
#[rustler::nif(schedule = "DirtyCpu")]
pub fn office_open_nif<'a>(
    env: Env<'a>,
    format: Term<'a>,
    bytes: Term<'a>,
    tail_ops: Term<'a>,
    checkpoint: Term<'a>,
) -> NIFResult<Term<'a>> {
    let format = decode_string(format, "format")?;
    let bytes = decode_binary(bytes, "bytes")?;
    let tail_ops = decode_string(tail_ops, "tail_ops")?;
    let checkpoint = decode_optional_string(checkpoint, "checkpoint")?;
    match format.as_str() {
        "spreadsheet" => {
            let doc = with_office_stack(|| ankole_spreadsheet::open(bytes.as_slice(), &tail_ops))
                .map_err(office_display_error)?;
            let plain_text = ankole_spreadsheet::plain_text(&doc);
            let metadata = encode_serialized(&ankole_spreadsheet::metadata(&doc))?;
            Ok((
                ResourceArc::new(OfficeDocResource::Spreadsheet(Box::new(doc))),
                Some(plain_text),
                Some(metadata),
            )
                .encode(env))
        }
        "word" => match with_office_stack(|| {
            ankole_word::open_with_checkpoint(bytes.as_slice(), &tail_ops, checkpoint.as_deref())
        }) {
            Ok(doc) => Ok((
                ResourceArc::new(OfficeDocResource::Word(doc)),
                Option::<String>::None,
                Option::<String>::None,
            )
                .encode(env)),
            Err(ankole_word::ApplyError::FutureVersion { .. }) => {
                Ok((atoms::busy(), "future_model_version").encode(env))
            }
            Err(reason) => Err(office_display_error(reason)),
        },
        "presentation" => match with_office_stack(|| {
            ankole_presentation::open_with_checkpoint(
                bytes.as_slice(),
                &tail_ops,
                checkpoint.as_deref(),
            )
        }) {
            Ok(doc) => Ok((
                ResourceArc::new(OfficeDocResource::Presentation(doc)),
                Option::<String>::None,
                Option::<String>::None,
            )
                .encode(env)),
            Err(ankole_presentation::ApplyError::FutureVersion { .. }) => {
                Ok((atoms::busy(), "future_model_version").encode(env))
            }
            Err(reason) => Err(office_display_error(reason)),
        },
        other => Err(error_message(format!("unsupported office format: {other}"))),
    }
}

/// Rebases `incoming_op` over `prior_ops` and applies it to `doc`.
#[rustler::nif(schedule = "DirtyCpu")]
pub fn office_apply_nif<'a>(
    env: Env<'a>,
    doc: ResourceArc<OfficeDocResource>,
    incoming_op: Term<'a>,
    prior_ops: Term<'a>,
    actor_name: Term<'a>,
) -> NIFResult<Term<'a>> {
    let incoming_op = decode_string(incoming_op, "incoming_op")?;
    let prior_ops = decode_string(prior_ops, "prior_ops")?;
    let actor_name = decode_optional_string(actor_name, "actor_name")?;
    match &*doc {
        OfficeDocResource::Spreadsheet(sheet) => {
            match with_office_stack(|| ankole_spreadsheet::apply(sheet, &incoming_op, &prior_ops)) {
                Ok(applied) => {
                    let op_json = encode_serialized(&applied.op)?;
                    let edit = applied
                        .structural_edit
                        .as_ref()
                        .map(encode_serialized)
                        .transpose()?;
                    Ok((
                        atoms::ok(),
                        (
                            ResourceArc::new(OfficeDocResource::Spreadsheet(Box::new(applied.doc))),
                            op_json,
                            applied.carries_media,
                            edit,
                        ),
                    )
                        .encode(env))
                }
                Err(ankole_spreadsheet::ApplyError::Conflict(conflict)) => {
                    let reason = match conflict {
                        ankole_spreadsheet::Conflict::TargetDeleted => atoms::target_deleted(),
                        ankole_spreadsheet::Conflict::OverlappingStructuralEdit => {
                            atoms::overlapping_structural_edit()
                        }
                        ankole_spreadsheet::Conflict::SheetDeleted => atoms::sheet_deleted(),
                        ankole_spreadsheet::Conflict::ConcurrentSortOrMerge => {
                            atoms::concurrent_sort_or_merge()
                        }
                    };
                    Ok((atoms::conflict(), reason).encode(env))
                }
                Err(ankole_spreadsheet::ApplyError::Error(reason)) => {
                    Err(office_display_error(reason))
                }
            }
        }
        OfficeDocResource::Word(word) => {
            match with_office_stack(|| {
                ankole_word::apply(word, &incoming_op, &prior_ops, actor_name.as_deref())
            }) {
                Ok(applied) => {
                    let op_json = encode_serialized(&applied.op)?;
                    Ok((
                        atoms::ok(),
                        (
                            ResourceArc::new(OfficeDocResource::Word(applied.doc)),
                            op_json,
                            applied.carries_media,
                            Option::<String>::None,
                        ),
                    )
                        .encode(env))
                }
                Err(ankole_word::ApplyError::Conflict(conflict)) => {
                    let reason = match conflict {
                        ankole_word::Conflict::BlockChanged => atoms::block_changed(),
                        ankole_word::Conflict::ContainerDeleted => atoms::container_deleted(),
                        ankole_word::Conflict::ContainerChanged => atoms::container_changed(),
                        ankole_word::Conflict::FieldChanged => atoms::field_changed(),
                        ankole_word::Conflict::IdentifierTaken => atoms::identifier_taken(),
                        ankole_word::Conflict::ConcurrentRevision => atoms::concurrent_revision(),
                        ankole_word::Conflict::UnbalancedMarkers => atoms::unbalanced_markers(),
                    };
                    Ok((atoms::conflict(), reason).encode(env))
                }
                Err(ankole_word::ApplyError::FutureVersion { .. }) => {
                    Ok((atoms::busy(), "future_model_version").encode(env))
                }
                Err(ankole_word::ApplyError::Error(reason)) => Err(office_display_error(reason)),
            }
        }
        OfficeDocResource::Presentation(pres) => {
            match with_office_stack(|| {
                ankole_presentation::apply(pres, &incoming_op, &prior_ops, actor_name.as_deref())
            }) {
                Ok(applied) => {
                    let op_json = encode_serialized(&applied.op)?;
                    Ok((
                        atoms::ok(),
                        (
                            ResourceArc::new(OfficeDocResource::Presentation(applied.doc)),
                            op_json,
                            applied.carries_media,
                            Option::<String>::None,
                        ),
                    )
                        .encode(env))
                }
                Err(ankole_presentation::ApplyError::Conflict(conflict)) => {
                    let reason = match conflict {
                        ankole_presentation::Conflict::SlideChanged => atoms::slide_changed(),
                        ankole_presentation::Conflict::SlideDeleted => atoms::slide_deleted(),
                        ankole_presentation::Conflict::SlidesReordered => atoms::slides_reordered(),
                        ankole_presentation::Conflict::FieldChanged => atoms::field_changed(),
                        ankole_presentation::Conflict::IdentifierTaken => atoms::identifier_taken(),
                    };
                    Ok((atoms::conflict(), reason).encode(env))
                }
                Err(ankole_presentation::ApplyError::FutureVersion { .. }) => {
                    Ok((atoms::busy(), "future_model_version").encode(env))
                }
                Err(ankole_presentation::ApplyError::Error(reason)) => {
                    Err(office_display_error(reason))
                }
            }
        }
    }
}

/// Serializes an Office document into `{bytes, plain_text | nil, metadata_json | nil}`.
#[rustler::nif(schedule = "DirtyCpu")]
pub fn office_export_nif<'a>(
    env: Env<'a>,
    doc: ResourceArc<OfficeDocResource>,
) -> NIFResult<Term<'a>> {
    match &*doc {
        OfficeDocResource::Spreadsheet(sheet) => {
            let exported = with_office_stack(|| ankole_spreadsheet::export_xlsx(sheet))
                .map_err(office_display_error)?;
            let metadata = encode_serialized(&exported.metadata)?;
            Ok((
                binary_term(env, exported.xlsx),
                Some(exported.plain_text),
                Some(metadata),
            )
                .encode(env))
        }
        OfficeDocResource::Word(word) => {
            let bytes = with_office_stack(|| ankole_word::export_docx(word))
                .map_err(office_display_error)?;
            Ok((
                binary_term(env, bytes),
                Option::<String>::None,
                Option::<String>::None,
            )
                .encode(env))
        }
        OfficeDocResource::Presentation(pres) => {
            let bytes = with_office_stack(|| ankole_presentation::export_pptx(pres))
                .map_err(office_display_error)?;
            Ok((
                binary_term(env, bytes),
                Option::<String>::None,
                Option::<String>::None,
            )
                .encode(env))
        }
    }
}

/// Serializes an Office document for compaction into `{bytes, plain_text | nil, metadata_json | nil, checkpoint_json | nil}`.
#[rustler::nif(schedule = "DirtyCpu")]
pub fn office_export_checkpoint_nif<'a>(
    env: Env<'a>,
    doc: ResourceArc<OfficeDocResource>,
) -> NIFResult<Term<'a>> {
    match &*doc {
        OfficeDocResource::Spreadsheet(sheet) => {
            let exported = with_office_stack(|| ankole_spreadsheet::export_xlsx(sheet))
                .map_err(office_display_error)?;
            let metadata = encode_serialized(&exported.metadata)?;
            Ok((
                binary_term(env, exported.xlsx),
                Some(exported.plain_text),
                Some(metadata),
                Option::<String>::None,
            )
                .encode(env))
        }
        OfficeDocResource::Word(word) => {
            let (bytes, checkpoint) =
                with_office_stack(|| ankole_word::export_docx_with_checkpoint(word))
                    .map_err(office_display_error)?;
            Ok((
                binary_term(env, bytes),
                Option::<String>::None,
                Option::<String>::None,
                checkpoint,
            )
                .encode(env))
        }
        OfficeDocResource::Presentation(pres) => {
            let (bytes, checkpoint) =
                with_office_stack(|| ankole_presentation::export_pptx_with_checkpoint(pres))
                    .map_err(office_display_error)?;
            Ok((
                binary_term(env, bytes),
                Option::<String>::None,
                Option::<String>::None,
                checkpoint,
            )
                .encode(env))
        }
    }
}

/// Inspects the structure and text of an Office document and returns JSON.
#[rustler::nif(schedule = "DirtyCpu")]
pub fn office_inspect_nif(
    doc: ResourceArc<OfficeDocResource>,
    params: Term<'_>,
) -> NIFResult<String> {
    let params = decode_string(params, "params")?;
    let value = match &*doc {
        OfficeDocResource::Spreadsheet(sheet) => {
            with_office_stack(|| ankole_spreadsheet::inspect(sheet, &params))
                .map_err(office_display_error)?
        }
        OfficeDocResource::Word(word) => with_office_stack(|| ankole_word::inspect(word, &params))
            .map_err(office_display_error)?,
        OfficeDocResource::Presentation(pres) => {
            with_office_stack(|| ankole_presentation::inspect(pres, &params))
                .map_err(office_display_error)?
        }
    };
    encode_serialized(&value)
}

/// Renders one 1-based page or slide of a Word or Presentation document to `{png_bytes, width, height, count}`.
#[rustler::nif(schedule = "DirtyCpu")]
pub fn office_render_nif<'a>(
    env: Env<'a>,
    doc: ResourceArc<OfficeDocResource>,
    index: Term<'a>,
    scale: Term<'a>,
    fonts_dir: Term<'a>,
) -> NIFResult<Term<'a>> {
    let index = decode_usize(index, "index")?;
    let zero_index = index
        .checked_sub(1)
        .ok_or_else(|| error_message("index must be at least 1"))?;
    let scale_f64: f64 = scale
        .decode()
        .map_err(|_| error_message("scale must be a float"))?;
    let scale_f32 = scale_f64 as f32;
    let fonts_dir = decode_string(fonts_dir, "fonts_dir")?;
    let (png, width, height, count) = match &*doc {
        OfficeDocResource::Word(word) => {
            ensure_word_site_fonts(&fonts_dir);
            with_office_stack(|| ankole_word::render_page_png_meta(word, zero_index, scale_f32))
                .map_err(office_display_error)?
        }
        OfficeDocResource::Presentation(pres) => {
            ensure_presentation_site_fonts(&fonts_dir);
            with_office_stack(|| {
                ankole_presentation::render_slide_png_meta(pres, zero_index, scale_f32)
            })
            .map_err(office_display_error)?
        }
        OfficeDocResource::Spreadsheet(_) => {
            return Err(error_message("spreadsheet rendering is not supported"));
        }
    };
    Ok((binary_term(env, png), width, height, count).encode(env))
}

/// Lists safe headless commands for `format` (`"word"` or `"presentation"`).
#[rustler::nif(schedule = "DirtyCpu")]
pub fn office_commands_nif(format: Term<'_>, query: Term<'_>) -> NIFResult<String> {
    let format = decode_string(format, "format")?;
    let query = decode_optional_string(query, "query")?;
    let value = match format.as_str() {
        "word" => with_office_stack(|| ankole_word::commands(query.as_deref())),
        "presentation" => with_office_stack(|| ankole_presentation::commands(query.as_deref())),
        other => {
            return Err(error_message(format!(
                "unsupported command format: {other}"
            )));
        }
    };
    encode_serialized(&value)
}

/// Applies a batch of headless engine commands and returns `{next_ref, change_set_json, results_json}`.
#[rustler::nif(schedule = "DirtyCpu")]
pub fn office_apply_commands_nif<'a>(
    env: Env<'a>,
    doc: ResourceArc<OfficeDocResource>,
    commands: Term<'a>,
    actor_name: Term<'a>,
    fonts_dir: Term<'a>,
) -> NIFResult<Term<'a>> {
    let commands = decode_string(commands, "commands")?;
    let actor_name = decode_string(actor_name, "actor_name")?;
    let fonts_dir = decode_string(fonts_dir, "fonts_dir")?;
    match &*doc {
        OfficeDocResource::Word(word) => {
            ensure_word_site_fonts(&fonts_dir);
            let (next_doc, changeset, results) =
                with_office_stack(|| ankole_word::apply_commands(word, &commands, &actor_name))
                    .map_err(office_display_error)?;
            let cs_json = match changeset {
                Some(cs) => encode_serialized(&cs)?,
                None => encode_serialized(&serde_json::json!({
                    "model_version": ankole_word::MODEL_VERSION,
                    "edits": []
                }))?,
            };
            let res_json = encode_serialized(&results)?;
            Ok((
                ResourceArc::new(OfficeDocResource::Word(next_doc)),
                cs_json,
                res_json,
            )
                .encode(env))
        }
        OfficeDocResource::Presentation(pres) => {
            ensure_presentation_site_fonts(&fonts_dir);
            let (next_doc, changeset, results) = with_office_stack(|| {
                ankole_presentation::apply_commands(pres, &commands, &actor_name)
            })
            .map_err(office_display_error)?;
            let cs_json = match changeset {
                Some(cs) => encode_serialized(&cs)?,
                None => encode_serialized(&serde_json::json!({
                    "model_version": ankole_presentation::MODEL_VERSION,
                    "edits": []
                }))?,
            };
            let res_json = encode_serialized(&results)?;
            Ok((
                ResourceArc::new(OfficeDocResource::Presentation(next_doc)),
                cs_json,
                res_json,
            )
                .encode(env))
        }
        OfficeDocResource::Spreadsheet(_) => Err(error_message(
            "spreadsheet operations do not use engine commands",
        )),
    }
}

/// Converts a Word document to validated `page_document` XML, extracted media, and a conversion report.
#[rustler::nif(schedule = "DirtyCpu")]
pub fn office_to_document_nif<'a>(
    env: Env<'a>,
    doc: ResourceArc<OfficeDocResource>,
) -> NIFResult<Term<'a>> {
    let OfficeDocResource::Word(word) = &*doc else {
        return Err(error_message(
            "only Word documents convert to document Pages",
        ));
    };
    let converted = match with_office_stack(|| ankole_word::to_document(word)) {
        Ok(converted) => converted,
        Err(ankole_word::Error::Invalid(ref reason)) if reason.contains("document_too_large") => {
            return Ok((atoms::error(), atoms::document_too_large()).encode(env));
        }
        Err(reason) => return Err(office_display_error(reason)),
    };

    let validated = match with_office_stack(|| crate::page_document::validate(&converted.xml)) {
        Ok(page) => page,
        Err(ref reason)
            if reason == "page source exceeds the UTF-16 limit"
                || reason == "page node or depth limit exceeded" =>
        {
            return Ok((atoms::error(), atoms::document_too_large()).encode(env));
        }
        Err(reason) => return Err(error_message(reason)),
    };

    let media_terms: Vec<Term<'a>> = converted
        .assets
        .into_iter()
        .map(|asset| (asset.filename, asset.mime, binary_term(env, asset.bytes)).encode(env))
        .collect();
    let omitted_json = encode_serialized(&converted.report.omitted)?;
    let downgraded_json = encode_serialized(&converted.report.downgraded)?;

    Ok((
        validated.xml,
        validated.plain_text,
        media_terms,
        omitted_json,
        downgraded_json,
    )
        .encode(env))
}

fn office_display_error(reason: impl std::fmt::Display) -> Error {
    error_message(reason.to_string())
}

fn encode_serialized(value: &impl serde::Serialize) -> NIFResult<String> {
    serde_json::to_string(value)
        .map_err(|reason| error_message(format!("failed to encode JSON: {reason}")))
}

#[cfg(feature = "markdown")]
#[rustler::nif(schedule = "DirtyCpu")]
pub fn markdown_code_ranges_nif(source: Term<'_>) -> NIFResult<Vec<(usize, usize)>> {
    let source = decode_string(source, "source")?;
    Ok(crate::markdown::code_ranges(&source))
}

#[cfg(feature = "markdown")]
#[rustler::nif(schedule = "DirtyCpu")]
pub fn markdown_repair_generated_nif(source: Term<'_>) -> NIFResult<String> {
    let source = decode_string(source, "source")?;
    Ok(crate::markdown::repair_generated_markdown(&source))
}

/// Returns `{:ok, facts}` or `{:error, %{"code" => code, "message" => message}}`.
#[cfg(feature = "sql_inspect")]
#[rustler::nif(schedule = "DirtyCpu")]
pub fn sql_inspect_nif<'a>(env: Env<'a>, sql: Term<'a>, dialect: Term<'a>) -> NIFResult<Term<'a>> {
    let sql = decode_binary(sql, "sql")?;
    let dialect = decode_string(dialect, "dialect")?;
    let result = str::from_utf8(sql.as_slice())
        .map_err(|_| crate::sql_inspect::InspectError::parse("SQL must be valid UTF-8"))
        .and_then(|sql| crate::sql_inspect::inspect(sql, &dialect));
    Ok(match result {
        Ok(facts) => (atoms::ok(), encode_json_value(env, &facts)).encode(env),
        Err(reason) => (atoms::error(), encode_json_value(env, &reason.to_json())).encode(env),
    })
}

#[cfg(feature = "file_text")]
#[rustler::nif]
pub fn file_extractor_version_nif() -> u32 {
    crate::file_text::EXTRACTOR_VERSION
}

#[cfg(feature = "file_text")]
#[rustler::nif]
pub fn file_classify_format_nif<'a>(
    env: Env<'a>,
    filename: Term<'a>,
    mime_type: Term<'a>,
) -> NIFResult<Term<'a>> {
    let filename = decode_string(filename, "filename")?;
    let mime_type = decode_optional_string(mime_type, "mime_type")?;
    match crate::file_text::classify(&filename, mime_type.as_deref()) {
        Some((subtype, format)) => {
            let subtype_atom = match subtype {
                crate::file_text::FileSubtype::Text => atoms::text(),
                crate::file_text::FileSubtype::Document => atoms::document(),
            };
            Ok((atoms::ok(), (subtype_atom, format)).encode(env))
        }
        None => Ok(atoms::unsupported().encode(env)),
    }
}

#[cfg(feature = "file_text")]
#[derive(rustler::NifMap)]
pub struct FileExtractTextNIF {
    pub status: rustler::Atom,
    pub subtype: rustler::Atom,
    pub format: String,
    pub extractor_version: u32,
    pub plain_text: String,
    pub metadata_json: String,
    pub error: Option<String>,
}

#[cfg(feature = "file_text")]
#[rustler::nif(schedule = "DirtyCpu")]
pub fn file_extract_text_nif(
    bytes: Term<'_>,
    filename: Term<'_>,
    mime_type: Term<'_>,
    page_texts: Term<'_>,
) -> NIFResult<FileExtractTextNIF> {
    let bytes = decode_binary(bytes, "bytes")?;
    let filename = decode_string(filename, "filename")?;
    let mime_type = decode_optional_string(mime_type, "mime_type")?;
    let recognized = page_texts
        .decode::<Option<Vec<(u32, String)>>>()
        .map_err(|_| error_message("page_texts must be nil or a list of {page, text}"))?
        .map(|pages| {
            pages
                .into_iter()
                .collect::<std::collections::BTreeMap<_, _>>()
        });
    let result = stacker::grow(8 * 1024 * 1024, || {
        crate::file_text::extract(
            bytes.as_slice(),
            &filename,
            mime_type.as_deref(),
            recognized.as_ref(),
        )
    });
    let status = match result.status {
        crate::file_text::ExtractStatus::Ok => atoms::ok(),
        crate::file_text::ExtractStatus::Skipped => atoms::skipped(),
        crate::file_text::ExtractStatus::Failed => atoms::failed(),
    };
    let subtype = match result.subtype {
        crate::file_text::FileSubtype::Text => atoms::text(),
        crate::file_text::FileSubtype::Document => atoms::document(),
    };
    let metadata_json = encode_serialized(&result.metadata)?;
    Ok(FileExtractTextNIF {
        status,
        subtype,
        format: result.format,
        extractor_version: result.extractor_version,
        plain_text: result.plain_text,
        metadata_json,
        error: result.error,
    })
}

// CEL's recursive parser needs more stack than BEAM's default dirty CPU stack.
// Keep compilation, evaluation, and program cleanup on this stack on the same
// scheduler thread. Host-neutral callers retain their own stack policy.
fn with_cel_stack<R>(call: impl FnOnce() -> R) -> R {
    stacker::grow(8 * 1024 * 1024, call)
}

/// Authorizes one exact action on one concrete resource from an encoded snapshot.
#[rustler::nif(schedule = "DirtyCpu")]
pub fn authz_authorize_nif(snapshot: Term<'_>) -> NIFResult<String> {
    let snapshot = decode_json(snapshot, "snapshot")?;
    let decision = with_cel_stack(|| authz::authorize_value(snapshot)).map_err(error)?;

    encode_json(decision)
}

/// Authorizes every requested action against the same resource from an encoded snapshot.
#[rustler::nif(schedule = "DirtyCpu")]
pub fn authz_authorize_all_nif(snapshot: Term<'_>) -> NIFResult<String> {
    let snapshot = decode_json(snapshot, "snapshot")?;
    let decision = with_cel_stack(|| authz::authorize_all_value(snapshot)).map_err(error)?;

    encode_json(decision)
}

/// Evaluates independent resource/action checks with one encoded snapshot.
#[rustler::nif(schedule = "DirtyCpu")]
pub fn authz_authorize_checks_nif(snapshot: Term<'_>) -> NIFResult<String> {
    let snapshot = decode_json(snapshot, "snapshot")?;
    let decisions = with_cel_stack(|| authz::authorize_checks_value(snapshot)).map_err(error)?;
    encode_json(decisions)
}

#[rustler::nif(schedule = "DirtyCpu")]
pub fn authz_evaluate_drive_context_nif(snapshot: Term<'_>) -> NIFResult<String> {
    let snapshot = decode_json(snapshot, "snapshot")?;
    let decision =
        with_cel_stack(|| authz::evaluate_drive_context_value(snapshot)).map_err(error)?;
    encode_json(decision)
}

#[rustler::nif(schedule = "DirtyCpu")]
pub fn authz_validate_condition(condition: Term<'_>) -> NIFResult<bool> {
    let condition = decode_string(condition, "condition")?;

    with_cel_stack(|| authz::validate_condition_source(&condition))
        .map(|_| true)
        .map_err(error)
}

#[rustler::nif(schedule = "DirtyCpu")]
pub fn authz_validate_drive_condition(condition: Term<'_>) -> NIFResult<bool> {
    let condition = decode_string(condition, "condition")?;
    with_cel_stack(|| authz::validate_drive_condition_source(&condition))
        .map(|_| true)
        .map_err(error)
}

#[rustler::nif(schedule = "DirtyCpu")]
pub fn authz_condition_free_variables(condition: Term<'_>) -> NIFResult<Vec<String>> {
    let condition = decode_string(condition, "condition")?;
    with_cel_stack(|| authz::condition_free_variables(&condition)).map_err(error)
}

#[rustler::nif(schedule = "DirtyCpu")]
pub fn signals_validate_filter(filter_source: Term<'_>) -> NIFResult<bool> {
    let filter_source = decode_string(filter_source, "filter_source")?;

    with_cel_stack(|| signals::validate_filter_source(&filter_source))
        .map(|_| true)
        .map_err(error)
}

#[rustler::nif(schedule = "DirtyCpu")]
pub fn signals_filter_match_nif(filter_source: Term<'_>, context: Term<'_>) -> NIFResult<bool> {
    let filter_source = decode_string(filter_source, "filter_source")?;
    let context = decode_json(context, "context")?;

    with_cel_stack(|| signals::evaluate_filter(&filter_source, context)).map_err(error)
}

#[rustler::nif(schedule = "DirtyCpu")]
pub fn authz_validate_resource_pattern(pattern: Term<'_>) -> NIFResult<bool> {
    let pattern = decode_string(pattern, "pattern")?;

    authz::validate_pattern_source(&pattern)
        .map(|_| true)
        .map_err(error)
}

#[rustler::nif(schedule = "DirtyIo")]
pub fn universal_ai_client_open_nif<'a>(
    env: Env<'a>,
    encoded_spec: Term<'a>,
    owner_pid: LocalPid,
    stream_ref: Term<'a>,
) -> NIFResult<Term<'a>> {
    let encoded_spec = decode_string(encoded_spec, "encoded_spec")?;
    let stream_ref = Arc::new(Mutex::new(BeamStreamRef::new(stream_ref)));
    let sink = {
        let stream_ref = Arc::clone(&stream_ref);
        Arc::new(move |event| {
            send_universal_ai_client_event(owner_pid, Arc::clone(&stream_ref), event)
        })
    };

    // Model specs include nested tool schemas that exceed a dirty scheduler's stack.
    let result = stacker::grow(8 * 1024 * 1024, || {
        universal_ai_client::start_stream(&encoded_spec, sink)
    });
    match result {
        Ok(handle) => {
            let resource = ResourceArc::new(UniversalAIClientStreamResource(handle));
            let _ = resource.monitor(Some(env), &owner_pid);
            Ok((atoms::ok(), resource).encode(env))
        }
        Err(reason) => Ok((
            atoms::error(),
            encode_json_value(
                env,
                &serde_json::json!({
                    "code": "stream_open_failed",
                    "stage": "open",
                    "message": reason.to_string()
                }),
            ),
        )
            .encode(env)),
    }
}

/// Grants downstream chunk credit to a native UniversalAIClient stream.
#[rustler::nif]
pub fn universal_ai_client_read_nif(
    stream: ResourceArc<UniversalAIClientStreamResource>,
    count: Term<'_>,
) -> NIFResult<rustler::Atom> {
    let count = decode_u64(count, "count")?;
    stream.0.read(count).map_err(error)?;
    Ok(atoms::ok())
}

#[rustler::nif]
pub fn universal_ai_client_cancel_nif(
    stream: ResourceArc<UniversalAIClientStreamResource>,
) -> NIFResult<rustler::Atom> {
    stream.0.cancel().map_err(error)?;
    Ok(atoms::ok())
}

/// The result arrives later as one `{:universal_ai_client_request, ref, result}` message.
#[rustler::nif(schedule = "DirtyIo")]
pub fn universal_ai_client_model_request_nif<'a>(
    env: Env<'a>,
    encoded_spec: Term<'a>,
    owner_pid: LocalPid,
    request_ref: Term<'a>,
) -> NIFResult<Term<'a>> {
    let encoded_spec = decode_string(encoded_spec, "encoded_spec")?;
    let resource = ResourceArc::new(UniversalAIClientRequestResource::new());
    let monitored = resource.monitor(Some(env), &owner_pid).is_some();
    let deliver =
        monitored_request_sink(owner_pid, BeamStreamRef::new(request_ref), resource.clone());

    let result = stacker::grow(8 * 1024 * 1024, || {
        universal_ai_client::start_model_request(&encoded_spec, deliver)
    });
    match result {
        Ok(handle) => {
            if !monitored {
                resource.cancel();
            }
            resource.install(handle);
            Ok(atoms::ok().encode(env))
        }
        Err(reason) => Ok((atoms::error(), encode_json_value(env, &reason.to_json())).encode(env)),
    }
}

/// No model normalization. Same result message as `universal_ai_client_model_request_nif`.
#[rustler::nif(schedule = "DirtyIo")]
pub fn universal_ai_client_raw_request_nif<'a>(
    env: Env<'a>,
    encoded_spec: Term<'a>,
    owner_pid: LocalPid,
    request_ref: Term<'a>,
) -> NIFResult<Term<'a>> {
    let encoded_spec = decode_string(encoded_spec, "encoded_spec")?;
    let resource = ResourceArc::new(UniversalAIClientRequestResource::new());
    let monitored = resource.monitor(Some(env), &owner_pid).is_some();
    let deliver =
        monitored_request_sink(owner_pid, BeamStreamRef::new(request_ref), resource.clone());

    match universal_ai_client::start_raw_request(&encoded_spec, deliver) {
        Ok(handle) => {
            if !monitored {
                resource.cancel();
            }
            resource.install(handle);
            Ok(atoms::ok().encode(env))
        }
        Err(reason) => Ok((atoms::error(), encode_json_value(env, &reason.to_json())).encode(env)),
    }
}

fn monitored_request_sink(
    owner_pid: LocalPid,
    request_ref: BeamStreamRef,
    resource: ResourceArc<UniversalAIClientRequestResource>,
) -> universal_ai_client::RequestResultSink {
    let deliver = universal_ai_client_request_sink(owner_pid, request_ref);
    Box::new(move |result| {
        deliver(result);
        // Drop the owner resource only after delivery. A fast provider result
        // must not race resource registration in the starting NIF call.
        drop(resource);
    })
}

fn universal_ai_client_request_sink(
    owner_pid: LocalPid,
    request_ref: BeamStreamRef,
) -> universal_ai_client::RequestResultSink {
    Box::new(move |result| {
        let mut env = OwnedEnv::new();
        let _ = env.send_and_clear(&owner_pid, |env| {
            let request_ref = request_ref.encode(env);
            let result = match &result {
                Ok(response) => (atoms::ok(), encode_json_value(env, response)).encode(env),
                Err(reason) => {
                    (atoms::error(), encode_json_value(env, &reason.to_json())).encode(env)
                }
            };
            (atoms::universal_ai_client_request(), request_ref, result).encode(env)
        });
    })
}

/// Opens one object store from its JSON spec.
///
/// Opening does no network I/O. The fs scheme creates its root and temporary
/// directory, which is why the NIF runs on a dirty I/O scheduler.
#[rustler::nif(schedule = "DirtyCpu")]
pub fn authz_match_resource_pattern(pattern: Term<'_>, resource: Term<'_>) -> NIFResult<bool> {
    let pattern = decode_string(pattern, "pattern")?;
    let resource = decode_string(resource, "resource")?;

    authz::pattern_matches(&pattern, &resource).map_err(error)
}

#[rustler::nif(schedule = "DirtyCpu")]
pub fn estimate_o200k_base_tokens(text: Term<'_>) -> NIFResult<u64> {
    let text = decode_str(text, "text")?;

    Ok(common::estimate_o200k_base_tokens(text))
}

#[rustler::nif(schedule = "DirtyCpu")]
pub fn truncate_o200k_base_tokens(text: Term<'_>, budget: Term<'_>) -> NIFResult<String> {
    let text = decode_str(text, "text")?;
    if text.len() > brain_chunker::MAX_CHUNK_INPUT_BYTES {
        return Err(error_message(format!(
            "text exceeds maximum input size of {} bytes",
            brain_chunker::MAX_CHUNK_INPUT_BYTES
        )));
    }
    let budget = decode_u64(budget, "budget")?;

    Ok(common::truncate_o200k_base_tokens(text, budget))
}

#[rustler::nif(schedule = "DirtyCpu")]
pub fn brain_chunk_text_with_tokens(
    text: Term<'_>,
    chunk_size: Term<'_>,
    chunk_overlap: Term<'_>,
    max_chars: Term<'_>,
    max_tokens: Term<'_>,
) -> NIFResult<Vec<(String, u64)>> {
    let text = decode_str(text, "text")?;
    let chunk_size = decode_usize(chunk_size, "chunk_size")?;
    let chunk_overlap = decode_usize(chunk_overlap, "chunk_overlap")?;
    let max_chars = decode_usize(max_chars, "max_chars")?;
    let max_tokens = decode_u64(max_tokens, "max_tokens")?;

    brain_chunker::chunk_text_with_tokens(text, chunk_size, chunk_overlap, max_chars, max_tokens)
        .map_err(|err| error_message(err.to_string()))
}

#[rustler::nif(schedule = "DirtyCpu")]
pub fn reciprocal_rank_fusion_nif(ranked_lists: Term<'_>, k: Term<'_>) -> NIFResult<String> {
    let ranked_lists = decode_json(ranked_lists, "ranked_lists")?;
    let ranked_lists: Vec<Vec<String>> = serde_json::from_value(ranked_lists)
        .map_err(|_| error_message("ranked_lists must contain a JSON array of string arrays"))?;
    let k = decode_u64(k, "k")?;
    let fused = common::reciprocal_rank_fusion(&ranked_lists, k);
    let fused = serde_json::to_value(fused)
        .map_err(|reason| error_message(format!("failed to encode RRF results: {reason}")))?;

    encode_json(fused)
}

/// Non-cryptographic observation fingerprint.
#[rustler::nif(schedule = "DirtyCpu")]
pub fn xxh3_128_hex(input: Term<'_>) -> NIFResult<String> {
    let input = decode_binary(input, "input")?;

    Ok(common::xxh3_128_hex(input.as_slice()))
}

/// Key seeds are binaries, so they can contain non-UTF-8 bytes.
#[rustler::nif(schedule = "DirtyCpu")]
pub fn derive_key(
    key_seed: Term<'_>,
    sub_key_id: Term<'_>,
    extra_context: Term<'_>,
) -> NIFResult<String> {
    let key_seed = decode_binary(key_seed, "key_seed")?;
    let sub_key_id = decode_string(sub_key_id, "sub_key_id")?;
    let extra_context = decode_optional_string(extra_context, "extra_context")?;

    Ok(common::derive_key(
        key_seed.as_slice(),
        &sub_key_id,
        extra_context.as_deref(),
    ))
}

#[rustler::nif(schedule = "DirtyCpu")]
pub fn jwt_sign_pem_nif(
    claims: Term<'_>,
    private_key_pem: Term<'_>,
    header: Term<'_>,
) -> NIFResult<String> {
    let claims = decode_string(claims, "claims")?;
    let private_key_pem = decode_string(private_key_pem, "private_key_pem")?;
    let header = decode_string(header, "header")?;

    common::jwt_sign_pem(&claims, &private_key_pem, &header).map_err(error)
}

#[rustler::nif(schedule = "DirtyCpu")]
pub fn jwt_verify_jwk_nif(
    token: Term<'_>,
    jwk: Term<'_>,
    validation: Term<'_>,
) -> NIFResult<String> {
    let token = decode_string(token, "token")?;
    let jwk = decode_string(jwk, "jwk")?;
    let validation = decode_string(validation, "validation")?;

    common::jwt_verify_jwk(&token, &jwk, &validation).map_err(error)
}

#[derive(rustler::NifMap)]
struct WebURLFactsNIF {
    scheme: String,
    host: Option<String>,
    host_class: Option<rustler::Atom>,
}

/// Parses a web URL with WHATWG semantics and classifies its host.
#[rustler::nif]
pub fn web_url_facts_nif(url: Term<'_>) -> NIFResult<WebURLFactsNIF> {
    let url = decode_string(url, "url")?;
    let facts = common::web_url_facts(&url).map_err(error)?;

    Ok(WebURLFactsNIF {
        scheme: facts.scheme,
        host: facts.host,
        host_class: facts.host_class.map(|host_class| match host_class {
            common::HostClass::Metadata => atoms::metadata(),
            common::HostClass::Private => atoms::private(),
            common::HostClass::Public => atoms::public(),
        }),
    })
}

#[rustler::nif]
pub fn validate_web_url_nif<'a>(
    env: Env<'a>,
    url: Term<'a>,
    schemes: Vec<String>,
    ssrf_filter: bool,
) -> NIFResult<Term<'a>> {
    let url = decode_string(url, "url")?;
    let schemes: Vec<&str> = schemes.iter().map(String::as_str).collect();
    Ok(web_url_verdict(
        env,
        common::validate_web_url(&url, &schemes, ssrf_filter),
    ))
}

#[rustler::nif]
pub fn validate_ip_addresses_nif<'a>(
    env: Env<'a>,
    addresses: Vec<String>,
    ssrf_filter: bool,
) -> Term<'a> {
    let addresses: Result<Vec<std::net::IpAddr>, _> =
        addresses.iter().map(|address| address.parse()).collect();
    let verdict = addresses
        .map_err(|_| common::WebURLRejection::Invalid)
        .and_then(|addresses| common::validate_ip_addresses(&addresses, ssrf_filter));
    web_url_verdict(env, verdict)
}

fn web_url_verdict<'a>(env: Env<'a>, verdict: Result<(), common::WebURLRejection>) -> Term<'a> {
    match verdict {
        Ok(()) => atoms::ok().encode(env),
        Err(reason) => {
            let atom = match reason {
                common::WebURLRejection::Metadata => atoms::metadata(),
                common::WebURLRejection::Private => atoms::private(),
                common::WebURLRejection::Invalid => atoms::invalid(),
            };
            (atoms::error(), atom).encode(env)
        }
    }
}

/// Generates a random 32-byte hex key for kernel cryptographic helpers.
#[rustler::nif]
pub fn generate_key() -> String {
    common::generate_key()
}

#[rustler::nif(schedule = "DirtyCpu")]
pub fn phone_normalize_e164(phone: Term<'_>) -> NIFResult<String> {
    let phone = decode_string(phone, "phone")?;

    common::phone_normalize_e164(&phone).map_err(error)
}

#[rustler::nif]
pub fn gen_uuid() -> String {
    common::gen_uuid()
}

#[rustler::nif]
pub fn gen_uuid_v7() -> String {
    common::gen_uuid_v7()
}

#[rustler::nif]
pub fn uuid_shorten(value: Term<'_>) -> NIFResult<String> {
    common::uuid_shorten(&decode_string(value, "uuid")?).map_err(error)
}

#[rustler::nif]
pub fn uuid_expand(value: Term<'_>) -> NIFResult<String> {
    common::uuid_expand(&decode_string(value, "short_uuid")?).map_err(error)
}

#[rustler::nif]
pub fn page_url_slug(value: Term<'_>) -> NIFResult<String> {
    Ok(common::page_url_slug(&decode_string(value, "title")?))
}

/// Copies Rust-owned bytes into an Elixir-owned binary.
///
/// Returning `Vec<u8>` directly would be encoded by Rustler as a list of byte
/// integers. `OwnedBinary` keeps the Elixir API binary-safe and matches caller
/// expectations for decrypted and decoded payloads.
fn binary_from_vec(bytes: Vec<u8>) -> NIFResult<OwnedBinary> {
    Ok(OwnedBinary::from_slice(&bytes))
}

fn binary_from_buf(mut buffer: impl bytes::Buf) -> OwnedBinary {
    let mut binary = OwnedBinary::new(buffer.remaining());
    buffer.copy_to_slice(binary.as_mut_slice());
    binary
}

/// The error text stays stable and does not use Rustler's conversion wording.
fn decode_binary<'a>(term: Term<'a>, field: &str) -> NIFResult<Binary<'a>> {
    if !term.is_binary() {
        return Err(error_message(format!("{field} must be a binary")));
    }

    Binary::from_term(term).map_err(|_| error_message(format!("{field} must be a binary")))
}

fn decode_json(term: Term<'_>, field: &str) -> NIFResult<JSONValue> {
    let json = decode_string(term, field)?;

    serde_json::from_str(&json)
        .map_err(|reason| error_message(format!("{field} must contain valid JSON: {reason}")))
}

fn decode_optional_string(term: Term<'_>, field: &str) -> NIFResult<Option<String>> {
    term.decode()
        .map_err(|_| error_message(format!("{field} must be a string or nil")))
}

fn decode_u64(term: Term<'_>, field: &str) -> NIFResult<u64> {
    term.decode()
        .map_err(|_| error_message(format!("{field} must be a non-negative integer")))
}

fn decode_usize(term: Term<'_>, field: &str) -> NIFResult<usize> {
    term.decode()
        .map_err(|_| error_message(format!("{field} must be a non-negative integer")))
}

fn decode_str<'a>(term: Term<'a>, field: &str) -> NIFResult<&'a str> {
    if !term.is_binary() {
        return Err(error_message(format!("{field} must be a string")));
    }

    let binary =
        Binary::from_term(term).map_err(|_| error_message(format!("{field} must be a string")))?;

    str::from_utf8(binary.as_slice())
        .map_err(|_| error_message(format!("{field} must be a string")))
}

fn decode_string(term: Term<'_>, field: &str) -> NIFResult<String> {
    term.decode()
        .map_err(|_| error_message(format!("{field} must be a string")))
}

fn encode_json(value: JSONValue) -> NIFResult<String> {
    serde_json::to_string(&value)
        .map_err(|reason| error_message(format!("failed to encode JSON: {reason}")))
}

fn error(error: common::KernelError) -> Error {
    error_message(error.to_string())
}

fn error_message(message: impl Into<String>) -> Error {
    Error::Term(Box::new(message.into()))
}

fn send_universal_ai_client_event(
    owner_pid: LocalPid,
    stream_ref: Arc<Mutex<BeamStreamRef>>,
    event: universal_ai_client::StreamEvent,
) {
    let mut env = OwnedEnv::new();

    let _ = env.send_and_clear(&owner_pid, |env| {
        let stream_ref = stream_ref
            .lock()
            .map(|stream_ref| stream_ref.encode(env))
            .unwrap_or_else(|_| "stream_ref_unavailable".encode(env));

        match event {
            universal_ai_client::StreamEvent::Ready(meta) => (
                atoms::universal_ai_client(),
                stream_ref,
                atoms::ready(),
                encode_json_value(env, &meta),
            )
                .encode(env),
            universal_ai_client::StreamEvent::Chunk { seq, origin, bytes } => {
                let origin = match origin {
                    universal_ai_client::ChunkOrigin::Provider => atoms::provider(),
                    universal_ai_client::ChunkOrigin::Client => atoms::client(),
                };
                (
                    atoms::universal_ai_client(),
                    stream_ref,
                    atoms::chunk(),
                    seq,
                    origin,
                    binary_term(env, bytes),
                )
                    .encode(env)
            }
            universal_ai_client::StreamEvent::Done(summary) => (
                atoms::universal_ai_client(),
                stream_ref,
                atoms::done(),
                encode_json_value(env, &summary),
            )
                .encode(env),
            universal_ai_client::StreamEvent::Error(error) => (
                atoms::universal_ai_client(),
                stream_ref,
                atoms::error(),
                encode_json_value(env, &error),
            )
                .encode(env),
            universal_ai_client::StreamEvent::Aborted => {
                (atoms::universal_ai_client(), stream_ref, atoms::aborted()).encode(env)
            }
        }
    });
}

fn binary_term<'a>(env: Env<'a>, bytes: Vec<u8>) -> Term<'a> {
    OwnedBinary::from_slice(&bytes).release(env).encode(env)
}

fn encode_json_value<'a>(env: Env<'a>, value: &JSONValue) -> Term<'a> {
    match value {
        JSONValue::Null => rustler_atom::nil().encode(env),
        JSONValue::Bool(value) => value.encode(env),
        JSONValue::Number(number) => {
            if let Some(value) = number.as_i64() {
                value.encode(env)
            } else if let Some(value) = number.as_u64() {
                value.encode(env)
            } else if let Some(value) = number.as_f64() {
                value.encode(env)
            } else {
                rustler_atom::nil().encode(env)
            }
        }
        JSONValue::String(value) => value.encode(env),
        JSONValue::Array(values) => values
            .iter()
            .map(|value| encode_json_value(env, value))
            .collect::<Vec<_>>()
            .encode(env),
        JSONValue::Object(values) => {
            let mut map = Term::map_new(env);
            for (key, value) in values {
                map = map
                    .map_put(key.as_str(), encode_json_value(env, value))
                    .unwrap_or(map);
            }
            map
        }
    }
}

rustler::init!("Elixir.Ankole.Kernel");
