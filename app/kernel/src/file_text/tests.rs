use std::io::{Cursor, Write};

use lopdf::content::{Content, Operation};
use lopdf::{Document, Object, Stream, dictionary};
use zip::ZipWriter;
use zip::write::SimpleFileOptions;

use super::pdf::clean_page;
use super::{ExtractStatus, FileSubtype, MAX_PDF_PAGES, PLAIN_TEXT_LIMIT, classify, extract};

fn build_zip(entries: &[(&str, &[u8])]) -> Vec<u8> {
    let mut writer = ZipWriter::new(Cursor::new(Vec::new()));
    let options = SimpleFileOptions::default();
    for &(name, data) in entries {
        writer.start_file(name, options).unwrap();
        writer.write_all(data).unwrap();
    }
    writer.finish().unwrap().into_inner()
}

fn build_pdf(pages: &[&str]) -> Vec<u8> {
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

    let kids: Vec<Object> = pages
        .iter()
        .map(|text| {
            let contents = doc.add_object(make_content(text));
            doc.add_object(dictionary! {
                "Type" => "Page",
                "Parent" => pages_id,
                "Contents" => contents,
            })
            .into()
        })
        .collect();

    doc.objects.insert(
        pages_id,
        Object::Dictionary(dictionary! {
            "Type" => "Pages",
            "Count" => kids.len() as i64,
            "Kids" => kids,
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
    assert_eq!(
        res.metadata,
        serde_json::json!({ "line_count": 2, "truncated": false })
    );

    let long = extract("长".repeat(200_000).as_bytes(), "long.txt", None);
    assert_eq!(long.plain_text.len(), PLAIN_TEXT_LIMIT - 2);
    assert_eq!(long.metadata["truncated"], true);

    let bin = extract(b"hello\0world", "fake.txt", Some("text/plain"));
    assert_eq!(bin.status, ExtractStatus::Skipped);
    assert_eq!(bin.error.as_deref(), Some("binary_content"));
}

#[test]
fn extracts_delimited_records_as_numbered_rows_one_line_each() {
    let csv_bytes = b"region,notes\n\"East\nChina\",Alpha\nWest,Beta\n";
    let res = extract(csv_bytes, "sales.csv", Some("text/csv"));
    assert_eq!(res.status, ExtractStatus::Ok);
    assert_eq!(res.format, "csv");
    assert_eq!(
        res.metadata,
        serde_json::json!({ "row_count": 2, "delimiter": ",", "truncated": false })
    );
    assert_eq!(
        res.plain_text,
        "R1\tregion\tnotes\nR2\tEast China\tAlpha\nR3\tWest\tBeta\n"
    );

    // Blank cells keep their column, trailing ones are dropped, and a blank record keeps its line.
    let sparse = extract(b"a\t\tc\t\t\n\t\t\n x \ty\n", "sparse.tsv", None);
    assert_eq!(sparse.plain_text, "R1\ta\t\tc\nR2\t\nR3\tx\ty\n");
    assert_eq!(sparse.metadata["row_count"], 2);

    let long = extract("内容,x\n".repeat(60_000).as_bytes(), "long.csv", None);
    assert!(long.plain_text.len() <= PLAIN_TEXT_LIMIT);
    assert_eq!(long.metadata["row_count"], 59_999);
    assert_eq!(long.metadata["truncated"], true);
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
    assert_eq!(
        res.metadata,
        serde_json::json!({ "part_count": 1, "truncated": false })
    );

    let ole_encrypted = [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1, 1, 2, 3];
    let skipped = extract(&ole_encrypted, "locked.docx", None);
    assert_eq!(skipped.status, ExtractStatus::Skipped);
    assert_eq!(skipped.error.as_deref(), Some("encrypted_or_legacy_ole"));
}

#[test]
fn docx_and_odt_headings_open_sections_named_by_their_outline() {
    let styles_xml = br#"<?xml version="1.0" encoding="UTF-8"?>
    <w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
      <w:style w:type="paragraph" w:styleId="1"><w:name w:val="heading 1"/></w:style>
      <w:style w:type="paragraph" w:styleId="Clause">
        <w:name w:val="Clause"/><w:pPr><w:outlineLvl w:val="1"/></w:pPr>
      </w:style>
      <w:style w:type="paragraph" w:styleId="SubClause">
        <w:name w:val="Sub clause"/><w:basedOn w:val="Clause"/>
      </w:style>
      <w:style w:type="paragraph" w:styleId="Body"><w:name w:val="Body Text"/></w:style>
    </w:styles>"#;
    let doc_xml = r#"<?xml version="1.0" encoding="UTF-8"?>
    <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
      <w:body>
        <w:p><w:r><w:t>采购合同</w:t></w:r></w:p>
        <w:p><w:pPr><w:pStyle w:val="1"/></w:pPr><w:r><w:t>合同</w:t></w:r><w:r><w:t>条款</w:t></w:r></w:p>
        <w:p><w:pPr><w:pStyle w:val="Body"/></w:pPr><w:r><w:t>甲方应按期付款。</w:t></w:r></w:p>
        <w:p><w:pPr><w:pStyle w:val="SubClause"/></w:pPr><w:r><w:t>违约责任</w:t></w:r></w:p>
        <w:p><w:r><w:t>逾期支付违约金。</w:t></w:r></w:p>
        <w:tbl><w:tr><w:tc>
          <w:p><w:pPr><w:pStyle w:val="1"/></w:pPr><w:r><w:t>表头</w:t></w:r></w:p>
        </w:tc></w:tr></w:tbl>
        <w:p><w:pPr><w:outlineLvl w:val="0"/></w:pPr><w:r><w:t>附则</w:t></w:r></w:p>
        <w:p><w:pPr><w:pStyle w:val="1"/><w:outlineLvl w:val="9"/></w:pPr><w:r><w:t>本合同一式两份。</w:t></w:r></w:p>
        <w:p><w:pPr><w:pStyle w:val="1"/></w:pPr></w:p>
      </w:body>
    </w:document>"#
        .as_bytes();
    let docx = extract(
        &build_zip(&[
            ("word/styles.xml", styles_xml),
            ("word/document.xml", doc_xml),
        ]),
        "contract.docx",
        None,
    );
    assert_eq!(
        docx.plain_text,
        "采购合同\n[Section: 合同条款]\n甲方应按期付款。\n[Section: 合同条款 > 违约责任]\n\
         逾期支付违约金。\n表头\n[Section: 附则]\n本合同一式两份。\n"
    );

    // Without a style sheet only a paragraph's own outline level marks a heading.
    let unstyled = extract(
        &build_zip(&[("word/document.xml", doc_xml)]),
        "contract.docx",
        None,
    );
    assert_eq!(unstyled.plain_text.matches("[Section: ").count(), 1);
    assert!(unstyled.plain_text.contains("合同条款\n甲方应按期付款。"));

    let odt_xml = br#"<?xml version="1.0" encoding="UTF-8"?>
    <office:document-content xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0"
                             xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0">
      <office:body><office:text>
        <text:h text:outline-level="1">General</text:h>
        <text:p>Opening words.</text:p>
        <text:h text:outline-level="2">Scope</text:h>
        <text:p>What it covers.</text:p>
        <text:h text:outline-level="1">Closing</text:h>
      </office:text></office:body>
    </office:document-content>"#;
    let odt = extract(&build_zip(&[("content.xml", odt_xml)]), "notes.odt", None);
    assert_eq!(
        odt.plain_text,
        "[Section: General]\nOpening words.\n[Section: General > Scope]\nWhat it covers.\n\
         [Section: Closing]\n"
    );
}

#[test]
fn extracts_pptx_in_presentation_order_with_slide_markers_notes_and_page_spans() {
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
    assert_eq!(
        &res.plain_text[p1_start..p1_end],
        "[Slide 1]\nOpening Cover\n"
    );
    assert_eq!(pages[1]["page"], 2);
    assert_eq!(
        &res.plain_text[p2_start..p2_end],
        "[Slide 2]\nSecond Deck Page\nSpeaker cue alpha\n"
    );
    assert_eq!((p1_start, p2_end), (0, res.plain_text.len()));
    assert_eq!(res.metadata["truncated"], false);
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
    assert_eq!(ods.plain_text, "[Sheet: Ledger]\nR1\tAccount\tBalance\n");
    assert_eq!(
        ods.metadata,
        serde_json::json!({
            "sheets": ["Ledger"],
            "sheet_spans": [{
                "sheet_name": "Ledger",
                "start_byte": 0,
                "end_byte": ods.plain_text.len()
            }],
            "truncated": false
        })
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
    let s2_start = spans[1]["start_byte"].as_u64().unwrap() as usize;
    let s2_end = spans[1]["end_byte"].as_u64().unwrap() as usize;
    assert_eq!(spans[1]["sheet_name"], "Second");
    assert_eq!(
        &multi_ods.plain_text[s2_start..s2_end],
        "[Sheet: Second]\nR1\tOdsreviewneedle\n"
    );

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
    let pdf_bytes = build_pdf(&["Executive Summary", "", "p. 3", "Appendix Metrics"]);
    let res = extract(&pdf_bytes, "brief.pdf", Some("application/pdf"));
    assert_eq!(res.status, ExtractStatus::Ok);
    assert_eq!(
        res.plain_text,
        "[Page 1]\nExecutive Summary\n[Page 3]\np. 3\n[Page 4]\nAppendix Metrics\n"
    );
    assert_eq!(
        res.metadata,
        serde_json::json!({
            "page_count": 4,
            "pages": [
                { "page": 1, "start_byte": 0, "end_byte": 27 },
                { "page": 3, "start_byte": 27, "end_byte": 41 },
                { "page": 4, "start_byte": 41, "end_byte": 67 }
            ],
            "truncated": false,
            "extracted_pages": 4,
            "textless_pages": [2, 3]
        })
    );

    let blank_pdf = build_pdf(&["", ""]);
    let blank_res = extract(&blank_pdf, "scan.pdf", None);
    assert_eq!(blank_res.status, ExtractStatus::Skipped);
    assert_eq!(blank_res.error.as_deref(), Some("empty_text_layer"));

    let corrupt = extract(b"%PDF-1.7\ngarbage-not-a-valid-xref", "broken.pdf", None);
    assert_eq!(corrupt.status, ExtractStatus::Failed);
}

#[test]
fn pdf_pages_lose_invisible_characters_and_stop_at_the_page_limit() {
    assert_eq!(
        clean_page(" \u{FEFF}co\u{00AD}op\u{200B}er\u{200F}ate\u{FFFE}\u{FFFF} Ｑ4\n"),
        "cooperate Q4"
    );
    // Line-end hyphens stay as the page wrote them.
    assert_eq!(clean_page("inter-\nnational"), "inter-\nnational");

    let pages = vec!["Recurring page text"; MAX_PDF_PAGES + 1];
    let res = extract(&build_pdf(&pages), "long.pdf", None);
    assert_eq!(res.metadata["page_count"], MAX_PDF_PAGES + 1);
    assert_eq!(res.metadata["extracted_pages"], MAX_PDF_PAGES);
    assert_eq!(res.metadata["truncated"], true);
    assert!(
        res.plain_text
            .ends_with("[Page 500]\nRecurring page text\n")
    );
}

#[test]
fn ods_rows_keep_their_numbers_and_columns_across_repeats() {
    let ods_xml = br#"<?xml version="1.0" encoding="UTF-8"?>
    <office:document-content xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0"
                             xmlns:table="urn:oasis:names:tc:opendocument:xmlns:table:1.0"
                             xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0">
      <office:body><office:spreadsheet>
        <table:table table:name=" Ledger ">
          <table:table-column table:number-columns-repeated="4"/>
          <table:table-row>
            <table:table-cell><text:p>Account</text:p></table:table-cell>
            <table:table-cell table:number-columns-repeated="2"/>
            <table:table-cell><text:p>Opening</text:p><text:p>balance</text:p></table:table-cell>
            <table:table-cell table:number-columns-repeated="1020"/>
          </table:table-row>
          <table:table-row table:number-rows-repeated="3">
            <table:table-cell table:number-columns-repeated="1024"/>
          </table:table-row>
          <table:table-row table:number-rows-repeated="2">
            <table:table-cell/>
            <table:table-cell table:number-columns-repeated="2"><text:p>0</text:p></table:table-cell>
          </table:table-row>
          <table:table-row table:number-rows-repeated="1048569"/>
          <table:table-row>
            <table:covered-table-cell/>
            <table:table-cell><text:p>Last</text:p></table:table-cell>
          </table:table-row>
        </table:table>
        <table:table table:name="Filled">
          <table:table-row table:number-rows-repeated="5000">
            <table:table-cell><text:p>same</text:p></table:table-cell>
          </table:table-row>
          <table:table-row><table:table-cell><text:p>end</text:p></table:table-cell></table:table-row>
        </table:table>
      </office:spreadsheet></office:body>
    </office:document-content>"#;
    let ods = extract(&build_zip(&[("content.xml", ods_xml)]), "book.ods", None);
    let (ledger, filled) = ods.plain_text.split_once("[Sheet: Filled]\n").unwrap();
    assert_eq!(
        ledger,
        "[Sheet: Ledger]\nR1\tAccount\t\t\tOpening balance\nR5\t\t0\t0\nR6\t\t0\t0\nR1048576\t\tLast\n"
    );
    // A repeated row with text is written 1,000 times at most; the next row keeps its number.
    let rows: Vec<&str> = filled.lines().collect();
    assert_eq!(rows.len(), 1_001);
    assert_eq!(rows[999], "R1000\tsame");
    assert_eq!(rows[1_000], "R5001\tend");
    assert_eq!(ods.metadata["truncated"], false);
}
