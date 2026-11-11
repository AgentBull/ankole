//! Presentation documents for Ankole Presentation Pages (`.pptx`).
//!
//! This crate is the anti-corruption layer between Ankole and DeckCraft. The control plane loads
//! it through the kernel NIF and the browser loads it through `ankole_presentation_wasm`, so both
//! sides open the same `.pptx` bytes, replay the same canonical change sets, and rebase concurrent
//! slide edits with identical deterministic rules.
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

use std::sync::{Arc, Once};

use deckcraft_fonts::FontDb;
use deckcraft_model::Presentation;
use deckcraft_pdf::PdfOptions;
use deckcraft_render::RenderOpts;
use serde::{Deserialize, Serialize};

mod checkpoint;
mod commands;
mod derive;
mod doc;
mod editor;
mod inspect;
mod ops;
mod rebase;

pub use commands::{apply_commands, commands};
pub use derive::derive;
pub use doc::PresentationDoc;
pub use editor::EditorState;
pub use inspect::{FindMatch, find, inspect};
pub use ops::{ChangeSet, DeckField, Edit, InsertedSlide};
pub use rebase::apply;

/// Current serialized wire model version for presentation operations.
pub const MODEL_VERSION: u32 = 1;

/// Maximum serialized JSON byte size of one presentation [`ChangeSet`].
pub const MAX_OP_BYTES: usize = 4 * 1024 * 1024;

/// Maximum decoded byte size of a picture or media payload added via an operation.
pub const MAX_PICTURE_BYTES: usize = 2 * 1024 * 1024;

/// Maximum rendered pixel side allowed on a single slide rasterization.
const MAX_RENDER_SIDE_PX: f64 = 16_000.0;

/// Why an operation, import, export, or render request failed.
#[derive(Clone, Debug, PartialEq, Eq, thiserror::Error)]
pub enum Error {
    /// The operation or caller arguments are invalid.
    #[error("{0}")]
    Invalid(String),
    /// The `.pptx` bytes could not be read as a presentation.
    #[error("{0}")]
    Read(String),
    /// The presentation could not be exported or rendered.
    #[error("{0}")]
    Write(String),
}

/// Reason a concurrent presentation operation could not be rebased without guessing.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Conflict {
    /// Another commit edited the same slide (or a `slides.order` tried to delete an edited slide).
    SlideChanged,
    /// An earlier `slides.order` deleted the target slide.
    SlideDeleted,
    /// Two concurrent `slides.order` operations changed the deck's slide sequence.
    SlidesReordered,
    /// Two concurrent `deck.set` operations modified the same deck-wide field.
    FieldChanged,
    /// A newly allocated slide, shape, master, layout, or media identifier collided.
    IdentifierTaken,
}

impl Conflict {
    /// Canonical `snake_case` wire reason string reported in `office_conflict` payloads.
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::SlideChanged => "slide_changed",
            Self::SlideDeleted => "slide_deleted",
            Self::SlidesReordered => "slides_reordered",
            Self::FieldChanged => "field_changed",
            Self::IdentifierTaken => "identifier_taken",
        }
    }
}

/// Why [`open`] or [`apply`] refused an operation.
#[derive(Clone, Debug, PartialEq, Eq, thiserror::Error)]
pub enum ApplyError {
    /// Rebasing the operation over concurrent commits encountered a unit or identifier conflict.
    #[error("operation conflicts with an earlier commit: {}", .0.as_str())]
    Conflict(Conflict),
    /// An operation carries a `model_version` newer than [`MODEL_VERSION`].
    #[error("operation model_version {found} exceeds supported version {supported}")]
    FutureVersion {
        /// Version number found on the operation.
        found: u32,
        /// Highest version number supported by this kernel build.
        supported: u32,
    },
    /// The file or operation is malformed or invalid.
    #[error(transparent)]
    Error(#[from] Error),
}

/// Result of committing one rebased [`ChangeSet`] via [`apply`].
#[derive(Clone, Debug)]
pub struct Applied {
    /// Resulting presentation document; the input document remains unchanged.
    pub doc: PresentationDoc,
    /// Committed change set (with server-stamped comment authors when provided).
    pub op: ChangeSet,
    /// True when [`Applied::op`] contains at least one `media.put` edit.
    pub carries_media: bool,
}

/// Ensures DeckCraft's global `FontDb` is initialized without host system font directories and
/// with lazy system fallback disabled so layout, rendering, and PDF export never scan host fonts.
pub(crate) fn ensure_isolated_fonts() {
    let _ = FontDb::init_without_system_fonts();
}

/// Initializes DeckCraft's process-wide [`FontDb`] once from the pinned site-wide font blobs, with
/// host system font fallback disabled. Never loads per-document embedded fonts on the server.
pub fn init_site_fonts(font_blobs: &[Vec<u8>]) {
    static INIT: Once = Once::new();
    ensure_isolated_fonts();
    INIT.call_once(|| {
        let db = FontDb::global();
        db.set_system_fallback(false);
        for blob in font_blobs {
            let _ = db.add_font(blob.clone());
        }
    });
}

/// Creates a clean 1-slide blank presentation with `title` and exports its `.pptx` bytes.
///
/// # Errors
///
/// Returns [`Error::Write`] if DeckCraft fails to serialize the blank `.pptx` archive.
pub fn create_blank(title: &str) -> Result<(PresentationDoc, Vec<u8>), Error> {
    PresentationDoc::blank_with_bytes(title)
}

/// Imports `.pptx` bytes with `deckcraft_pptx::import_checked`, replays committed `tail_ops_json`
/// in order while verifying `model_version`, updates `next_id`, and returns the opened document.
///
/// # Errors
///
/// Returns [`ApplyError::Error`] if `bytes` cannot be decoded or a replayed operation is invalid,
/// and [`ApplyError::FutureVersion`] if any replayed operation has `model_version > MODEL_VERSION`.
pub fn open(bytes: &[u8], tail_ops_json: &str) -> Result<PresentationDoc, ApplyError> {
    open_with_checkpoint(bytes, tail_ops_json, None)
}

/// Imports `.pptx` bytes with `deckcraft_pptx::import_checked`, applies an optional compaction
/// identity checkpoint, replays committed `tail_ops_json` in order while verifying `model_version`,
/// updates `next_id`, and returns the opened document.
///
/// # Errors
///
/// Returns [`ApplyError::Error`] if `bytes` or `checkpoint_json` cannot be decoded or a replayed
/// operation is invalid, and [`ApplyError::FutureVersion`] if any replayed operation has
/// `model_version > MODEL_VERSION`.
pub fn open_with_checkpoint(
    bytes: &[u8],
    tail_ops_json: &str,
    checkpoint_json: Option<&str>,
) -> Result<PresentationDoc, ApplyError> {
    let tail_ops = ops::parse_changeset_list(tail_ops_json)?;
    let base = PresentationDoc::read_pptx(bytes)?;
    let has_checkpoint = checkpoint_json.is_some_and(|cp| !cp.trim().is_empty());
    if tail_ops.is_empty() && !has_checkpoint {
        return Ok(base);
    }
    let mut pres = base.presentation().clone();
    if let Some(cp_json) = checkpoint_json {
        checkpoint::apply_json(&mut pres, cp_json)?;
    }
    for cs in &tail_ops {
        pres = ops::apply_changeset_to_presentation(&pres, cs)?;
    }
    pres.fix_next_id();
    Ok(PresentationDoc::from_parts(
        Arc::new(pres),
        Arc::clone(base.warnings_arc()),
    ))
}

/// Exports `doc` as standard `.pptx` package bytes.
///
/// # Errors
///
/// Returns [`Error::Write`] if DeckCraft cannot serialize the presentation package.
pub fn export_pptx(doc: &PresentationDoc) -> Result<Vec<u8>, Error> {
    deckcraft_pptx::export(doc.presentation())
        .map_err(|err| Error::Write(format!("failed to export pptx: {err}")))
}

/// Exports `doc` as standard `.pptx` package bytes and returns an optional compaction checkpoint
/// JSON sidecar that preserves internal slide, shape, layout, master, and media identifiers across
/// [`open_with_checkpoint`].
///
/// # Errors
///
/// Returns [`Error::Write`] if OOXML or checkpoint serialization fails, or [`Error::Read`] if
/// DeckCraft cannot re-import the exported package to compute the identity bijection.
pub fn export_pptx_with_checkpoint(
    doc: &PresentationDoc,
) -> Result<(Vec<u8>, Option<String>), Error> {
    let bytes = export_pptx(doc)?;
    let reopened = PresentationDoc::read_pptx(&bytes)?;
    let checkpoint_json = checkpoint::capture_json(doc.presentation(), reopened.presentation())?;
    Ok((bytes, checkpoint_json))
}

/// Exports `doc` as PDF bytes using DeckCraft's vector PDF writer.
///
/// # Errors
///
/// Returns [`Error::Write`] if DeckCraft fails to write the PDF document.
pub fn export_pdf(doc: &PresentationDoc) -> Result<Vec<u8>, Error> {
    ensure_isolated_fonts();
    deckcraft_pdf::export(doc.presentation(), &PdfOptions::default())
        .map_err(|err| Error::Write(format!("failed to export pdf: {err}")))
}

/// Renders `slide_index` at `scale` into `(png_bytes, width_px, height_px, slide_count)`.
///
/// # Errors
///
/// Returns [`Error::Invalid`] if `slide_index` is out of bounds or `scale` is non-positive or
/// non-finite, and [`Error::Write`] if PNG encoding fails.
pub fn render_slide_png_meta(
    doc: &PresentationDoc,
    slide_index: usize,
    scale: f32,
) -> Result<(Vec<u8>, u32, u32, usize), Error> {
    let pres = doc.presentation();
    let count = pres.slides.len();
    let (img, eff_scale) = render_slide_image(pres, slide_index, scale)?;
    let png = img.to_png_at(deckcraft_render::dpi_for_scale(eff_scale));
    if png.is_empty() {
        return Err(Error::Write("failed to encode slide PNG".into()));
    }
    Ok((png, img.width, img.height, count))
}

/// Renders `slide_index` at `scale` into encoded PNG bytes.
///
/// # Errors
///
/// Returns [`Error::Invalid`] if `slide_index` is out of bounds or `scale` is non-positive or
/// non-finite, and [`Error::Write`] if PNG encoding fails.
pub fn render_slide_png(
    doc: &PresentationDoc,
    slide_index: usize,
    scale: f32,
) -> Result<Vec<u8>, Error> {
    render_slide_png_meta(doc, slide_index, scale).map(|(png, ..)| png)
}

/// Renders `slide_index` at `scale` into `(width, height, straight_rgba_bytes)`.
///
/// # Errors
///
/// Returns [`Error::Invalid`] if `slide_index` is out of bounds or `scale` is non-positive or
/// non-finite.
pub fn render_slide_rgba(
    doc: &PresentationDoc,
    slide_index: usize,
    scale: f32,
) -> Result<(u32, u32, Vec<u8>), Error> {
    let (img, _) = render_slide_image(doc.presentation(), slide_index, scale)?;
    Ok((img.width, img.height, img.to_straight()))
}

pub(crate) fn slide_pixel_dimensions(pres: &Presentation, scale: f32) -> Result<(u32, u32), Error> {
    let eff = clamped_scale(pres, scale)?;
    let w = (pres.slide_size.width * eff).round().max(1.0) as u32;
    let h = (pres.slide_size.height * eff).round().max(1.0) as u32;
    Ok((w, h))
}

fn clamped_scale(pres: &Presentation, scale: f32) -> Result<f64, Error> {
    if !scale.is_finite() || scale <= 0.0 {
        return Err(Error::Invalid(format!(
            "render scale must be a finite positive number, got {scale}"
        )));
    }
    let requested = f64::from(scale);
    let max_dim = pres.slide_size.width.max(pres.slide_size.height).max(1.0);
    Ok(requested.min(MAX_RENDER_SIDE_PX / max_dim))
}

fn render_slide_image(
    pres: &Presentation,
    slide_index: usize,
    scale: f32,
) -> Result<(deckcraft_render::Image, f64), Error> {
    ensure_isolated_fonts();
    if slide_index >= pres.slides.len() {
        return Err(Error::Invalid(format!(
            "slide index {slide_index} out of bounds (slide_count = {})",
            pres.slides.len()
        )));
    }
    let eff_scale = clamped_scale(pres, scale)?;
    let opts = RenderOpts {
        scale: eff_scale,
        ..RenderOpts::default()
    };
    let img = deckcraft_render::render_slide(pres, slide_index, &opts);
    Ok((img, eff_scale))
}

#[cfg(test)]
mod tests;
