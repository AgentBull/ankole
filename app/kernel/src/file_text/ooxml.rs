use std::collections::HashMap;

use quick_xml::events::Event;
use quick_xml::{Reader, XmlVersion};
use serde_json::json;

use super::{
    BoundedZip, FileSubtype, FileTextResult, Outline, PLAIN_TEXT_LIMIT, PageTextSpan, ZipOpenError,
    append_xml_entity, attr_value_by_local, local_name, push_newline_once, push_tab_once,
    sanitize_nfkc, truncate_utf8, zip_error_to_result,
};

#[derive(Clone, Copy)]
struct OoxmlDialect {
    error_prefix: &'static str,
    allow_carriage_return_break: bool,
    skip_revisions_and_fields: bool,
}

const WORDPROCESSING_DIALECT: OoxmlDialect = OoxmlDialect {
    error_prefix: "docx_xml_error",
    allow_carriage_return_break: true,
    skip_revisions_and_fields: true,
};

const DRAWINGML_DIALECT: OoxmlDialect = OoxmlDialect {
    error_prefix: "pptx_xml_error",
    allow_carriage_return_break: false,
    skip_revisions_and_fields: false,
};

pub(super) fn extract_docx(bytes: &[u8]) -> FileTextResult {
    let mut zip = match BoundedZip::open(bytes) {
        Ok(z) => z,
        Err(err) => return zip_error_to_result("docx", err),
    };
    if zip.contains("EncryptedPackage") {
        return FileTextResult::skipped(FileSubtype::Document, "docx", "encrypted_document");
    }

    let names = zip.file_names();
    let mut headers: Vec<String> = names
        .iter()
        .filter(|n| n.starts_with("word/header") && n.ends_with(".xml"))
        .cloned()
        .collect();
    headers.sort();

    let mut footers: Vec<String> = names
        .iter()
        .filter(|n| n.starts_with("word/footer") && n.ends_with(".xml"))
        .cloned()
        .collect();
    footers.sort();

    let Some(main_xml) = (match zip.read_utf8("word/document.xml") {
        Ok(xml) => xml,
        Err(err) => return zip_error_to_result("docx", err),
    }) else {
        return FileTextResult::failed(FileSubtype::Document, "docx", "missing_word_document_xml");
    };

    let mut out = String::new();
    // Each part with whether it is the main document, whose headings open sections.
    let mut parts = Vec::with_capacity(headers.len() + footers.len() + 3);
    for h in headers {
        match zip.read_utf8(&h) {
            Ok(Some(xml)) => parts.push((xml, false)),
            Ok(None) => {}
            Err(err) => return zip_error_to_result("docx", err),
        }
    }
    parts.push((main_xml, true));
    for extra in ["word/footnotes.xml", "word/endnotes.xml"] {
        match zip.read_utf8(extra) {
            Ok(Some(xml)) => parts.push((xml, false)),
            Ok(None) => {}
            Err(err) => return zip_error_to_result("docx", err),
        }
    }
    for f in footers {
        match zip.read_utf8(&f) {
            Ok(Some(xml)) => parts.push((xml, false)),
            Ok(None) => {}
            Err(err) => return zip_error_to_result("docx", err),
        }
    }

    let styles = match heading_styles(&mut zip) {
        Ok(styles) => styles,
        Err(err) => return zip_error_to_result("docx", err),
    };
    let mut headings = Headings {
        styles,
        outline: Outline::default(),
    };
    let mut truncated = false;
    for (xml, main) in &parts {
        if out.len() >= PLAIN_TEXT_LIMIT {
            truncated = true;
            break;
        }
        let headings = main.then_some(&mut headings);
        match parse_ooxml_text_events(xml, WORDPROCESSING_DIALECT, &mut out, headings) {
            Ok(stopped) => truncated |= stopped,
            Err(reason) => return FileTextResult::failed(FileSubtype::Document, "docx", reason),
        }
        push_newline_once(&mut out);
    }

    let clean = sanitize_nfkc(&out);
    truncated |= clean.len() > PLAIN_TEXT_LIMIT;
    FileTextResult::ok(
        FileSubtype::Document,
        "docx",
        truncate_utf8(clean, PLAIN_TEXT_LIMIT),
        json!({ "part_count": parts.len(), "truncated": truncated }),
    )
}

/// Extracts each slide's text and speaker notes in presentation order. Each slide with text
/// starts with a `[Slide N]` line, and its entry in `pages` spans that line and the text.
pub(super) fn extract_pptx(bytes: &[u8]) -> FileTextResult {
    let mut zip = match BoundedZip::open(bytes) {
        Ok(z) => z,
        Err(err) => return zip_error_to_result("pptx", err),
    };
    if zip.contains("EncryptedPackage") {
        return FileTextResult::skipped(FileSubtype::Document, "pptx", "encrypted_document");
    }

    let slide_paths = match resolve_pptx_slide_order(&mut zip) {
        Ok(paths) => paths,
        Err(err) => return zip_error_to_result("pptx", err),
    };

    if slide_paths.is_empty() {
        return FileTextResult::failed(FileSubtype::Document, "pptx", "missing_pptx_slides");
    }

    let total_slides = slide_paths.len();
    let mut out = String::new();
    let mut pages = Vec::with_capacity(total_slides);
    let mut truncated = false;

    for (index, slide_path) in slide_paths.iter().enumerate() {
        if out.len() >= PLAIN_TEXT_LIMIT {
            truncated = true;
            break;
        }
        let page_num = (index + 1) as u32;
        let mut slide_raw = String::new();

        match zip.read_utf8(slide_path) {
            Ok(Some(xml)) => {
                match parse_ooxml_text_events(&xml, DRAWINGML_DIALECT, &mut slide_raw, None) {
                    Ok(stopped) => truncated |= stopped,
                    Err(reason) => {
                        return FileTextResult::failed(FileSubtype::Document, "pptx", reason);
                    }
                }
            }
            Ok(None) => continue,
            Err(err) => return zip_error_to_result("pptx", err),
        }

        let notes_path = match resolve_slide_notes_path(&mut zip, slide_path) {
            Ok(path) => path,
            Err(err) => return zip_error_to_result("pptx", err),
        };
        if let Some(notes_path) = notes_path {
            match zip.read_utf8(&notes_path) {
                Ok(Some(notes_xml)) => {
                    push_newline_once(&mut slide_raw);
                    truncated |= parse_ooxml_text_events(
                        &notes_xml,
                        DRAWINGML_DIALECT,
                        &mut slide_raw,
                        None,
                    )
                    .unwrap_or(false);
                }
                Ok(None) => {}
                Err(err) => return zip_error_to_result("pptx", err),
            }
        }

        let slide_clean = sanitize_nfkc(slide_raw.trim());
        if slide_clean.is_empty() {
            continue;
        }

        if !out.is_empty() && !out.ends_with('\n') {
            out.push('\n');
        }
        let start_byte = out.len();
        out.push_str(&format!("[Slide {page_num}]\n{slide_clean}\n"));
        if out.len() > PLAIN_TEXT_LIMIT {
            out = truncate_utf8(out, PLAIN_TEXT_LIMIT);
            truncated = true;
        }
        let end_byte = out.len();
        if end_byte > start_byte {
            pages.push(PageTextSpan {
                page: page_num,
                start_byte,
                end_byte,
            });
        }
    }

    FileTextResult::ok(
        FileSubtype::Document,
        "pptx",
        out,
        json!({
            "page_count": total_slides,
            "pages": pages,
            "truncated": truncated,
        }),
    )
}

/// Appends the text of one part to `out`. Returns whether the text budget stopped the read before
/// the end of the part.
///
/// With `headings`, a paragraph outside a table whose style or own properties give it an outline
/// level becomes a `[Section: …]` line instead of plain text.
fn parse_ooxml_text_events(
    xml: &str,
    dialect: OoxmlDialect,
    out: &mut String,
    mut headings: Option<&mut Headings>,
) -> Result<bool, String> {
    let mut reader = Reader::from_str(xml);
    let mut in_text = false;
    let mut ignored_depth = 0usize;
    // The open paragraphs, innermost last: where each one's text starts and its outline level.
    let mut paragraphs: Vec<(usize, Option<u8>)> = Vec::new();
    let mut table_depth = 0usize;

    loop {
        match reader.read_event() {
            Ok(Event::Start(e)) => {
                if ignored_depth > 0 {
                    ignored_depth += 1;
                    continue;
                }
                match local_name(e.name().as_ref()) {
                    // AlternateContent Fallbacks duplicate Choice textboxes in both DOCX and PPTX;
                    // DOCX additionally skips deleted tracked-change runs and field instruction codes.
                    "Fallback" => ignored_depth = 1,
                    "delText" | "instrText" if dialect.skip_revisions_and_fields => {
                        ignored_depth = 1;
                    }
                    "t" => in_text = true,
                    "tab" => out.push('\t'),
                    "br" => out.push('\n'),
                    "cr" if dialect.allow_carriage_return_break => out.push('\n'),
                    "p" if headings.is_some() => paragraphs.push((out.len(), None)),
                    "tbl" => table_depth += 1,
                    name @ ("pStyle" | "outlineLvl") => {
                        outline_level(name, &e, headings.as_deref(), paragraphs.last_mut());
                    }
                    _ => {}
                }
            }
            Ok(Event::Empty(e)) => {
                if ignored_depth == 0 {
                    match local_name(e.name().as_ref()) {
                        name @ ("pStyle" | "outlineLvl") => {
                            outline_level(name, &e, headings.as_deref(), paragraphs.last_mut());
                        }
                        "tab" => out.push('\t'),
                        "br" => out.push('\n'),
                        "cr" if dialect.allow_carriage_return_break => out.push('\n'),
                        _ => {}
                    }
                }
            }
            Ok(Event::End(e)) => {
                if ignored_depth > 0 {
                    ignored_depth -= 1;
                    continue;
                }
                match local_name(e.name().as_ref()) {
                    "t" => in_text = false,
                    "p" => match (paragraphs.pop(), headings.as_deref_mut()) {
                        (Some((start, Some(level))), Some(headings))
                            if paragraphs.is_empty() && table_depth == 0 =>
                        {
                            headings.outline.mark(out, start, level);
                        }
                        _ => push_newline_once(out),
                    },
                    "tr" => push_newline_once(out),
                    "tc" => push_tab_once(out),
                    "tbl" => table_depth = table_depth.saturating_sub(1),
                    _ => {}
                }
            }
            Ok(Event::Text(e)) => {
                if ignored_depth == 0 && in_text {
                    out.push_str(&e.xml10_content());
                }
            }
            Ok(Event::CData(e)) => {
                if ignored_depth == 0 && in_text {
                    out.push_str(&e.xml10_content());
                }
            }
            Ok(Event::GeneralRef(e)) => {
                if ignored_depth == 0 && in_text {
                    append_xml_entity(&e, out);
                }
            }
            Ok(Event::Eof) => return Ok(false),
            Err(err) => return Err(format!("{}: {err}", dialect.error_prefix)),
            _ => {}
        }
        if out.len() >= PLAIN_TEXT_LIMIT + 4096 {
            return Ok(true);
        }
    }
}

/// What the main document part needs to turn its heading paragraphs into `[Section: …]` lines.
struct Headings {
    /// The outline level, from 1, of each paragraph style that is a heading, by style id.
    styles: HashMap<String, u8>,
    outline: Outline,
}

/// Records the outline level that a paragraph's `pStyle` or own `outlineLvl` gives it. Word
/// counts outline levels from 0 and writes 9 for body text.
fn outline_level(
    name: &str,
    element: &quick_xml::events::BytesStart<'_>,
    headings: Option<&Headings>,
    paragraph: Option<&mut (usize, Option<u8>)>,
) {
    let (Some(headings), Some((_, level)), Some(value)) =
        (headings, paragraph, attr_value_by_local(element, "val"))
    else {
        return;
    };
    if name == "pStyle" {
        *level = level.or(headings.styles.get(&value).copied());
    } else {
        *level = value.parse::<u8>().ok().filter(|v| *v <= 8).map(|v| v + 1);
    }
}

/// The heading styles of `word/styles.xml`: a style is a heading when it is named `heading N`,
/// which Word keeps in English in every locale, when it sets an outline level, or when the style
/// it is based on is one.
fn heading_styles(zip: &mut BoundedZip<'_>) -> Result<HashMap<String, u8>, ZipOpenError> {
    let Some(xml) = zip.read_utf8("word/styles.xml")? else {
        return Ok(HashMap::new());
    };
    let mut levels: HashMap<String, u8> = HashMap::new();
    let mut parents: HashMap<String, String> = HashMap::new();
    let mut style: Option<String> = None;
    let mut reader = Reader::from_str(&xml);
    loop {
        let event = reader.read_event();
        let element = match &event {
            Ok(Event::Start(e)) | Ok(Event::Empty(e)) => e,
            Ok(Event::End(e)) if local_name(e.name().as_ref()) == "style" => {
                style = None;
                continue;
            }
            Ok(Event::Eof) | Err(_) => break,
            _ => continue,
        };
        let value = attr_value_by_local(element, "val");
        match (local_name(element.name().as_ref()), &style, value) {
            ("style", _, _) => style = attr_value_by_local(element, "styleId"),
            ("name", Some(id), Some(name)) => {
                let level = name
                    .to_ascii_lowercase()
                    .strip_prefix("heading ")
                    .and_then(|level| level.parse::<u8>().ok())
                    .filter(|level| (1..=9).contains(level));
                if let Some(level) = level {
                    levels.entry(id.clone()).or_insert(level);
                }
            }
            ("outlineLvl", Some(id), Some(level)) => {
                if let Some(level) = level.parse::<u8>().ok().filter(|level| *level <= 8) {
                    levels.insert(id.clone(), level + 1);
                }
            }
            ("basedOn", Some(id), Some(parent)) => {
                parents.insert(id.clone(), parent);
            }
            _ => {}
        }
    }
    // A style inherits its outline level along `basedOn`; eight hops cover any real chain.
    for _ in 0..8 {
        let inherited: Vec<(String, u8)> = parents
            .iter()
            .filter(|(id, _)| !levels.contains_key(*id))
            .filter_map(|(id, parent)| Some((id.clone(), *levels.get(parent)?)))
            .collect();
        if inherited.is_empty() {
            break;
        }
        levels.extend(inherited);
    }
    Ok(levels)
}

fn resolve_pptx_slide_order(zip: &mut BoundedZip<'_>) -> Result<Vec<String>, ZipOpenError> {
    if let (Some(pres_xml), Some(rels_xml)) = (
        zip.read_utf8("ppt/presentation.xml")?,
        zip.read_utf8("ppt/_rels/presentation.xml.rels")?,
    ) {
        let rels = parse_relationships(&rels_xml);
        let mut ordered = Vec::new();
        let mut reader = Reader::from_str(&pres_xml);
        let mut in_sld_id_lst = false;
        loop {
            match reader.read_event() {
                Ok(Event::Start(e)) if local_name(e.name().as_ref()) == "sldIdLst" => {
                    in_sld_id_lst = true;
                }
                Ok(Event::End(e)) if local_name(e.name().as_ref()) == "sldIdLst" => {
                    in_sld_id_lst = false;
                }
                Ok(Event::Start(e) | Event::Empty(e))
                    if in_sld_id_lst && local_name(e.name().as_ref()) == "sldId" =>
                {
                    let rel_id = e.attributes().flatten().find_map(|attr| {
                        let key = attr.key.as_ref();
                        if (key == "r:id" || key.ends_with(":id"))
                            && let Ok(val) = attr.normalized_value(XmlVersion::Implicit1_0)
                        {
                            Some(val.into_owned())
                        } else {
                            None
                        }
                    });
                    if let Some(rel_id) = rel_id
                        && let Some((target, _)) = rels.get(&rel_id)
                    {
                        let resolved = resolve_zip_path("ppt", target);
                        if zip.contains(&resolved) {
                            ordered.push(resolved);
                        }
                    }
                }
                Ok(Event::Eof) | Err(_) => break,
                _ => {}
            }
        }
        if !ordered.is_empty() {
            return Ok(ordered);
        }
    }

    let mut numbered: Vec<(u32, String)> = zip
        .file_names()
        .into_iter()
        .filter_map(|name| {
            let rest = name.strip_prefix("ppt/slides/slide")?;
            let num_str = rest.strip_suffix(".xml")?;
            let num = num_str.parse::<u32>().ok()?;
            Some((num, name))
        })
        .collect();
    numbered.sort_by_key(|(num, _)| *num);
    Ok(numbered.into_iter().map(|(_, name)| name).collect())
}

fn resolve_slide_notes_path(
    zip: &mut BoundedZip<'_>,
    slide_path: &str,
) -> Result<Option<String>, ZipOpenError> {
    let Some((dir, filename)) = slide_path.rsplit_once('/') else {
        return Ok(None);
    };
    let rels_path = format!("{dir}/_rels/{filename}.rels");
    let Some(rels_xml) = zip.read_utf8(&rels_path)? else {
        return Ok(None);
    };
    let rels = parse_relationships(&rels_xml);
    for (target, rel_type) in rels.values() {
        if rel_type.ends_with("/notesSlide") {
            let resolved = resolve_zip_path(dir, target);
            if zip.contains(&resolved) {
                return Ok(Some(resolved));
            }
        }
    }
    Ok(None)
}

fn parse_relationships(xml: &str) -> HashMap<String, (String, String)> {
    let mut map = HashMap::new();
    let mut reader = Reader::from_str(xml);
    loop {
        match reader.read_event() {
            Ok(Event::Start(e) | Event::Empty(e))
                if local_name(e.name().as_ref()) == "Relationship" =>
            {
                if let (Some(id), Some(target)) = (
                    attr_value_by_local(&e, "Id"),
                    attr_value_by_local(&e, "Target"),
                ) {
                    let rel_type = attr_value_by_local(&e, "Type").unwrap_or_default();
                    map.insert(id, (target, rel_type));
                }
            }
            Ok(Event::Eof) | Err(_) => break,
            _ => {}
        }
    }
    map
}

fn resolve_zip_path(base_dir: &str, target: &str) -> String {
    if let Some(stripped) = target.strip_prefix('/') {
        return stripped.to_owned();
    }
    let mut parts: Vec<&str> = base_dir.split('/').filter(|p| !p.is_empty()).collect();
    for seg in target.split('/') {
        match seg {
            "" | "." => {}
            ".." => {
                parts.pop();
            }
            other => parts.push(other),
        }
    }
    parts.join("/")
}
