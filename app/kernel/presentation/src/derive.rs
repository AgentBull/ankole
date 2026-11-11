//! Deriving minimal canonical [`ChangeSet`]s between two [`PresentationDoc`] snapshots.

use std::collections::{HashMap, HashSet};
use std::sync::Arc;

use deckcraft_model::{Master, MediaItem, Slide};
use serde::Serialize;

use crate::ops::{ChangeSet, DeckField, Edit, InsertedSlide, encode_base64};
use crate::{Error, MODEL_VERSION, PresentationDoc};

/// Derives the minimal unit-level [`ChangeSet`] transforming `before` into `after`, or `Ok(None)`
/// when both documents carry the same logical content.
///
/// # Errors
///
/// Returns [`Error::Write`] if any modified field cannot be serialized into JSON.
pub fn derive(
    before: &PresentationDoc,
    after: &PresentationDoc,
) -> Result<Option<ChangeSet>, Error> {
    if Arc::ptr_eq(before.presentation_arc(), after.presentation_arc()) {
        return Ok(None);
    }
    let b = before.presentation();
    let a = after.presentation();
    let mut edits = Vec::new();

    derive_media(&b.media, &a.media, &mut edits);
    derive_slides(&b.slides, &a.slides, &mut edits);
    derive_deck_fields(b, a, &mut edits)?;

    if edits.is_empty() {
        Ok(None)
    } else {
        Ok(Some(ChangeSet {
            model_version: MODEL_VERSION,
            edits,
        }))
    }
}

fn derive_media(before: &[MediaItem], after: &[MediaItem], edits: &mut Vec<Edit>) {
    let before_map: HashMap<u32, &MediaItem> = before.iter().map(|m| (m.id.0, m)).collect();
    let after_ids: HashSet<u32> = after.iter().map(|m| m.id.0).collect();

    for b_item in before {
        if !after_ids.contains(&b_item.id.0) {
            edits.push(Edit::MediaDelete { id: b_item.id.0 });
        }
    }

    for a_item in after {
        let unchanged = before_map.get(&a_item.id.0).is_some_and(|b_item| {
            b_item.name == a_item.name
                && b_item.content_type == a_item.content_type
                && b_item.link == a_item.link
                && (Arc::ptr_eq(&b_item.data, &a_item.data) || *b_item.data == *a_item.data)
        });
        if !unchanged {
            edits.push(Edit::MediaPut {
                id: a_item.id.0,
                filename: a_item.name.clone(),
                mime: a_item.content_type.clone(),
                data: encode_base64(&a_item.data),
                link: a_item.link.clone(),
            });
        }
    }
}

fn derive_slides(before: &[Arc<Slide>], after: &[Arc<Slide>], edits: &mut Vec<Edit>) {
    let before_order: Vec<u32> = before.iter().map(|s| s.id.0).collect();
    let after_order: Vec<u32> = after.iter().map(|s| s.id.0).collect();
    let before_by_id: HashMap<u32, &Arc<Slide>> = before.iter().map(|s| (s.id.0, s)).collect();

    if before_order != after_order {
        let mut insert = Vec::new();
        for s in after {
            if !before_by_id.contains_key(&s.id.0) {
                insert.push(InsertedSlide {
                    id: s.id.0,
                    value: (**s).clone(),
                });
            }
        }
        edits.push(Edit::SlidesOrder {
            order: after_order,
            insert,
        });
    }

    for a_slide in after {
        if let Some(b_slide) = before_by_id.get(&a_slide.id.0)
            && !Arc::ptr_eq(b_slide, a_slide)
            && ***b_slide != **a_slide
        {
            edits.push(Edit::SlidePut {
                slide: a_slide.id.0,
                value: (**a_slide).clone(),
            });
        }
    }
}

fn masters_eq(before: &[Arc<Master>], after: &[Arc<Master>]) -> bool {
    before.len() == after.len()
        && before
            .iter()
            .zip(after.iter())
            .all(|(b, a)| Arc::ptr_eq(b, a) || **b == **a)
}

fn opt_master_eq(before: &Option<Arc<Master>>, after: &Option<Arc<Master>>) -> bool {
    match (before, after) {
        (None, None) => true,
        (Some(b), Some(a)) => Arc::ptr_eq(b, a) || **b == **a,
        _ => false,
    }
}

fn push_deck_set<T: Serialize>(
    edits: &mut Vec<Edit>,
    field: DeckField,
    val: &T,
) -> Result<(), Error> {
    let value = serde_json::to_value(val).map_err(|err| {
        Error::Write(format!("failed to serialize deck field {:?}: {err}", field))
    })?;
    edits.push(Edit::DeckSet { field, value });
    Ok(())
}

fn derive_deck_fields(
    b: &deckcraft_model::Presentation,
    a: &deckcraft_model::Presentation,
    edits: &mut Vec<Edit>,
) -> Result<(), Error> {
    if b.slide_size != a.slide_size {
        push_deck_set(edits, DeckField::SlideSize, &a.slide_size)?;
    }
    if b.notes_size != a.notes_size {
        push_deck_set(edits, DeckField::NotesSize, &a.notes_size)?;
    }
    if !masters_eq(&b.masters, &a.masters) {
        let plain: Vec<&Master> = a.masters.iter().map(Arc::as_ref).collect();
        push_deck_set(edits, DeckField::Masters, &plain)?;
    }
    if !opt_master_eq(&b.notes_master, &a.notes_master) {
        push_deck_set(edits, DeckField::NotesMaster, &a.notes_master.as_deref())?;
    }
    if !opt_master_eq(&b.handout_master, &a.handout_master) {
        push_deck_set(
            edits,
            DeckField::HandoutMaster,
            &a.handout_master.as_deref(),
        )?;
    }
    if b.sections != a.sections {
        push_deck_set(edits, DeckField::Sections, &a.sections)?;
    }
    if b.custom_shows != a.custom_shows {
        push_deck_set(edits, DeckField::CustomShows, &a.custom_shows)?;
    }
    if b.show != a.show {
        push_deck_set(edits, DeckField::ShowSettings, &a.show)?;
    }
    if b.header_footer != a.header_footer {
        push_deck_set(edits, DeckField::HeaderFooter, &a.header_footer)?;
    }
    if b.props != a.props {
        push_deck_set(edits, DeckField::Props, &a.props)?;
    }
    if b.default_text_style != a.default_text_style {
        push_deck_set(edits, DeckField::DefaultTextStyle, &a.default_text_style)?;
    }
    if b.first_slide_number != a.first_slide_number {
        push_deck_set(edits, DeckField::FirstSlideNumber, &a.first_slide_number)?;
    }
    if b.embedded_fonts != a.embedded_fonts {
        push_deck_set(edits, DeckField::EmbeddedFonts, &a.embedded_fonts)?;
    }
    if b.table_styles != a.table_styles {
        push_deck_set(edits, DeckField::TableStyles, &a.table_styles)?;
    }
    if b.tags != a.tags {
        push_deck_set(edits, DeckField::Tags, &a.tags)?;
    }
    if b.kept_parts != a.kept_parts {
        push_deck_set(edits, DeckField::KeptParts, &a.kept_parts)?;
    }
    if b.guides != a.guides {
        push_deck_set(edits, DeckField::Guides, &a.guides)?;
    }
    if b.raw_ext != a.raw_ext {
        push_deck_set(edits, DeckField::RawExt, &a.raw_ext)?;
    }
    Ok(())
}
