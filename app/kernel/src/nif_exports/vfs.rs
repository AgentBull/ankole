use super::{NIFResult, Term};
use crate::page_document;
use crate::vfs;
use crate::vfs::webdav_xml::Entry;
use serde_json::Value;

#[rustler::nif(schedule = "DirtyCpu")]
fn page_content_empty_nif(source: Term<'_>) -> NIFResult<bool> {
    let source = super::decode_string(source, "source")?;
    stacker::grow(8 * 1024 * 1024, || page_document::vfs::is_empty(&source))
        .map_err(super::error_message)
}

#[rustler::nif(schedule = "DirtyCpu")]
fn vfs_pipeline_nif(parts: Term<'_>) -> NIFResult<String> {
    let parts: Vec<String> = serde_json::from_str(&super::decode_string(parts, "parts")?)
        .map_err(|e| super::error_message(e.to_string()))?;
    Ok(vfs::tabular::pipeline(&parts).to_string())
}

#[rustler::nif(schedule = "DirtyIo")]
fn vfs_export_chunk_nif(
    path: Term<'_>,
    format: Term<'_>,
    columns: Term<'_>,
    rows: Term<'_>,
    first: bool,
    last: bool,
) -> NIFResult<u64> {
    let columns: Vec<String> = serde_json::from_str(&super::decode_string(columns, "columns")?)
        .map_err(|e| super::error_message(e.to_string()))?;
    let rows: Vec<Value> = serde_json::from_str(&super::decode_string(rows, "rows")?)
        .map_err(|e| super::error_message(e.to_string()))?;
    vfs::tabular::export_chunk(
        &super::decode_string(path, "path")?,
        &super::decode_string(format, "format")?,
        &columns,
        &rows,
        first,
        last,
    )
    .map_err(super::error_message)
}

#[rustler::nif(schedule = "DirtyIo")]
fn vfs_import_chunk_nif(path: Term<'_>, format: Term<'_>, offset: u64) -> NIFResult<String> {
    vfs::tabular::import_chunk(
        &super::decode_string(path, "path")?,
        &super::decode_string(format, "format")?,
        offset,
    )
    .map(|v| v.to_string())
    .map_err(super::error_message)
}

#[rustler::nif(schedule = "DirtyCpu")]
fn vfs_document_export_nif(source: Term<'_>) -> NIFResult<String> {
    let source = super::decode_string(source, "source")?;
    stacker::grow(8 * 1024 * 1024, || page_document::vfs::export(&source))
        .map_err(super::error_message)
}

#[rustler::nif(schedule = "DirtyCpu")]
fn vfs_document_reconcile_nif(source: Term<'_>, markdown: Term<'_>) -> NIFResult<(String, String)> {
    let source = super::decode_string(source, "source")?;
    let markdown = super::decode_string(markdown, "markdown")?;
    stacker::grow(8 * 1024 * 1024, || {
        page_document::vfs::reconcile(&source, &markdown)
    })
    .map(|page| (page.xml, page.plain_text))
    .map_err(super::error_message)
}

#[rustler::nif(schedule = "DirtyCpu")]
fn vfs_fingerprint_nif(source: Term<'_>) -> NIFResult<String> {
    let source = super::decode_binary(source, "source")?;
    Ok(blake3::hash(source.as_slice()).to_hex().to_string())
}

#[rustler::nif]
fn vfs_name_nif(name: Term<'_>, kind: Term<'_>, id: Term<'_>) -> NIFResult<String> {
    vfs::path_codec::encode(
        &super::decode_string(name, "name")?,
        &super::decode_string(kind, "kind")?,
        &super::decode_string(id, "id")?,
    )
    .map_err(super::error_message)
}

#[rustler::nif]
fn vfs_decode_name_nif(name: Term<'_>) -> NIFResult<(String, String)> {
    vfs::path_codec::decode_new(&super::decode_string(name, "name")?).map_err(super::error_message)
}

#[rustler::nif]
fn vfs_range_nif(range: Term<'_>, size: u64) -> NIFResult<(u64, u64)> {
    vfs::http_headers::byte_range(&super::decode_string(range, "range")?, size)
        .map_err(super::error_message)
}

#[rustler::nif(schedule = "DirtyCpu")]
fn vfs_xml_request_nif(source: Term<'_>, method: Term<'_>) -> NIFResult<bool> {
    vfs::webdav_xml::request(
        &super::decode_string(source, "source")?,
        &super::decode_string(method, "method")?,
    )
    .map_err(super::error_message)?;
    Ok(true)
}

#[rustler::nif(schedule = "DirtyCpu")]
fn vfs_multistatus_nif(entries: Term<'_>) -> NIFResult<String> {
    let entries: Vec<Entry> = serde_json::from_str(&super::decode_string(entries, "entries")?)
        .map_err(|e| super::error_message(e.to_string()))?;
    Ok(vfs::webdav_xml::multistatus(&entries))
}

#[rustler::nif(schedule = "DirtyCpu")]
fn vfs_record_patch_nif(source: Term<'_>) -> NIFResult<String> {
    let source: Value = serde_json::from_str(&super::decode_string(source, "source")?)
        .map_err(|e| super::error_message(e.to_string()))?;
    vfs::tabular::record_patch(&source["base"], &source["next"])
        .map(|v| v.to_string())
        .map_err(super::error_message)
}

#[rustler::nif]
fn vfs_import_id_nif(
    tenant: Term<'_>,
    table: Term<'_>,
    request: Term<'_>,
    millis: u64,
    row: u64,
) -> NIFResult<String> {
    vfs::tabular::import_id(
        &super::decode_string(tenant, "tenant")?,
        &super::decode_string(table, "table")?,
        &super::decode_string(request, "request")?,
        millis,
        row,
    )
    .map_err(super::error_message)
}

#[rustler::nif(schedule = "DirtyCpu")]
fn vfs_merge_knowledge_nif<'a>(
    base: Term<'a>,
    base_meta: Term<'a>,
    current: Term<'a>,
    current_meta: Term<'a>,
    edited: Term<'a>,
    edited_meta: Term<'a>,
) -> NIFResult<String> {
    let metadata = |value| {
        serde_json::from_str(&super::decode_string(value, "metadata")?)
            .map_err(|e: serde_json::Error| super::error_message(e.to_string()))
    };
    let base = super::decode_string(base, "base")?;
    let base_meta = metadata(base_meta)?;
    let current = super::decode_string(current, "current")?;
    let current_meta = metadata(current_meta)?;
    let edited = super::decode_string(edited, "edited")?;
    let edited_meta = metadata(edited_meta)?;
    stacker::grow(8 * 1024 * 1024, || {
        page_document::knowledge::merge(
            &base,
            &base_meta,
            &current,
            &current_meta,
            &edited,
            &edited_meta,
        )
        .and_then(|result| serde_json::to_string(&result).map_err(|e| e.to_string()))
    })
    .map_err(super::error_message)
}
