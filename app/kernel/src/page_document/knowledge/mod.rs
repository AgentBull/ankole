//! Knowledge pages use the Markdown-representable subset of the page vocabulary.
//! Business frontmatter is independent from the page's internal synchronization state.
mod document;
mod merge;
mod read;
mod write;

pub use document::{Knowledge, export, overview, parse, validate};
pub use merge::merge;

#[cfg(test)]
mod tests;
