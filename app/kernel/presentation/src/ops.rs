//! Canonical wire change sets for presentation operations.

use std::collections::{HashMap, HashSet};
use std::sync::Arc;

use deckcraft_geom::Size;
use deckcraft_model::table::TableStyleDef;
use deckcraft_model::text::ListStyle;
use deckcraft_model::{
    CustomShow, DrawGuide, EmbeddedFont, HeaderFooter, KeptPart, Master, MediaId, MediaItem,
    Presentation, Properties, Section, Shape, ShowSettings, Slide, SlideId,
};
use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::{ApplyError, Error, MAX_OP_BYTES, MAX_PICTURE_BYTES, MODEL_VERSION};

/// A canonical unit-level change set committed as one atomic presentation operation.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct ChangeSet {
    /// Serialized wire model version of the kernel that produced this operation.
    pub model_version: u32,
    /// Ordered unit-level edits applied together.
    pub edits: Vec<Edit>,
}

impl ChangeSet {
    /// Reports whether any edit in this change set carries embedded media bytes.
    #[must_use]
    pub fn carries_media(&self) -> bool {
        self.edits
            .iter()
            .any(|edit| matches!(edit, Edit::MediaPut { .. }))
    }
}

/// A newly inserted slide carried inside [`Edit::SlidesOrder`].
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct InsertedSlide {
    /// Stable identifier of the new slide (`value.id.0`).
    pub id: u32,
    /// Full slide payload.
    pub value: Slide,
}

/// Deck-wide fields on [`Presentation`] outside individual slides and media items.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum DeckField {
    /// Slide page dimensions (`slide_size`).
    SlideSize,
    /// Notes page dimensions (`notes_size`).
    NotesSize,
    /// Slide masters and their layouts (`masters`).
    Masters,
    /// Optional notes master (`notes_master`).
    NotesMaster,
    /// Optional handout master (`handout_master`).
    HandoutMaster,
    /// Presentation sections (`sections`).
    Sections,
    /// Named custom slide shows (`custom_shows`).
    CustomShows,
    /// Slide show playback settings (`show`).
    ShowSettings,
    /// Deck-wide header and footer settings (`header_footer`).
    HeaderFooter,
    /// Core and extended document properties (`props`).
    Props,
    /// Default text list styles (`default_text_style`).
    DefaultTextStyle,
    /// Starting slide number (`first_slide_number`).
    FirstSlideNumber,
    /// Embedded font table referencing media items (`embedded_fonts`).
    EmbeddedFonts,
    /// Retained OOXML table style parts (`table_styles`).
    TableStyles,
    /// Presentation-level add-in tags (`tags`).
    Tags,
    /// Unmodelled OOXML parts retained verbatim (`kept_parts`).
    KeptParts,
    /// Drawing guides (`guides`).
    Guides,
    /// Presentation-level raw XML extension list (`raw_ext`).
    RawExt,
}

/// One unit-level edit inside a [`ChangeSet`].
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(tag = "kind")]
#[allow(
    clippy::large_enum_variant,
    reason = "SlidePut holds Slide inline to match the public ChangeSet wire type contract"
)]
pub enum Edit {
    /// Replaces the content of an existing slide in place without changing slide order.
    #[serde(rename = "slide.put")]
    SlidePut {
        /// Stable `SlideId` of the target slide.
        slide: u32,
        /// Updated slide value.
        value: Slide,
    },
    /// Sets the deck's slide sequence, deleting omitted existing slides and inserting `insert`.
    #[serde(rename = "slides.order")]
    SlidesOrder {
        /// Desired sequence of `SlideId`s across the presentation.
        order: Vec<u32>,
        /// Payloads for newly introduced `SlideId`s only.
        #[serde(default, skip_serializing_if = "Vec::is_empty")]
        insert: Vec<InsertedSlide>,
    },
    /// Adds or replaces a binary media item (carrying standard base64 bytes on the wire).
    #[serde(rename = "media.put")]
    MediaPut {
        /// Stable `MediaId` of the item.
        id: u32,
        /// File name inside `ppt/media/`.
        filename: String,
        /// MIME content type.
        mime: String,
        /// Standard base64 encoding of `MediaItem.data`.
        data: String,
        /// External relationship target when linked rather than embedded.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        link: Option<String>,
    },
    /// Removes a media item by `MediaId`.
    #[serde(rename = "media.delete")]
    MediaDelete {
        /// Stable `MediaId` to remove.
        id: u32,
    },
    /// Replaces one deck-wide field.
    #[serde(rename = "deck.set")]
    DeckSet {
        /// Which deck-wide field to replace.
        field: DeckField,
        /// Serialized value of that field.
        value: Value,
    },
}

/// Decodes standard base64 text into raw bytes.
pub(crate) fn decode_base64(encoded: &str) -> Result<Vec<u8>, Error> {
    base64_simd::STANDARD
        .decode_to_vec(encoded.as_bytes())
        .map_err(|_| Error::Invalid("media.put data must be valid standard base64".into()))
}

/// Encodes raw bytes as standard base64 text.
pub(crate) fn encode_base64(bytes: &[u8]) -> String {
    base64_simd::STANDARD.encode_to_string(bytes)
}

/// Checks `model_version` on a raw JSON value before full deserialization so future versions
/// report [`ApplyError::FutureVersion`] even if a later kernel added new edit kinds.
fn check_value_version(val: &Value) -> Result<(), ApplyError> {
    let raw_ver = val
        .as_object()
        .and_then(|obj| obj.get("model_version"))
        .and_then(Value::as_u64)
        .ok_or_else(|| {
            ApplyError::Error(Error::Invalid(
                "operation must be a JSON object with an integer model_version".into(),
            ))
        })?;
    let found = u32::try_from(raw_ver).unwrap_or(u32::MAX);
    if found == 0 {
        return Err(ApplyError::Error(Error::Invalid(
            "model_version must be at least 1".into(),
        )));
    }
    if found > MODEL_VERSION {
        return Err(ApplyError::FutureVersion {
            found,
            supported: MODEL_VERSION,
        });
    }
    Ok(())
}

/// Parses and validates a single incoming [`ChangeSet`] JSON string, enforcing [`MAX_OP_BYTES`]
/// and [`MAX_PICTURE_BYTES`].
pub(crate) fn parse_incoming_changeset(json_str: &str) -> Result<ChangeSet, ApplyError> {
    if json_str.len() > MAX_OP_BYTES {
        return Err(ApplyError::Error(Error::Invalid(format!(
            "operation size {} exceeds maximum {} bytes",
            json_str.len(),
            MAX_OP_BYTES
        ))));
    }
    let val: Value = serde_json::from_str(json_str).map_err(|err| {
        ApplyError::Error(Error::Invalid(format!("invalid operation JSON: {err}")))
    })?;
    check_value_version(&val)?;
    let cs: ChangeSet = serde_json::from_value(val).map_err(|err| {
        ApplyError::Error(Error::Invalid(format!("invalid operation payload: {err}")))
    })?;
    validate_changeset(&cs, true)?;
    Ok(cs)
}

/// Parses a JSON array of already-committed [`ChangeSet`]s (for `open` and `prior_ops`).
pub(crate) fn parse_changeset_list(json_str: &str) -> Result<Vec<ChangeSet>, ApplyError> {
    if json_str.trim().is_empty() {
        return Ok(Vec::new());
    }
    let values: Vec<Value> = serde_json::from_str(json_str).map_err(|err| {
        ApplyError::Error(Error::Invalid(format!(
            "expected JSON array of operations: {err}"
        )))
    })?;
    let mut out = Vec::with_capacity(values.len());
    for val in values {
        check_value_version(&val)?;
        let cs: ChangeSet = serde_json::from_value(val).map_err(|err| {
            ApplyError::Error(Error::Invalid(format!(
                "invalid committed operation: {err}"
            )))
        })?;
        validate_changeset(&cs, false)?;
        out.push(cs);
    }
    Ok(out)
}

/// Validates structural invariants of a [`ChangeSet`] independent of the target document.
pub(crate) fn validate_changeset(
    cs: &ChangeSet,
    enforce_picture_limit: bool,
) -> Result<(), ApplyError> {
    if cs.model_version == 0 {
        return Err(ApplyError::Error(Error::Invalid(
            "model_version must be at least 1".into(),
        )));
    }
    if cs.model_version > MODEL_VERSION {
        return Err(ApplyError::FutureVersion {
            found: cs.model_version,
            supported: MODEL_VERSION,
        });
    }

    for edit in &cs.edits {
        match edit {
            Edit::SlidePut { slide, value } => {
                if *slide == 0 || value.id.0 != *slide {
                    return Err(ApplyError::Error(Error::Invalid(format!(
                        "slide.put id {slide} must be non-zero and match value.id {}",
                        value.id.0
                    ))));
                }
                validate_slide_shapes(&value.shapes)?;
            }
            Edit::SlidesOrder { order, insert } => {
                let mut seen_order = HashSet::with_capacity(order.len());
                for &sid in order {
                    if sid == 0 || !seen_order.insert(sid) {
                        return Err(ApplyError::Error(Error::Invalid(format!(
                            "slides.order contains zero or duplicate slide id {sid}"
                        ))));
                    }
                }
                let mut seen_insert = HashSet::with_capacity(insert.len());
                for ins in insert {
                    if ins.id == 0 || ins.value.id.0 != ins.id {
                        return Err(ApplyError::Error(Error::Invalid(format!(
                            "slides.order insert id {} must be non-zero and match slide value id {}",
                            ins.id, ins.value.id.0
                        ))));
                    }
                    if !seen_insert.insert(ins.id) {
                        return Err(ApplyError::Error(Error::Invalid(format!(
                            "slides.order insert contains duplicate slide id {}",
                            ins.id
                        ))));
                    }
                    if !seen_order.contains(&ins.id) {
                        return Err(ApplyError::Error(Error::Invalid(format!(
                            "slides.order insert id {} is absent from order",
                            ins.id
                        ))));
                    }
                    validate_slide_shapes(&ins.value.shapes)?;
                }
            }
            Edit::MediaPut { id, data, .. } => {
                if *id == 0 {
                    return Err(ApplyError::Error(Error::Invalid(
                        "media.put id must be non-zero".into(),
                    )));
                }
                let decoded = decode_base64(data)?;
                if enforce_picture_limit && decoded.len() > MAX_PICTURE_BYTES {
                    return Err(ApplyError::Error(Error::Invalid(format!(
                        "media payload of {} bytes exceeds maximum {} bytes",
                        decoded.len(),
                        MAX_PICTURE_BYTES
                    ))));
                }
            }
            Edit::MediaDelete { id } => {
                if *id == 0 {
                    return Err(ApplyError::Error(Error::Invalid(
                        "media.delete id must be non-zero".into(),
                    )));
                }
            }
            Edit::DeckSet { field, value } => {
                validate_deck_field(*field, value)?;
            }
        }
    }
    Ok(())
}

/// Validates that all shape identifiers inside a shape tree are non-zero and unique.
fn validate_slide_shapes(shapes: &[Shape]) -> Result<(), Error> {
    fn walk(shapes: &[Shape], seen: &mut HashSet<u32>, depth: usize) -> Result<(), Error> {
        if depth > 64 {
            return Err(Error::Invalid(
                "shape group nesting exceeds maximum depth".into(),
            ));
        }
        for sh in shapes {
            if sh.id.0 == 0 || !seen.insert(sh.id.0) {
                return Err(Error::Invalid(format!(
                    "zero or duplicate shape id {} within slide",
                    sh.id.0
                )));
            }
            if !sh.children().is_empty() {
                walk(sh.children(), seen, depth + 1)?;
            }
        }
        Ok(())
    }
    let mut seen = HashSet::new();
    walk(shapes, &mut seen, 0)
}

/// Validates that `value` deserializes into the concrete type of `field`.
fn validate_deck_field(field: DeckField, value: &Value) -> Result<(), Error> {
    let invalid = |err: serde_json::Error| {
        Error::Invalid(format!("invalid value for deck.set {:?}: {err}", field))
    };
    match field {
        DeckField::SlideSize | DeckField::NotesSize => {
            let sz: Size = serde_json::from_value(value.clone()).map_err(invalid)?;
            if !sz.width.is_finite()
                || !sz.height.is_finite()
                || sz.width <= 0.0
                || sz.height <= 0.0
            {
                return Err(Error::Invalid(
                    "slide dimensions must be finite positive numbers".into(),
                ));
            }
        }
        DeckField::Masters => {
            let masters: Vec<Master> = serde_json::from_value(value.clone()).map_err(invalid)?;
            for m in &masters {
                validate_master_ids(m)?;
            }
        }
        DeckField::NotesMaster | DeckField::HandoutMaster => {
            let master: Option<Master> = serde_json::from_value(value.clone()).map_err(invalid)?;
            if let Some(m) = &master {
                validate_master_ids(m)?;
            }
        }
        DeckField::Sections => {
            let _: Vec<Section> = serde_json::from_value(value.clone()).map_err(invalid)?;
        }
        DeckField::CustomShows => {
            let _: Vec<CustomShow> = serde_json::from_value(value.clone()).map_err(invalid)?;
        }
        DeckField::ShowSettings => {
            let _: ShowSettings = serde_json::from_value(value.clone()).map_err(invalid)?;
        }
        DeckField::HeaderFooter => {
            let _: HeaderFooter = serde_json::from_value(value.clone()).map_err(invalid)?;
        }
        DeckField::Props => {
            let _: Properties = serde_json::from_value(value.clone()).map_err(invalid)?;
        }
        DeckField::DefaultTextStyle => {
            let _: ListStyle = serde_json::from_value(value.clone()).map_err(invalid)?;
        }
        DeckField::FirstSlideNumber => {
            let _: u32 = serde_json::from_value(value.clone()).map_err(invalid)?;
        }
        DeckField::EmbeddedFonts => {
            let _: Vec<EmbeddedFont> = serde_json::from_value(value.clone()).map_err(invalid)?;
        }
        DeckField::TableStyles => {
            let _: Vec<TableStyleDef> = serde_json::from_value(value.clone()).map_err(invalid)?;
        }
        DeckField::KeptParts => {
            let _: Vec<KeptPart> = serde_json::from_value(value.clone()).map_err(invalid)?;
        }
        DeckField::Tags => {
            let _: Vec<(String, String)> =
                serde_json::from_value(value.clone()).map_err(invalid)?;
        }
        DeckField::Guides => {
            let _: Vec<DrawGuide> = serde_json::from_value(value.clone()).map_err(invalid)?;
        }
        DeckField::RawExt => {
            let _: Option<String> = serde_json::from_value(value.clone()).map_err(invalid)?;
        }
    }
    Ok(())
}

fn validate_master_ids(master: &Master) -> Result<(), Error> {
    if master.id.0 == 0 {
        return Err(Error::Invalid("master id must be non-zero".into()));
    }
    validate_slide_shapes(&master.shapes)?;
    for layout in &master.layouts {
        if layout.id.0 == 0 {
            return Err(Error::Invalid("layout id must be non-zero".into()));
        }
        validate_slide_shapes(&layout.shapes)?;
    }
    Ok(())
}

/// Applies an already-validated [`ChangeSet`] to a cloned [`Presentation`] and updates `next_id`.
pub(crate) fn apply_changeset_to_presentation(
    pres: &Presentation,
    cs: &ChangeSet,
) -> Result<Presentation, Error> {
    let mut next = pres.clone();
    for edit in &cs.edits {
        match edit {
            Edit::SlidePut { slide, value } => {
                let target = SlideId(*slide);
                let slot = next
                    .slides
                    .iter_mut()
                    .find(|s| s.id == target)
                    .ok_or_else(|| Error::Invalid(format!("slide {slide} does not exist")))?;
                *slot = Arc::new(value.clone());
            }
            Edit::SlidesOrder { order, insert } => {
                let mut existing: HashMap<u32, Arc<Slide>> = next
                    .slides
                    .iter()
                    .map(|s| (s.id.0, Arc::clone(s)))
                    .collect();
                let mut inserted: HashMap<u32, Arc<Slide>> = insert
                    .iter()
                    .map(|ins| (ins.id, Arc::new(ins.value.clone())))
                    .collect();
                let mut reordered = Vec::with_capacity(order.len());
                for &sid in order {
                    if let Some(s) = inserted.remove(&sid) {
                        if existing.contains_key(&sid) {
                            return Err(Error::Invalid(format!(
                                "slides.order insert id {sid} already exists in presentation"
                            )));
                        }
                        reordered.push(s);
                    } else if let Some(s) = existing.remove(&sid) {
                        reordered.push(s);
                    } else {
                        return Err(Error::Invalid(format!(
                            "slides.order references unknown slide id {sid}"
                        )));
                    }
                }
                next.slides = reordered;
            }
            Edit::MediaPut {
                id,
                filename,
                mime,
                data,
                link,
            } => {
                let raw = decode_base64(data)?;
                let item = MediaItem {
                    id: MediaId(*id),
                    name: filename.clone(),
                    content_type: mime.clone(),
                    data: Arc::new(raw),
                    link: link.clone(),
                };
                if let Some(slot) = next.media.iter_mut().find(|m| m.id.0 == *id) {
                    *slot = item;
                } else {
                    next.media.push(item);
                }
            }
            Edit::MediaDelete { id } => {
                next.media.retain(|m| m.id.0 != *id);
            }
            Edit::DeckSet { field, value } => {
                apply_deck_field(&mut next, *field, value)?;
            }
        }
    }
    next.fix_next_id();
    Ok(next)
}

fn apply_deck_field(pres: &mut Presentation, field: DeckField, value: &Value) -> Result<(), Error> {
    let invalid = |err: serde_json::Error| {
        Error::Invalid(format!("invalid value for deck.set {:?}: {err}", field))
    };
    match field {
        DeckField::SlideSize => {
            pres.slide_size = serde_json::from_value(value.clone()).map_err(invalid)?;
        }
        DeckField::NotesSize => {
            pres.notes_size = serde_json::from_value(value.clone()).map_err(invalid)?;
        }
        DeckField::Masters => {
            let masters: Vec<Master> = serde_json::from_value(value.clone()).map_err(invalid)?;
            pres.masters = masters.into_iter().map(Arc::new).collect();
        }
        DeckField::NotesMaster => {
            let master: Option<Master> = serde_json::from_value(value.clone()).map_err(invalid)?;
            pres.notes_master = master.map(Arc::new);
        }
        DeckField::HandoutMaster => {
            let master: Option<Master> = serde_json::from_value(value.clone()).map_err(invalid)?;
            pres.handout_master = master.map(Arc::new);
        }
        DeckField::Sections => {
            pres.sections = serde_json::from_value(value.clone()).map_err(invalid)?;
        }
        DeckField::CustomShows => {
            pres.custom_shows = serde_json::from_value(value.clone()).map_err(invalid)?;
        }
        DeckField::ShowSettings => {
            pres.show = serde_json::from_value(value.clone()).map_err(invalid)?;
        }
        DeckField::HeaderFooter => {
            pres.header_footer = serde_json::from_value(value.clone()).map_err(invalid)?;
        }
        DeckField::Props => {
            pres.props = serde_json::from_value(value.clone()).map_err(invalid)?;
        }
        DeckField::DefaultTextStyle => {
            pres.default_text_style = serde_json::from_value(value.clone()).map_err(invalid)?;
        }
        DeckField::FirstSlideNumber => {
            pres.first_slide_number = serde_json::from_value(value.clone()).map_err(invalid)?;
        }
        DeckField::EmbeddedFonts => {
            pres.embedded_fonts = serde_json::from_value(value.clone()).map_err(invalid)?;
        }
        DeckField::TableStyles => {
            pres.table_styles = serde_json::from_value(value.clone()).map_err(invalid)?;
        }
        DeckField::Tags => {
            pres.tags = serde_json::from_value(value.clone()).map_err(invalid)?;
        }
        DeckField::KeptParts => {
            pres.kept_parts = serde_json::from_value(value.clone()).map_err(invalid)?;
        }
        DeckField::Guides => {
            pres.guides = serde_json::from_value(value.clone()).map_err(invalid)?;
        }
        DeckField::RawExt => {
            pres.raw_ext = serde_json::from_value(value.clone()).map_err(invalid)?;
        }
    }
    Ok(())
}
