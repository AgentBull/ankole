//! Host-neutral text extraction for Pod file pages (UTF-8 text/code/CSV, OOXML, ODF, and PDF).
//!
//! Callers run this module on dirty CPU schedulers and persist the resulting status, metadata,
//! and bounded NFKC-normalized search text in PostgreSQL. Every input limit is enforced before or
//! during streaming decompression so malformed or adversarial archives cannot exhaust memory.
//!
//! The text carries its own structure, so a reader can split it without byte offsets. A marker
//! line stands alone before each part of a document: `[Page N]` before a PDF page, `[Slide N]`
//! before a PPTX slide, `[Sheet: <name>]` before an ODS sheet, and `[Section: <headings>]` in
//! place of a DOCX or ODT heading, where `<headings>` joins the heading and the ones above it
//! with ` > `. A table row (ODS, CSV, TSV) is
//! one line, `R<row>\t<cell>\t<cell>...`: `<row>` counts from 1, the cells run from the first
//! column, a blank cell is an empty string between two tabs, and the blank cells after the last
//! filled one are dropped. Every format reports in `metadata.truncated` whether a limit cut its
//! text short.

mod odf;
mod ooxml;
mod pdf;

use std::io::{Cursor, Read};

use quick_xml::XmlVersion;
use quick_xml::events::{BytesRef, BytesStart};
use serde::Serialize;
use serde_json::{Value, json};
use unicode_normalization::UnicodeNormalization;
use zip::ZipArchive;

/// Bump when extraction rules or metadata layout change so background self-healing refreshes caches.
pub const EXTRACTOR_VERSION: u32 = 2;

/// Maximum UTF-8 search text retained per file, matching `ankole_spreadsheet::PLAIN_TEXT_LIMIT`.
pub const PLAIN_TEXT_LIMIT: usize = 512 * 1024;

/// Maximum raw byte size for UTF-8 text/code/CSV extraction.
pub const MAX_TEXT_INPUT_BYTES: usize = 8 * 1024 * 1024;

/// Maximum raw byte size for archive/PDF document extraction.
pub const MAX_DOCUMENT_INPUT_BYTES: usize = 32 * 1024 * 1024;

const MAX_ZIP_ENTRIES: usize = 4_096;
const MAX_ZIP_ENTRY_UNCOMPRESSED_BYTES: u64 = 16 * 1024 * 1024;
const MAX_ZIP_TOTAL_UNCOMPRESSED_BYTES: u64 = 64 * 1024 * 1024;
pub(super) const MAX_PDF_PAGES: usize = 500;

const OLE2_MAGIC: [u8; 8] = [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1];

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum ExtractStatus {
    Ok,
    Skipped,
    Failed,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum FileSubtype {
    Text,
    Document,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct PageTextSpan {
    pub page: u32,
    pub start_byte: usize,
    pub end_byte: usize,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct FileTextResult {
    pub status: ExtractStatus,
    pub subtype: FileSubtype,
    pub format: String,
    pub extractor_version: u32,
    pub plain_text: String,
    pub metadata: Value,
    pub error: Option<String>,
}

impl FileTextResult {
    pub(super) fn ok(
        subtype: FileSubtype,
        format: &str,
        plain_text: String,
        metadata: Value,
    ) -> Self {
        Self {
            status: ExtractStatus::Ok,
            subtype,
            format: format.to_owned(),
            extractor_version: EXTRACTOR_VERSION,
            plain_text,
            metadata,
            error: None,
        }
    }

    pub(super) fn skipped(subtype: FileSubtype, format: &str, reason: impl Into<String>) -> Self {
        Self {
            status: ExtractStatus::Skipped,
            subtype,
            format: format.to_owned(),
            extractor_version: EXTRACTOR_VERSION,
            plain_text: String::new(),
            metadata: json!({}),
            error: Some(reason.into()),
        }
    }

    pub(super) fn failed(subtype: FileSubtype, format: &str, reason: impl Into<String>) -> Self {
        Self {
            status: ExtractStatus::Failed,
            subtype,
            format: format.to_owned(),
            extractor_version: EXTRACTOR_VERSION,
            plain_text: String::new(),
            metadata: json!({}),
            error: Some(reason.into()),
        }
    }
}

/// Classifies a file by its filename and optional MIME type into `(subtype, format)`.
/// Returns `None` for unsupported binary formats (images, audio, video, raw archives, etc.).
pub fn classify(filename: &str, mime_type: Option<&str>) -> Option<(FileSubtype, &'static str)> {
    let lower_name = filename
        .rsplit(['/', '\\'])
        .next()
        .unwrap_or(filename)
        .trim()
        .to_ascii_lowercase();

    match lower_name.as_str() {
        "makefile" | "gnumakefile" | "dockerfile" | "containerfile" | "justfile" | "procfile" => {
            return Some((FileSubtype::Text, "code"));
        }
        _ => {}
    }

    if let Some((_, ext)) = lower_name.rsplit_once('.') {
        match ext {
            "md" | "markdown" | "mdx" => return Some((FileSubtype::Text, "md")),
            "csv" => return Some((FileSubtype::Text, "csv")),
            "tsv" | "tab" => return Some((FileSubtype::Text, "tsv")),
            "json" | "jsonl" | "ndjson" | "jsonc" => return Some((FileSubtype::Text, "json")),
            "txt" | "text" | "log" | "rst" | "adoc" | "asciidoc" | "org" => {
                return Some((FileSubtype::Text, "txt"));
            }
            "yaml" | "yml" | "toml" | "ini" | "cfg" | "conf" | "env" | "properties" | "xml"
            | "svg" | "html" | "htm" | "xhtml" | "css" | "scss" | "sass" | "less" | "js"
            | "jsx" | "mjs" | "cjs" | "ts" | "tsx" | "mts" | "cts" | "py" | "pyi" | "rb" | "rs"
            | "go" | "java" | "kt" | "kts" | "swift" | "c" | "h" | "cc" | "cpp" | "cxx" | "hpp"
            | "hh" | "cs" | "php" | "ex" | "exs" | "heex" | "erl" | "hrl" | "sh" | "bash"
            | "zsh" | "fish" | "ps1" | "sql" | "graphql" | "gql" | "proto" | "tf" | "tfvars"
            | "hcl" | "lua" | "r" | "jl" | "scala" | "clj" | "cljs" | "edn" | "elm" | "vue"
            | "svelte" | "astro" | "zig" | "nim" | "dart" | "gradle" | "cmake" => {
                return Some((FileSubtype::Text, "code"));
            }
            "docx" => return Some((FileSubtype::Document, "docx")),
            "pptx" => return Some((FileSubtype::Document, "pptx")),
            "odt" => return Some((FileSubtype::Document, "odt")),
            "ods" => return Some((FileSubtype::Document, "ods")),
            "pdf" => return Some((FileSubtype::Document, "pdf")),
            // Known binary / archive / media extensions should not fall back to a generic MIME hint.
            "png" | "jpg" | "jpeg" | "gif" | "webp" | "bmp" | "ico" | "avif" | "heic" | "tiff"
            | "tif" | "mp3" | "wav" | "ogg" | "flac" | "m4a" | "aac" | "mp4" | "mov" | "webm"
            | "mkv" | "avi" | "zip" | "tar" | "gz" | "tgz" | "bz2" | "xz" | "zst" | "7z"
            | "rar" | "wasm" | "exe" | "dll" | "so" | "dylib" | "bin" | "dmg" | "iso" | "doc"
            | "ppt" | "xls" | "xlsx" | "xlsm" => {
                return None;
            }
            _ => {}
        }
    }

    let mime = mime_type?
        .split(';')
        .next()
        .unwrap_or("")
        .trim()
        .to_ascii_lowercase();

    match mime.as_str() {
        "text/markdown" | "text/x-markdown" => Some((FileSubtype::Text, "md")),
        "text/csv" | "application/csv" => Some((FileSubtype::Text, "csv")),
        "text/tab-separated-values" => Some((FileSubtype::Text, "tsv")),
        "application/json" | "application/ld+json" | "application/x-ndjson" => {
            Some((FileSubtype::Text, "json"))
        }
        "application/pdf" => Some((FileSubtype::Document, "pdf")),
        "application/vnd.openxmlformats-officedocument.wordprocessingml.document" => {
            Some((FileSubtype::Document, "docx"))
        }
        "application/vnd.openxmlformats-officedocument.presentationml.presentation" => {
            Some((FileSubtype::Document, "pptx"))
        }
        "application/vnd.oasis.opendocument.text" => Some((FileSubtype::Document, "odt")),
        "application/vnd.oasis.opendocument.spreadsheet" => Some((FileSubtype::Document, "ods")),
        "application/xml"
        | "text/xml"
        | "application/javascript"
        | "text/javascript"
        | "application/typescript"
        | "application/x-yaml"
        | "text/yaml"
        | "application/toml"
        | "application/sql"
        | "application/x-sh" => Some((FileSubtype::Text, "code")),
        _ if mime.starts_with("text/") => Some((FileSubtype::Text, "txt")),
        _ if mime.ends_with("+json") => Some((FileSubtype::Text, "json")),
        _ if mime.ends_with("+xml") => Some((FileSubtype::Text, "code")),
        _ => None,
    }
}

/// Extracts bounded, NFKC-normalized searchable text and locating metadata from file bytes.
pub fn extract(bytes: &[u8], filename: &str, mime_type: Option<&str>) -> FileTextResult {
    let Some((subtype, format)) = classify(filename, mime_type) else {
        return FileTextResult::skipped(FileSubtype::Document, "unsupported", "unsupported_format");
    };

    let outcome =
        std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| match (subtype, format) {
            (FileSubtype::Text, "csv") => extract_delimited(bytes, format, b','),
            (FileSubtype::Text, "tsv") => extract_delimited(bytes, format, b'\t'),
            (FileSubtype::Text, _) => extract_utf8_text(bytes, format),
            (FileSubtype::Document, "docx") => ooxml::extract_docx(bytes),
            (FileSubtype::Document, "pptx") => ooxml::extract_pptx(bytes),
            (FileSubtype::Document, "odt") => odf::extract_odt(bytes),
            (FileSubtype::Document, "ods") => odf::extract_ods(bytes),
            (FileSubtype::Document, "pdf") => pdf::extract_pdf(bytes),
            _ => FileTextResult::skipped(subtype, format, "unsupported_format"),
        }));

    match outcome {
        Ok(result) => result,
        Err(_) => FileTextResult::failed(subtype, format, "extractor_panicked"),
    }
}

pub(super) fn sanitize_nfkc(input: &str) -> String {
    let normalized = input.replace("\r\n", "\n").replace('\r', "\n");
    normalized
        .nfkc()
        .filter(|ch| !matches!(*ch, '\0' | '\u{001e}' | '\u{001f}'))
        .collect()
}

pub(super) fn truncate_utf8(mut text: String, limit: usize) -> String {
    if text.len() > limit {
        let mut end = limit;
        while !text.is_char_boundary(end) {
            end -= 1;
        }
        text.truncate(end);
    }
    text
}

fn decode_utf8_checked<'a>(bytes: &'a [u8], format: &str) -> Result<&'a str, FileTextResult> {
    if bytes.len() > MAX_TEXT_INPUT_BYTES {
        return Err(FileTextResult::skipped(
            FileSubtype::Text,
            format,
            "file_too_large",
        ));
    }
    let stripped = bytes.strip_prefix(&[0xEF, 0xBB, 0xBF]).unwrap_or(bytes);
    if stripped.contains(&0) {
        return Err(FileTextResult::skipped(
            FileSubtype::Text,
            format,
            "binary_content",
        ));
    }
    std::str::from_utf8(stripped)
        .map_err(|_| FileTextResult::skipped(FileSubtype::Text, format, "invalid_utf8"))
}

fn extract_utf8_text(bytes: &[u8], format: &str) -> FileTextResult {
    let raw = match decode_utf8_checked(bytes, format) {
        Ok(value) => value,
        Err(result) => return result,
    };
    let line_count = if raw.is_empty() {
        0
    } else {
        raw.split('\n').count()
    };
    let clean = sanitize_nfkc(raw);
    let truncated = clean.len() > PLAIN_TEXT_LIMIT;
    FileTextResult::ok(
        FileSubtype::Text,
        format,
        truncate_utf8(clean, PLAIN_TEXT_LIMIT),
        json!({ "line_count": line_count, "truncated": truncated }),
    )
}

fn extract_delimited(bytes: &[u8], format: &str, delimiter: u8) -> FileTextResult {
    let raw = match decode_utf8_checked(bytes, format) {
        Ok(value) => value,
        Err(result) => return result,
    };

    let mut reader = csv::ReaderBuilder::new()
        .delimiter(delimiter)
        .flexible(true)
        .has_headers(false)
        .from_reader(raw.as_bytes());

    let mut out = String::new();
    let mut record = csv::StringRecord::new();
    let mut record_count = 0usize;
    let mut truncated = false;

    loop {
        match reader.read_record(&mut record) {
            Ok(true) => {
                record_count += 1;
                if out.len() < PLAIN_TEXT_LIMIT {
                    // Every record takes exactly one line, a blank record included, so line N of
                    // `plain_text` is record N (line 1 = header, line k+1 = data row k).
                    let mut cells: Vec<String> = record.iter().map(table_cell).collect();
                    while cells.last().is_some_and(String::is_empty) {
                        cells.pop();
                    }
                    out.push_str(&format!("R{record_count}\t{}\n", cells.join("\t")));
                } else {
                    truncated = true;
                }
            }
            Ok(false) => break,
            Err(_) => {
                // Fall back to line-based text when a hand-edited CSV has unbalanced quotes.
                return extract_utf8_text(bytes, format);
            }
        }
    }

    let data_rows = record_count.saturating_sub(1);
    let clean = sanitize_nfkc(&out);
    let truncated = truncated || clean.len() > PLAIN_TEXT_LIMIT;
    let delim_str = if delimiter == b'\t' { "\t" } else { "," };
    FileTextResult::ok(
        FileSubtype::Text,
        format,
        truncate_utf8(clean, PLAIN_TEXT_LIMIT),
        json!({
            "row_count": data_rows,
            "delimiter": delim_str,
            "truncated": truncated,
        }),
    )
}

/// One table cell on one line: a tab or line break inside it becomes a space.
pub(super) fn table_cell(text: &str) -> String {
    text.replace(['\t', '\n', '\r'], " ").trim().to_owned()
}

/// A styled heading longer than this many characters is body text with a heading style, so it
/// stays as it is.
const MAX_HEADING_CHARS: usize = 200;

/// The headings above the current position of a text document, outermost first.
#[derive(Default)]
pub(super) struct Outline(Vec<(u8, String)>);

impl Outline {
    /// Turns the heading that `out` ends with, from byte `start`, into a `[Section: a > b]` line
    /// that names the headings it sits under, and leaves `out` at the start of a new line.
    pub(super) fn mark(&mut self, out: &mut String, start: usize, level: u8) {
        let title = table_cell(&out[start..]);
        if title.is_empty() || title.chars().count() > MAX_HEADING_CHARS {
            push_newline_once(out);
            return;
        }
        self.0.retain(|(above, _)| *above < level);
        self.0.push((level, title));
        let path: Vec<&str> = self.0.iter().map(|(_, title)| title.as_str()).collect();
        out.truncate(start);
        push_newline_once(out);
        out.push_str(&format!("[Section: {}]\n", path.join(" > ")));
    }
}

pub(super) struct BoundedZip<'a> {
    archive: ZipArchive<Cursor<&'a [u8]>>,
    total_uncompressed: u64,
}

pub(super) enum ZipOpenError {
    Skipped(&'static str),
    Failed(String),
}

impl<'a> BoundedZip<'a> {
    pub(super) fn open(bytes: &'a [u8]) -> Result<Self, ZipOpenError> {
        if bytes.len() > MAX_DOCUMENT_INPUT_BYTES {
            return Err(ZipOpenError::Skipped("file_too_large"));
        }
        if bytes.starts_with(&OLE2_MAGIC) {
            return Err(ZipOpenError::Skipped("encrypted_or_legacy_ole"));
        }
        let archive = ZipArchive::new(Cursor::new(bytes))
            .map_err(|err| ZipOpenError::Failed(format!("invalid_zip: {err}")))?;
        if archive.len() > MAX_ZIP_ENTRIES {
            return Err(ZipOpenError::Skipped("zip_limit_exceeded"));
        }
        Ok(Self {
            archive,
            total_uncompressed: 0,
        })
    }

    pub(super) fn contains(&self, name: &str) -> bool {
        self.archive.index_for_name(name).is_some()
    }

    /// Entry names that decode as text; the extractors only look up ASCII OOXML part names.
    pub(super) fn file_names(&self) -> Vec<String> {
        self.archive
            .file_names()
            .filter_map(|entry| entry.ok().map(|name| name.into_owned()))
            .collect()
    }

    pub(super) fn read_utf8(&mut self, name: &str) -> Result<Option<String>, ZipOpenError> {
        let entry = match self.archive.by_name(name) {
            Ok(file) => file,
            Err(zip::result::ZipError::FileNotFound) => return Ok(None),
            Err(err) => return Err(ZipOpenError::Failed(format!("zip_entry_error: {err}"))),
        };

        if entry.size() > MAX_ZIP_ENTRY_UNCOMPRESSED_BYTES {
            return Err(ZipOpenError::Skipped("zip_limit_exceeded"));
        }

        let mut buf = Vec::with_capacity((entry.size() as usize).min(256 * 1024));
        entry
            .take(MAX_ZIP_ENTRY_UNCOMPRESSED_BYTES + 1)
            .read_to_end(&mut buf)
            .map_err(|err| ZipOpenError::Failed(format!("zip_read_error: {err}")))?;

        if (buf.len() as u64) > MAX_ZIP_ENTRY_UNCOMPRESSED_BYTES {
            return Err(ZipOpenError::Skipped("zip_limit_exceeded"));
        }

        self.total_uncompressed = self.total_uncompressed.saturating_add(buf.len() as u64);
        if self.total_uncompressed > MAX_ZIP_TOTAL_UNCOMPRESSED_BYTES {
            return Err(ZipOpenError::Skipped("zip_limit_exceeded"));
        }

        let text = String::from_utf8(buf)
            .map_err(|err| ZipOpenError::Failed(format!("invalid_xml_utf8: {err}")))?;
        Ok(Some(text))
    }
}

pub(super) fn zip_error_to_result(format: &str, err: ZipOpenError) -> FileTextResult {
    match err {
        ZipOpenError::Skipped(reason) => {
            FileTextResult::skipped(FileSubtype::Document, format, reason)
        }
        ZipOpenError::Failed(reason) => {
            FileTextResult::failed(FileSubtype::Document, format, reason)
        }
    }
}

pub(super) fn local_name(qname: &str) -> &str {
    match qname.rfind(':') {
        Some(pos) => &qname[pos + 1..],
        None => qname,
    }
}

pub(super) fn attr_value_by_local(start: &BytesStart<'_>, target_local: &str) -> Option<String> {
    for attr in start.attributes().flatten() {
        if local_name(attr.key.as_ref()) == target_local
            && let Ok(val) = attr.normalized_value(XmlVersion::Implicit1_0)
        {
            return Some(val.into_owned());
        }
    }
    None
}

pub(super) fn append_xml_entity(entity: &BytesRef<'_>, out: &mut String) {
    if let Ok(unescaped) = quick_xml::escape::unescape(&format!("&{};", entity.as_ref())) {
        out.push_str(&unescaped);
    }
}

pub(super) fn push_newline_once(out: &mut String) {
    if !out.is_empty() && !out.ends_with('\n') {
        out.push('\n');
    }
}

pub(super) fn push_tab_once(out: &mut String) {
    if !out.is_empty() && !out.ends_with(['\n', '\t']) {
        out.push('\t');
    }
}

#[cfg(test)]
mod tests;
