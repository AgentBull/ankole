//! Canonical wire types, validation, author stamping, and execution for Word change sets.

use std::collections::BTreeSet;
use std::sync::Arc;

use serde::{Deserialize, Serialize};
use serde_json::Value;
use wordcraft_doc::{
    Block, BuildingBlock, Comment, CoreProps, CustomProp, Document, NoteSeparators, Numbering,
    Paragraph, Part, Revision, SectionProps, Source, StoryRef, StyleSheet,
};

use crate::{ApplyError, Conflict, Error, MAX_OP_BYTES, MAX_PICTURE_BYTES, MODEL_VERSION, WordDoc};

/// Result of successfully rebasing and committing one [`ChangeSet`] via [`crate::apply`].
#[derive(Clone, Debug, PartialEq)]
pub struct Applied {
    /// Updated Word document after applying the rebased and author-stamped change set.
    pub doc: WordDoc,
    /// Canonical rebased and author-stamped change set to persist in `pod_office_ops`.
    pub op: ChangeSet,
    /// Whether the committed change set writes binary bytes to `media` or `passthrough`.
    pub carries_media: bool,
}

/// Keyed map container targeted by [`Edit::EntryPut`] and [`Edit::EntryDelete`].
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum EntryMap {
    /// `Document::parts` keyed by `u32` story part identifier.
    Parts,
    /// `Document::comments` keyed by `u32` comment identifier.
    Comments,
    /// `Document::media` keyed by media name, base64-encoded on the wire.
    Media,
    /// `Document::passthrough` keyed by archive path, base64-encoded on the wire.
    Passthrough,
}

/// Document-wide value targeted by [`Edit::FieldSet`].
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum DocField {
    /// `Document::styles`.
    Styles,
    /// `Document::numbering`.
    Numbering,
    /// `Document::settings`.
    Settings,
    /// `Document::core`.
    Core,
    /// `Document::last_section`.
    LastSection,
    /// `Document::sources`.
    Sources,
    /// `Document::custom_props`.
    CustomProps,
    /// `Document::glossary`.
    Glossary,
    /// `Document::footnote_separators`.
    FootnoteSeparators,
    /// `Document::endnote_separators`.
    EndnoteSeparators,
    /// `Document::revisions` (full replacement for accept-all / reject-all).
    Revisions,
}

/// One atomic unit edit inside a [`ChangeSet`].
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(tag = "kind")]
pub enum Edit {
    /// Replaces `delete` top-level blocks starting at `at` in `story` with `insert`.
    #[serde(rename = "blocks.splice")]
    BlocksSplice {
        /// Target story (`"body"` or `{"part": id}`).
        story: StoryRef,
        /// Zero-based starting top-level block index.
        at: usize,
        /// Number of existing top-level blocks to remove.
        delete: usize,
        /// Replacement top-level blocks (`Paragraph` or `Table`).
        insert: Vec<Block>,
    },
    /// Inserts or replaces a single entry in `parts`, `comments`, `media`, or `passthrough`.
    #[serde(rename = "entry.put")]
    EntryPut {
        /// Target keyed map.
        map: EntryMap,
        /// Map key (`u32` string for `parts` and `comments`, string key for `media` and `passthrough`).
        key: String,
        /// Entry payload (`Part`, `Comment`, or standard base64 string for binary maps).
        value: Value,
    },
    /// Removes a single entry from `parts`, `comments`, `media`, or `passthrough`.
    #[serde(rename = "entry.delete")]
    EntryDelete {
        /// Target keyed map.
        map: EntryMap,
        /// Key to remove.
        key: String,
    },
    /// Appends tracked-change revision records starting at expected length `from`.
    #[serde(rename = "revisions.append")]
    RevisionsAppend {
        /// Expected length of `Document::revisions` prior to appending.
        from: usize,
        /// Newly appended revision records.
        items: Vec<Revision>,
    },
    /// Replaces one document-wide field value.
    #[serde(rename = "field.set")]
    FieldSet {
        /// Target document-wide field.
        field: DocField,
        /// Replacement field value.
        value: Value,
    },
}

/// Ordered list of unit-level edits committed or rejected together as a single operation.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct ChangeSet {
    /// Wire model version of the kernel that produced this change set.
    pub model_version: u32,
    /// Ordered unit-level edits.
    pub edits: Vec<Edit>,
}

impl ChangeSet {
    /// Returns `true` when any edit writes binary bytes to `media` or `passthrough`.
    #[must_use]
    pub fn carries_media(&self) -> bool {
        self.edits.iter().any(|edit| {
            matches!(
                edit,
                Edit::EntryPut {
                    map: EntryMap::Media | EntryMap::Passthrough,
                    ..
                }
            )
        })
    }
}

#[derive(Deserialize)]
struct VersionProbe {
    model_version: u32,
}

pub(crate) fn check_version(version: u32) -> Result<(), ApplyError> {
    if version > MODEL_VERSION {
        return Err(ApplyError::FutureVersion {
            found: version,
            supported: MODEL_VERSION,
        });
    }
    if version == 0 {
        return Err(ApplyError::Error(Error::Invalid(
            "model_version must be >= 1".to_string(),
        )));
    }
    Ok(())
}

pub(crate) fn parse_incoming_changeset(json_str: &str) -> Result<ChangeSet, ApplyError> {
    if json_str.len() > MAX_OP_BYTES {
        return Err(ApplyError::Error(Error::Invalid(format!(
            "operation size {} exceeds maximum {} bytes",
            json_str.len(),
            MAX_OP_BYTES
        ))));
    }
    // Check `model_version` first so future-version wire payloads with unknown edit variants
    // still report `ApplyError::FutureVersion` instead of a serde parse error.
    let probe: VersionProbe = serde_json::from_str(json_str)
        .map_err(|e| ApplyError::Error(Error::Invalid(format!("invalid changeset JSON: {e}"))))?;
    check_version(probe.model_version)?;

    let cs: ChangeSet = serde_json::from_str(json_str)
        .map_err(|e| ApplyError::Error(Error::Invalid(format!("invalid changeset JSON: {e}"))))?;
    validate_changeset(&cs)?;
    Ok(cs)
}

pub(crate) fn parse_changeset_list(json_str: &str) -> Result<Vec<ChangeSet>, ApplyError> {
    let trimmed = json_str.trim();
    if trimmed.is_empty() {
        return Ok(Vec::new());
    }
    let raw_items: Vec<Value> = serde_json::from_str(trimmed).map_err(|e| {
        ApplyError::Error(Error::Invalid(format!("invalid changeset list JSON: {e}")))
    })?;
    let mut out = Vec::with_capacity(raw_items.len());
    for item in raw_items {
        let version = item
            .get("model_version")
            .and_then(Value::as_u64)
            .and_then(|v| u32::try_from(v).ok())
            .ok_or_else(|| {
                ApplyError::Error(Error::Invalid(
                    "changeset missing valid u32 model_version".to_string(),
                ))
            })?;
        check_version(version)?;
        let cs: ChangeSet = serde_json::from_value(item).map_err(|e| {
            ApplyError::Error(Error::Invalid(format!("invalid changeset entry: {e}")))
        })?;
        validate_changeset(&cs)?;
        out.push(cs);
    }
    Ok(out)
}

pub(crate) fn validate_changeset(cs: &ChangeSet) -> Result<(), ApplyError> {
    check_version(cs.model_version)?;
    for edit in &cs.edits {
        match edit {
            Edit::EntryPut { map, key, value } => match map {
                EntryMap::Parts => {
                    parse_u32_key(key, "parts")?;
                    let _: Part = serde_json::from_value(value.clone()).map_err(|e| {
                        ApplyError::Error(Error::Invalid(format!("invalid part `{key}`: {e}")))
                    })?;
                }
                EntryMap::Comments => {
                    parse_u32_key(key, "comments")?;
                    let _: Comment = serde_json::from_value(value.clone()).map_err(|e| {
                        ApplyError::Error(Error::Invalid(format!("invalid comment `{key}`: {e}")))
                    })?;
                }
                EntryMap::Media => {
                    if key.is_empty() {
                        return Err(ApplyError::Error(Error::Invalid(
                            "media key cannot be empty".to_string(),
                        )));
                    }
                    let decoded = decode_base64_value(value, "media")?;
                    if decoded.len() > MAX_PICTURE_BYTES {
                        return Err(ApplyError::Error(Error::Invalid(format!(
                            "picture `{key}` size {} exceeds maximum {} bytes",
                            decoded.len(),
                            MAX_PICTURE_BYTES
                        ))));
                    }
                }
                EntryMap::Passthrough => {
                    if key.is_empty() {
                        return Err(ApplyError::Error(Error::Invalid(
                            "passthrough key cannot be empty".to_string(),
                        )));
                    }
                    let _ = decode_base64_value(value, "passthrough")?;
                }
            },
            Edit::EntryDelete { map, key } => match map {
                EntryMap::Parts => {
                    parse_u32_key(key, "parts")?;
                }
                EntryMap::Comments => {
                    parse_u32_key(key, "comments")?;
                }
                EntryMap::Media | EntryMap::Passthrough => {
                    if key.is_empty() {
                        return Err(ApplyError::Error(Error::Invalid(
                            "entry.delete key cannot be empty".to_string(),
                        )));
                    }
                }
            },
            Edit::BlocksSplice { .. } | Edit::RevisionsAppend { .. } | Edit::FieldSet { .. } => {}
        }
    }
    Ok(())
}

pub(crate) fn parse_u32_key(key: &str, map_name: &str) -> Result<u32, ApplyError> {
    key.parse::<u32>().map_err(|e| {
        ApplyError::Error(Error::Invalid(format!(
            "invalid {map_name} key `{key}`: {e}"
        )))
    })
}

fn decode_base64_value(value: &Value, label: &str) -> Result<Vec<u8>, ApplyError> {
    let encoded = value.as_str().ok_or_else(|| {
        ApplyError::Error(Error::Invalid(format!(
            "{label} value must be a base64 string"
        )))
    })?;
    base64_simd::STANDARD
        .decode_to_vec(encoded)
        .map_err(|e| ApplyError::Error(Error::Invalid(format!("invalid {label} base64: {e}"))))
}

pub(crate) fn derive_initials(name: &str) -> String {
    name.split_whitespace()
        .filter_map(|word| word.chars().next())
        .collect()
}

/// Stamps `actor_name` onto newly appended revisions and newly added comments (or newly added
/// comment replies) in `cs`, updating `cs` in place so the persisted operation matches memory.
pub(crate) fn stamp_actor(
    cs: &mut ChangeSet,
    existing_doc: &Document,
    actor_name: Option<&str>,
) -> Result<(), ApplyError> {
    let Some(actor) = actor_name else {
        return Ok(());
    };
    let initials = derive_initials(actor);
    let mut seen_new_comments: BTreeSet<u32> = BTreeSet::new();

    for edit in &mut cs.edits {
        match edit {
            Edit::RevisionsAppend { items, .. } => {
                for rev in items {
                    rev.author = actor.to_string();
                }
            }
            Edit::EntryPut {
                map: EntryMap::Comments,
                key,
                value,
            } => {
                let id = parse_u32_key(key, "comments")?;
                let mut comment: Comment = serde_json::from_value(value.clone()).map_err(|e| {
                    ApplyError::Error(Error::Invalid(format!("invalid comment `{key}`: {e}")))
                })?;
                let is_new =
                    !existing_doc.comments.contains_key(&id) || seen_new_comments.contains(&id);
                if is_new {
                    seen_new_comments.insert(id);
                    comment.author = actor.to_string();
                    comment.initials.clone_from(&initials);
                }
                *value = serde_json::to_value(&comment).map_err(|e| {
                    ApplyError::Error(Error::Invalid(format!(
                        "failed to serialize stamped comment `{key}`: {e}"
                    )))
                })?;
            }
            _ => {}
        }
    }
    Ok(())
}

fn normalize_block_runs(block: &mut Block) {
    match block {
        Block::Para(p) => p.normalize(),
        Block::Table(t) => {
            for row in &mut t.rows {
                for cell in &mut row.cells {
                    for child in &mut cell.blocks {
                        normalize_block_runs(Arc::make_mut(child));
                    }
                    if cell.blocks.is_empty() {
                        cell.blocks.push(Arc::new(Block::Para(Paragraph::new())));
                    }
                }
            }
        }
    }
}

/// Applies all edits of `cs` in order onto `doc`.
pub(crate) fn execute_changeset(doc: &mut Document, cs: &ChangeSet) -> Result<(), ApplyError> {
    for edit in &cs.edits {
        match edit {
            Edit::BlocksSplice {
                story,
                at,
                delete,
                insert,
            } => {
                let blocks = match story {
                    StoryRef::Body => &mut doc.body,
                    StoryRef::Part(id) => doc
                        .parts
                        .get_mut(id)
                        .map(|p| &mut p.blocks)
                        .ok_or(ApplyError::Conflict(Conflict::ContainerDeleted))?,
                };
                let end = at.checked_add(*delete).ok_or_else(|| {
                    ApplyError::Error(Error::Invalid("blocks.splice span overflow".to_string()))
                })?;
                if end > blocks.len() {
                    return Err(ApplyError::Error(Error::Invalid(format!(
                        "blocks.splice out of bounds: at={at}, delete={delete}, len={}",
                        blocks.len()
                    ))));
                }
                let normalized: Vec<Arc<Block>> = insert
                    .iter()
                    .cloned()
                    .map(|mut b| {
                        normalize_block_runs(&mut b);
                        Arc::new(b)
                    })
                    .collect();
                blocks.splice(*at..end, normalized);
                if blocks.is_empty() {
                    blocks.push(Arc::new(Block::Para(Paragraph::new())));
                }
            }
            Edit::EntryPut { map, key, value } => match map {
                EntryMap::Parts => {
                    let id = parse_u32_key(key, "parts")?;
                    let mut part: Part = serde_json::from_value(value.clone()).map_err(|e| {
                        ApplyError::Error(Error::Invalid(format!("invalid part `{key}`: {e}")))
                    })?;
                    for blk in &mut part.blocks {
                        normalize_block_runs(Arc::make_mut(blk));
                    }
                    if part.blocks.is_empty() {
                        part.blocks.push(Arc::new(Block::Para(Paragraph::new())));
                    }
                    doc.parts.insert(id, part);
                }
                EntryMap::Comments => {
                    let id = parse_u32_key(key, "comments")?;
                    let comment: Comment = serde_json::from_value(value.clone()).map_err(|e| {
                        ApplyError::Error(Error::Invalid(format!("invalid comment `{key}`: {e}")))
                    })?;
                    doc.comments.insert(id, comment);
                }
                EntryMap::Media => {
                    let bytes = decode_base64_value(value, "media")?;
                    if bytes.len() > MAX_PICTURE_BYTES {
                        return Err(ApplyError::Error(Error::Invalid(format!(
                            "picture `{key}` size {} exceeds maximum {} bytes",
                            bytes.len(),
                            MAX_PICTURE_BYTES
                        ))));
                    }
                    doc.media.insert(key.clone(), Arc::new(bytes));
                }
                EntryMap::Passthrough => {
                    let bytes = decode_base64_value(value, "passthrough")?;
                    doc.passthrough.insert(key.clone(), Arc::new(bytes));
                }
            },
            Edit::EntryDelete { map, key } => match map {
                EntryMap::Parts => {
                    let id = parse_u32_key(key, "parts")?;
                    doc.parts.remove(&id);
                }
                EntryMap::Comments => {
                    let id = parse_u32_key(key, "comments")?;
                    doc.comments.remove(&id);
                }
                EntryMap::Media => {
                    doc.media.remove(key);
                }
                EntryMap::Passthrough => {
                    doc.passthrough.remove(key);
                }
            },
            Edit::RevisionsAppend { from, items } => {
                if doc.revisions.len() != *from {
                    return Err(ApplyError::Conflict(Conflict::ConcurrentRevision));
                }
                doc.revisions.extend(items.iter().cloned());
            }
            Edit::FieldSet { field, value } => {
                apply_field_set(doc, *field, value)?;
            }
        }
    }
    Ok(())
}

fn apply_field_set(doc: &mut Document, field: DocField, value: &Value) -> Result<(), ApplyError> {
    let invalid = |name: &str, err: serde_json::Error| {
        ApplyError::Error(Error::Invalid(format!("invalid field `{name}`: {err}")))
    };
    match field {
        DocField::Styles => {
            let styles: StyleSheet =
                serde_json::from_value(value.clone()).map_err(|e| invalid("styles", e))?;
            doc.styles = Arc::new(styles);
        }
        DocField::Numbering => {
            let numbering: Numbering =
                serde_json::from_value(value.clone()).map_err(|e| invalid("numbering", e))?;
            doc.numbering = Arc::new(numbering);
        }
        DocField::Settings => {
            doc.settings =
                serde_json::from_value(value.clone()).map_err(|e| invalid("settings", e))?;
        }
        DocField::Core => {
            let core: CoreProps =
                serde_json::from_value(value.clone()).map_err(|e| invalid("core", e))?;
            doc.core = core;
        }
        DocField::LastSection => {
            let section: SectionProps =
                serde_json::from_value(value.clone()).map_err(|e| invalid("last_section", e))?;
            doc.last_section = section;
        }
        DocField::Sources => {
            let sources: Vec<Source> =
                serde_json::from_value(value.clone()).map_err(|e| invalid("sources", e))?;
            doc.sources = sources;
        }
        DocField::CustomProps => {
            let props: Vec<CustomProp> =
                serde_json::from_value(value.clone()).map_err(|e| invalid("custom_props", e))?;
            doc.custom_props = props;
        }
        DocField::Glossary => {
            let glossary: Vec<BuildingBlock> =
                serde_json::from_value(value.clone()).map_err(|e| invalid("glossary", e))?;
            doc.glossary = glossary;
        }
        DocField::FootnoteSeparators => {
            let seps: NoteSeparators = serde_json::from_value(value.clone())
                .map_err(|e| invalid("footnote_separators", e))?;
            doc.footnote_separators = seps;
        }
        DocField::EndnoteSeparators => {
            let seps: NoteSeparators = serde_json::from_value(value.clone())
                .map_err(|e| invalid("endnote_separators", e))?;
            doc.endnote_separators = seps;
        }
        DocField::Revisions => {
            let revisions: Vec<Revision> =
                serde_json::from_value(value.clone()).map_err(|e| invalid("revisions", e))?;
            doc.revisions = revisions;
        }
    }
    Ok(())
}
