//! In-presentation text search and structured document inspection.

use deckcraft_model::resolve::{self, Ctx};
use deckcraft_model::{Shape, ShapeKind};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use unicode_normalization::UnicodeNormalization;
use unicode_normalization::char::{canonical_combining_class, compose};
use unicode_segmentation::UnicodeSegmentation;

use crate::{Error, PresentationDoc};

/// One text search match inside a presentation slide or its speaker notes.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct FindMatch {
    /// Zero-based index of the matching slide.
    pub slide_index: usize,
    /// Stable identifier of the matching slide.
    pub slide_id: u32,
    /// Identifier of the shape containing the match, or `None` when in speaker notes.
    pub shape_id: Option<u32>,
    /// True when the match lies inside speaker notes rather than a slide shape.
    pub in_notes: bool,
    /// Surrounding text snippet for search previews.
    pub snippet: String,
    /// Zero-based Unicode scalar offset of the match inside the searched text.
    pub char_offset: usize,
}

#[derive(Default, Deserialize)]
struct InspectParams {
    #[serde(default)]
    from_slide: Option<usize>,
    #[serde(default)]
    to_slide: Option<usize>,
    #[serde(default)]
    slide_id: Option<u32>,
}

/// Searches all slide shapes (including group children and table cells) and speaker notes for
/// `query`.
#[must_use]
pub fn find(doc: &PresentationDoc, query: &str, match_case: bool) -> Vec<FindMatch> {
    if query.is_empty() {
        return Vec::new();
    }
    let mut needle = String::new();
    append_search_text(&mut needle, query.nfkc(), match_case);
    if needle.is_empty() {
        return Vec::new();
    }

    let mut matches = Vec::new();
    let pres = doc.presentation();
    for (slide_index, slide) in pres.slides.iter().enumerate() {
        find_in_shapes(
            &slide.shapes,
            slide_index,
            slide.id.0,
            &needle,
            match_case,
            &mut matches,
            0,
        );
        let notes_text = slide.notes.text();
        if !notes_text.is_empty() {
            find_in_text(
                &notes_text,
                MatchLocation {
                    slide_index,
                    slide_id: slide.id.0,
                    shape_id: None,
                    in_notes: true,
                },
                &needle,
                match_case,
                &mut matches,
            );
        }
    }
    matches
}

#[derive(Clone, Copy)]
struct MatchLocation {
    slide_index: usize,
    slide_id: u32,
    shape_id: Option<u32>,
    in_notes: bool,
}

fn find_in_shapes(
    shapes: &[Shape],
    slide_index: usize,
    slide_id: u32,
    needle: &str,
    match_case: bool,
    out: &mut Vec<FindMatch>,
    depth: usize,
) {
    if depth > 64 {
        return;
    }
    for sh in shapes {
        let text = shape_plain_text(sh);
        if !text.is_empty() {
            find_in_text(
                &text,
                MatchLocation {
                    slide_index,
                    slide_id,
                    shape_id: Some(sh.id.0),
                    in_notes: false,
                },
                needle,
                match_case,
                out,
            );
        }
        if !sh.children().is_empty() {
            find_in_shapes(
                sh.children(),
                slide_index,
                slide_id,
                needle,
                match_case,
                out,
                depth + 1,
            );
        }
    }
}

fn find_in_text(
    text: &str,
    loc: MatchLocation,
    needle: &str,
    match_case: bool,
    out: &mut Vec<FindMatch>,
) {
    let raw_chars: Vec<char> = text.chars().collect();
    let (folded, spans) = fold_with_offsets(text, match_case);
    let mut previous = None;
    for (start, _) in folded.char_indices() {
        if !folded
            .get(start..)
            .is_some_and(|tail| tail.starts_with(needle))
        {
            continue;
        }
        let end = start + needle.len();
        let first = spans.partition_point(|(offset, ..)| *offset <= start);
        let last = spans.partition_point(|(offset, ..)| *offset < end);
        let (Some(&(_, raw_start, _)), Some(&(_, _, raw_end))) =
            (spans.get(first), spans.get(last))
        else {
            continue;
        };
        if previous.replace((raw_start, raw_end)) == Some((raw_start, raw_end)) {
            continue;
        }
        let snippet = raw_chars
            .get(raw_start.saturating_sub(32)..(raw_end + 32).min(raw_chars.len()))
            .unwrap_or_default()
            .iter()
            .collect();
        out.push(FindMatch {
            slide_index: loc.slide_index,
            slide_id: loc.slide_id,
            shape_id: loc.shape_id,
            in_notes: loc.in_notes,
            snippet,
            char_offset: raw_start,
        });
    }
}

fn append_search_text(out: &mut String, chars: impl Iterator<Item = char>, match_case: bool) {
    if match_case {
        out.extend(chars);
    } else {
        out.extend(chars.flat_map(char::to_lowercase));
    }
}

fn fold_with_offsets(text: &str, match_case: bool) -> (String, Vec<(usize, usize, usize)>) {
    let mut folded = String::with_capacity(text.len());
    let mut spans = Vec::new();
    let mut group = String::new();
    let mut next = String::new();
    let mut source_start = 0;
    let mut source_end = 0;

    // Keep raw scalar offsets even when NFKC expands a ligature or joins compatibility jamo.
    for cluster in text.graphemes(true) {
        next.clear();
        next.extend(cluster.nfkc());
        let joins_previous = group
            .chars()
            .next_back()
            .zip(next.chars().next())
            .is_some_and(|(last, first)| {
                canonical_combining_class(first) != 0 || compose(last, first).is_some()
            });
        if joins_previous {
            group.push_str(&next);
            group = group.nfc().collect();
        } else {
            if !group.is_empty() {
                append_search_text(&mut folded, group.chars(), match_case);
                spans.push((folded.len(), source_start, source_end));
            }
            std::mem::swap(&mut group, &mut next);
            source_start = source_end;
        }
        source_end += cluster.chars().count();
    }
    if !group.is_empty() {
        append_search_text(&mut folded, group.chars(), match_case);
        spans.push((folded.len(), source_start, source_end));
    }
    (folded, spans)
}

/// Extracts plain text directly owned by `shape` (a text body or table cells; group children are
/// visited separately).
pub(crate) fn shape_plain_text(shape: &Shape) -> String {
    match &shape.kind {
        ShapeKind::Table(table) => table
            .rows
            .iter()
            .map(|row| {
                row.cells
                    .iter()
                    .map(|cell| cell.text.text())
                    .collect::<Vec<_>>()
                    .join("\t")
            })
            .collect::<Vec<_>>()
            .join("\n"),
        _ => shape.text.as_ref().map(|tb| tb.text()).unwrap_or_default(),
    }
}

/// Returns a structured JSON summary of `doc`, optionally filtered by `from_slide`, `to_slide`, or
/// `slide_id`.
///
/// # Errors
///
/// Returns [`Error::Invalid`] if `params_json` is malformed or specifies `from_slide > to_slide`.
pub fn inspect(doc: &PresentationDoc, params_json: &str) -> Result<Value, Error> {
    let params: InspectParams = if params_json.trim().is_empty() {
        InspectParams::default()
    } else {
        serde_json::from_str(params_json)
            .map_err(|err| Error::Invalid(format!("invalid inspect parameters: {err}")))?
    };

    if let (Some(from), Some(to)) = (params.from_slide, params.to_slide)
        && from > to
    {
        return Err(Error::Invalid(format!(
            "from_slide ({from}) must not exceed to_slide ({to})"
        )));
    }

    let pres = doc.presentation();
    let mut slides_out = Vec::new();
    for (index, slide) in pres.slides.iter().enumerate() {
        if let Some(from) = params.from_slide
            && index < from
        {
            continue;
        }
        if let Some(to) = params.to_slide
            && index > to
        {
            continue;
        }
        if let Some(target_id) = params.slide_id
            && slide.id.0 != target_id
        {
            continue;
        }

        let ctx = Ctx::for_slide(pres, slide);
        let mut shapes_out = Vec::new();
        collect_inspected_shapes(ctx.as_ref(), &slide.shapes, &mut shapes_out, 0);

        slides_out.push(json!({
            "index": index,
            "slide_id": slide.id.0,
            "title": slide.title(),
            "notes": slide.notes.text(),
            "shapes": shapes_out,
            "comments_count": slide.comments.len(),
        }));
    }

    Ok(json!({
        "title": pres.props.title,
        "slide_count": pres.slides.len(),
        "width_pt": pres.slide_size.width,
        "height_pt": pres.slide_size.height,
        "warnings": doc.warnings(),
        "slides": slides_out,
    }))
}

fn collect_inspected_shapes(
    ctx: Option<&Ctx>,
    shapes: &[Shape],
    out: &mut Vec<Value>,
    depth: usize,
) {
    if depth > 64 {
        return;
    }
    for sh in shapes {
        let box_xfrm = if depth == 0 {
            ctx.map(|c| resolve::xfrm(c, sh))
                .or(sh.xfrm)
                .unwrap_or_default()
        } else {
            sh.xfrm.unwrap_or_default()
        };
        out.push(json!({
            "shape_id": sh.id.0,
            "kind": sh.kind_name(),
            "name": sh.name,
            "x_pt": box_xfrm.x,
            "y_pt": box_xfrm.y,
            "width_pt": box_xfrm.w,
            "height_pt": box_xfrm.h,
            "text": shape_plain_text(sh),
        }));
        if !sh.children().is_empty() {
            collect_inspected_shapes(None, sh.children(), out, depth + 1);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use deckcraft_model::text::TextBody;
    use std::sync::Arc;

    #[test]
    fn finds_normalized_notes_with_raw_offsets() {
        let (base, _) = crate::create_blank("Notes").unwrap();
        let mut pres = base.presentation().clone();
        let text = "🎙 ﬃ cafe\u{301} Ｑ４ ㄱㅏ";
        Arc::make_mut(&mut pres.slides[0]).notes = TextBody::from_text(text);
        let doc = PresentationDoc::from_presentation(pres, Vec::new());

        for (needle, offset) in [("ffi", 2), ("café", 4), ("q4", 10), ("가", 13)] {
            let matches = find(&doc, needle, false);
            assert_eq!(matches.len(), 1);
            assert!(matches[0].in_notes);
            assert_eq!(matches[0].char_offset, offset);
            assert_eq!(matches[0].snippet, text);
        }
        assert!(find(&doc, "q4", true).is_empty());
        assert_eq!(find(&doc, "Q4", true).len(), 1);
    }
}
