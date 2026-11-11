//! Host-neutral Word documents, unit change sets, and block conflict rules over WordCraft.

#![forbid(unsafe_code)]
#![warn(
    missing_docs,
    unreachable_pub,
    clippy::unwrap_used,
    clippy::expect_used,
    clippy::panic,
    clippy::indexing_slicing,
    clippy::must_use_candidate,
    clippy::missing_errors_doc
)]
#![cfg_attr(
    test,
    allow(
        clippy::unwrap_used,
        clippy::expect_used,
        clippy::panic,
        clippy::indexing_slicing,
        reason = "a failing test should stop at the broken expectation"
    )
)]

use std::io::Read as _;
use std::sync::Arc;

use serde::{Deserialize, Serialize};
pub use wordcraft_doc::StoryRef;

mod agent;
mod checkpoint;
mod convert;
mod derive;
/// Headless collaborative Word editor state for browser Web Workers.
pub mod editor;
mod markers;
mod ops;
mod rebase;

pub use agent::{
    FindMatch, PageRect, apply_commands, commands, export_pdf, find, init_site_fonts, inspect,
    render_page_png, render_page_png_meta, render_page_rgba,
};
pub use convert::{ConversionReport, ConvertedAsset, ConvertedDocument, to_document};
pub use ops::{Applied, ChangeSet, DocField, Edit, EntryMap};

/// Current canonical wire model version for Word change sets.
pub const MODEL_VERSION: u32 = 1;

/// Maximum byte length of a serialized JSON change set accepted by [`apply`].
pub const MAX_OP_BYTES: usize = 4 * 1024 * 1024;

/// Maximum decoded byte size of a single picture payload in `Document::media`.
pub const MAX_PICTURE_BYTES: usize = 2 * 1024 * 1024;

/// Errors returned while reading, writing, converting, or running commands on a Word document.
#[derive(Clone, Debug, PartialEq, Eq, thiserror::Error)]
pub enum Error {
    /// The caller supplied malformed JSON, out-of-range indices, or unsupported parameters.
    #[error("invalid word operation: {0}")]
    Invalid(String),
    /// WordCraft could not decode the `.docx` or `.docm` package.
    #[error("word read failed: {0}")]
    Read(String),
    /// WordCraft could not encode the output `.docx`, `.docm`, PNG, or PDF bytes.
    #[error("word write failed: {0}")]
    Write(String),
}

/// Collaboration conflict reason codes reported when rebasing cannot proceed without guessing.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Conflict {
    /// Two concurrent `blocks.splice` edits overlap or insert at the exact same position.
    BlockChanged,
    /// A `blocks.splice` targets a story part that an earlier operation deleted.
    ContainerDeleted,
    /// A `blocks.splice` targets a story part replaced by an earlier operation, or vice versa.
    ContainerChanged,
    /// Two concurrent `field.set` edits modify the same document-wide field.
    FieldChanged,
    /// Two concurrent `entry.put` or `entry.delete` edits touch the same map key.
    IdentifierTaken,
    /// Two concurrent operations append or replace tracked-change revision records.
    ConcurrentRevision,
    /// Rebasing left paired inline markers unbalanced across paragraphs in the edited story.
    UnbalancedMarkers,
}

impl Conflict {
    /// Returns the wire snake_case conflict code expected by `Ankole.Pod.OfficeFiles`.
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::BlockChanged => "block_changed",
            Self::ContainerDeleted => "container_deleted",
            Self::ContainerChanged => "container_changed",
            Self::FieldChanged => "field_changed",
            Self::IdentifierTaken => "identifier_taken",
            Self::ConcurrentRevision => "concurrent_revision",
            Self::UnbalancedMarkers => "unbalanced_markers",
        }
    }
}

/// Errors returned when opening a Word document with uncompacted operations or applying an edit.
#[derive(Clone, Debug, PartialEq, Eq, thiserror::Error)]
pub enum ApplyError {
    /// The incoming operation conflicts with an earlier committed operation.
    #[error("office conflict: {}", .0.as_str())]
    Conflict(Conflict),
    /// An operation carries a `model_version` newer than this kernel supports.
    #[error("unsupported word operation model_version {found} (supported up to {supported})")]
    FutureVersion {
        /// Version number found on the wire.
        found: u32,
        /// Highest version number supported by this build.
        supported: u32,
    },
    /// Malformed input or file read/write failure.
    #[error(transparent)]
    Error(#[from] Error),
}

/// Diagnostic entry for a picture that WordCraft could not load or decode on open.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct MissingPictureEntry {
    /// Relationship target or resolved part name of the missing picture.
    pub part: String,
    /// Source story part (`word/document.xml`, `word/header1.xml`, etc.) referencing the picture.
    pub story: String,
    /// Stable reason code (`missing_part`, `external_target`, `link_only`, `undecodable`, `unsupported_format`).
    pub reason: String,
}

/// Immutable host-neutral wrapper around an opened WordCraft document.
#[derive(Clone, Debug)]
pub struct WordDoc {
    pub(crate) doc: Arc<wordcraft_doc::Document>,
    pub(crate) macro_enabled: bool,
    pub(crate) missing_pictures: Arc<Vec<MissingPictureEntry>>,
}

impl PartialEq for WordDoc {
    fn eq(&self, other: &Self) -> bool {
        (Arc::ptr_eq(&self.doc, &other.doc) || self.doc == other.doc)
            && self.macro_enabled == other.macro_enabled
    }
}

impl WordDoc {
    pub(crate) fn from_parts(
        mut doc: wordcraft_doc::Document,
        macro_enabled: bool,
        missing_pictures: Arc<Vec<MissingPictureEntry>>,
    ) -> Self {
        doc.ensure_nonempty();
        let has_vba = doc.passthrough.contains_key("word/vbaProject.bin");
        Self {
            doc: Arc::new(doc),
            macro_enabled: macro_enabled || has_vba,
            missing_pictures,
        }
    }

    /// Borrows the underlying WordCraft document model.
    #[must_use]
    pub fn document(&self) -> &wordcraft_doc::Document {
        &self.doc
    }

    /// Returns `true` when the document originated from `.docm` or carries `word/vbaProject.bin`.
    #[must_use]
    pub fn is_macro_enabled(&self) -> bool {
        self.macro_enabled || self.doc.passthrough.contains_key("word/vbaProject.bin")
    }

    /// Returns diagnostic records for pictures that could not be loaded when the file was opened.
    #[must_use]
    pub fn missing_pictures(&self) -> &[MissingPictureEntry] {
        &self.missing_pictures
    }
}

/// Creates a blank `.docx` Word document with the given metadata title and returns both the
/// opened [`WordDoc`] and its serialized OOXML package bytes.
///
/// # Errors
///
/// Returns [`Error::Write`] if WordCraft fails to serialize the blank document package.
pub fn create_blank(title: &str) -> Result<(WordDoc, Vec<u8>), Error> {
    create_blank_with_macros(title, false)
}

/// Creates a blank `.docx` or macro-enabled `.docm` Word document with the given metadata title.
///
/// # Errors
///
/// Returns [`Error::Write`] if WordCraft fails to serialize the blank document package.
pub fn create_blank_with_macros(
    title: &str,
    macro_enabled: bool,
) -> Result<(WordDoc, Vec<u8>), Error> {
    let mut raw = wordcraft_engine::blank_document(&wordcraft_geom::Region::default());
    raw.core.title = title.to_string();
    raw.ensure_nonempty();
    let doc = WordDoc::from_parts(raw, macro_enabled, Arc::new(Vec::new()));
    let bytes = export_docx(&doc)?;
    Ok((doc, bytes))
}

/// Opens a `.docx` or `.docm` byte slice and replays a JSON array of uncompacted [`ChangeSet`]s.
///
/// # Errors
///
/// Returns [`ApplyError::Error`] if the package or operation JSON cannot be read,
/// [`ApplyError::FutureVersion`] if any operation exceeds [`MODEL_VERSION`], or
/// [`ApplyError::Conflict`] if an operation violates container or revision invariants.
pub fn open(bytes: &[u8], tail_ops_json: &str) -> Result<WordDoc, ApplyError> {
    open_with_checkpoint(bytes, tail_ops_json, None)
}

/// Opens a `.docx` or `.docm` byte slice, applies an optional compaction identity checkpoint, and
/// replays a JSON array of uncompacted [`ChangeSet`]s.
///
/// # Errors
///
/// Returns [`ApplyError::Error`] if the package, checkpoint JSON, or operation JSON cannot be
/// read, [`ApplyError::FutureVersion`] if any operation exceeds [`MODEL_VERSION`], or
/// [`ApplyError::Conflict`] if an operation violates container or revision invariants.
pub fn open_with_checkpoint(
    bytes: &[u8],
    tail_ops_json: &str,
    checkpoint_json: Option<&str>,
) -> Result<WordDoc, ApplyError> {
    let mut raw =
        wordcraft_docx::read(bytes).map_err(|e| ApplyError::Error(Error::Read(e.to_string())))?;
    if let Some(cp_json) = checkpoint_json {
        checkpoint::apply_json(&mut raw, cp_json)?;
    }
    let macro_enabled = detect_macro_enabled(bytes, &raw);
    let missing_pictures = Arc::new(extract_missing_pictures(&raw));
    let tail_ops = ops::parse_changeset_list(tail_ops_json)?;
    for op in &tail_ops {
        ops::execute_changeset(&mut raw, op)?;
    }
    raw.ensure_nonempty();
    Ok(WordDoc::from_parts(raw, macro_enabled, missing_pictures))
}

/// Computes the canonical unit-level [`ChangeSet`] that transforms `before` into `after`,
/// or `None` when the two documents have identical content.
///
/// # Errors
///
/// Returns [`Error::Invalid`] if a newly added media entry exceeds [`MAX_PICTURE_BYTES`] or if a
/// changed value cannot be serialized to JSON.
pub fn derive(before: &WordDoc, after: &WordDoc) -> Result<Option<ChangeSet>, Error> {
    derive::derive_changeset(before.document(), after.document())
}

/// Validates, rebases across `prior_ops_json`, stamps server-owned author metadata, and applies
/// `incoming_op_json` onto `doc` (which already reflects `prior_ops_json`).
///
/// # Errors
///
/// Returns [`ApplyError::Error`] when JSON is malformed or exceeds [`MAX_OP_BYTES`],
/// [`ApplyError::FutureVersion`] when `model_version > MODEL_VERSION`, or
/// [`ApplyError::Conflict`] when rebasing detects an overlapping edit or unbalanced markers.
pub fn apply(
    doc: &WordDoc,
    incoming_op_json: &str,
    prior_ops_json: &str,
    actor_name: Option<&str>,
) -> Result<Applied, ApplyError> {
    rebase::apply_with_rebase(doc, incoming_op_json, prior_ops_json, actor_name)
}

/// Exports `doc` as standard `.docm` when macro-enabled (or carrying `word/vbaProject.bin`) and
/// standard `.docx` otherwise.
///
/// # Errors
///
/// Returns [`Error::Write`] if WordCraft fails to encode the OOXML zip archive.
pub fn export_docx(doc: &WordDoc) -> Result<Vec<u8>, Error> {
    let flavor = if doc.is_macro_enabled() {
        wordcraft_docx::Flavor::MacroDocument
    } else {
        wordcraft_docx::Flavor::Document
    };
    wordcraft_docx::write_as(doc.document(), flavor).map_err(|e| Error::Write(e.to_string()))
}

/// Exports `doc` as standard `.docx`/`.docm` bytes and returns an optional compaction checkpoint
/// JSON sidecar that preserves internal story, media, drawing, and revision identities across
/// [`open_with_checkpoint`].
///
/// # Errors
///
/// Returns [`Error::Write`] if OOXML or checkpoint serialization fails, or [`Error::Read`] if
/// WordCraft cannot re-read the exported package to compute the identity bijection.
pub fn export_docx_with_checkpoint(doc: &WordDoc) -> Result<(Vec<u8>, Option<String>), Error> {
    let bytes = export_docx(doc)?;
    let reopened = wordcraft_docx::read(&bytes).map_err(|e| Error::Read(e.to_string()))?;
    let checkpoint_json = checkpoint::capture_json(doc.document(), &reopened)?;
    Ok((bytes, checkpoint_json))
}

pub(crate) fn extract_missing_pictures(doc: &wordcraft_doc::Document) -> Vec<MissingPictureEntry> {
    doc.missing_pictures
        .list
        .iter()
        .map(|item| MissingPictureEntry {
            part: item.part.clone(),
            story: item.story.clone(),
            reason: item.reason.code().to_string(),
        })
        .collect()
}

fn detect_macro_enabled(bytes: &[u8], doc: &wordcraft_doc::Document) -> bool {
    if doc.passthrough.contains_key("word/vbaProject.bin") {
        return true;
    }
    let cursor = std::io::Cursor::new(bytes);
    let Ok(mut archive) = zip::ZipArchive::new(cursor) else {
        return false;
    };
    let Ok(mut content_types) = archive.by_name("[Content_Types].xml") else {
        return false;
    };
    let mut xml = String::new();
    if content_types.read_to_string(&mut xml).is_err() {
        return false;
    }
    xml.contains("macroEnabled")
}

#[cfg(test)]
mod tests;
