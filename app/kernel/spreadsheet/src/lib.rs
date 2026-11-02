//! Spreadsheet documents for Pod spreadsheet pages.
//!
//! This crate is the anti-corruption layer between Ankole and GridCraft. The control plane loads it
//! through the kernel NIF and the browser loads it through the WebAssembly build, so both sides open
//! the same `.xlsx` bytes, replay the same canonical operations, and rebase concurrent operations
//! with the same code. The crate holds no durable state: the caller owns the authoritative file and
//! the operation log, and every function here is a pure transformation of them.
//!
//! Documents are copy-on-write. [`apply`] returns a new [`SpreadsheetDoc`] and leaves its input
//! valid, so a host can keep serving reads from the old document while it commits the new one.
#![forbid(unsafe_code)]
// Input from the hosts must never panic, every public item is documented, and pure functions are
// marked so that ignoring their result is a warning (Google's Rust style guide).
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

mod clipboard;
mod doc;
mod functions;
mod index;
mod ops;
mod rebase;
mod structure;
mod view;

pub use clipboard::{
    ClipboardBlock, ClipboardCell, MAX_CLIPBOARD_CELLS, PasteMode, copy_block, paste_op,
};
pub use doc::SpreadsheetDoc;
pub use functions::{FunctionInfo, functions};
pub use index::{Metadata, PLAIN_TEXT_LIMIT, SheetSummary};
pub use ops::{
    FillMode, FormatPatch, ImageAnchor, MAX_PICTURE_BYTES, Op, PasteCell, Picture, PictureMime,
    StructuralEdit,
};
pub use rebase::Conflict;
pub use view::{
    CellPictureData, RenderCell, RenderImage, RenderStyle, SelectionStats, SheetInfo, Viewport,
    cell_input, cell_picture, image_data, images, selection_stats, sheets, viewport,
};

/// Why an input was refused. Every variant carries a message for the caller's error response.
#[derive(Debug, thiserror::Error, PartialEq, Eq)]
pub enum Error {
    /// The operation or its arguments are invalid for the document.
    #[error("{0}")]
    Invalid(String),
    /// The `.xlsx` bytes could not be read as a workbook.
    #[error("the workbook could not be read: {0}")]
    Read(String),
    /// The workbook could not be written as `.xlsx`.
    #[error("the workbook could not be written: {0}")]
    Write(String),
}

impl Error {
    pub(crate) fn invalid(message: impl Into<String>) -> Self {
        Error::Invalid(message.into())
    }
}

/// Why [`apply`] refused an incoming operation.
#[derive(Debug, PartialEq, Eq)]
pub enum ApplyError {
    /// Rebasing the operation over concurrent commits would have to guess, so the caller must
    /// resynchronize and let the author confirm the edit again.
    Conflict(Conflict),
    /// The operation is invalid on its own or against the document.
    Error(Error),
}

impl From<Error> for ApplyError {
    fn from(error: Error) -> Self {
        ApplyError::Error(error)
    }
}

/// The result of committing one operation.
#[derive(Debug)]
pub struct Applied {
    /// The document after the operation; the input document is unchanged.
    pub doc: SpreadsheetDoc,
    /// The operation as committed: rebased onto the latest revision and normalized (assigned sheet
    /// ids and names filled in), so replaying it on the same base gives the same document.
    pub op: Op,
    /// How the operation moved rows, columns, or blocks, when it did.
    pub structural_edit: Option<StructuralEdit>,
}

/// A serialized workbook with the search text and outline derived from it.
#[derive(Debug)]
pub struct Exported {
    /// The workbook as `.xlsx` bytes.
    pub xlsx: Vec<u8>,
    /// The search text, as [`plain_text`] returns it.
    pub plain_text: String,
    /// The sheet outline, as [`metadata`] returns it.
    pub metadata: Metadata,
}

/// Creates a workbook with one empty sheet whose `sheet_id` is 1.
///
/// # Errors
///
/// Returns an [`Error`] when GridCraft cannot build or write the blank workbook.
pub fn create_blank(title: &str) -> Result<(SpreadsheetDoc, Exported), Error> {
    let doc = SpreadsheetDoc::blank(title)?;
    let exported = export_xlsx(&doc)?;
    Ok((doc, exported))
}

/// Reads `.xlsx` bytes and replays the committed operations that are not yet compacted into them.
///
/// `tail_ops` is a JSON array of committed operations in revision order. They replay without
/// rebasing because each one was already rebased when it was committed.
///
/// # Errors
///
/// Returns [`Error::Read`] when `bytes` is not a readable workbook, and [`Error::Invalid`] when
/// `tail_ops` is not a list of operations that apply to it.
pub fn open(bytes: &[u8], tail_ops: &str) -> Result<SpreadsheetDoc, Error> {
    let tail = ops::parse_list(tail_ops)?;
    let mut doc = SpreadsheetDoc::read(bytes)?;
    for op in tail {
        doc = commit(&doc, op)?.doc;
    }
    Ok(doc)
}

/// Rebases `incoming_op` over `prior_ops` and applies it to `doc`.
///
/// `doc` must be the document at the latest revision, and `prior_ops` (a JSON array) must hold the
/// operations committed after the revision the author based `incoming_op` on, in revision order.
///
/// # Errors
///
/// Returns [`ApplyError::Conflict`] when rebasing would have to guess, and
/// [`ApplyError::Error`] when the operation or `prior_ops` is invalid for the document.
pub fn apply(
    doc: &SpreadsheetDoc,
    incoming_op: &str,
    prior_ops: &str,
) -> Result<Applied, ApplyError> {
    let op = ops::parse(incoming_op)?;
    let prior = ops::parse_list(prior_ops)?;
    let op = rebase::rebase(doc.workbook(), op, &prior)?;
    Ok(commit(doc, op)?)
}

/// Serializes the document and derives its search text and outline.
///
/// # Errors
///
/// Returns [`Error::Write`] when GridCraft cannot write the workbook.
pub fn export_xlsx(doc: &SpreadsheetDoc) -> Result<Exported, Error> {
    let xlsx = gridcraft_xlsx::write_xlsx(doc.workbook())
        .map_err(|error| Error::Write(error.to_string()))?;
    Ok(Exported {
        xlsx,
        plain_text: plain_text(doc),
        metadata: metadata(doc),
    })
}

/// The document's search text: sheet names, constant text cells, and notes, at most
/// [`PLAIN_TEXT_LIMIT`] bytes.
#[must_use]
pub fn plain_text(doc: &SpreadsheetDoc) -> String {
    index::plain_text(doc.workbook())
}

/// The document's sheet outline and what reading its source file reported.
#[must_use]
pub fn metadata(doc: &SpreadsheetDoc) -> Metadata {
    index::metadata(doc)
}

fn commit(doc: &SpreadsheetDoc, mut op: Op) -> Result<Applied, Error> {
    let next = doc.execute(&mut op)?;
    let structural_edit = op.structural_edit();
    Ok(Applied {
        doc: next,
        op,
        structural_edit,
    })
}
