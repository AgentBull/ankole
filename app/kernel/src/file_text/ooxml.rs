use std::collections::HashMap;

use quick_xml::events::Event;
use quick_xml::{Reader, XmlVersion};
use serde_json::json;

use super::{
    BoundedZip, FileSubtype, FileTextResult, PLAIN_TEXT_LIMIT, PageTextSpan, ZipOpenError,
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
    let mut parts = Vec::with_capacity(headers.len() + footers.len() + 3);
    for h in headers {
        if let Ok(Some(xml)) = zip.read_utf8(&h) {
            parts.push(xml);
        }
    }
    parts.push(main_xml);
    for extra in ["word/footnotes.xml", "word/endnotes.xml"] {
        if let Ok(Some(xml)) = zip.read_utf8(extra) {
            parts.push(xml);
        }
    }
    for f in footers {
        if let Ok(Some(xml)) = zip.read_utf8(&f) {
            parts.push(xml);
        }
    }

    for xml in &parts {
        if let Err(reason) = parse_ooxml_text_events(xml, WORDPROCESSING_DIALECT, &mut out) {
            return FileTextResult::failed(FileSubtype::Document, "docx", reason);
        }
        push_newline_once(&mut out);
        if out.len() >= PLAIN_TEXT_LIMIT {
            break;
        }
    }

    let clean = truncate_utf8(sanitize_nfkc(&out), PLAIN_TEXT_LIMIT);
    FileTextResult::ok(
        FileSubtype::Document,
        "docx",
        clean,
        json!({ "part_count": parts.len() }),
    )
}

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

    for (index, slide_path) in slide_paths.iter().enumerate() {
        if out.len() >= PLAIN_TEXT_LIMIT {
            break;
        }
        let page_num = (index + 1) as u32;
        let mut slide_raw = String::new();

        match zip.read_utf8(slide_path) {
            Ok(Some(xml)) => {
                if let Err(reason) =
                    parse_ooxml_text_events(&xml, DRAWINGML_DIALECT, &mut slide_raw)
                {
                    return FileTextResult::failed(FileSubtype::Document, "pptx", reason);
                }
            }
            Ok(None) => continue,
            Err(err) => return zip_error_to_result("pptx", err),
        }

        if let Some(notes_path) = resolve_slide_notes_path(&mut zip, slide_path)
            && let Ok(Some(notes_xml)) = zip.read_utf8(&notes_path)
        {
            push_newline_once(&mut slide_raw);
            let _ = parse_ooxml_text_events(&notes_xml, DRAWINGML_DIALECT, &mut slide_raw);
        }

        let slide_clean = sanitize_nfkc(slide_raw.trim());
        if slide_clean.is_empty() {
            continue;
        }

        if !out.is_empty() && !out.ends_with('\n') {
            out.push('\n');
        }
        let start_byte = out.len();
        out.push_str(&slide_clean);
        out.push('\n');
        if out.len() > PLAIN_TEXT_LIMIT {
            out = truncate_utf8(out, PLAIN_TEXT_LIMIT);
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
        }),
    )
}

fn parse_ooxml_text_events(
    xml: &str,
    dialect: OoxmlDialect,
    out: &mut String,
) -> Result<(), String> {
    let mut reader = Reader::from_str(xml);
    let mut in_text = false;
    let mut ignored_depth = 0usize;

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
                    _ => {}
                }
            }
            Ok(Event::Empty(e)) => {
                if ignored_depth == 0 {
                    match local_name(e.name().as_ref()) {
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
                    "p" | "tr" => push_newline_once(out),
                    "tc" => push_tab_once(out),
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
            Ok(Event::Eof) => break,
            Err(err) => return Err(format!("{}: {err}", dialect.error_prefix)),
            _ => {}
        }
        if out.len() >= PLAIN_TEXT_LIMIT + 4096 {
            break;
        }
    }
    Ok(())
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

fn resolve_slide_notes_path(zip: &mut BoundedZip<'_>, slide_path: &str) -> Option<String> {
    let (dir, filename) = slide_path.rsplit_once('/')?;
    let rels_path = format!("{dir}/_rels/{filename}.rels");
    let rels_xml = zip.read_utf8(&rels_path).ok()??;
    let rels = parse_relationships(&rels_xml);
    for (target, rel_type) in rels.values() {
        if rel_type.ends_with("/notesSlide") {
            let resolved = resolve_zip_path(dir, target);
            if zip.contains(&resolved) {
                return Some(resolved);
            }
        }
    }
    None
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
