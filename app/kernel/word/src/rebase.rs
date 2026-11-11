//! Unit-level operational transformation, conflict checks, and marker verification for [`apply`].

use std::collections::BTreeSet;

use wordcraft_doc::{Document, StoryRef};

use crate::markers::story_markers_balanced;
use crate::ops::{
    Applied, ChangeSet, DocField, Edit, EntryMap, execute_changeset, parse_changeset_list,
    parse_incoming_changeset, parse_u32_key, stamp_actor,
};
use crate::{ApplyError, Conflict, WordDoc};

pub(crate) fn apply_with_rebase(
    doc: &WordDoc,
    incoming_op_json: &str,
    prior_ops_json: &str,
    actor_name: Option<&str>,
) -> Result<Applied, ApplyError> {
    let incoming = parse_incoming_changeset(incoming_op_json)?;
    let prior_ops = parse_changeset_list(prior_ops_json)?;
    let mut rebased = rebase_changeset(incoming, &prior_ops, doc.document())?;
    stamp_actor(&mut rebased, doc.document(), actor_name)?;

    let spliced_stories = collect_spliced_stories(&rebased);
    let balanced_before: BTreeSet<StoryRef> = spliced_stories
        .iter()
        .copied()
        .filter(|story| story_markers_balanced(doc.document(), *story))
        .collect();

    let mut next_raw = doc.document().clone();
    execute_changeset(&mut next_raw, &rebased)?;
    next_raw.ensure_nonempty();

    for story in spliced_stories {
        if (!prior_ops.is_empty() || balanced_before.contains(&story))
            && !story_markers_balanced(&next_raw, story)
        {
            return Err(ApplyError::Conflict(Conflict::UnbalancedMarkers));
        }
    }

    let carries_media = rebased.carries_media();
    let next_doc = WordDoc::from_parts(
        next_raw,
        doc.is_macro_enabled(),
        doc.missing_pictures.clone(),
    );
    Ok(Applied {
        doc: next_doc,
        op: rebased,
        carries_media,
    })
}

pub(crate) fn collect_spliced_stories(cs: &ChangeSet) -> Vec<StoryRef> {
    let mut stories = Vec::new();
    for edit in &cs.edits {
        if let Edit::BlocksSplice { story, .. } = edit
            && !stories.contains(story)
        {
            stories.push(*story);
        }
    }
    stories
}

/// Rebases `incoming` across committed `prior_ops` without mutating `current_doc`.
pub(crate) fn rebase_changeset(
    mut incoming: ChangeSet,
    prior_ops: &[ChangeSet],
    current_doc: &Document,
) -> Result<ChangeSet, ApplyError> {
    if prior_ops.is_empty() {
        check_part_existence(&incoming, current_doc)?;
        return Ok(incoming);
    }

    for prior in prior_ops {
        incoming = rebase_over_one(incoming, prior)?;
    }
    check_part_existence(&incoming, current_doc)?;
    Ok(incoming)
}

fn check_part_existence(cs: &ChangeSet, current_doc: &Document) -> Result<(), ApplyError> {
    let mut created_parts: BTreeSet<u32> = BTreeSet::new();
    let mut deleted_parts: BTreeSet<u32> = BTreeSet::new();
    for edit in &cs.edits {
        match edit {
            Edit::EntryPut {
                map: EntryMap::Parts,
                key,
                ..
            } => {
                let id = parse_u32_key(key, "parts")?;
                deleted_parts.remove(&id);
                created_parts.insert(id);
            }
            Edit::EntryDelete {
                map: EntryMap::Parts,
                key,
            } => {
                let id = parse_u32_key(key, "parts")?;
                created_parts.remove(&id);
                deleted_parts.insert(id);
            }
            Edit::BlocksSplice {
                story: StoryRef::Part(id),
                ..
            } => {
                let exists = (current_doc.parts.contains_key(id) || created_parts.contains(id))
                    && !deleted_parts.contains(id);
                if !exists {
                    return Err(ApplyError::Conflict(Conflict::ContainerDeleted));
                }
            }
            _ => {}
        }
    }
    Ok(())
}

fn rebase_over_one(mut incoming: ChangeSet, prior: &ChangeSet) -> Result<ChangeSet, ApplyError> {
    for edit in &mut incoming.edits {
        match edit {
            Edit::BlocksSplice {
                story, at, delete, ..
            } => {
                if let StoryRef::Part(part_id) = *story {
                    for p_edit in &prior.edits {
                        match p_edit {
                            Edit::EntryDelete {
                                map: EntryMap::Parts,
                                key,
                            } if parse_u32_key(key, "parts")? == part_id => {
                                return Err(ApplyError::Conflict(Conflict::ContainerDeleted));
                            }
                            Edit::EntryPut {
                                map: EntryMap::Parts,
                                key,
                                ..
                            } if parse_u32_key(key, "parts")? == part_id => {
                                return Err(ApplyError::Conflict(Conflict::ContainerChanged));
                            }
                            _ => {}
                        }
                    }
                }
                for p_edit in &prior.edits {
                    if let Edit::BlocksSplice {
                        story: p_story,
                        at: p_at,
                        delete: p_del,
                        insert: p_ins,
                    } = p_edit
                        && *p_story == *story
                    {
                        *at = rebase_splice_position(*at, *delete, *p_at, *p_del, p_ins.len())
                            .map_err(ApplyError::Conflict)?;
                    }
                }
            }
            Edit::EntryPut { map, key, .. } | Edit::EntryDelete { map, key } => {
                if *map == EntryMap::Parts {
                    let part_id = parse_u32_key(key, "parts")?;
                    for p_edit in &prior.edits {
                        if let Edit::BlocksSplice {
                            story: StoryRef::Part(p_id),
                            ..
                        } = p_edit
                            && *p_id == part_id
                        {
                            return Err(ApplyError::Conflict(Conflict::ContainerChanged));
                        }
                    }
                }
                for p_edit in &prior.edits {
                    match p_edit {
                        Edit::EntryPut {
                            map: p_map,
                            key: p_key,
                            ..
                        }
                        | Edit::EntryDelete {
                            map: p_map,
                            key: p_key,
                        } if p_map == map && p_key == key => {
                            return Err(ApplyError::Conflict(Conflict::IdentifierTaken));
                        }
                        _ => {}
                    }
                }
            }
            Edit::RevisionsAppend { .. } => {
                for p_edit in &prior.edits {
                    if matches!(
                        p_edit,
                        Edit::RevisionsAppend { .. }
                            | Edit::FieldSet {
                                field: DocField::Revisions,
                                ..
                            }
                    ) {
                        return Err(ApplyError::Conflict(Conflict::ConcurrentRevision));
                    }
                }
            }
            Edit::FieldSet { field, .. } => {
                if *field == DocField::Revisions {
                    for p_edit in &prior.edits {
                        if matches!(
                            p_edit,
                            Edit::RevisionsAppend { .. }
                                | Edit::FieldSet {
                                    field: DocField::Revisions,
                                    ..
                                }
                        ) {
                            return Err(ApplyError::Conflict(Conflict::ConcurrentRevision));
                        }
                    }
                } else {
                    for p_edit in &prior.edits {
                        if let Edit::FieldSet { field: p_field, .. } = p_edit
                            && p_field == field
                        {
                            return Err(ApplyError::Conflict(Conflict::FieldChanged));
                        }
                    }
                }
            }
        }
    }
    Ok(incoming)
}

/// Shifts `(at, delete)` over an already-applied splice `(p_at, p_del, p_ins_len)` in the same
/// story, rejecting overlapping edits symmetrically regardless of commit order.
pub(crate) fn rebase_splice_position(
    at: usize,
    delete: usize,
    p_at: usize,
    p_del: usize,
    p_ins_len: usize,
) -> Result<usize, Conflict> {
    match (delete == 0, p_del == 0) {
        (true, true) => {
            if at == p_at {
                Err(Conflict::BlockChanged)
            } else if p_at < at {
                Ok(at.saturating_add(p_ins_len))
            } else {
                Ok(at)
            }
        }
        (true, false) => {
            let p_end = p_at.saturating_add(p_del);
            if at <= p_at {
                Ok(at)
            } else if at >= p_end {
                Ok(at.saturating_sub(p_del).saturating_add(p_ins_len))
            } else {
                Err(Conflict::BlockChanged)
            }
        }
        (false, true) => {
            let end = at.saturating_add(delete);
            if p_at <= at {
                Ok(at.saturating_add(p_ins_len))
            } else if p_at >= end {
                Ok(at)
            } else {
                Err(Conflict::BlockChanged)
            }
        }
        (false, false) => {
            let end = at.saturating_add(delete);
            let p_end = p_at.saturating_add(p_del);
            if p_end <= at {
                Ok(at.saturating_sub(p_del).saturating_add(p_ins_len))
            } else if end <= p_at {
                Ok(at)
            } else {
                Err(Conflict::BlockChanged)
            }
        }
    }
}
