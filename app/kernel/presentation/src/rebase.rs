//! Unit-level conflict detection, rebasing, identifier collision checks, and comment stamping.

use std::collections::HashSet;
use std::sync::Arc;

use deckcraft_model::{Comment, Master, MediaId, Presentation, Shape, SlideId};
use serde_json::Value;

use crate::ops::{
    ChangeSet, DeckField, Edit, apply_changeset_to_presentation, parse_changeset_list,
    parse_incoming_changeset,
};
use crate::{Applied, ApplyError, Conflict, Error, PresentationDoc};

/// Rebases and commits `incoming_op_json` over `prior_ops_json` against `doc`, stamping newly
/// added slide comments and replies when `actor_name` is supplied.
///
/// # Errors
///
/// Returns [`ApplyError::FutureVersion`] when `model_version` exceeds [`crate::MODEL_VERSION`],
/// [`ApplyError::Conflict`] when concurrent edits collide on a slide, slide order, deck field, or
/// allocated identifier, and [`ApplyError::Error`] when the input is malformed or invalid.
pub fn apply(
    doc: &PresentationDoc,
    incoming_op_json: &str,
    prior_ops_json: &str,
    actor_name: Option<&str>,
) -> Result<Applied, ApplyError> {
    let incoming = parse_incoming_changeset(incoming_op_json)?;
    let prior_ops = parse_changeset_list(prior_ops_json)?;
    apply_parsed(doc, incoming, &prior_ops, actor_name)
}

/// Applies an already-parsed [`ChangeSet`] against `doc` and `prior_ops`.
pub(crate) fn apply_parsed(
    doc: &PresentationDoc,
    mut incoming: ChangeSet,
    prior_ops: &[ChangeSet],
    actor_name: Option<&str>,
) -> Result<Applied, ApplyError> {
    let pres = doc.presentation();
    let prior_summary = PriorSummary::collect(prior_ops);

    check_conflicts_and_ids(pres, &incoming, &prior_summary, !prior_ops.is_empty())?;

    if let Some(author) = actor_name {
        stamp_changeset_comments(pres, &mut incoming, author);
    }

    let carries_media = incoming.carries_media();
    let next_pres = apply_changeset_to_presentation(pres, &incoming)?;
    let next_doc = PresentationDoc::from_parts(Arc::new(next_pres), Arc::clone(doc.warnings_arc()));

    Ok(Applied {
        doc: next_doc,
        op: incoming,
        carries_media,
    })
}

/// Summary of units and identifiers touched by operations committed after `base_revision`.
#[derive(Default)]
struct PriorSummary {
    edited_slides: HashSet<u32>,
    has_slides_order: bool,
    touched_media: HashSet<u32>,
    deck_fields: HashSet<DeckField>,
    mentioned_ids: HashSet<u32>,
}

impl PriorSummary {
    fn collect(prior_ops: &[ChangeSet]) -> Self {
        let mut out = Self::default();
        for cs in prior_ops {
            for edit in &cs.edits {
                match edit {
                    Edit::SlidePut { slide, value } => {
                        out.edited_slides.insert(*slide);
                        out.mentioned_ids.insert(*slide);
                        collect_shape_ids(&value.shapes, &mut out.mentioned_ids);
                    }
                    Edit::SlidesOrder { order, insert } => {
                        out.has_slides_order = true;
                        for &sid in order {
                            out.mentioned_ids.insert(sid);
                        }
                        for ins in insert {
                            out.edited_slides.insert(ins.id);
                            out.mentioned_ids.insert(ins.id);
                            collect_shape_ids(&ins.value.shapes, &mut out.mentioned_ids);
                        }
                    }
                    Edit::MediaPut { id, .. } => {
                        out.touched_media.insert(*id);
                        out.mentioned_ids.insert(*id);
                    }
                    Edit::MediaDelete { id } => {
                        out.touched_media.insert(*id);
                        out.mentioned_ids.insert(*id);
                    }
                    Edit::DeckSet { field, value } => {
                        out.deck_fields.insert(*field);
                        collect_deck_field_ids(*field, value, &mut out.mentioned_ids);
                    }
                }
            }
        }
        out
    }
}

fn check_conflicts_and_ids(
    pres: &Presentation,
    incoming: &ChangeSet,
    prior: &PriorSummary,
    has_prior_ops: bool,
) -> Result<(), ApplyError> {
    let all_doc_ids = collect_all_presentation_ids(pres);
    let doc_slide_ids: HashSet<u32> = pres.slides.iter().map(|s| s.id.0).collect();

    // Track slide changes introduced earlier within the same ChangeSet.
    let mut intra_inserted_slides = HashSet::new();
    let mut intra_deleted_slides = HashSet::new();
    let mut intra_new_ids = HashSet::new();

    for edit in &incoming.edits {
        match edit {
            Edit::SlidePut { slide, value } => {
                if intra_deleted_slides.contains(slide) {
                    return Err(ApplyError::Error(Error::Invalid(format!(
                        "changeset deletes and updates slide {slide} simultaneously"
                    ))));
                }
                let exists_in_doc = doc_slide_ids.contains(slide);
                if !exists_in_doc && !intra_inserted_slides.contains(slide) {
                    return Err(ApplyError::Conflict(Conflict::SlideDeleted));
                }
                if prior.edited_slides.contains(slide) {
                    return Err(ApplyError::Conflict(Conflict::SlideChanged));
                }

                // Every shape id on `value` not already on this slide in `pres` is newly introduced.
                let mut existing_on_slide = HashSet::new();
                if let Some(cur_slide) = pres.slide(SlideId(*slide)) {
                    collect_shape_ids(&cur_slide.shapes, &mut existing_on_slide);
                }
                let mut incoming_shapes = HashSet::new();
                collect_shape_ids(&value.shapes, &mut incoming_shapes);
                for sid in incoming_shapes {
                    if !existing_on_slide.contains(&sid) {
                        check_new_id(sid, &all_doc_ids, &prior.mentioned_ids, &mut intra_new_ids)?;
                    }
                }
            }
            Edit::SlidesOrder { order, insert } => {
                if prior.has_slides_order {
                    return Err(ApplyError::Conflict(Conflict::SlidesReordered));
                }
                let order_set: HashSet<u32> = order.iter().copied().collect();
                let insert_ids: HashSet<u32> = insert.iter().map(|i| i.id).collect();

                // Check newly inserted slides and their shapes for ID collisions first.
                for ins in insert {
                    if doc_slide_ids.contains(&ins.id) {
                        return Err(ApplyError::Conflict(Conflict::IdentifierTaken));
                    }
                    check_new_id(
                        ins.id,
                        &all_doc_ids,
                        &prior.mentioned_ids,
                        &mut intra_new_ids,
                    )?;
                    let mut shape_ids = HashSet::new();
                    collect_shape_ids(&ins.value.shapes, &mut shape_ids);
                    for sid in shape_ids {
                        check_new_id(sid, &all_doc_ids, &prior.mentioned_ids, &mut intra_new_ids)?;
                    }
                    intra_inserted_slides.insert(ins.id);
                }

                // Check that any existing slide omitted by `order` was not edited by a prior op.
                for &existing_sid in &doc_slide_ids {
                    if !order_set.contains(&existing_sid) {
                        if prior.edited_slides.contains(&existing_sid) {
                            return Err(ApplyError::Conflict(Conflict::SlideChanged));
                        }
                        intra_deleted_slides.insert(existing_sid);
                    }
                }

                // Every surviving ID in `order` must exist in `doc`.
                for &sid in order {
                    if !insert_ids.contains(&sid) && !doc_slide_ids.contains(&sid) {
                        return Err(ApplyError::Error(Error::Invalid(format!(
                            "slides.order references unknown existing slide id {sid}"
                        ))));
                    }
                }
            }
            Edit::MediaPut { id, .. } => {
                if prior.touched_media.contains(id) {
                    return Err(ApplyError::Conflict(Conflict::IdentifierTaken));
                }
                let exists_as_media = pres.media(MediaId(*id)).is_some();
                if exists_as_media {
                    if has_prior_ops {
                        return Err(ApplyError::Conflict(Conflict::IdentifierTaken));
                    }
                } else {
                    check_new_id(*id, &all_doc_ids, &prior.mentioned_ids, &mut intra_new_ids)?;
                }
            }
            Edit::MediaDelete { id } => {
                if prior.touched_media.contains(id) {
                    return Err(ApplyError::Conflict(Conflict::IdentifierTaken));
                }
            }
            Edit::DeckSet { field, value } => {
                if prior.deck_fields.contains(field) {
                    return Err(ApplyError::Conflict(Conflict::FieldChanged));
                }
                let mut existing_field_ids = HashSet::new();
                collect_existing_deck_field_ids(pres, *field, &mut existing_field_ids);
                let mut incoming_field_ids = HashSet::new();
                collect_deck_field_ids(*field, value, &mut incoming_field_ids);
                for fid in incoming_field_ids {
                    if !existing_field_ids.contains(&fid) {
                        check_new_id(fid, &all_doc_ids, &prior.mentioned_ids, &mut intra_new_ids)?;
                    }
                }
            }
        }
    }

    Ok(())
}

fn check_new_id(
    id: u32,
    all_doc_ids: &HashSet<u32>,
    prior_ids: &HashSet<u32>,
    intra_new_ids: &mut HashSet<u32>,
) -> Result<(), ApplyError> {
    if !intra_new_ids.insert(id) {
        return Err(ApplyError::Error(Error::Invalid(format!(
            "duplicate newly allocated identifier {id} within operation"
        ))));
    }
    if all_doc_ids.contains(&id) || prior_ids.contains(&id) {
        return Err(ApplyError::Conflict(Conflict::IdentifierTaken));
    }
    Ok(())
}

pub(crate) fn collect_all_presentation_ids(pres: &Presentation) -> HashSet<u32> {
    let mut ids = HashSet::new();
    for slide in &pres.slides {
        ids.insert(slide.id.0);
        collect_shape_ids(&slide.shapes, &mut ids);
    }
    for master in &pres.masters {
        collect_master_ids(master, &mut ids);
    }
    if let Some(nm) = &pres.notes_master {
        collect_master_ids(nm, &mut ids);
    }
    if let Some(hm) = &pres.handout_master {
        collect_master_ids(hm, &mut ids);
    }
    for media in &pres.media {
        ids.insert(media.id.0);
    }
    ids
}

fn collect_master_ids(master: &Master, ids: &mut HashSet<u32>) {
    ids.insert(master.id.0);
    collect_shape_ids(&master.shapes, ids);
    for layout in &master.layouts {
        ids.insert(layout.id.0);
        collect_shape_ids(&layout.shapes, ids);
    }
}

fn collect_shape_ids(shapes: &[Shape], ids: &mut HashSet<u32>) {
    fn walk(shapes: &[Shape], ids: &mut HashSet<u32>, depth: usize) {
        if depth > 64 {
            return;
        }
        for sh in shapes {
            ids.insert(sh.id.0);
            if !sh.children().is_empty() {
                walk(sh.children(), ids, depth + 1);
            }
        }
    }
    walk(shapes, ids, 0);
}

fn collect_existing_deck_field_ids(pres: &Presentation, field: DeckField, ids: &mut HashSet<u32>) {
    match field {
        DeckField::Masters => {
            for m in &pres.masters {
                collect_master_ids(m, ids);
            }
        }
        DeckField::NotesMaster => {
            if let Some(m) = &pres.notes_master {
                collect_master_ids(m, ids);
            }
        }
        DeckField::HandoutMaster => {
            if let Some(m) = &pres.handout_master {
                collect_master_ids(m, ids);
            }
        }
        _ => {}
    }
}

fn collect_deck_field_ids(field: DeckField, value: &Value, ids: &mut HashSet<u32>) {
    match field {
        DeckField::Masters => {
            if let Ok(masters) = serde_json::from_value::<Vec<Master>>(value.clone()) {
                for m in &masters {
                    collect_master_ids(m, ids);
                }
            }
        }
        DeckField::NotesMaster | DeckField::HandoutMaster => {
            if let Ok(Some(m)) = serde_json::from_value::<Option<Master>>(value.clone()) {
                collect_master_ids(&m, ids);
            }
        }
        _ => {}
    }
}

/// Computes uppercase initials from an actor display name, matching DeckCraft's review helper.
pub(crate) fn author_initials(author: &str) -> String {
    author
        .split_whitespace()
        .filter_map(|word| word.chars().next())
        .collect()
}

/// Stamps `author` and derived `initials` onto any newly added or edited comments and replies
/// inside `cs`, preserving the original authors of untouched existing threads.
pub(crate) fn stamp_changeset_comments(pres: &Presentation, cs: &mut ChangeSet, author: &str) {
    let initials = author_initials(author);
    for edit in &mut cs.edits {
        match edit {
            Edit::SlidePut { slide, value } => {
                let existing: &[Comment] = pres
                    .slide(SlideId(*slide))
                    .map_or(&[], |s| s.comments.as_slice());
                stamp_comment_list(existing, &mut value.comments, author, &initials, 0);
            }
            Edit::SlidesOrder { insert, .. } => {
                for ins in insert {
                    stamp_comment_list(&[], &mut ins.value.comments, author, &initials, 0);
                }
            }
            _ => {}
        }
    }
}

/// Stamps newly added or modified comments on `after` relative to `before` on whole slides.
pub(crate) fn stamp_presentation_comments(
    before: &Presentation,
    after: &mut Presentation,
    author: &str,
) {
    let initials = author_initials(author);
    for slide_arc in &mut after.slides {
        let existing_slide = before.slide(slide_arc.id);
        let unchanged = existing_slide.is_some_and(|old| old.comments == slide_arc.comments);
        if unchanged {
            continue;
        }
        let old_comments: Vec<Comment> = existing_slide
            .map(|s| s.comments.clone())
            .unwrap_or_default();
        let slide = Arc::make_mut(slide_arc);
        stamp_comment_list(&old_comments, &mut slide.comments, author, &initials, 0);
    }
}

fn stamp_comment_list(
    old_comments: &[Comment],
    new_comments: &mut [Comment],
    author: &str,
    initials: &str,
    depth: usize,
) {
    if depth > 32 {
        return;
    }
    let mut matched = vec![false; old_comments.len()];
    for new_c in new_comments {
        let found = old_comments.iter().enumerate().find(|(idx, old_c)| {
            !matched.get(*idx).copied().unwrap_or(true)
                && old_c.text == new_c.text
                && old_c.date == new_c.date
                && old_c.shape == new_c.shape
                && (old_c.x - new_c.x).abs() <= 1e-9
                && (old_c.y - new_c.y).abs() <= 1e-9
        });
        if let Some((idx, old_c)) = found {
            if let Some(slot) = matched.get_mut(idx) {
                *slot = true;
            }
            new_c.author.clone_from(&old_c.author);
            new_c.initials.clone_from(&old_c.initials);
            stamp_comment_list(
                &old_c.replies,
                &mut new_c.replies,
                author,
                initials,
                depth + 1,
            );
        } else {
            new_c.author = author.to_string();
            new_c.initials = initials.to_string();
            stamp_comment_list(&[], &mut new_c.replies, author, initials, depth + 1);
        }
    }
}
