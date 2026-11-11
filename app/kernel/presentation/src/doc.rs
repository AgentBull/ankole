//! Copy-on-write presentation document wrapper.

use std::sync::Arc;

use deckcraft_model::Presentation;

use crate::Error;

/// An immutable, cheaply cloneable presentation document and any import warnings.
#[derive(Clone, Debug)]
pub struct PresentationDoc {
    inner: Arc<Presentation>,
    warnings: Arc<Vec<String>>,
}

impl PresentationDoc {
    /// Wraps an existing [`Presentation`] and import warning list, ensuring `next_id` exceeds all
    /// live identifiers.
    #[must_use]
    pub fn from_presentation(mut pres: Presentation, warnings: Vec<String>) -> Self {
        pres.fix_next_id();
        Self {
            inner: Arc::new(pres),
            warnings: Arc::new(warnings),
        }
    }

    /// Wraps an already-normalized `Arc<Presentation>` and shared warning list.
    pub(crate) fn from_parts(inner: Arc<Presentation>, warnings: Arc<Vec<String>>) -> Self {
        Self { inner, warnings }
    }

    /// Creates a clean blank 1-slide presentation with `title` stored in its core properties,
    /// round-tripped through `deckcraft_pptx` so its in-memory identifiers match [`Self::read_pptx`]
    /// on the exported `.pptx` bytes.
    ///
    /// # Errors
    ///
    /// Returns [`Error::Write`] if exporting the blank `.pptx` fails, or [`Error::Read`] if
    /// importing the exported bytes fails.
    pub fn blank_with_bytes(title: &str) -> Result<(Self, Vec<u8>), Error> {
        let mut pres = Presentation::default();
        pres.props.title = title.to_string();
        pres.fix_next_id();
        let bytes = deckcraft_pptx::export(&pres)
            .map_err(|err| Error::Write(format!("failed to export blank pptx: {err}")))?;
        let doc = Self::read_pptx(&bytes)?;
        Ok((doc, bytes))
    }

    /// Reads `.pptx` package bytes without touching the global font database.
    ///
    /// # Errors
    ///
    /// Returns [`Error::Read`] if `bytes` cannot be decoded as an unencrypted `.pptx` package.
    pub fn read_pptx(bytes: &[u8]) -> Result<Self, Error> {
        let (mut pres, lost_slides) = deckcraft_pptx::import_checked(bytes)
            .map_err(|err| Error::Read(format!("the presentation could not be read: {err}")))?;
        pres.fix_next_id();
        Ok(Self {
            inner: Arc::new(pres),
            warnings: Arc::new(lost_slides),
        })
    }

    /// Borrows the underlying DeckCraft [`Presentation`].
    #[must_use]
    pub fn presentation(&self) -> &Presentation {
        &self.inner
    }

    /// Borrows the shared [`Arc`] holding the underlying [`Presentation`].
    #[must_use]
    pub fn presentation_arc(&self) -> &Arc<Presentation> {
        &self.inner
    }

    /// Borrows the slide part names or import warnings reported when the file was opened.
    #[must_use]
    pub fn warnings(&self) -> &[String] {
        &self.warnings
    }

    /// Borrows the shared [`Arc`] holding the document's import warnings.
    pub(crate) fn warnings_arc(&self) -> &Arc<Vec<String>> {
        &self.warnings
    }
}
