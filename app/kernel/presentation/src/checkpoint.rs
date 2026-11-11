//! Deterministic identity checkpointing across pure OOXML `.pptx` compaction.
//!
//! Exported `.pptx` archives contain only standard ECMA-376 PresentationML markup. When
//! `Ankole.Pod.OfficeFiles` compacts uncompacted operations into a fresh object-storage version,
//! [`capture`] compares the in-memory [`Presentation`] before export with the [`Presentation`]
//! decoded by `deckcraft_pptx::import_checked` from the exported bytes, recording remapped slide,
//! layout, master, shape, and media identifiers, `next_id`, and whether `deckcraft_pptx::export`
//! synthesized a default `notes_master` part. Storing that JSON sidecar alongside the compacted
//! `object_id` in PostgreSQL lets [`apply`] restore identical in-memory identifiers without
//! writing proprietary parts into user `.pptx` files.

use std::collections::{BTreeMap, BTreeSet};
use std::sync::Arc;

use deckcraft_engine::media_refs;
use deckcraft_model::table::Table;
use deckcraft_model::text::{Action, Hyperlink, ListStyle, RunProps, TextBody};
use deckcraft_model::{
    Comment, Layout, LayoutId, Master, MasterId, MediaId, Presentation, Shape, ShapeId, ShapeKind,
    Slide, SlideId,
};
use serde::{Deserialize, Serialize};

use crate::Error;

const CHECKPOINT_VERSION: u32 = 1;
const MAX_NESTED_DEPTH: usize = 64;

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub(crate) struct Checkpoint {
    version: u32,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    next_id: Option<u32>,
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    synthetic_notes_master: bool,
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    master_map: BTreeMap<u32, u32>,
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    layout_map: BTreeMap<u32, u32>,
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    slide_map: BTreeMap<u32, u32>,
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    media_map: BTreeMap<u32, u32>,
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    media_names: BTreeMap<u32, String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    part_shapes: Vec<PartShapeCheckpoint>,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(tag = "kind", content = "index", rename_all = "snake_case")]
enum PartKey {
    #[default]
    NotesMaster,
    HandoutMaster,
    Slide(usize),
    Master(usize),
    Layout([usize; 2]),
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
struct PartShapeCheckpoint {
    part: PartKey,
    shape_map: BTreeMap<u32, u32>,
}

pub(crate) fn capture_json(
    orig: &Presentation,
    reopened: &Presentation,
) -> Result<Option<String>, Error> {
    let Some(checkpoint) = capture(orig, reopened) else {
        return Ok(None);
    };
    let json = serde_json::to_string(&checkpoint).map_err(|e| Error::Write(e.to_string()))?;
    Ok(Some(json))
}

pub(crate) fn apply_json(pres: &mut Presentation, checkpoint_json: &str) -> Result<(), Error> {
    let trimmed = checkpoint_json.trim();
    if trimmed.is_empty() {
        return Ok(());
    }
    let checkpoint: Checkpoint = serde_json::from_str(trimmed)
        .map_err(|e| Error::Invalid(format!("invalid presentation checkpoint JSON: {e}")))?;
    apply(pres, &checkpoint)
}

pub(crate) fn capture(orig: &Presentation, reopened: &Presentation) -> Option<Checkpoint> {
    let synthetic_notes_master = orig.notes_master.is_none() && reopened.notes_master.is_some();

    let mut master_map = BTreeMap::new();
    let mut layout_map = BTreeMap::new();
    for (r_master, o_master) in reopened.masters.iter().zip(orig.masters.iter()) {
        if r_master.id != o_master.id {
            master_map.insert(r_master.id.0, o_master.id.0);
        }
        for (r_layout, o_layout) in r_master.layouts.iter().zip(o_master.layouts.iter()) {
            if r_layout.id != o_layout.id {
                layout_map.insert(r_layout.id.0, o_layout.id.0);
            }
        }
    }
    if !synthetic_notes_master
        && let (Some(r_nm), Some(o_nm)) = (&reopened.notes_master, &orig.notes_master)
    {
        if r_nm.id != o_nm.id {
            master_map.insert(r_nm.id.0, o_nm.id.0);
        }
        for (r_layout, o_layout) in r_nm.layouts.iter().zip(o_nm.layouts.iter()) {
            if r_layout.id != o_layout.id {
                layout_map.insert(r_layout.id.0, o_layout.id.0);
            }
        }
    }
    if let (Some(r_hm), Some(o_hm)) = (&reopened.handout_master, &orig.handout_master) {
        if r_hm.id != o_hm.id {
            master_map.insert(r_hm.id.0, o_hm.id.0);
        }
        for (r_layout, o_layout) in r_hm.layouts.iter().zip(o_hm.layouts.iter()) {
            if r_layout.id != o_layout.id {
                layout_map.insert(r_layout.id.0, o_layout.id.0);
            }
        }
    }

    let slide_map: BTreeMap<u32, u32> = reopened
        .slides
        .iter()
        .zip(orig.slides.iter())
        .filter(|(rs, os)| rs.id != os.id)
        .map(|(rs, os)| (rs.id.0, os.id.0))
        .collect();

    let paired_media = collect_media_pairs(reopened, orig, synthetic_notes_master);
    let mut media_names = BTreeMap::new();
    for (&r_mid, &o_mid) in &paired_media {
        if let (Some(r_item), Some(o_item)) =
            (reopened.media(MediaId(r_mid)), orig.media(MediaId(o_mid)))
            && r_item.name != o_item.name
        {
            media_names.insert(o_mid, o_item.name.clone());
        }
    }
    let media_map: BTreeMap<u32, u32> = paired_media
        .into_iter()
        .filter(|(r_id, o_id)| r_id != o_id)
        .collect();

    let mut part_shapes = Vec::new();
    for (idx, (rs, os)) in reopened.slides.iter().zip(orig.slides.iter()).enumerate() {
        let shape_map = collect_shape_map(&rs.shapes, &os.shapes);
        if !shape_map.is_empty() {
            part_shapes.push(PartShapeCheckpoint {
                part: PartKey::Slide(idx),
                shape_map,
            });
        }
    }
    for (m_idx, (rm, om)) in reopened.masters.iter().zip(orig.masters.iter()).enumerate() {
        let shape_map = collect_shape_map(&rm.shapes, &om.shapes);
        if !shape_map.is_empty() {
            part_shapes.push(PartShapeCheckpoint {
                part: PartKey::Master(m_idx),
                shape_map,
            });
        }
        for (l_idx, (rl, ol)) in rm.layouts.iter().zip(om.layouts.iter()).enumerate() {
            let l_map = collect_shape_map(&rl.shapes, &ol.shapes);
            if !l_map.is_empty() {
                part_shapes.push(PartShapeCheckpoint {
                    part: PartKey::Layout([m_idx, l_idx]),
                    shape_map: l_map,
                });
            }
        }
    }
    if !synthetic_notes_master
        && let (Some(r_nm), Some(o_nm)) = (&reopened.notes_master, &orig.notes_master)
    {
        let shape_map = collect_shape_map(&r_nm.shapes, &o_nm.shapes);
        if !shape_map.is_empty() {
            part_shapes.push(PartShapeCheckpoint {
                part: PartKey::NotesMaster,
                shape_map,
            });
        }
    }
    if let (Some(r_hm), Some(o_hm)) = (&reopened.handout_master, &orig.handout_master) {
        let shape_map = collect_shape_map(&r_hm.shapes, &o_hm.shapes);
        if !shape_map.is_empty() {
            part_shapes.push(PartShapeCheckpoint {
                part: PartKey::HandoutMaster,
                shape_map,
            });
        }
    }

    let next_id = (orig.next_id != reopened.next_id).then_some(orig.next_id);

    if next_id.is_none()
        && !synthetic_notes_master
        && master_map.is_empty()
        && layout_map.is_empty()
        && slide_map.is_empty()
        && media_map.is_empty()
        && media_names.is_empty()
        && part_shapes.is_empty()
    {
        return None;
    }

    Some(Checkpoint {
        version: CHECKPOINT_VERSION,
        next_id,
        synthetic_notes_master,
        master_map,
        layout_map,
        slide_map,
        media_map,
        media_names,
        part_shapes,
    })
}

pub(crate) fn apply(pres: &mut Presentation, checkpoint: &Checkpoint) -> Result<(), Error> {
    if checkpoint.version != CHECKPOINT_VERSION {
        return Err(Error::Invalid(format!(
            "unsupported presentation checkpoint version {}",
            checkpoint.version
        )));
    }

    if checkpoint.synthetic_notes_master {
        pres.notes_master = None;
    }

    if !checkpoint.master_map.is_empty() || !checkpoint.layout_map.is_empty() {
        apply_master_and_layout_maps(pres, &checkpoint.master_map, &checkpoint.layout_map)?;
    }

    if !checkpoint.slide_map.is_empty() {
        apply_slide_map(pres, &checkpoint.slide_map)?;
    }

    if !checkpoint.media_map.is_empty() || !checkpoint.media_names.is_empty() {
        apply_media_map(pres, &checkpoint.media_map, &checkpoint.media_names)?;
    }

    for part_cp in &checkpoint.part_shapes {
        apply_part_shapes(pres, part_cp)?;
    }

    if let Some(target_next) = checkpoint.next_id {
        pres.next_id = target_next;
    }
    pres.fix_next_id();
    Ok(())
}

fn collect_media_pairs(
    reopened: &Presentation,
    orig: &Presentation,
    synthetic_notes_master: bool,
) -> BTreeMap<u32, u32> {
    let mut map = BTreeMap::new();
    let mut used_orig = BTreeSet::new();

    let mut record = |r_refs: Vec<MediaId>, o_refs: Vec<MediaId>| {
        for (r_id, o_id) in r_refs.into_iter().zip(o_refs) {
            if !map.contains_key(&r_id.0) && !used_orig.contains(&o_id.0) {
                map.insert(r_id.0, o_id.0);
                used_orig.insert(o_id.0);
            }
        }
    };

    for (rs, os) in reopened.slides.iter().zip(orig.slides.iter()) {
        record(
            collect_media_vec(|f| media_refs::visit::slide(rs, f)),
            collect_media_vec(|f| media_refs::visit::slide(os, f)),
        );
    }
    for (rm, om) in reopened.masters.iter().zip(orig.masters.iter()) {
        record(
            collect_media_vec(|f| media_refs::visit::master(rm, f)),
            collect_media_vec(|f| media_refs::visit::master(om, f)),
        );
    }
    if !synthetic_notes_master
        && let (Some(r_nm), Some(o_nm)) = (&reopened.notes_master, &orig.notes_master)
    {
        record(
            collect_media_vec(|f| media_refs::visit::master(r_nm, f)),
            collect_media_vec(|f| media_refs::visit::master(o_nm, f)),
        );
    }
    if let (Some(r_hm), Some(o_hm)) = (&reopened.handout_master, &orig.handout_master) {
        record(
            collect_media_vec(|f| media_refs::visit::master(r_hm, f)),
            collect_media_vec(|f| media_refs::visit::master(o_hm, f)),
        );
    }
    record(
        collect_media_vec(|f| media_refs::visit::list(&reopened.default_text_style, f)),
        collect_media_vec(|f| media_refs::visit::list(&orig.default_text_style, f)),
    );
    for (rt, ot) in reopened.table_styles.iter().zip(orig.table_styles.iter()) {
        record(
            collect_media_vec(|f| media_refs::visit::table_style(rt, f)),
            collect_media_vec(|f| media_refs::visit::table_style(ot, f)),
        );
    }
    for (rf, of) in reopened
        .embedded_fonts
        .iter()
        .zip(orig.embedded_fonts.iter())
    {
        record(
            collect_media_vec(|f| media_refs::visit::font(rf, f)),
            collect_media_vec(|f| media_refs::visit::font(of, f)),
        );
    }

    map
}

fn collect_media_vec(walk: impl FnOnce(&mut media_refs::visit::F)) -> Vec<MediaId> {
    let mut out = Vec::new();
    walk(&mut |id: &MediaId| out.push(*id));
    out
}

fn collect_shape_map(r_shapes: &[Shape], o_shapes: &[Shape]) -> BTreeMap<u32, u32> {
    let mut map = BTreeMap::new();
    let mut used_orig = BTreeSet::new();
    pair_shapes(r_shapes, o_shapes, 0, &mut map, &mut used_orig);
    map.retain(|r_id, o_id| r_id != o_id);
    map
}

fn pair_shapes(
    r_shapes: &[Shape],
    o_shapes: &[Shape],
    depth: usize,
    map: &mut BTreeMap<u32, u32>,
    used_orig: &mut BTreeSet<u32>,
) {
    if depth > MAX_NESTED_DEPTH {
        return;
    }
    for (rs, os) in r_shapes.iter().zip(o_shapes.iter()) {
        if !map.contains_key(&rs.id.0) && !used_orig.contains(&os.id.0) {
            map.insert(rs.id.0, os.id.0);
            used_orig.insert(os.id.0);
        }
        if let (
            ShapeKind::Group {
                children: r_children,
                ..
            },
            ShapeKind::Group {
                children: o_children,
                ..
            },
        ) = (&rs.kind, &os.kind)
        {
            pair_shapes(r_children, o_children, depth + 1, map, used_orig);
        }
    }
}

fn validate_bijective_targets(
    existing_ids: impl Iterator<Item = u32>,
    map: &BTreeMap<u32, u32>,
    label: &str,
) -> Result<(), Error> {
    let mut targets = BTreeSet::new();
    for id in existing_ids {
        let next = map.get(&id).copied().unwrap_or(id);
        if !targets.insert(next) {
            return Err(Error::Invalid(format!(
                "presentation checkpoint maps multiple {label} entries to ID {next}"
            )));
        }
    }
    Ok(())
}

fn apply_master_and_layout_maps(
    pres: &mut Presentation,
    master_map: &BTreeMap<u32, u32>,
    layout_map: &BTreeMap<u32, u32>,
) -> Result<(), Error> {
    if !master_map.is_empty() {
        let master_ids = pres
            .masters
            .iter()
            .map(|m| m.id.0)
            .chain(pres.notes_master.iter().map(|m| m.id.0))
            .chain(pres.handout_master.iter().map(|m| m.id.0));
        validate_bijective_targets(master_ids, master_map, "master")?;
    }
    if !layout_map.is_empty() {
        let layout_ids = pres
            .masters
            .iter()
            .chain(pres.notes_master.iter())
            .chain(pres.handout_master.iter())
            .flat_map(|m| m.layouts.iter().map(|l| l.id.0));
        validate_bijective_targets(layout_ids, layout_map, "layout")?;
    }

    for master_arc in &mut pres.masters {
        remap_master_and_layouts(Arc::make_mut(master_arc), master_map, layout_map);
    }
    if let Some(nm) = &mut pres.notes_master {
        remap_master_and_layouts(Arc::make_mut(nm), master_map, layout_map);
    }
    if let Some(hm) = &mut pres.handout_master {
        remap_master_and_layouts(Arc::make_mut(hm), master_map, layout_map);
    }
    if !layout_map.is_empty() {
        for slide_arc in &mut pres.slides {
            if let Some(&new_layout) = layout_map.get(&slide_arc.layout.0) {
                Arc::make_mut(slide_arc).layout = LayoutId(new_layout);
            }
        }
    }
    Ok(())
}

fn remap_master_and_layouts(
    master: &mut Master,
    master_map: &BTreeMap<u32, u32>,
    layout_map: &BTreeMap<u32, u32>,
) {
    if let Some(&new_id) = master_map.get(&master.id.0) {
        master.id = MasterId(new_id);
    }
    for layout in &mut master.layouts {
        if let Some(&new_layout) = layout_map.get(&layout.id.0) {
            layout.id = LayoutId(new_layout);
        }
    }
}

fn apply_slide_map(pres: &mut Presentation, slide_map: &BTreeMap<u32, u32>) -> Result<(), Error> {
    validate_bijective_targets(pres.slides.iter().map(|s| s.id.0), slide_map, "slide")?;

    let remap = |sid: SlideId| slide_map.get(&sid.0).copied().map_or(sid, SlideId);

    for slide_arc in &mut pres.slides {
        let slide = Arc::make_mut(slide_arc);
        slide.id = remap(slide.id);
        remap_slide_links(slide, &remap);
    }
    for section in &mut pres.sections {
        for sid in &mut section.slides {
            *sid = remap(*sid);
        }
    }
    for show in &mut pres.custom_shows {
        for sid in &mut show.slides {
            *sid = remap(*sid);
        }
    }
    for master_arc in &mut pres.masters {
        remap_master_links(Arc::make_mut(master_arc), &remap);
    }
    if let Some(nm) = &mut pres.notes_master {
        remap_master_links(Arc::make_mut(nm), &remap);
    }
    if let Some(hm) = &mut pres.handout_master {
        remap_master_links(Arc::make_mut(hm), &remap);
    }
    remap_list_style_links(&mut pres.default_text_style, &remap);
    Ok(())
}

fn remap_slide_links(slide: &mut Slide, remap: &dyn Fn(SlideId) -> SlideId) {
    remap_shapes_links(&mut slide.shapes, 0, remap);
    remap_text_links(&mut slide.notes, remap);
}

fn remap_master_links(master: &mut Master, remap: &dyn Fn(SlideId) -> SlideId) {
    remap_shapes_links(&mut master.shapes, 0, remap);
    remap_list_style_links(&mut master.title_style, remap);
    remap_list_style_links(&mut master.body_style, remap);
    remap_list_style_links(&mut master.other_style, remap);
    for layout in &mut master.layouts {
        remap_layout_links(layout, remap);
    }
}

fn remap_layout_links(layout: &mut Layout, remap: &dyn Fn(SlideId) -> SlideId) {
    remap_shapes_links(&mut layout.shapes, 0, remap);
}

fn remap_shapes_links(shapes: &mut [Shape], depth: usize, remap: &dyn Fn(SlideId) -> SlideId) {
    if depth > MAX_NESTED_DEPTH {
        return;
    }
    for shape in shapes {
        remap_opt_hyperlink(&mut shape.click, remap);
        remap_opt_hyperlink(&mut shape.hover, remap);
        if let Some(text) = &mut shape.text {
            remap_text_links(text, remap);
        }
        match &mut shape.kind {
            ShapeKind::Group { children, .. } => {
                remap_shapes_links(children, depth + 1, remap);
            }
            ShapeKind::Table(table) => remap_table_links(table, remap),
            _ => {}
        }
    }
}

fn remap_table_links(table: &mut Table, remap: &dyn Fn(SlideId) -> SlideId) {
    for row in &mut table.rows {
        for cell in &mut row.cells {
            remap_text_links(&mut cell.text, remap);
        }
    }
}

fn remap_text_links(text: &mut TextBody, remap: &dyn Fn(SlideId) -> SlideId) {
    remap_list_style_links(&mut text.list_style, remap);
    for para in &mut text.paragraphs {
        remap_run_links(&mut para.def_props, remap);
        remap_run_links(&mut para.end_props, remap);
        for run in &mut para.runs {
            remap_run_links(&mut run.props, remap);
        }
    }
}

fn remap_list_style_links(list: &mut ListStyle, remap: &dyn Fn(SlideId) -> SlideId) {
    for level in list.levels.iter_mut().flatten() {
        remap_run_links(&mut level.run, remap);
    }
}

fn remap_run_links(run: &mut RunProps, remap: &dyn Fn(SlideId) -> SlideId) {
    remap_opt_hyperlink(&mut run.link, remap);
    remap_opt_hyperlink(&mut run.hover, remap);
}

fn remap_opt_hyperlink(link: &mut Option<Hyperlink>, remap: &dyn Fn(SlideId) -> SlideId) {
    let Some(h) = link else {
        return;
    };
    if let Action::Slide { slide } = &mut h.action {
        *slide = remap(*slide);
    }
    if let Some(ret) = &mut h.zoom_return {
        *ret = remap(*ret);
    }
}

fn apply_media_map(
    pres: &mut Presentation,
    media_map: &BTreeMap<u32, u32>,
    media_names: &BTreeMap<u32, String>,
) -> Result<(), Error> {
    if !media_map.is_empty() {
        validate_bijective_targets(pres.media.iter().map(|m| m.id.0), media_map, "media")?;
        let mut remap = |id: &mut MediaId| {
            if let Some(&new_id) = media_map.get(&id.0) {
                *id = MediaId(new_id);
            }
        };
        for slide_arc in &mut pres.slides {
            media_refs::visit_mut::slide(Arc::make_mut(slide_arc), &mut remap);
        }
        for master_arc in &mut pres.masters {
            media_refs::visit_mut::master(Arc::make_mut(master_arc), &mut remap);
        }
        if let Some(nm) = &mut pres.notes_master {
            media_refs::visit_mut::master(Arc::make_mut(nm), &mut remap);
        }
        if let Some(hm) = &mut pres.handout_master {
            media_refs::visit_mut::master(Arc::make_mut(hm), &mut remap);
        }
        media_refs::visit_mut::list(&mut pres.default_text_style, &mut remap);
        for ts in &mut pres.table_styles {
            media_refs::visit_mut::table_style(ts, &mut remap);
        }
        for ef in &mut pres.embedded_fonts {
            media_refs::visit_mut::font(ef, &mut remap);
        }
        for item in &mut pres.media {
            remap(&mut item.id);
        }
    }

    for item in &mut pres.media {
        if let Some(orig_name) = media_names.get(&item.id.0) {
            item.name.clone_from(orig_name);
        }
    }
    Ok(())
}

fn apply_part_shapes(pres: &mut Presentation, part_cp: &PartShapeCheckpoint) -> Result<(), Error> {
    if part_cp.shape_map.is_empty() {
        return Ok(());
    }
    let remap = |sid: ShapeId| part_cp.shape_map.get(&sid.0).copied().map_or(sid, ShapeId);

    match part_cp.part {
        PartKey::Slide(idx) => {
            let slide_arc = pres.slides.get_mut(idx).ok_or_else(|| {
                Error::Invalid(format!("presentation checkpoint slide index {idx} missing"))
            })?;
            validate_part_shape_bijection(&slide_arc.shapes, &part_cp.shape_map)?;
            let slide = Arc::make_mut(slide_arc);
            remap_shapes_ids(&mut slide.shapes, 0, &remap);
            for anim in &mut slide.animations {
                anim.shape = remap(anim.shape);
                if let Some(trigger) = &mut anim.trigger {
                    *trigger = remap(*trigger);
                }
            }
            remap_comment_shapes(&mut slide.comments, 0, &remap);
        }
        PartKey::Master(m_idx) => {
            let master_arc = pres.masters.get_mut(m_idx).ok_or_else(|| {
                Error::Invalid(format!(
                    "presentation checkpoint master index {m_idx} missing"
                ))
            })?;
            validate_part_shape_bijection(&master_arc.shapes, &part_cp.shape_map)?;
            remap_shapes_ids(&mut Arc::make_mut(master_arc).shapes, 0, &remap);
        }
        PartKey::Layout([m_idx, l_idx]) => {
            let master_arc = pres.masters.get_mut(m_idx).ok_or_else(|| {
                Error::Invalid(format!(
                    "presentation checkpoint master index {m_idx} missing"
                ))
            })?;
            let layout = Arc::make_mut(master_arc)
                .layouts
                .get_mut(l_idx)
                .ok_or_else(|| {
                    Error::Invalid(format!(
                        "presentation checkpoint layout [{m_idx}, {l_idx}] missing"
                    ))
                })?;
            validate_part_shape_bijection(&layout.shapes, &part_cp.shape_map)?;
            remap_shapes_ids(&mut layout.shapes, 0, &remap);
        }
        PartKey::NotesMaster => {
            if let Some(nm) = &mut pres.notes_master {
                validate_part_shape_bijection(&nm.shapes, &part_cp.shape_map)?;
                remap_shapes_ids(&mut Arc::make_mut(nm).shapes, 0, &remap);
            }
        }
        PartKey::HandoutMaster => {
            if let Some(hm) = &mut pres.handout_master {
                validate_part_shape_bijection(&hm.shapes, &part_cp.shape_map)?;
                remap_shapes_ids(&mut Arc::make_mut(hm).shapes, 0, &remap);
            }
        }
    }
    Ok(())
}

fn validate_part_shape_bijection(
    shapes: &[Shape],
    shape_map: &BTreeMap<u32, u32>,
) -> Result<(), Error> {
    let mut existing = Vec::new();
    deckcraft_model::walk(shapes, &mut |shape, _| existing.push(shape.id.0));
    validate_bijective_targets(existing.into_iter(), shape_map, "shape")
}

fn remap_shapes_ids(shapes: &mut [Shape], depth: usize, remap: &dyn Fn(ShapeId) -> ShapeId) {
    if depth > MAX_NESTED_DEPTH {
        return;
    }
    for shape in shapes {
        shape.id = remap(shape.id);
        match &mut shape.kind {
            ShapeKind::Group { children, .. } => remap_shapes_ids(children, depth + 1, remap),
            ShapeKind::Connector { start, end } => {
                if let Some((sid, _)) = start {
                    *sid = remap(*sid);
                }
                if let Some((sid, _)) = end {
                    *sid = remap(*sid);
                }
            }
            _ => {}
        }
    }
}

fn remap_comment_shapes(
    comments: &mut [Comment],
    depth: usize,
    remap: &dyn Fn(ShapeId) -> ShapeId,
) {
    if depth > MAX_NESTED_DEPTH {
        return;
    }
    for comment in comments {
        if let Some(sid) = &mut comment.shape {
            *sid = remap(*sid);
        }
        remap_comment_shapes(&mut comment.replies, depth + 1, remap);
    }
}
