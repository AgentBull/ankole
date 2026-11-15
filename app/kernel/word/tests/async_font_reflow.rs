//! Separate-process integration test verifying that opening a `.docx` declaring `华文楷体`
//! (`STKaiti`) before `Editor::add_font` and then registering `LXGW WenKai GB` produces the
//! exact same layout, substitution metadata, and rendered RGBA pixels as opening a fresh
//! `Editor` after the font is already loaded, without rewriting declared `.docx` font names.

#![allow(
    clippy::unwrap_used,
    clippy::expect_used,
    clippy::panic,
    clippy::indexing_slicing,
    reason = "integration test assertions fail fast"
)]

use std::io::Read as _;

use ankole_word::editor::Editor;
use serde_json::{Value, json};

fn build_synthetic_cjk_font(family: &str, local_zh: &str, extra_chars: &[char]) -> Vec<u8> {
    let base = wordcraft_fonts::bundled()[0];
    let num_tables = u16::from_be_bytes([base[4], base[5]]) as usize;

    // Locate 'W' glyph ID from bundled Source Sans 3 via a minimal lookup in `maxp` (any valid
    // non-zero glyph ID with real outlines works; glyph ID 56 in Source Sans 3 is 'W').
    let glyph_id = 56u32;

    let mut mappings = std::collections::BTreeMap::new();
    for cp in 0x20u32..=0x7Eu32 {
        mappings.insert(cp, if cp == 0x20 { 1 } else { glyph_id });
    }
    for &ch in extra_chars {
        mappings.insert(ch as u32, glyph_id);
    }

    let mut cmap = Vec::new();
    cmap.extend_from_slice(&0u16.to_be_bytes());
    cmap.extend_from_slice(&1u16.to_be_bytes());
    cmap.extend_from_slice(&3u16.to_be_bytes());
    cmap.extend_from_slice(&10u16.to_be_bytes());
    cmap.extend_from_slice(&12u32.to_be_bytes());
    cmap.extend_from_slice(&12u16.to_be_bytes());
    cmap.extend_from_slice(&0u16.to_be_bytes());
    let subtable_len = 16 + 12 * mappings.len() as u32;
    cmap.extend_from_slice(&subtable_len.to_be_bytes());
    cmap.extend_from_slice(&0u32.to_be_bytes());
    cmap.extend_from_slice(&(mappings.len() as u32).to_be_bytes());
    for (cp, gid) in mappings {
        cmap.extend_from_slice(&cp.to_be_bytes());
        cmap.extend_from_slice(&cp.to_be_bytes());
        cmap.extend_from_slice(&gid.to_be_bytes());
    }

    let mut names: Vec<(u16, u16, String)> = vec![
        (0x409, 1, family.to_string()),
        (0x409, 2, "Regular".to_string()),
        (0x409, 16, family.to_string()),
        (0x409, 17, "Regular".to_string()),
        (0x804, 1, local_zh.to_string()),
        (0x804, 2, "Regular".to_string()),
        (0x804, 16, local_zh.to_string()),
        (0x804, 17, "Regular".to_string()),
    ];
    names.sort_by_key(|(lang, id, _)| (*lang, *id));

    let mut name_table = vec![0, 0];
    name_table.extend_from_slice(&(names.len() as u16).to_be_bytes());
    name_table.extend_from_slice(&(6 + 12 * names.len() as u16).to_be_bytes());
    let mut pool = Vec::new();
    for (lang, id, text) in &names {
        let utf16: Vec<u8> = text.encode_utf16().flat_map(u16::to_be_bytes).collect();
        for v in [3u16, 1, *lang, *id, utf16.len() as u16, pool.len() as u16] {
            name_table.extend_from_slice(&v.to_be_bytes());
        }
        pool.extend(utf16);
    }
    name_table.extend(pool);

    let mut tables: Vec<([u8; 4], Vec<u8>)> = (0..num_tables)
        .filter_map(|i| {
            let rec = &base[12 + i * 16..28 + i * 16];
            let tag: [u8; 4] = rec[..4].try_into().unwrap();
            if &tag == b"name" || &tag == b"cmap" {
                return None;
            }
            let off = u32::from_be_bytes(rec[8..12].try_into().unwrap()) as usize;
            let len = u32::from_be_bytes(rec[12..16].try_into().unwrap()) as usize;
            Some((tag, base[off..off + len].to_vec()))
        })
        .collect();
    tables.push((*b"cmap", cmap));
    tables.push((*b"name", name_table));
    tables.sort_by_key(|(tag, _)| *tag);

    let mut font = Vec::new();
    font.extend_from_slice(&0x0001_0000_u32.to_be_bytes());
    font.extend_from_slice(&(tables.len() as u16).to_be_bytes());
    font.extend_from_slice(&[0; 6]);
    let mut offset = 12 + 16 * tables.len();
    for (tag, data) in &tables {
        font.extend_from_slice(tag);
        font.extend_from_slice(&[0; 4]);
        font.extend_from_slice(&(offset as u32).to_be_bytes());
        font.extend_from_slice(&(data.len() as u32).to_be_bytes());
        offset += data.len().next_multiple_of(4);
    }
    for (_, data) in &tables {
        font.extend_from_slice(data);
        font.resize(font.len().next_multiple_of(4), 0);
    }
    font
}

fn build_stkaiti_docx() -> Vec<u8> {
    let mut builder = Editor::create_blank("澳门基金管理公司经营计划书").expect("blank editor");
    let paragraph = "澳门基金管理公司经营计划书（正文华文楷体）2026年度资产配置与风险控制方案。";
    let full_text = std::iter::repeat_n(paragraph, 45)
        .collect::<Vec<_>>()
        .join("\n");
    builder.insert_text(&full_text).unwrap();
    builder.key_event("a", true, false, false).unwrap();
    builder
        .execute_command("format.font", &json!({"name": "华文楷体"}).to_string())
        .unwrap();
    builder
        .execute_command("format.size", &json!({"size": 14}).to_string())
        .unwrap();
    builder.export_docx().expect("export stkaiti docx")
}

#[test]
fn cold_open_then_add_font_matches_warm_open_layout_and_pixels() {
    let docx_bytes = build_stkaiti_docx();

    // 1. Open BEFORE site fonts arrive: layout caches missing-glyph metrics and substituted fonts.
    let mut cold = Editor::open(&docx_bytes, "[]").expect("open cold docx");
    let cold_missing_before: Vec<String> =
        serde_json::from_str(&cold.missing_glyph_fonts().unwrap()).unwrap();
    assert_eq!(cold_missing_before, vec!["IBM Plex Sans SC"]);

    let cold_subs_before: Vec<Value> =
        serde_json::from_str(&cold.substituted_fonts().unwrap()).unwrap();
    assert!(
        cold_subs_before
            .iter()
            .any(|item| item["requested"] == "华文楷体" && item["used"] != "LXGW WenKai GB"),
        "before LXGW WenKai GB loads, 华文楷体 cannot resolve to it: {cold_subs_before:?}"
    );

    let _cold_pages_before = cold.pages_info().unwrap();
    let cold_rgba_before = cold.render_page_rgba(0, 1.0).unwrap();

    // 2. Register LXGW WenKai GB dynamically (simulating async `/fonts/office/` Worker injection).
    let cjk_chars: Vec<char> =
        "澳门基金管理公司经营计划书（正文华文楷体）年度资产配置与风险控制方案。"
            .chars()
            .collect();
    let wenkai_bytes = build_synthetic_cjk_font("LXGW WenKai GB", "霞鹜文楷 GB", &cjk_chars);
    assert_eq!(Editor::add_font(&wenkai_bytes), 1);

    // 3. Re-query the SAME cold editor without reopening: generation bump must invalidate both
    //    `word::resolve` and `Session` layout caches.
    let cold_missing_after: Vec<String> =
        serde_json::from_str(&cold.missing_glyph_fonts().unwrap()).unwrap();
    assert!(
        cold_missing_after.is_empty(),
        "LXGW WenKai GB covers all document CJK characters: {cold_missing_after:?}"
    );

    let cold_subs_after: Vec<Value> =
        serde_json::from_str(&cold.substituted_fonts().unwrap()).unwrap();
    assert!(
        cold_subs_after
            .iter()
            .any(|item| item["requested"] == "华文楷体" && item["used"] == "LXGW WenKai GB"),
        "expected 华文楷体 -> LXGW WenKai GB after add_font, got {cold_subs_after:?}"
    );

    let cold_pages_after = cold.pages_info().unwrap();
    let cold_rgba_after = cold.render_page_rgba(0, 1.0).unwrap();
    assert_ne!(
        cold_rgba_after, cold_rgba_before,
        "rendered page 0 RGBA must update after async CJK font registration"
    );

    // 4. Open a brand-new warm editor AFTER the font is already in FontDb: layout, substitutions,
    //    and rendered pixels must match byte-for-byte.
    let mut warm = Editor::open(&docx_bytes, "[]").expect("open warm docx");
    assert_eq!(cold_pages_after, warm.pages_info().unwrap());
    assert_eq!(
        cold.substituted_fonts().unwrap(),
        warm.substituted_fonts().unwrap()
    );
    assert_eq!(cold_rgba_after, warm.render_page_rgba(0, 1.0).unwrap());

    // 5. Display/export substitution must NEVER rewrite the `.docx`'s declared `华文楷体` family.
    let saved_docx = cold.export_docx().unwrap();
    let mut archive = zip::ZipArchive::new(std::io::Cursor::new(saved_docx)).unwrap();
    let mut document_xml = String::new();
    archive
        .by_name("word/document.xml")
        .unwrap()
        .read_to_string(&mut document_xml)
        .unwrap();
    assert!(
        document_xml.contains("华文楷体"),
        "saved word/document.xml must preserve original 华文楷体 declaration"
    );
    assert!(
        !document_xml.contains("LXGW WenKai GB"),
        "saved word/document.xml must not overwrite declared font with substitute name"
    );
}
