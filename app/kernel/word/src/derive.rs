//! Pointer-aware unit diff (`derive`) between two WordCraft documents.

use std::collections::BTreeMap;
use std::sync::Arc;

use serde::Serialize;
use serde_json::Value;
use wordcraft_doc::{Block, Document, StoryRef};

use crate::ops::{ChangeSet, DocField, Edit, EntryMap};
use crate::{Error, MAX_PICTURE_BYTES, MODEL_VERSION};

pub(crate) fn derive_changeset(
    before: &Document,
    after: &Document,
) -> Result<Option<ChangeSet>, Error> {
    let mut edits = Vec::new();

    // 1. Keyed containers (`parts`, `comments`, `media`, `passthrough`) so newly referenced parts
    // and media entries exist when `blocks.splice` or subsequent lookups inspect the document.
    diff_parts(before, after, &mut edits)?;
    diff_comments(before, after, &mut edits)?;
    diff_binary_map(
        &before.media,
        &after.media,
        EntryMap::Media,
        Some(MAX_PICTURE_BYTES),
        &mut edits,
    )?;
    diff_binary_map(
        &before.passthrough,
        &after.passthrough,
        EntryMap::Passthrough,
        None,
        &mut edits,
    )?;

    // 2. Main body story.
    if let Some(splice) = diff_blocks(StoryRef::Body, &before.body, &after.body) {
        edits.push(splice);
    }

    // 3. Tracked-change revisions (`revisions.append` when extended, `field.set` when rewritten).
    diff_revisions(before, after, &mut edits)?;

    // 4. Document-wide fields.
    if !Arc::ptr_eq(&before.styles, &after.styles) && before.styles != after.styles {
        edits.push(field_edit(DocField::Styles, after.styles.as_ref())?);
    }
    if !Arc::ptr_eq(&before.numbering, &after.numbering) && before.numbering != after.numbering {
        edits.push(field_edit(DocField::Numbering, after.numbering.as_ref())?);
    }
    if before.settings != after.settings {
        edits.push(field_edit(DocField::Settings, &after.settings)?);
    }
    if before.core != after.core {
        edits.push(field_edit(DocField::Core, &after.core)?);
    }
    if before.last_section != after.last_section {
        edits.push(field_edit(DocField::LastSection, &after.last_section)?);
    }
    if before.sources != after.sources {
        edits.push(field_edit(DocField::Sources, &after.sources)?);
    }
    if before.custom_props != after.custom_props {
        edits.push(field_edit(DocField::CustomProps, &after.custom_props)?);
    }
    if before.glossary != after.glossary {
        edits.push(field_edit(DocField::Glossary, &after.glossary)?);
    }
    if before.footnote_separators != after.footnote_separators {
        edits.push(field_edit(
            DocField::FootnoteSeparators,
            &after.footnote_separators,
        )?);
    }
    if before.endnote_separators != after.endnote_separators {
        edits.push(field_edit(
            DocField::EndnoteSeparators,
            &after.endnote_separators,
        )?);
    }

    if edits.is_empty() {
        Ok(None)
    } else {
        Ok(Some(ChangeSet {
            model_version: MODEL_VERSION,
            edits,
        }))
    }
}

fn blocks_equal(a: &Arc<Block>, b: &Arc<Block>) -> bool {
    Arc::ptr_eq(a, b) || **a == **b
}

fn diff_blocks(story: StoryRef, before: &[Arc<Block>], after: &[Arc<Block>]) -> Option<Edit> {
    let min_len = before.len().min(after.len());
    let mut prefix = 0;
    while prefix < min_len {
        let (Some(b), Some(a)) = (before.get(prefix), after.get(prefix)) else {
            break;
        };
        if !blocks_equal(b, a) {
            break;
        }
        prefix += 1;
    }

    if prefix == before.len() && prefix == after.len() {
        return None;
    }

    let mut suffix = 0;
    let max_suffix = before
        .len()
        .saturating_sub(prefix)
        .min(after.len().saturating_sub(prefix));
    while suffix < max_suffix {
        let b_idx = before.len().saturating_sub(1).saturating_sub(suffix);
        let a_idx = after.len().saturating_sub(1).saturating_sub(suffix);
        let (Some(b), Some(a)) = (before.get(b_idx), after.get(a_idx)) else {
            break;
        };
        if !blocks_equal(b, a) {
            break;
        }
        suffix += 1;
    }

    let delete = before.len().saturating_sub(prefix).saturating_sub(suffix);
    let insert_end = after.len().saturating_sub(suffix);
    let insert = after
        .get(prefix..insert_end)
        .unwrap_or(&[])
        .iter()
        .map(|blk| (**blk).clone())
        .collect();

    Some(Edit::BlocksSplice {
        story,
        at: prefix,
        delete,
        insert,
    })
}

fn diff_parts(before: &Document, after: &Document, edits: &mut Vec<Edit>) -> Result<(), Error> {
    for id in before.parts.keys() {
        if !after.parts.contains_key(id) {
            edits.push(Edit::EntryDelete {
                map: EntryMap::Parts,
                key: id.to_string(),
            });
        }
    }
    for (id, after_part) in &after.parts {
        match before.parts.get(id) {
            None => {
                edits.push(Edit::EntryPut {
                    map: EntryMap::Parts,
                    key: id.to_string(),
                    value: to_json_value(after_part, "part")?,
                });
            }
            Some(before_part) => {
                if before_part.kind != after_part.kind || before_part.body != after_part.body {
                    edits.push(Edit::EntryPut {
                        map: EntryMap::Parts,
                        key: id.to_string(),
                        value: to_json_value(after_part, "part")?,
                    });
                } else if let Some(splice) =
                    diff_blocks(StoryRef::Part(*id), &before_part.blocks, &after_part.blocks)
                {
                    edits.push(splice);
                }
            }
        }
    }
    Ok(())
}

fn diff_comments(before: &Document, after: &Document, edits: &mut Vec<Edit>) -> Result<(), Error> {
    for id in before.comments.keys() {
        if !after.comments.contains_key(id) {
            edits.push(Edit::EntryDelete {
                map: EntryMap::Comments,
                key: id.to_string(),
            });
        }
    }
    for (id, after_comment) in &after.comments {
        if before.comments.get(id) != Some(after_comment) {
            edits.push(Edit::EntryPut {
                map: EntryMap::Comments,
                key: id.to_string(),
                value: to_json_value(after_comment, "comment")?,
            });
        }
    }
    Ok(())
}

fn diff_binary_map(
    before: &BTreeMap<String, Arc<Vec<u8>>>,
    after: &BTreeMap<String, Arc<Vec<u8>>>,
    map: EntryMap,
    max_bytes: Option<usize>,
    edits: &mut Vec<Edit>,
) -> Result<(), Error> {
    for key in before.keys() {
        if !after.contains_key(key) {
            edits.push(Edit::EntryDelete {
                map,
                key: key.clone(),
            });
        }
    }
    for (key, after_bytes) in after {
        let same = before.get(key).is_some_and(|before_bytes| {
            Arc::ptr_eq(before_bytes, after_bytes) || **before_bytes == **after_bytes
        });
        if !same {
            if let Some(limit) = max_bytes
                && after_bytes.len() > limit
            {
                return Err(Error::Invalid(format!(
                    "picture `{key}` size {} exceeds maximum {limit} bytes",
                    after_bytes.len()
                )));
            }
            let encoded = base64_simd::STANDARD.encode_to_string(after_bytes.as_slice());
            edits.push(Edit::EntryPut {
                map,
                key: key.clone(),
                value: Value::String(encoded),
            });
        }
    }
    Ok(())
}

fn diff_revisions(before: &Document, after: &Document, edits: &mut Vec<Edit>) -> Result<(), Error> {
    let b_len = before.revisions.len();
    let a_len = after.revisions.len();
    if a_len >= b_len && after.revisions.get(..b_len) == Some(before.revisions.as_slice()) {
        if a_len > b_len
            && let Some(added) = after.revisions.get(b_len..)
        {
            edits.push(Edit::RevisionsAppend {
                from: b_len,
                items: added.to_vec(),
            });
        }
    } else {
        edits.push(field_edit(DocField::Revisions, &after.revisions)?);
    }
    Ok(())
}

fn field_edit<T: Serialize + ?Sized>(field: DocField, value: &T) -> Result<Edit, Error> {
    Ok(Edit::FieldSet {
        field,
        value: to_json_value(value, "field")?,
    })
}

fn to_json_value<T: Serialize + ?Sized>(value: &T, label: &str) -> Result<Value, Error> {
    serde_json::to_value(value)
        .map_err(|e| Error::Invalid(format!("failed to serialize {label}: {e}")))
}
