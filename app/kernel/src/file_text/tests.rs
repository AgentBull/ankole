use std::io::{Cursor, Write};

use lopdf::content::{Content, Operation};
use lopdf::{Document, Object, Stream, dictionary};
use zip::ZipWriter;
use zip::write::SimpleFileOptions;

use super::{ExtractStatus, FileSubtype, classify, extract};

fn build_zip(entries: &[(&str, &[u8])]) -> Vec<u8> {
    let mut writer = ZipWriter::new(Cursor::new(Vec::new()));
    let options = SimpleFileOptions::default();
    for &(name, data) in entries {
        writer.start_file(name, options).unwrap();
        writer.write_all(data).unwrap();
    }
    writer.finish().unwrap().into_inner()
}

fn build_two_page_pdf(page1: &str, page2: &str) -> Vec<u8> {
    let mut doc = Document::with_version("1.5");
    let pages_id = doc.new_object_id();
    let font_id = doc.add_object(dictionary! {
        "Type" => "Font",
        "Subtype" => "Type1",
        "BaseFont" => "Helvetica",
    });
    let resources_id = doc.add_object(dictionary! {
        "Font" => dictionary! {
            "F1" => font_id,
        },
    });

    let make_content = |text: &str| -> Stream {
        let ops = if text.is_empty() {
            vec![]
        } else {
            vec![
                Operation::new("BT", vec![]),
                Operation::new("Tf", vec!["F1".into(), 12.into()]),
                Operation::new("Tj", vec![Object::string_literal(text)]),
                Operation::new("ET", vec![]),
            ]
        };
        Stream::new(
            dictionary! {},
            Content { operations: ops }.encode().unwrap(),
        )
    };

    let c1 = doc.add_object(make_content(page1));
    let c2 = doc.add_object(make_content(page2));

    let p1_id = doc.add_object(dictionary! {
        "Type" => "Page",
        "Parent" => pages_id,
        "Contents" => c1,
    });
    let p2_id = doc.add_object(dictionary! {
        "Type" => "Page",
        "Parent" => pages_id,
        "Contents" => c2,
    });

    doc.objects.insert(
        pages_id,
        Object::Dictionary(dictionary! {
            "Type" => "Pages",
            "Kids" => vec![p1_id.into(), p2_id.into()],
            "Count" => 2,
            "Resources" => resources_id,
            "MediaBox" => vec![0.into(), 0.into(), 595.into(), 842.into()],
        }),
    );
    let catalog_id = doc.add_object(dictionary! {
        "Type" => "Catalog",
        "Pages" => pages_id,
    });
    doc.trailer.set("Root", catalog_id);

    let mut buf = Vec::new();
    doc.save_to(&mut buf).unwrap();
    buf
}

#[test]
fn classifies_extensions_and_mimes() {
    assert_eq!(
        classify("notes/README.md", None),
        Some((FileSubtype::Text, "md"))
    );
    assert_eq!(
        classify("report.CSV", None),
        Some((FileSubtype::Text, "csv"))
    );
    assert_eq!(
        classify("Makefile", None),
        Some((FileSubtype::Text, "code"))
    );
    assert_eq!(
        classify("spec.docx", None),
        Some((FileSubtype::Document, "docx"))
    );
    assert_eq!(
        classify("deck.pptx", None),
        Some((FileSubtype::Document, "pptx"))
    );
    assert_eq!(
        classify("paper.pdf", None),
        Some((FileSubtype::Document, "pdf"))
    );
    assert_eq!(classify("photo.png", Some("image/png")), None);
    assert_eq!(classify("sheet.xlsx", None), None);
    assert_eq!(
        classify("untitled", Some("text/plain; charset=utf-8")),
        Some((FileSubtype::Text, "txt"))
    );
}

#[test]
fn extracts_utf8_markdown_with_nfkc_and_rejects_binary() {
    let md = "\u{FEFF}# Ｑ４ 路线图\r\n第二行\u{001e}正文\u{001f}完";
    let res = extract(md.as_bytes(), "roadmap.md", Some("text/markdown"));
    assert_eq!(res.status, ExtractStatus::Ok);
    assert_eq!(res.subtype, FileSubtype::Text);
    assert_eq!(res.format, "md");
    assert_eq!(res.plain_text, "# Q4 路线图\n第二行正文完");
    assert_eq!(res.metadata["line_count"], 2);

    let bin = extract(b"hello\0world", "fake.txt", Some("text/plain"));
    assert_eq!(bin.status, ExtractStatus::Skipped);
    assert_eq!(bin.error.as_deref(), Some("binary_content"));
}

#[test]
fn extracts_csv_preserving_data_row_line_alignment() {
    let csv_bytes = b"region,notes\n\"East\nChina\",Alpha\nWest,Beta\n";
    let res = extract(csv_bytes, "sales.csv", Some("text/csv"));
    assert_eq!(res.status, ExtractStatus::Ok);
    assert_eq!(res.format, "csv");
    assert_eq!(res.metadata["row_count"], 2);
    let lines: Vec<&str> = res.plain_text.lines().collect();
    assert_eq!(
        lines,
        vec!["region\tnotes", "East China\tAlpha", "West\tBeta"]
    );
}

#[test]
fn extracts_docx_skipping_deleted_revisions_and_fallbacks() {
    let doc_xml = r#"<?xml version="1.0" encoding="UTF-8"?>
    <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"
                xmlns:mc="http://schemas.openxmlformats.org/markup-compatibility/2006">
      <w:body>
        <w:p><w:r><w:t>季度复盘</w:t></w:r><w:del><w:r><w:delText>旧草稿</w:delText></w:r></w:del></w:p>
        <w:p>
          <mc:AlternateContent>
            <mc:Choice><w:r><w:t>文本框内容</w:t></w:r></mc:Choice>
            <mc:Fallback><w:r><w:t>文本框内容</w:t></w:r></mc:Fallback>
          </mc:AlternateContent>
        </w:p>
        <w:tbl><w:tr><w:tc><w:p><w:r><w:t>指标</w:t></w:r></w:p></w:tc><w:tc><w:p><w:r><w:t>99%</w:t></w:r></w:p></w:tc></w:tr></w:tbl>
      </w:body>
    </w:document>"#
        .as_bytes();
    let bytes = build_zip(&[("word/document.xml", doc_xml)]);
    let res = extract(&bytes, "review.docx", None);
    assert_eq!(res.status, ExtractStatus::Ok);
    assert!(res.plain_text.contains("季度复盘"));
    assert!(!res.plain_text.contains("旧草稿"));
    assert_eq!(res.plain_text.matches("文本框内容").count(), 1);
    assert!(res.plain_text.contains("指标"));
    assert!(res.plain_text.contains("99%"));

    let ole_encrypted = [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1, 1, 2, 3];
    let skipped = extract(&ole_encrypted, "locked.docx", None);
    assert_eq!(skipped.status, ExtractStatus::Skipped);
    assert_eq!(skipped.error.as_deref(), Some("encrypted_or_legacy_ole"));
}

#[test]
fn extracts_pptx_in_presentation_order_with_notes_and_page_spans() {
    let pres_xml = br#"<?xml version="1.0" encoding="UTF-8"?>
    <p:presentation xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"
                    xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
      <p:sldIdLst>
        <p:sldId id="256" r:id="rId2"/>
        <p:sldId id="257" r:id="rId1"/>
      </p:sldIdLst>
    </p:presentation>"#;
    let pres_rels = br#"<?xml version="1.0" encoding="UTF-8"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
      <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide" Target="slides/slide1.xml"/>
      <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide" Target="slides/slide2.xml"/>
    </Relationships>"#;
    let slide1 = br#"<p:sld xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"><p:cSld><p:spTree><p:sp><p:txBody><a:p><a:r><a:t>Second Deck Page</a:t></a:r></a:p></p:txBody></p:sp></p:spTree></p:cSld></p:sld>"#;
    let slide2 = br#"<p:sld xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"><p:cSld><p:spTree><p:sp><p:txBody><a:p><a:r><a:t>Opening Cover</a:t></a:r></a:p></p:txBody></p:sp></p:spTree></p:cSld></p:sld>"#;
    let slide1_rels = br#"<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/notesSlide" Target="../notesSlides/notesSlide1.xml"/></Relationships>"#;
    let notes1 = br#"<p:notes xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"><p:cSld><p:spTree><p:sp><p:txBody><a:p><a:r><a:t>Speaker cue alpha</a:t></a:r></a:p></p:txBody></p:sp></p:spTree></p:cSld></p:notes>"#;

    let bytes = build_zip(&[
        ("ppt/presentation.xml", pres_xml),
        ("ppt/_rels/presentation.xml.rels", pres_rels),
        ("ppt/slides/slide1.xml", slide1),
        ("ppt/slides/slide2.xml", slide2),
        ("ppt/slides/_rels/slide1.xml.rels", slide1_rels),
        ("ppt/notesSlides/notesSlide1.xml", notes1),
    ]);

    let res = extract(&bytes, "pitch.pptx", None);
    assert_eq!(res.status, ExtractStatus::Ok);
    assert_eq!(res.metadata["page_count"], 2);
    let pages = res.metadata["pages"].as_array().unwrap();
    assert_eq!(pages.len(), 2);
    let p1_start = pages[0]["start_byte"].as_u64().unwrap() as usize;
    let p1_end = pages[0]["end_byte"].as_u64().unwrap() as usize;
    let p2_start = pages[1]["start_byte"].as_u64().unwrap() as usize;
    let p2_end = pages[1]["end_byte"].as_u64().unwrap() as usize;
    assert_eq!(pages[0]["page"], 1);
    assert!(res.plain_text[p1_start..p1_end].contains("Opening Cover"));
    assert_eq!(pages[1]["page"], 2);
    assert!(res.plain_text[p2_start..p2_end].contains("Second Deck Page"));
    assert!(res.plain_text[p2_start..p2_end].contains("Speaker cue alpha"));
}

#[test]
fn extracts_odt_and_ods_and_skips_encrypted_manifest() {
    let ods_xml = br#"<?xml version="1.0" encoding="UTF-8"?>
    <office:document-content xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0"
                             xmlns:table="urn:oasis:names:tc:opendocument:xmlns:table:1.0"
                             xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0">
      <office:body><office:spreadsheet>
        <table:table table:name="Ledger">
          <table:table-row>
            <table:table-cell><text:p>Account</text:p></table:table-cell>
            <table:table-cell><text:p>Balance</text:p></table:table-cell>
          </table:table-row>
        </table:table>
      </office:spreadsheet></office:body>
    </office:document-content>"#;
    let ods = extract(&build_zip(&[("content.xml", ods_xml)]), "book.ods", None);
    assert_eq!(ods.status, ExtractStatus::Ok);
    assert_eq!(ods.plain_text, "Ledger\nAccount\tBalance\n");
    assert_eq!(ods.metadata["sheets"], serde_json::json!(["Ledger"]));
    assert_eq!(
        ods.metadata["sheet_spans"],
        serde_json::json!([{
            "sheet_name": "Ledger",
            "start_byte": 0,
            "end_byte": 23
        }])
    );

    let multi_ods_xml = br#"<?xml version="1.0" encoding="UTF-8"?>
    <office:document-content xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0"
                             xmlns:table="urn:oasis:names:tc:opendocument:xmlns:table:1.0"
                             xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0">
      <office:body><office:spreadsheet>
        <table:table table:name="First">
          <table:table-row><table:table-cell><text:p>Second</text:p></table:table-cell></table:table-row>
        </table:table>
        <table:table table:name="Second">
          <table:table-row><table:table-cell><text:p>Odsreviewneedle</text:p></table:table-cell></table:table-row>
        </table:table>
      </office:spreadsheet></office:body>
    </office:document-content>"#;
    let multi_ods = extract(
        &build_zip(&[("content.xml", multi_ods_xml)]),
        "review.ods",
        None,
    );
    let spans = multi_ods.metadata["sheet_spans"].as_array().unwrap();
    assert_eq!(spans.len(), 2);
    let needle_offset = multi_ods.plain_text.find("Odsreviewneedle").unwrap();
    let s2_start = spans[1]["start_byte"].as_u64().unwrap() as usize;
    let s2_end = spans[1]["end_byte"].as_u64().unwrap() as usize;
    assert_eq!(spans[1]["sheet_name"], "Second");
    assert!(needle_offset >= s2_start && needle_offset < s2_end);

    let enc_manifest = br#"<manifest:manifest><manifest:file-entry><manifest:encryption-data/></manifest:file-entry></manifest:manifest>"#;
    let locked = extract(
        &build_zip(&[
            ("META-INF/manifest.xml", enc_manifest),
            ("content.xml", ods_xml),
        ]),
        "secret.odt",
        None,
    );
    assert_eq!(locked.status, ExtractStatus::Skipped);
    assert_eq!(locked.error.as_deref(), Some("encrypted_document"));
}

#[test]
fn extracts_pdf_pages_and_classifies_blank_or_corrupt_pdfs() {
    let pdf_bytes = build_two_page_pdf("Executive Summary", "Appendix Metrics");
    let res = extract(&pdf_bytes, "brief.pdf", Some("application/pdf"));
    assert_eq!(res.status, ExtractStatus::Ok);
    assert_eq!(res.metadata["page_count"], 2);
    let pages = res.metadata["pages"].as_array().unwrap();
    assert_eq!(pages.len(), 2);
    let s2 = pages[1]["start_byte"].as_u64().unwrap() as usize;
    let e2 = pages[1]["end_byte"].as_u64().unwrap() as usize;
    assert_eq!(pages[1]["page"], 2);
    assert!(res.plain_text[s2..e2].contains("Appendix Metrics"));

    let blank_pdf = build_two_page_pdf("", "");
    let blank_res = extract(&blank_pdf, "scan.pdf", None);
    assert_eq!(blank_res.status, ExtractStatus::Skipped);
    assert_eq!(blank_res.error.as_deref(), Some("empty_text_layer"));

    let corrupt = extract(b"%PDF-1.7\ngarbage-not-a-valid-xref", "broken.pdf", None);
    assert_eq!(corrupt.status, ExtractStatus::Failed);
}
