//! Deterministic identity checkpointing across pure OOXML `.docx`/`.docm` compaction.
//!
//! Exported `.docx` and `.docm` archives contain only standard ECMA-376 markup. When
//! `Ankole.Pod.OfficeFiles` compacts uncompacted operations into a fresh object-storage version,
//! [`capture`] compares the in-memory [`Document`] before export with the [`Document`] decoded by
//! `wordcraft_docx::read` from the exported bytes, recording any remapped secondary story IDs,
//! media keys, unglued drawing IDs, and deduplicated tracked-change revision slots. Storing that
//! JSON sidecar alongside the compacted `object_id` in PostgreSQL lets [`apply`] restore identical
//! in-memory identities without writing proprietary parts or attributes into user files.

use std::collections::{BTreeMap, BTreeSet, VecDeque};
use std::sync::Arc;

use serde::{Deserialize, Serialize};
use wordcraft_doc::connector::ConnEnd;
use wordcraft_doc::graphic::GraphicItem;
use wordcraft_doc::props::PropChange;
use wordcraft_doc::section::HeaderSet;
use wordcraft_doc::{
    Block, Blocks, Document, InlineObject, NoteSeparators, Paragraph, Revision, SectionProps, Table,
};

use crate::Error;

const CHECKPOINT_VERSION: u32 = 1;
const MAX_NESTED_DEPTH: usize = 32;

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub(crate) struct Checkpoint {
    version: u32,
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    part_map: BTreeMap<u32, u32>,
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    media_map: BTreeMap<String, String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    revisions: Option<Vec<Revision>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    last_section_fmt_rev: Option<u32>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    stories: Vec<StoryCheckpoint>,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(tag = "kind", content = "id", rename_all = "snake_case")]
enum StoryKey {
    #[default]
    Body,
    Part(u32),
    FootnoteSep(u8),
    EndnoteSep(u8),
    Glossary(usize),
}

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
struct StoryCheckpoint {
    story: StoryKey,
    #[serde(default, skip_serializing_if = "is_zero")]
    shape_count: usize,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    shapes: Vec<ShapeCheckpoint>,
    #[serde(default, skip_serializing_if = "is_zero")]
    para_count: usize,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    paras: Vec<ParaRevCheckpoint>,
    #[serde(default, skip_serializing_if = "is_zero")]
    table_count: usize,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    tables: Vec<TableRevCheckpoint>,
}

#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
struct ShapeCheckpoint {
    index: usize,
    id: u32,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    start: Option<ConnEnd>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    end: Option<ConnEnd>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
struct ParaRevCheckpoint {
    index: usize,
    text_len: usize,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    num_rev: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    fmt_rev: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    section_fmt_rev: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    mark_ins: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    mark_del: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    mark_fmt_rev: Option<u32>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    spans: Vec<RunRevSpan>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    ruby_revs: Vec<RubyRevCheckpoint>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
struct RunRevSpan {
    start: usize,
    end: usize,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    ins: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    del: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    fmt_rev: Option<u32>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
struct RubyRevCheckpoint {
    obj_index: usize,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    ins: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    del: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    fmt_rev: Option<u32>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
struct TableRevCheckpoint {
    index: usize,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    fmt_rev: Option<u32>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    rows: Vec<RowRevCheckpoint>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    cells: Vec<CellRevCheckpoint>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
struct RowRevCheckpoint {
    row: usize,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    fmt_rev: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    exc_fmt_rev: Option<u32>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
struct CellRevCheckpoint {
    row: usize,
    cell: usize,
    fmt_rev: u32,
}

const fn is_zero(value: &usize) -> bool {
    *value == 0
}

pub(crate) fn capture_json(orig: &Document, reopened: &Document) -> Result<Option<String>, Error> {
    let Some(checkpoint) = capture(orig, reopened) else {
        return Ok(None);
    };
    let json = serde_json::to_string(&checkpoint).map_err(|e| Error::Write(e.to_string()))?;
    Ok(Some(json))
}

pub(crate) fn apply_json(doc: &mut Document, checkpoint_json: &str) -> Result<(), Error> {
    let trimmed = checkpoint_json.trim();
    if trimmed.is_empty() {
        return Ok(());
    }
    let checkpoint: Checkpoint = serde_json::from_str(trimmed)
        .map_err(|e| Error::Invalid(format!("invalid word checkpoint JSON: {e}")))?;
    apply(doc, &checkpoint)
}

pub(crate) fn capture(orig: &Document, reopened: &Document) -> Option<Checkpoint> {
    let paired_parts = collect_part_pairs(reopened, orig);
    let part_map: BTreeMap<u32, u32> = paired_parts
        .iter()
        .filter(|(r_id, o_id)| r_id != o_id)
        .map(|(r_id, o_id)| (*r_id, *o_id))
        .collect();

    let paired_media = collect_media_pairs(reopened, orig, &paired_parts);
    let media_map: BTreeMap<String, String> = paired_media
        .into_iter()
        .filter(|(r_key, o_key)| r_key != o_key)
        .collect();

    let revisions = (reopened.revisions != orig.revisions).then(|| orig.revisions.clone());
    let last_section_fmt_rev = diff_prop_change_rev(
        reopened.last_section.fmt_change.as_deref(),
        orig.last_section.fmt_change.as_deref(),
    );

    let mut stories = Vec::new();
    for (story_key, r_blocks, o_blocks) in paired_story_containers(reopened, orig, &paired_parts) {
        if let Some(story_cp) = capture_story(story_key, r_blocks, o_blocks) {
            stories.push(story_cp);
        }
    }

    if part_map.is_empty()
        && media_map.is_empty()
        && revisions.is_none()
        && last_section_fmt_rev.is_none()
        && stories.is_empty()
    {
        return None;
    }

    Some(Checkpoint {
        version: CHECKPOINT_VERSION,
        part_map,
        media_map,
        revisions,
        last_section_fmt_rev,
        stories,
    })
}

pub(crate) fn apply(doc: &mut Document, checkpoint: &Checkpoint) -> Result<(), Error> {
    if checkpoint.version != CHECKPOINT_VERSION {
        return Err(Error::Invalid(format!(
            "unsupported word checkpoint version {}",
            checkpoint.version
        )));
    }

    if !checkpoint.part_map.is_empty() {
        apply_part_map(doc, &checkpoint.part_map)?;
    }

    if !checkpoint.media_map.is_empty() {
        apply_media_map(doc, &checkpoint.media_map)?;
    }

    if let Some(revisions) = &checkpoint.revisions {
        doc.revisions.clone_from(revisions);
    }

    let rev_len = doc.revisions.len();
    if let Some(rev) = checkpoint.last_section_fmt_rev {
        validate_rev_slot(rev, rev_len)?;
        if let Some(fc) = doc.last_section.fmt_change.as_deref_mut() {
            fc.rev = rev;
        }
    }

    for story_cp in &checkpoint.stories {
        apply_story_checkpoint(doc, story_cp, rev_len)?;
    }

    Ok(())
}

fn collect_part_pairs(reopened: &Document, orig: &Document) -> BTreeMap<u32, u32> {
    let mut map: BTreeMap<u32, u32> = BTreeMap::new();
    let mut used_orig: BTreeSet<u32> = BTreeSet::new();
    let mut queue: VecDeque<(u32, u32)> = VecDeque::new();

    let mut record = |r_id: u32, o_id: u32, queue: &mut VecDeque<(u32, u32)>| {
        if r_id == 0 || o_id == 0 {
            return;
        }
        if !reopened.parts.contains_key(&r_id) || !orig.parts.contains_key(&o_id) {
            return;
        }
        if map.contains_key(&r_id) || used_orig.contains(&o_id) {
            return;
        }
        map.insert(r_id, o_id);
        used_orig.insert(o_id);
        queue.push_back((r_id, o_id));
    };

    for ((_, r_sec), (_, o_sec)) in reopened.sections().into_iter().zip(orig.sections()) {
        pair_section_parts(r_sec, o_sec, &mut |r_id, o_id| {
            record(r_id, o_id, &mut queue);
        });
    }

    for (cid, r_comment) in &reopened.comments {
        if let Some(o_comment) = orig.comments.get(cid) {
            record(r_comment.part, o_comment.part, &mut queue);
        }
    }

    pair_blocks_parts(&reopened.body, &orig.body, 0, &mut |r_id, o_id| {
        record(r_id, o_id, &mut queue);
    });
    for (r_sep, o_sep) in [
        (&reopened.footnote_separators, &orig.footnote_separators),
        (&reopened.endnote_separators, &orig.endnote_separators),
    ] {
        for (rb, ob) in [
            (r_sep.separator.as_ref(), o_sep.separator.as_ref()),
            (
                r_sep.continuation_separator.as_ref(),
                o_sep.continuation_separator.as_ref(),
            ),
            (
                r_sep.continuation_notice.as_ref(),
                o_sep.continuation_notice.as_ref(),
            ),
        ] {
            if let (Some(rb), Some(ob)) = (rb, ob) {
                pair_blocks_parts(rb, ob, 0, &mut |r_id, o_id| {
                    record(r_id, o_id, &mut queue);
                });
            }
        }
    }
    for (r_bb, o_bb) in reopened.glossary.iter().zip(orig.glossary.iter()) {
        pair_blocks_parts(&r_bb.blocks, &o_bb.blocks, 0, &mut |r_id, o_id| {
            record(r_id, o_id, &mut queue);
        });
    }

    while let Some((r_id, o_id)) = queue.pop_front() {
        let Some(r_part) = reopened.parts.get(&r_id) else {
            continue;
        };
        let Some(o_part) = orig.parts.get(&o_id) else {
            continue;
        };
        if let (Some(r_next), Some(o_next)) = (r_part.body.next, o_part.body.next) {
            record(r_next, o_next, &mut queue);
        }
        pair_blocks_parts(&r_part.blocks, &o_part.blocks, 0, &mut |sub_r, sub_o| {
            record(sub_r, sub_o, &mut queue);
        });
    }

    map
}

fn pair_section_parts(
    r_sec: &SectionProps,
    o_sec: &SectionProps,
    on_pair: &mut dyn FnMut(u32, u32),
) {
    pair_header_set(&r_sec.headers, &o_sec.headers, on_pair);
    pair_header_set(&r_sec.footers, &o_sec.footers, on_pair);
    if let (Some(r_fc), Some(o_fc)) = (r_sec.fmt_change.as_deref(), o_sec.fmt_change.as_deref()) {
        pair_header_set(&r_fc.old.headers, &o_fc.old.headers, on_pair);
        pair_header_set(&r_fc.old.footers, &o_fc.old.footers, on_pair);
    }
}

fn pair_header_set(r_set: &HeaderSet, o_set: &HeaderSet, on_pair: &mut dyn FnMut(u32, u32)) {
    for (r_slot, o_slot) in [
        (r_set.default, o_set.default),
        (r_set.first, o_set.first),
        (r_set.even, o_set.even),
    ] {
        if let (Some(r_id), Some(o_id)) = (r_slot, o_slot) {
            on_pair(r_id, o_id);
        }
    }
}

fn pair_blocks_parts(
    r_blocks: &Blocks,
    o_blocks: &Blocks,
    depth: usize,
    on_pair: &mut dyn FnMut(u32, u32),
) {
    if depth > MAX_NESTED_DEPTH {
        return;
    }
    for (rb, ob) in r_blocks.iter().zip(o_blocks.iter()) {
        match (rb.as_ref(), ob.as_ref()) {
            (Block::Para(rp), Block::Para(op)) => {
                for (ro, oo) in rp.objects.iter().zip(op.objects.iter()) {
                    pair_object_parts(ro, oo, depth, on_pair);
                }
            }
            (Block::Table(rt), Block::Table(ot)) => {
                for (rr, orow) in rt.rows.iter().zip(ot.rows.iter()) {
                    for (rc, oc) in rr.cells.iter().zip(orow.cells.iter()) {
                        pair_blocks_parts(&rc.blocks, &oc.blocks, depth + 1, on_pair);
                    }
                }
            }
            _ => {}
        }
    }
}

fn pair_object_parts(
    r_obj: &InlineObject,
    o_obj: &InlineObject,
    depth: usize,
    on_pair: &mut dyn FnMut(u32, u32),
) {
    if depth > MAX_NESTED_DEPTH {
        return;
    }
    match (r_obj, o_obj) {
        (InlineObject::NoteRef { id: r_id, .. }, InlineObject::NoteRef { id: o_id, .. }) => {
            on_pair(*r_id, *o_id);
        }
        (
            InlineObject::Shape {
                story: Some(r_id), ..
            },
            InlineObject::Shape {
                story: Some(o_id), ..
            },
        ) => {
            on_pair(*r_id, *o_id);
        }
        (
            InlineObject::Group {
                children: r_kids, ..
            },
            InlineObject::Group {
                children: o_kids, ..
            },
        ) => {
            for (rk, ok) in r_kids.iter().zip(o_kids.iter()) {
                pair_object_parts(&rk.obj, &ok.obj, depth + 1, on_pair);
            }
        }
        _ => {}
    }
}

fn collect_media_pairs(
    reopened: &Document,
    orig: &Document,
    paired_parts: &BTreeMap<u32, u32>,
) -> BTreeMap<String, String> {
    let mut map: BTreeMap<String, String> = BTreeMap::new();
    let mut used_orig: BTreeSet<String> = BTreeSet::new();

    let mut record = |r_key: &str, o_key: &str| {
        if r_key.is_empty() || o_key.is_empty() {
            return;
        }
        if !reopened.media.contains_key(r_key) || !orig.media.contains_key(o_key) {
            return;
        }
        if map.contains_key(r_key) || used_orig.contains(o_key) {
            return;
        }
        map.insert(r_key.to_owned(), o_key.to_owned());
        used_orig.insert(o_key.to_owned());
    };

    if let (Some(r_pic), Some(o_pic)) = (
        reopened.settings.page_picture.as_ref(),
        orig.settings.page_picture.as_ref(),
    ) {
        record(&r_pic.media, &o_pic.media);
    }

    for (_, r_blocks, o_blocks) in paired_story_containers(reopened, orig, paired_parts) {
        pair_blocks_media(r_blocks, o_blocks, 0, &mut record);
    }

    map
}

fn pair_blocks_media(
    r_blocks: &Blocks,
    o_blocks: &Blocks,
    depth: usize,
    on_pair: &mut dyn FnMut(&str, &str),
) {
    if depth > MAX_NESTED_DEPTH {
        return;
    }
    for (rb, ob) in r_blocks.iter().zip(o_blocks.iter()) {
        match (rb.as_ref(), ob.as_ref()) {
            (Block::Para(rp), Block::Para(op)) => {
                for (ro, oo) in rp.objects.iter().zip(op.objects.iter()) {
                    pair_object_media(ro, oo, depth, on_pair);
                }
            }
            (Block::Table(rt), Block::Table(ot)) => {
                for (rr, orow) in rt.rows.iter().zip(ot.rows.iter()) {
                    for (rc, oc) in rr.cells.iter().zip(orow.cells.iter()) {
                        if let (Some(r_pic), Some(o_pic)) =
                            (rc.props.picture.as_deref(), oc.props.picture.as_deref())
                        {
                            on_pair(&r_pic.media, &o_pic.media);
                        }
                        if let (Some(r_fc), Some(o_fc)) = (
                            rc.props.fmt_change.as_deref(),
                            oc.props.fmt_change.as_deref(),
                        ) && let (Some(r_pic), Some(o_pic)) =
                            (r_fc.old.picture.as_deref(), o_fc.old.picture.as_deref())
                        {
                            on_pair(&r_pic.media, &o_pic.media);
                        }
                        pair_blocks_media(&rc.blocks, &oc.blocks, depth + 1, on_pair);
                    }
                }
            }
            _ => {}
        }
    }
}

fn pair_object_media(
    r_obj: &InlineObject,
    o_obj: &InlineObject,
    depth: usize,
    on_pair: &mut dyn FnMut(&str, &str),
) {
    if depth > MAX_NESTED_DEPTH {
        return;
    }
    match (r_obj, o_obj) {
        (InlineObject::Image { media: r_m, .. }, InlineObject::Image { media: o_m, .. }) => {
            on_pair(r_m, o_m);
        }
        (
            InlineObject::Graphic { graphic: r_g, .. },
            InlineObject::Graphic { graphic: o_g, .. },
        ) => {
            for (ri, oi) in r_g.items.iter().zip(o_g.items.iter()) {
                if let (
                    GraphicItem::Image { media: r_m, .. },
                    GraphicItem::Image { media: o_m, .. },
                ) = (ri, oi)
                {
                    on_pair(r_m, o_m);
                }
            }
        }
        (
            InlineObject::Group {
                children: r_kids, ..
            },
            InlineObject::Group {
                children: o_kids, ..
            },
        ) => {
            for (rk, ok) in r_kids.iter().zip(o_kids.iter()) {
                pair_object_media(&rk.obj, &ok.obj, depth + 1, on_pair);
            }
        }
        _ => {}
    }
}

fn paired_story_containers<'a>(
    reopened: &'a Document,
    orig: &'a Document,
    paired_parts: &BTreeMap<u32, u32>,
) -> Vec<(StoryKey, &'a Blocks, &'a Blocks)> {
    let mut out = Vec::new();
    out.push((StoryKey::Body, &reopened.body, &orig.body));

    for (r_id, o_id) in paired_parts {
        if let (Some(r_part), Some(o_part)) = (reopened.parts.get(r_id), orig.parts.get(o_id)) {
            out.push((StoryKey::Part(*o_id), &r_part.blocks, &o_part.blocks));
        }
    }

    append_sep_pairs(
        &mut out,
        &reopened.footnote_separators,
        &orig.footnote_separators,
        StoryKey::FootnoteSep,
    );
    append_sep_pairs(
        &mut out,
        &reopened.endnote_separators,
        &orig.endnote_separators,
        StoryKey::EndnoteSep,
    );

    for (idx, (r_bb, o_bb)) in reopened
        .glossary
        .iter()
        .zip(orig.glossary.iter())
        .enumerate()
    {
        out.push((StoryKey::Glossary(idx), &r_bb.blocks, &o_bb.blocks));
    }

    out
}

fn append_sep_pairs<'a>(
    out: &mut Vec<(StoryKey, &'a Blocks, &'a Blocks)>,
    r_sep: &'a NoteSeparators,
    o_sep: &'a NoteSeparators,
    make_key: fn(u8) -> StoryKey,
) {
    for (slot, (rb, ob)) in [
        (r_sep.separator.as_ref(), o_sep.separator.as_ref()),
        (
            r_sep.continuation_separator.as_ref(),
            o_sep.continuation_separator.as_ref(),
        ),
        (
            r_sep.continuation_notice.as_ref(),
            o_sep.continuation_notice.as_ref(),
        ),
    ]
    .into_iter()
    .enumerate()
    {
        if let (Some(rb), Some(ob)) = (rb, ob)
            && let Ok(slot_u8) = u8::try_from(slot)
        {
            out.push((make_key(slot_u8), rb, ob));
        }
    }
}

fn capture_story(story: StoryKey, r_blocks: &Blocks, o_blocks: &Blocks) -> Option<StoryCheckpoint> {
    let mut cp = StoryCheckpoint {
        story,
        ..StoryCheckpoint::default()
    };

    capture_story_blocks(r_blocks, o_blocks, 0, &mut cp);

    if cp.shapes.is_empty() {
        cp.shape_count = 0;
    }
    if cp.paras.is_empty() {
        cp.para_count = 0;
    }
    if cp.tables.is_empty() {
        cp.table_count = 0;
    }

    if cp.shapes.is_empty() && cp.paras.is_empty() && cp.tables.is_empty() {
        None
    } else {
        Some(cp)
    }
}

fn capture_story_blocks(
    r_blocks: &Blocks,
    o_blocks: &Blocks,
    depth: usize,
    cp: &mut StoryCheckpoint,
) {
    if depth > MAX_NESTED_DEPTH || r_blocks.len() != o_blocks.len() {
        return;
    }
    for (rb, ob) in r_blocks.iter().zip(o_blocks.iter()) {
        match (rb.as_ref(), ob.as_ref()) {
            (Block::Para(rp), Block::Para(op)) => {
                let para_idx = cp.para_count;
                cp.para_count = cp.para_count.saturating_add(1);
                if let Some(p_cp) = capture_para_revs(para_idx, rp, op) {
                    cp.paras.push(p_cp);
                }
                for (ro, oo) in rp.objects.iter().zip(op.objects.iter()) {
                    capture_object_shapes(ro, oo, depth, cp);
                }
            }
            (Block::Table(rt), Block::Table(ot)) => {
                let tbl_idx = cp.table_count;
                cp.table_count = cp.table_count.saturating_add(1);
                if let Some(t_cp) = capture_table_revs(tbl_idx, rt, ot) {
                    cp.tables.push(t_cp);
                }
                if rt.rows.len() == ot.rows.len() {
                    for (rr, orow) in rt.rows.iter().zip(ot.rows.iter()) {
                        if rr.cells.len() == orow.cells.len() {
                            for (rc, oc) in rr.cells.iter().zip(orow.cells.iter()) {
                                capture_story_blocks(&rc.blocks, &oc.blocks, depth + 1, cp);
                            }
                        }
                    }
                }
            }
            _ => {}
        }
    }
}

fn capture_object_shapes(
    r_obj: &InlineObject,
    o_obj: &InlineObject,
    depth: usize,
    cp: &mut StoryCheckpoint,
) {
    if depth > MAX_NESTED_DEPTH {
        return;
    }
    match (r_obj, o_obj) {
        (
            InlineObject::Shape { extra: r_extra, .. },
            InlineObject::Shape { extra: o_extra, .. },
        ) => {
            let idx = cp.shape_count;
            cp.shape_count = cp.shape_count.saturating_add(1);
            if r_extra.id != o_extra.id
                || r_extra.start != o_extra.start
                || r_extra.end != o_extra.end
            {
                cp.shapes.push(ShapeCheckpoint {
                    index: idx,
                    id: o_extra.id,
                    start: o_extra.start,
                    end: o_extra.end,
                });
            }
        }
        (
            InlineObject::Group {
                children: r_kids, ..
            },
            InlineObject::Group {
                children: o_kids, ..
            },
        ) => {
            for (rk, ok) in r_kids.iter().zip(o_kids.iter()) {
                capture_object_shapes(&rk.obj, &ok.obj, depth + 1, cp);
            }
        }
        _ => {}
    }
}

fn capture_para_revs(index: usize, rp: &Paragraph, op: &Paragraph) -> Option<ParaRevCheckpoint> {
    if rp.text != op.text {
        return None;
    }
    let num_rev = match (
        rp.props.num_change.as_deref(),
        op.props.num_change.as_deref(),
    ) {
        (Some(rn), Some(on)) if rn.rev != on.rev => Some(on.rev),
        _ => None,
    };
    let fmt_rev = diff_prop_change_rev(
        rp.props.fmt_change.as_deref(),
        op.props.fmt_change.as_deref(),
    );
    let section_fmt_rev = match (rp.section.as_deref(), op.section.as_deref()) {
        (Some(rs), Some(os)) => {
            diff_prop_change_rev(rs.fmt_change.as_deref(), os.fmt_change.as_deref())
        }
        _ => None,
    };
    let mark_ins = (rp.mark.ins != op.mark.ins)
        .then_some(op.mark.ins)
        .flatten();
    let mark_del = (rp.mark.del != op.mark.del)
        .then_some(op.mark.del)
        .flatten();
    let mark_fmt_rev =
        diff_prop_change_rev(rp.mark.fmt_change.as_deref(), op.mark.fmt_change.as_deref());

    let spans = capture_run_rev_spans(rp, op);

    let mut ruby_revs = Vec::new();
    for (obj_idx, (ro, oo)) in rp.objects.iter().zip(op.objects.iter()).enumerate() {
        if let (
            InlineObject::Ruby { props: r_props, .. },
            InlineObject::Ruby { props: o_props, .. },
        ) = (ro, oo)
        {
            let ins = (r_props.ins != o_props.ins)
                .then_some(o_props.ins)
                .flatten();
            let del = (r_props.del != o_props.del)
                .then_some(o_props.del)
                .flatten();
            let f_rev =
                diff_prop_change_rev(r_props.fmt_change.as_deref(), o_props.fmt_change.as_deref());
            if ins.is_some() || del.is_some() || f_rev.is_some() {
                ruby_revs.push(RubyRevCheckpoint {
                    obj_index: obj_idx,
                    ins,
                    del,
                    fmt_rev: f_rev,
                });
            }
        }
    }

    if num_rev.is_none()
        && fmt_rev.is_none()
        && section_fmt_rev.is_none()
        && mark_ins.is_none()
        && mark_del.is_none()
        && mark_fmt_rev.is_none()
        && spans.is_empty()
        && ruby_revs.is_empty()
    {
        return None;
    }

    Some(ParaRevCheckpoint {
        index,
        text_len: op.text.len(),
        num_rev,
        fmt_rev,
        section_fmt_rev,
        mark_ins,
        mark_del,
        mark_fmt_rev,
        spans,
        ruby_revs,
    })
}

fn capture_run_rev_spans(rp: &Paragraph, op: &Paragraph) -> Vec<RunRevSpan> {
    let runs_match = rp.runs.len() == op.runs.len()
        && rp.runs.iter().zip(op.runs.iter()).all(|(rr, orun)| {
            rr.len == orun.len
                && rr.props.ins == orun.props.ins
                && rr.props.del == orun.props.del
                && prop_change_rev(rr.props.fmt_change.as_deref())
                    == prop_change_rev(orun.props.fmt_change.as_deref())
        });
    if runs_match {
        return Vec::new();
    }

    let mut out = Vec::new();
    for (range, props) in op.run_ranges() {
        let fmt_rev = prop_change_rev(props.fmt_change.as_deref());
        let r_props = rp.props_of_char(range.start);
        let r_fmt_rev = prop_change_rev(r_props.fmt_change.as_deref());
        // Record every span whose revision marks differ (or all non-empty revision spans when run
        // boundaries merged across adjacent identical revisions).
        if props.ins != r_props.ins
            || props.del != r_props.del
            || fmt_rev != r_fmt_rev
            || props.ins.is_some()
            || props.del.is_some()
            || fmt_rev.is_some()
        {
            out.push(RunRevSpan {
                start: range.start,
                end: range.end,
                ins: props.ins,
                del: props.del,
                fmt_rev,
            });
        }
    }
    out
}

fn capture_table_revs(index: usize, rt: &Table, ot: &Table) -> Option<TableRevCheckpoint> {
    let fmt_rev = diff_prop_change_rev(
        rt.props.fmt_change.as_deref(),
        ot.props.fmt_change.as_deref(),
    );
    let mut rows = Vec::new();
    let mut cells = Vec::new();

    for (r_idx, (rr, orow)) in rt.rows.iter().zip(ot.rows.iter()).enumerate() {
        let row_fmt = diff_prop_change_rev(
            rr.props.fmt_change.as_deref(),
            orow.props.fmt_change.as_deref(),
        );
        let exc_fmt = match (
            rr.props.exceptions.as_deref(),
            orow.props.exceptions.as_deref(),
        ) {
            (Some(re), Some(oe)) => {
                diff_prop_change_rev(re.fmt_change.as_deref(), oe.fmt_change.as_deref())
            }
            _ => None,
        };
        if row_fmt.is_some() || exc_fmt.is_some() {
            rows.push(RowRevCheckpoint {
                row: r_idx,
                fmt_rev: row_fmt,
                exc_fmt_rev: exc_fmt,
            });
        }
        for (c_idx, (rc, oc)) in rr.cells.iter().zip(orow.cells.iter()).enumerate() {
            if let Some(cell_rev) = diff_prop_change_rev(
                rc.props.fmt_change.as_deref(),
                oc.props.fmt_change.as_deref(),
            ) {
                cells.push(CellRevCheckpoint {
                    row: r_idx,
                    cell: c_idx,
                    fmt_rev: cell_rev,
                });
            }
        }
    }

    if fmt_rev.is_none() && rows.is_empty() && cells.is_empty() {
        None
    } else {
        Some(TableRevCheckpoint {
            index,
            fmt_rev,
            rows,
            cells,
        })
    }
}

fn prop_change_rev<T>(change: Option<&PropChange<T>>) -> Option<u32> {
    change.map(|c| c.rev)
}

fn diff_prop_change_rev<T>(
    r_change: Option<&PropChange<T>>,
    o_change: Option<&PropChange<T>>,
) -> Option<u32> {
    match (r_change, o_change) {
        (Some(rc), Some(oc)) if rc.rev != oc.rev => Some(oc.rev),
        _ => None,
    }
}

fn apply_part_map(doc: &mut Document, part_map: &BTreeMap<u32, u32>) -> Result<(), Error> {
    let mut full_map: BTreeMap<u32, u32> = BTreeMap::new();
    let mut used_targets: BTreeSet<u32> = BTreeSet::new();

    for (&r_id, &o_id) in part_map {
        if r_id == 0 || o_id == 0 {
            return Err(Error::Invalid(
                "word checkpoint part ID must be non-zero".into(),
            ));
        }
        if !used_targets.insert(o_id) {
            return Err(Error::Invalid(format!(
                "duplicate target part ID {o_id} in word checkpoint"
            )));
        }
        full_map.insert(r_id, o_id);
    }

    let mut next_free = 1u32;
    for &r_id in doc.parts.keys() {
        if full_map.contains_key(&r_id) {
            continue;
        }
        if used_targets.insert(r_id) {
            full_map.insert(r_id, r_id);
        } else {
            while used_targets.contains(&next_free) {
                next_free = next_free
                    .checked_add(1)
                    .ok_or_else(|| Error::Invalid("exhausted part IDs".into()))?;
            }
            used_targets.insert(next_free);
            full_map.insert(r_id, next_free);
        }
    }

    let old_parts = std::mem::take(&mut doc.parts);
    for (old_id, mut part) in old_parts {
        let new_id = full_map.get(&old_id).copied().unwrap_or(old_id);
        if let Some(next_id) = part.body.next.as_mut()
            && let Some(&mapped) = full_map.get(next_id)
        {
            *next_id = mapped;
        }
        doc.parts.insert(new_id, part);
    }

    let old_part_names = std::mem::take(&mut doc.missing_pictures.part_names);
    for (old_id, name) in old_part_names {
        let new_id = full_map.get(&old_id).copied().unwrap_or(old_id);
        doc.missing_pictures.part_names.insert(new_id, name);
    }

    remap_section_parts(&mut doc.last_section, &full_map);
    for comment in doc.comments.values_mut() {
        if let Some(&mapped) = full_map.get(&comment.part) {
            comment.part = mapped;
        }
    }

    for blocks in all_doc_blocks_mut(doc) {
        remap_blocks_parts(blocks, &full_map, 0);
    }

    Ok(())
}

fn remap_section_parts(sec: &mut SectionProps, full_map: &BTreeMap<u32, u32>) {
    remap_header_set(&mut sec.headers, full_map);
    remap_header_set(&mut sec.footers, full_map);
    if let Some(fc) = sec.fmt_change.as_deref_mut() {
        remap_header_set(&mut fc.old.headers, full_map);
        remap_header_set(&mut fc.old.footers, full_map);
    }
}

fn remap_header_set(set: &mut HeaderSet, full_map: &BTreeMap<u32, u32>) {
    for slot in [&mut set.default, &mut set.first, &mut set.even] {
        if let Some(id) = slot
            && let Some(&mapped) = full_map.get(id)
        {
            *id = mapped;
        }
    }
}

fn remap_blocks_parts(blocks: &mut Blocks, full_map: &BTreeMap<u32, u32>, depth: usize) {
    if depth > MAX_NESTED_DEPTH {
        return;
    }
    for block in blocks.iter_mut() {
        if !block_needs_part_remap(block, full_map, depth) {
            continue;
        }
        match Arc::make_mut(block) {
            Block::Para(para) => {
                if let Some(sec) = para.section.as_deref_mut() {
                    remap_section_parts(sec, full_map);
                }
                let mut touched = false;
                for obj in &mut para.objects {
                    touched |= remap_object_parts(obj, full_map, depth);
                }
                if touched {
                    para.touch();
                }
            }
            Block::Table(tbl) => {
                for row in &mut tbl.rows {
                    for cell in &mut row.cells {
                        remap_blocks_parts(&mut cell.blocks, full_map, depth + 1);
                    }
                }
            }
        }
    }
}

fn block_needs_part_remap(block: &Block, full_map: &BTreeMap<u32, u32>, depth: usize) -> bool {
    if depth > MAX_NESTED_DEPTH {
        return false;
    }
    match block {
        Block::Para(para) => {
            para.section.is_some()
                || para
                    .objects
                    .iter()
                    .any(|o| object_needs_part_remap(o, full_map, depth))
        }
        Block::Table(tbl) => tbl.rows.iter().any(|r| {
            r.cells.iter().any(|c| {
                c.blocks
                    .iter()
                    .any(|b| block_needs_part_remap(b, full_map, depth + 1))
            })
        }),
    }
}

fn object_needs_part_remap(
    obj: &InlineObject,
    full_map: &BTreeMap<u32, u32>,
    depth: usize,
) -> bool {
    if depth > MAX_NESTED_DEPTH {
        return false;
    }
    match obj {
        InlineObject::NoteRef { id, .. } => full_map.get(id).is_some_and(|&m| m != *id),
        InlineObject::Shape {
            story: Some(id), ..
        } => full_map.get(id).is_some_and(|&m| m != *id),
        InlineObject::Group { children, .. } => children
            .iter()
            .any(|c| object_needs_part_remap(&c.obj, full_map, depth + 1)),
        _ => false,
    }
}

fn remap_object_parts(obj: &mut InlineObject, full_map: &BTreeMap<u32, u32>, depth: usize) -> bool {
    if depth > MAX_NESTED_DEPTH {
        return false;
    }
    match obj {
        InlineObject::NoteRef { id, .. } => {
            if let Some(&mapped) = full_map.get(id)
                && mapped != *id
            {
                *id = mapped;
                return true;
            }
            false
        }
        InlineObject::Shape {
            story: Some(id), ..
        } => {
            if let Some(&mapped) = full_map.get(id)
                && mapped != *id
            {
                *id = mapped;
                return true;
            }
            false
        }
        InlineObject::Group { children, .. } => {
            let mut changed = false;
            for child in children {
                changed |= remap_object_parts(&mut child.obj, full_map, depth + 1);
            }
            changed
        }
        _ => false,
    }
}

fn apply_media_map(doc: &mut Document, media_map: &BTreeMap<String, String>) -> Result<(), Error> {
    let mut full_map: BTreeMap<String, String> = BTreeMap::new();
    let mut used_targets: BTreeSet<String> = BTreeSet::new();

    for (r_key, o_key) in media_map {
        if r_key.is_empty() || o_key.is_empty() {
            return Err(Error::Invalid(
                "word checkpoint media key must be non-empty".into(),
            ));
        }
        if !used_targets.insert(o_key.clone()) {
            return Err(Error::Invalid(format!(
                "duplicate target media key `{o_key}` in word checkpoint"
            )));
        }
        full_map.insert(r_key.clone(), o_key.clone());
    }

    let mut suffix = 1usize;
    for r_key in doc.media.keys() {
        if full_map.contains_key(r_key) {
            continue;
        }
        if used_targets.insert(r_key.clone()) {
            full_map.insert(r_key.clone(), r_key.clone());
        } else {
            loop {
                let candidate = format!("{r_key}_{suffix}");
                suffix = suffix.saturating_add(1);
                if used_targets.insert(candidate.clone()) {
                    full_map.insert(r_key.clone(), candidate);
                    break;
                }
            }
        }
    }

    let old_media = std::mem::take(&mut doc.media);
    for (old_key, bytes) in old_media {
        let new_key = full_map.get(&old_key).cloned().unwrap_or(old_key);
        doc.media.insert(new_key, bytes);
    }

    let old_media_parts = std::mem::take(&mut doc.missing_pictures.media_parts);
    for (old_key, part_name) in old_media_parts {
        let new_key = full_map.get(&old_key).cloned().unwrap_or(old_key);
        doc.missing_pictures.media_parts.insert(new_key, part_name);
    }

    if let Some(pic) = doc.settings.page_picture.as_mut()
        && let Some(mapped) = full_map.get(&pic.media)
    {
        pic.media.clone_from(mapped);
    }

    for blocks in all_doc_blocks_mut(doc) {
        remap_blocks_media(blocks, &full_map, 0);
    }

    Ok(())
}

fn remap_blocks_media(blocks: &mut Blocks, full_map: &BTreeMap<String, String>, depth: usize) {
    if depth > MAX_NESTED_DEPTH {
        return;
    }
    for block in blocks.iter_mut() {
        if !block_needs_media_remap(block, full_map, depth) {
            continue;
        }
        match Arc::make_mut(block) {
            Block::Para(para) => {
                for obj in &mut para.objects {
                    remap_object_media(obj, full_map, depth);
                }
                para.touch();
            }
            Block::Table(tbl) => {
                for row in &mut tbl.rows {
                    for cell in &mut row.cells {
                        if let Some(pic) = cell.props.picture.as_deref_mut()
                            && let Some(mapped) = full_map.get(&pic.media)
                        {
                            pic.media.clone_from(mapped);
                        }
                        if let Some(fc) = cell.props.fmt_change.as_deref_mut()
                            && let Some(pic) = fc.old.picture.as_deref_mut()
                            && let Some(mapped) = full_map.get(&pic.media)
                        {
                            pic.media.clone_from(mapped);
                        }
                        remap_blocks_media(&mut cell.blocks, full_map, depth + 1);
                    }
                }
            }
        }
    }
}

fn block_needs_media_remap(
    block: &Block,
    full_map: &BTreeMap<String, String>,
    depth: usize,
) -> bool {
    if depth > MAX_NESTED_DEPTH {
        return false;
    }
    match block {
        Block::Para(para) => para
            .objects
            .iter()
            .any(|o| object_needs_media_remap(o, full_map, depth)),
        Block::Table(tbl) => tbl.rows.iter().any(|r| {
            r.cells.iter().any(|c| {
                c.props
                    .picture
                    .as_deref()
                    .is_some_and(|p| full_map.get(&p.media).is_some_and(|m| m != &p.media))
                    || c.props
                        .fmt_change
                        .as_deref()
                        .and_then(|fc| fc.old.picture.as_deref())
                        .is_some_and(|p| full_map.get(&p.media).is_some_and(|m| m != &p.media))
                    || c.blocks
                        .iter()
                        .any(|b| block_needs_media_remap(b, full_map, depth + 1))
            })
        }),
    }
}

fn object_needs_media_remap(
    obj: &InlineObject,
    full_map: &BTreeMap<String, String>,
    depth: usize,
) -> bool {
    if depth > MAX_NESTED_DEPTH {
        return false;
    }
    match obj {
        InlineObject::Image { media, .. } => full_map.get(media).is_some_and(|m| m != media),
        InlineObject::Graphic { graphic, .. } => graphic.items.iter().any(|item| match item {
            GraphicItem::Image { media, .. } => full_map.get(media).is_some_and(|m| m != media),
            _ => false,
        }),
        InlineObject::Group { children, .. } => children
            .iter()
            .any(|c| object_needs_media_remap(&c.obj, full_map, depth + 1)),
        _ => false,
    }
}

fn remap_object_media(obj: &mut InlineObject, full_map: &BTreeMap<String, String>, depth: usize) {
    if depth > MAX_NESTED_DEPTH {
        return;
    }
    match obj {
        InlineObject::Image { media, .. } => {
            if let Some(mapped) = full_map.get(media) {
                media.clone_from(mapped);
            }
        }
        InlineObject::Graphic { graphic, .. } => {
            let needs = graphic.items.iter().any(|item| {
                matches!(
                    item,
                    GraphicItem::Image { media, .. } if full_map.get(media).is_some_and(|m| m != media)
                )
            });
            if needs {
                for item in &mut Arc::make_mut(graphic).items {
                    if let GraphicItem::Image { media, .. } = item
                        && let Some(mapped) = full_map.get(media)
                    {
                        media.clone_from(mapped);
                    }
                }
            }
        }
        InlineObject::Group { children, .. } => {
            for child in children {
                remap_object_media(&mut child.obj, full_map, depth + 1);
            }
        }
        _ => {}
    }
}

fn apply_story_checkpoint(
    doc: &mut Document,
    story_cp: &StoryCheckpoint,
    rev_len: usize,
) -> Result<(), Error> {
    validate_story_rev_slots(story_cp, rev_len)?;
    let Some(blocks) = story_blocks_mut(doc, story_cp.story) else {
        return Ok(());
    };

    let mut counts = StoryCounts::default();
    count_story_items(blocks, 0, &mut counts);

    let apply_shapes = !story_cp.shapes.is_empty() && counts.shapes == story_cp.shape_count;
    let apply_paras = !story_cp.paras.is_empty() && counts.paras == story_cp.para_count;
    let apply_tables = !story_cp.tables.is_empty() && counts.tables == story_cp.table_count;

    if !apply_shapes && !apply_paras && !apply_tables {
        return Ok(());
    }

    let shape_by_idx: BTreeMap<usize, &ShapeCheckpoint> = if apply_shapes {
        story_cp.shapes.iter().map(|s| (s.index, s)).collect()
    } else {
        BTreeMap::new()
    };
    let para_by_idx: BTreeMap<usize, &ParaRevCheckpoint> = if apply_paras {
        story_cp.paras.iter().map(|p| (p.index, p)).collect()
    } else {
        BTreeMap::new()
    };
    let table_by_idx: BTreeMap<usize, &TableRevCheckpoint> = if apply_tables {
        story_cp.tables.iter().map(|t| (t.index, t)).collect()
    } else {
        BTreeMap::new()
    };

    let mut cursor = StoryCounts::default();
    apply_story_blocks(
        blocks,
        0,
        &mut cursor,
        &shape_by_idx,
        &para_by_idx,
        &table_by_idx,
    );

    Ok(())
}

#[derive(Default)]
struct StoryCounts {
    shapes: usize,
    paras: usize,
    tables: usize,
}

fn count_story_items(blocks: &Blocks, depth: usize, counts: &mut StoryCounts) {
    if depth > MAX_NESTED_DEPTH {
        return;
    }
    for block in blocks {
        match block.as_ref() {
            Block::Para(para) => {
                counts.paras = counts.paras.saturating_add(1);
                for obj in &para.objects {
                    count_object_shapes(obj, depth, counts);
                }
            }
            Block::Table(tbl) => {
                counts.tables = counts.tables.saturating_add(1);
                for row in &tbl.rows {
                    for cell in &row.cells {
                        count_story_items(&cell.blocks, depth + 1, counts);
                    }
                }
            }
        }
    }
}

fn count_object_shapes(obj: &InlineObject, depth: usize, counts: &mut StoryCounts) {
    if depth > MAX_NESTED_DEPTH {
        return;
    }
    match obj {
        InlineObject::Shape { .. } => {
            counts.shapes = counts.shapes.saturating_add(1);
        }
        InlineObject::Group { children, .. } => {
            for child in children {
                count_object_shapes(&child.obj, depth + 1, counts);
            }
        }
        _ => {}
    }
}

fn apply_story_blocks(
    blocks: &mut Blocks,
    depth: usize,
    cursor: &mut StoryCounts,
    shape_by_idx: &BTreeMap<usize, &ShapeCheckpoint>,
    para_by_idx: &BTreeMap<usize, &ParaRevCheckpoint>,
    table_by_idx: &BTreeMap<usize, &TableRevCheckpoint>,
) {
    if depth > MAX_NESTED_DEPTH {
        return;
    }
    for block in blocks.iter_mut() {
        match block.as_ref() {
            Block::Para(para) => {
                let para_idx = cursor.paras;
                cursor.paras = cursor.paras.saturating_add(1);
                let shape_start = cursor.shapes;
                for obj in &para.objects {
                    count_object_shapes(obj, depth, cursor);
                }
                let shape_end = cursor.shapes;

                let has_para_cp = para_by_idx.contains_key(&para_idx);
                let has_shape_cp = shape_by_idx.range(shape_start..shape_end).next().is_some();

                if (has_para_cp || has_shape_cp)
                    && let Block::Para(para_mut) = Arc::make_mut(block)
                {
                    if let Some(p_cp) = para_by_idx.get(&para_idx) {
                        apply_para_rev(para_mut, p_cp);
                    }
                    if has_shape_cp {
                        let mut shape_cursor = shape_start;
                        for obj in &mut para_mut.objects {
                            apply_object_shapes(obj, depth, &mut shape_cursor, shape_by_idx);
                        }
                        para_mut.touch();
                    }
                }
            }
            Block::Table(_) => {
                let tbl_idx = cursor.tables;
                cursor.tables = cursor.tables.saturating_add(1);
                if let Block::Table(tbl_mut) = Arc::make_mut(block) {
                    if let Some(t_cp) = table_by_idx.get(&tbl_idx) {
                        apply_table_rev(tbl_mut, t_cp);
                    }
                    for row in &mut tbl_mut.rows {
                        for cell in &mut row.cells {
                            apply_story_blocks(
                                &mut cell.blocks,
                                depth + 1,
                                cursor,
                                shape_by_idx,
                                para_by_idx,
                                table_by_idx,
                            );
                        }
                    }
                }
            }
        }
    }
}

fn apply_object_shapes(
    obj: &mut InlineObject,
    depth: usize,
    shape_cursor: &mut usize,
    shape_by_idx: &BTreeMap<usize, &ShapeCheckpoint>,
) {
    if depth > MAX_NESTED_DEPTH {
        return;
    }
    match obj {
        InlineObject::Shape { extra, .. } => {
            let idx = *shape_cursor;
            *shape_cursor = shape_cursor.saturating_add(1);
            if let Some(s_cp) = shape_by_idx.get(&idx) {
                extra.id = s_cp.id;
                extra.start = s_cp.start;
                extra.end = s_cp.end;
            }
        }
        InlineObject::Group { children, .. } => {
            for child in children {
                apply_object_shapes(&mut child.obj, depth + 1, shape_cursor, shape_by_idx);
            }
        }
        _ => {}
    }
}

fn apply_para_rev(para: &mut Paragraph, cp: &ParaRevCheckpoint) {
    if para.text.len() != cp.text_len {
        return;
    }
    if let (Some(nc), Some(rev)) = (para.props.num_change.as_deref_mut(), cp.num_rev) {
        nc.rev = rev;
    }
    if let (Some(fc), Some(rev)) = (para.props.fmt_change.as_deref_mut(), cp.fmt_rev) {
        fc.rev = rev;
    }
    if let (Some(sec), Some(rev)) = (para.section.as_deref_mut(), cp.section_fmt_rev)
        && let Some(fc) = sec.fmt_change.as_deref_mut()
    {
        fc.rev = rev;
    }
    if let Some(ins) = cp.mark_ins {
        para.mark.ins = Some(ins);
    }
    if let Some(del) = cp.mark_del {
        para.mark.del = Some(del);
    }
    if let (Some(fc), Some(rev)) = (para.mark.fmt_change.as_deref_mut(), cp.mark_fmt_rev) {
        fc.rev = rev;
    }
    for span in &cp.spans {
        let _ = para.format(span.start, span.end, &|props| {
            props.ins = span.ins;
            props.del = span.del;
            if let (Some(fc), Some(rev)) = (props.fmt_change.as_deref_mut(), span.fmt_rev) {
                fc.rev = rev;
            }
        });
    }
    for ruby in &cp.ruby_revs {
        if let Some(InlineObject::Ruby { props, .. }) = para.objects.get_mut(ruby.obj_index) {
            if let Some(ins) = ruby.ins {
                props.ins = Some(ins);
            }
            if let Some(del) = ruby.del {
                props.del = Some(del);
            }
            if let (Some(fc), Some(rev)) = (props.fmt_change.as_deref_mut(), ruby.fmt_rev) {
                fc.rev = rev;
            }
        }
    }
    para.touch();
}

fn apply_table_rev(tbl: &mut Table, cp: &TableRevCheckpoint) {
    if let (Some(fc), Some(rev)) = (tbl.props.fmt_change.as_deref_mut(), cp.fmt_rev) {
        fc.rev = rev;
    }
    for row_cp in &cp.rows {
        if let Some(row) = tbl.rows.get_mut(row_cp.row) {
            if let (Some(fc), Some(rev)) = (row.props.fmt_change.as_deref_mut(), row_cp.fmt_rev) {
                fc.rev = rev;
            }
            if let (Some(exc), Some(rev)) =
                (row.props.exceptions.as_deref_mut(), row_cp.exc_fmt_rev)
                && let Some(fc) = exc.fmt_change.as_deref_mut()
            {
                fc.rev = rev;
            }
        }
    }
    for cell_cp in &cp.cells {
        if let Some(row) = tbl.rows.get_mut(cell_cp.row)
            && let Some(cell) = row.cells.get_mut(cell_cp.cell)
            && let Some(fc) = cell.props.fmt_change.as_deref_mut()
        {
            fc.rev = cell_cp.fmt_rev;
        }
    }
}

fn validate_story_rev_slots(story_cp: &StoryCheckpoint, rev_len: usize) -> Result<(), Error> {
    for p in &story_cp.paras {
        for slot in [
            p.num_rev,
            p.fmt_rev,
            p.section_fmt_rev,
            p.mark_ins,
            p.mark_del,
            p.mark_fmt_rev,
        ]
        .into_iter()
        .flatten()
        {
            validate_rev_slot(slot, rev_len)?;
        }
        for span in &p.spans {
            for slot in [span.ins, span.del, span.fmt_rev].into_iter().flatten() {
                validate_rev_slot(slot, rev_len)?;
            }
        }
        for ruby in &p.ruby_revs {
            for slot in [ruby.ins, ruby.del, ruby.fmt_rev].into_iter().flatten() {
                validate_rev_slot(slot, rev_len)?;
            }
        }
    }
    for t in &story_cp.tables {
        if let Some(slot) = t.fmt_rev {
            validate_rev_slot(slot, rev_len)?;
        }
        for r in &t.rows {
            for slot in [r.fmt_rev, r.exc_fmt_rev].into_iter().flatten() {
                validate_rev_slot(slot, rev_len)?;
            }
        }
        for c in &t.cells {
            validate_rev_slot(c.fmt_rev, rev_len)?;
        }
    }
    Ok(())
}

fn validate_rev_slot(slot: u32, rev_len: usize) -> Result<(), Error> {
    if (slot as usize) >= rev_len {
        return Err(Error::Invalid(format!(
            "word checkpoint revision slot {slot} out of bounds (revisions={rev_len})"
        )));
    }
    Ok(())
}

fn story_blocks_mut(doc: &mut Document, key: StoryKey) -> Option<&mut Blocks> {
    match key {
        StoryKey::Body => Some(&mut doc.body),
        StoryKey::Part(id) => doc.parts.get_mut(&id).map(|p| &mut p.blocks),
        StoryKey::FootnoteSep(0) => doc.footnote_separators.separator.as_mut(),
        StoryKey::FootnoteSep(1) => doc.footnote_separators.continuation_separator.as_mut(),
        StoryKey::FootnoteSep(2) => doc.footnote_separators.continuation_notice.as_mut(),
        StoryKey::FootnoteSep(_) => None,
        StoryKey::EndnoteSep(0) => doc.endnote_separators.separator.as_mut(),
        StoryKey::EndnoteSep(1) => doc.endnote_separators.continuation_separator.as_mut(),
        StoryKey::EndnoteSep(2) => doc.endnote_separators.continuation_notice.as_mut(),
        StoryKey::EndnoteSep(_) => None,
        StoryKey::Glossary(idx) => doc.glossary.get_mut(idx).map(|b| &mut b.blocks),
    }
}

fn all_doc_blocks_mut(doc: &mut Document) -> Vec<&mut Blocks> {
    let mut out = Vec::new();
    out.push(&mut doc.body);
    out.extend(doc.parts.values_mut().map(|p| &mut p.blocks));
    for sep in [&mut doc.footnote_separators, &mut doc.endnote_separators] {
        if let Some(b) = sep.separator.as_mut() {
            out.push(b);
        }
        if let Some(b) = sep.continuation_separator.as_mut() {
            out.push(b);
        }
        if let Some(b) = sep.continuation_notice.as_mut() {
            out.push(b);
        }
    }
    out.extend(doc.glossary.iter_mut().map(|b| &mut b.blocks));
    out
}
