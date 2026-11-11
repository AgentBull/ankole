use std::io::{Cursor, Read as _};
use std::sync::Arc;

use base64_simd::STANDARD as BASE64;
use image::{ImageBuffer, ImageFormat, Rgba};
use serde_json::json;
use wordcraft_doc::control::{ContentControl, ControlKind};
use wordcraft_doc::graphic::{Graphic, GraphicKind};
use wordcraft_doc::numbering::{AbstractNum, Level, Num};
use wordcraft_doc::para::{Anchor, Float, InlineObject, NoteKind, PAGE_BREAK, ShapeKind, Wrap};
use wordcraft_doc::props::{
    Align, CellProps, CharProps, Highlight, NumRef, Rgb, RowProps, TextColor, Underline, VMerge,
    VertAlign,
};
use wordcraft_doc::section::NumFormat;
use wordcraft_doc::{
    Block, Cell, Comment, CustomProp, Document, Paragraph, Part, PartKind, Revision, RevisionKind,
    Row, SectionProps, Source, StoryRef, Style, StyleKind, Table, para_block,
};

use crate::editor::Editor;
use crate::{
    ApplyError, ChangeSet, Conflict, DocField, Edit, EntryMap, Error, MAX_OP_BYTES,
    MAX_PICTURE_BYTES, MODEL_VERSION, WordDoc, apply, apply_commands, commands, create_blank,
    create_blank_with_macros, derive, export_docx, export_docx_with_checkpoint, export_pdf, find,
    init_site_fonts, inspect, open, open_with_checkpoint, render_page_png, render_page_rgba,
    to_document,
};

fn make_png_bytes(width: u32, height: u32, color: [u8; 4]) -> Vec<u8> {
    let img: ImageBuffer<Rgba<u8>, Vec<u8>> =
        ImageBuffer::from_fn(width, height, |_x, _y| Rgba(color));
    let mut out = Vec::new();
    img.write_to(&mut Cursor::new(&mut out), ImageFormat::Png)
        .expect("PNG encoding should succeed");
    out
}

fn read_content_types_xml(bytes: &[u8]) -> String {
    let mut archive = zip::ZipArchive::new(Cursor::new(bytes)).expect("valid zip archive");
    let mut ct = archive
        .by_name("[Content_Types].xml")
        .expect("[Content_Types].xml present");
    let mut xml = String::new();
    ct.read_to_string(&mut xml).expect("UTF-8 XML");
    xml
}

fn mutate_doc(doc: &WordDoc, f: impl FnOnce(&mut Document)) -> WordDoc {
    let mut raw = doc.document().clone();
    f(&mut raw);
    WordDoc::from_parts(raw, doc.is_macro_enabled(), Arc::new(Vec::new()))
}

#[test]
fn create_blank_and_docm_macro_round_trip() {
    init_site_fonts(&[]);

    let (blank, docx_bytes) = create_blank("Quarterly Plan").expect("blank docx");
    assert!(!blank.is_macro_enabled());
    assert_eq!(blank.document().core.title, "Quarterly Plan");
    let docx_ct = read_content_types_xml(&docx_bytes);
    assert!(
        !docx_ct.contains("macroEnabled"),
        "standard docx must not advertise macroEnabled content type"
    );

    let reopened = open(&docx_bytes, "[]").expect("reopen docx");
    assert!(!reopened.is_macro_enabled());
    assert_eq!(reopened.document().core.title, "Quarterly Plan");

    let (mut docm, docm_bytes) = create_blank_with_macros("Macro Workbook", true).expect("docm");
    assert!(docm.is_macro_enabled());
    let docm_ct = read_content_types_xml(&docm_bytes);
    assert!(
        docm_ct.contains("macroEnabled"),
        ".docm export must write macroEnabled main content type"
    );

    // Attach a synthetic VBA project binary via passthrough and verify round-trip preservation.
    let vba_payload = b"VBA-PROJECT-BINARY-STUB".to_vec();
    docm = mutate_doc(&docm, |raw| {
        raw.passthrough.insert(
            "word/vbaProject.bin".to_string(),
            Arc::new(vba_payload.clone()),
        );
    });
    let exported_docm = export_docx(&docm).expect("export docm with vbaProject.bin");
    let reopened_docm = open(&exported_docm, "[]").expect("reopen docm");
    assert!(reopened_docm.is_macro_enabled());
    assert_eq!(
        reopened_docm
            .document()
            .passthrough
            .get("word/vbaProject.bin")
            .map(|b| b.as_slice()),
        Some(vba_payload.as_slice())
    );
}

fn assert_pure_ooxml_zip(bytes: &[u8]) {
    let mut archive = zip::ZipArchive::new(Cursor::new(bytes)).expect("valid zip archive");
    for idx in 0..archive.len() {
        let mut entry = archive.by_index(idx).expect("zip entry");
        let name = entry.name().expect("utf8 zip entry name").into_owned();
        assert!(
            !name.to_ascii_lowercase().contains("ankole"),
            "exported OOXML archive must not contain proprietary part {name:?}"
        );
        if name.ends_with(".xml") || name.ends_with(".rels") {
            let mut xml = String::new();
            entry.read_to_string(&mut xml).expect("UTF-8 XML part");
            assert!(
                !xml.to_ascii_lowercase().contains("ankole"),
                "exported OOXML part {name:?} must not contain proprietary ankole markup"
            );
        }
    }
}

#[test]
fn compacted_docx_replays_edits_authored_before_reopen() {
    let (blank, blank_bytes) = create_blank("Stable stories").unwrap();
    assert_pure_ooxml_zip(&blank_bytes);
    let (with_header, _, _) = apply_commands(
        &blank,
        r#"[{"command":"insert.header","params":{"text":"Keep the header"}}]"#,
        "Author",
    )
    .unwrap();
    let (edited, _, _) = apply_commands(
        &with_header,
        r#"[{"command":"references.footnote","params":{"text":"Keep the footnote"}}]"#,
        "Author",
    )
    .unwrap();
    let original_parts = edited
        .document()
        .parts
        .iter()
        .map(|(id, part)| (*id, part.kind))
        .collect::<Vec<_>>();
    assert_eq!(
        original_parts,
        [(1, PartKind::Header), (2, PartKind::Footnote)]
    );
    let (bytes, checkpoint) = export_docx_with_checkpoint(&edited).unwrap();
    assert_pure_ooxml_zip(&bytes);
    let reopened = open_with_checkpoint(&bytes, "[]", checkpoint.as_deref()).unwrap();
    assert_eq!(
        reopened
            .document()
            .parts
            .iter()
            .map(|(id, part)| (*id, part.kind))
            .collect::<Vec<_>>(),
        original_parts
    );
    let after = mutate_doc(&edited, |raw| {
        raw.parts.get_mut(&1).unwrap().blocks = vec![para_block(Paragraph::with_text(
            "Queued header",
            CharProps::default(),
        ))];
    });
    let op = derive(&edited, &after).unwrap().unwrap();
    let replayed = open_with_checkpoint(
        &bytes,
        &serde_json::to_string(&vec![op]).unwrap(),
        checkpoint.as_deref(),
    )
    .unwrap();
    assert_eq!(replayed.document().parts[&1].kind, PartKind::Header);
    assert_eq!(
        replayed.document().parts[&1].blocks[0]
            .as_para()
            .unwrap()
            .text,
        "Queued header"
    );
    assert_eq!(replayed.document().parts[&2].kind, PartKind::Footnote);

    // An external desktop edit replaces the object without a checkpoint and opens cleanly.
    let external_bytes = export_docx(&replayed).unwrap();
    assert_pure_ooxml_zip(&external_bytes);
    let external_reopened = open(&external_bytes, "[]").unwrap();
    assert_eq!(
        external_reopened
            .document()
            .parts
            .values()
            .filter(|part| part.kind == PartKind::Header)
            .count(),
        1
    );
}

#[test]
fn docx_checkpoint_keeps_media_keys_and_revision_slots() {
    let (blank, _) = create_blank("Stable media and revision slots").unwrap();
    let key = "image with spaces.png";
    let png = make_png_bytes(4, 4, [20, 120, 220, 255]);
    let edited = mutate_doc(&blank, |raw| {
        let same_revision = Revision::new(RevisionKind::Insert, "Author", "2026-11-11T00:00:00Z");
        raw.revisions = vec![same_revision.clone(), same_revision];
        raw.media.insert(key.into(), Arc::new(png.clone()));
        let mut image = Paragraph::new();
        image
            .insert_object(
                0,
                InlineObject::Image {
                    media: key.into(),
                    w: 30.0,
                    h: 30.0,
                    alt: "Image".into(),
                    float: Float::default(),
                    crop: [0.0; 4],
                    fx: Default::default(),
                    ole: None,
                },
                &CharProps::default(),
            )
            .unwrap();
        let mut merged_runs = Paragraph::new();
        merged_runs
            .insert_text(
                merged_runs.len(),
                "Alpha ",
                &CharProps {
                    ins: Some(1),
                    ..Default::default()
                },
            )
            .unwrap();
        merged_runs
            .insert_text(
                merged_runs.len(),
                "Beta",
                &CharProps {
                    ins: Some(0),
                    ..Default::default()
                },
            )
            .unwrap();
        raw.body = [1, 0]
            .into_iter()
            .map(|slot| {
                para_block(Paragraph::with_text(
                    "Tracked",
                    CharProps {
                        ins: Some(slot),
                        ..Default::default()
                    },
                ))
            })
            .chain([para_block(merged_runs), para_block(image)])
            .collect();
    });
    let (bytes, checkpoint) = export_docx_with_checkpoint(&edited).unwrap();
    assert!(checkpoint.is_some());
    assert_pure_ooxml_zip(&bytes);
    let reopened = open_with_checkpoint(&bytes, "[]", checkpoint.as_deref()).unwrap();
    assert_eq!(*reopened.document().media[key], png);
    assert_eq!(reopened.document().revisions, edited.document().revisions);
    let slots: Vec<_> = reopened
        .document()
        .body
        .iter()
        .take(2)
        .map(|block| block.as_para().unwrap().runs[0].props.ins)
        .collect();
    assert_eq!(slots, [Some(1), Some(0)]);
    let intra_para_runs: Vec<_> = reopened.document().body[2]
        .as_para()
        .unwrap()
        .runs
        .iter()
        .map(|run| (run.len, run.props.ins))
        .collect();
    assert_eq!(intra_para_runs, [(6, Some(1)), (4, Some(0))]);
}

#[test]
fn editor_missing_glyph_fonts_detects_cjk_without_polluting_substituted_fonts() {
    let mut baseline = Editor::create_blank("Baseline").expect("blank editor");
    baseline.insert_text("Latin text only").unwrap();
    let baseline_subs = baseline.substituted_fonts().unwrap();

    for (sample, expected) in [
        ("Latin text only", Vec::<&str>::new()),
        ("季度工作汇报", vec!["Noto Sans SC"]),
        ("日本語のテスト", vec!["Noto Sans JP"]),
        ("분기 보고서", vec!["Noto Sans KR"]),
        ("ㄅㄆㄇㄈ", vec!["Noto Sans TC"]),
    ] {
        let mut editor = Editor::create_blank("CJK Fallback").expect("blank editor");
        editor.insert_text(sample).unwrap();
        let missing: Vec<String> =
            serde_json::from_str(&editor.missing_glyph_fonts().unwrap()).unwrap();
        assert_eq!(
            missing, expected,
            "unexpected fallback fonts for {sample:?}"
        );
        assert_eq!(
            editor.substituted_fonts().unwrap(),
            baseline_subs,
            "auto-loaded CJK glyph fallback must not add substituted-font warnings"
        );
    }
}

#[test]
fn story_ref_and_conflict_wire_representations_match_spec() {
    let body_json = serde_json::to_value(StoryRef::Body).unwrap();
    assert_eq!(body_json, json!("body"));
    let parsed_body: StoryRef = serde_json::from_value(json!("body")).unwrap();
    assert_eq!(parsed_body, StoryRef::Body);

    let part_json = serde_json::to_value(StoryRef::Part(31)).unwrap();
    assert_eq!(part_json, json!({"part": 31}));
    let parsed_part: StoryRef = serde_json::from_value(json!({"part": 31})).unwrap();
    assert_eq!(parsed_part, StoryRef::Part(31));

    assert_eq!(Conflict::BlockChanged.as_str(), "block_changed");
    assert_eq!(Conflict::ContainerDeleted.as_str(), "container_deleted");
    assert_eq!(Conflict::ContainerChanged.as_str(), "container_changed");
    assert_eq!(Conflict::FieldChanged.as_str(), "field_changed");
    assert_eq!(Conflict::IdentifierTaken.as_str(), "identifier_taken");
    assert_eq!(Conflict::ConcurrentRevision.as_str(), "concurrent_revision");
    assert_eq!(Conflict::UnbalancedMarkers.as_str(), "unbalanced_markers");
}

#[test]
fn derive_and_apply_round_trip_across_all_containers_and_fields() {
    let (base, _) = create_blank("Base Doc").unwrap();
    assert_eq!(derive(&base, &base).unwrap(), None);

    let png_bytes = make_png_bytes(4, 4, [20, 120, 220, 255]);
    let chart_bytes =
        b"<c:chartSpace xmlns:c=\"http://schemas.openxmlformats.org/drawingml/2006/chart\"/>"
            .to_vec();
    let vba_bytes = b"VBA_STREAM".to_vec();

    // Seed base with an existing part so we test both modifying an existing part and adding a new one.
    let seeded = mutate_doc(&base, |raw| {
        raw.body = vec![
            para_block(Paragraph::with_text("Keep start", CharProps::default())),
            para_block(Paragraph::with_text("Replace middle", CharProps::default())),
            para_block(Paragraph::with_text("Keep end", CharProps::default())),
        ];
        raw.parts.insert(
            10,
            Part {
                kind: PartKind::Header,
                blocks: vec![
                    para_block(Paragraph::with_text("Header static", CharProps::default())),
                    para_block(Paragraph::with_text("Header old", CharProps::default())),
                ],
                ..Default::default()
            },
        );
        raw.parts.insert(
            11,
            Part {
                kind: PartKind::Footer,
                blocks: vec![para_block(Paragraph::with_text(
                    "Remove me",
                    CharProps::default(),
                ))],
                ..Default::default()
            },
        );
    });

    let after = mutate_doc(&seeded, |raw| {
        // Modify middle block into a paragraph + table while keeping prefix and suffix Arc pointers intact.
        let mut tbl = Table::new(2, 2, 300.0);
        tbl.rows[0].props.header = true;
        tbl.rows[0].cells[0] = Cell::with_text("Col A");
        tbl.rows[0].cells[1] = Cell::with_text("Col B");
        tbl.rows[1].cells[0] = Cell::with_text("Val 1");
        tbl.rows[1].cells[1] = Cell::with_text("Val 2");
        raw.body.splice(
            1..2,
            [
                para_block(Paragraph::with_text("Updated middle", CharProps::default())),
                Arc::new(Block::Table(tbl)),
            ],
        );

        // Update part 10, delete part 11, add footnote part 31.
        let header = raw.parts.get_mut(&10).unwrap();
        header.blocks[1] = para_block(Paragraph::with_text("Header new", CharProps::default()));
        raw.parts.remove(&11);
        raw.parts.insert(
            31,
            Part {
                kind: PartKind::Footnote,
                blocks: vec![para_block(Paragraph::with_text(
                    "Footnote text",
                    CharProps::default(),
                ))],
                ..Default::default()
            },
        );

        // Add comment, media, passthrough, revisions, styles, numbering, core, settings, sources, custom_props.
        raw.comments.insert(
            1,
            Comment {
                author: "Alice".into(),
                initials: "A".into(),
                date: "2026-11-11T00:00:00Z".into(),
                parent: None,
                resolved: false,
                part: 31,
                durable_id: None,
                date_utc: None,
            },
        );
        raw.media
            .insert("image1.png".into(), Arc::new(png_bytes.clone()));
        raw.passthrough
            .insert("word/vbaProject.bin".into(), Arc::new(vba_bytes.clone()));
        raw.passthrough.insert(
            "word/charts/chart1.xml".into(),
            Arc::new(chart_bytes.clone()),
        );
        raw.revisions.push(Revision {
            kind: RevisionKind::Insert,
            author: "Alice".into(),
            date: "2026-11-11T00:00:00Z".into(),
            move_name: None,
        });

        Arc::make_mut(&mut raw.styles).styles.push(Style {
            id: "CustomCallout".into(),
            name: "Custom Callout".into(),
            kind: StyleKind::Paragraph,
            ..Default::default()
        });
        Arc::make_mut(&mut raw.numbering).nums.push(Num {
            id: 7,
            abstract_id: 0,
            start_overrides: vec![(0, 1)],
            level_overrides: Vec::new(),
        });
        raw.core.title = "Edited Title".into();
        raw.settings.track_changes = true;
        raw.last_section.landscape = true;
        raw.sources.push(Source {
            tag: "Knuth84".into(),
            kind: "Book".into(),
            title: "Literate Programming".into(),
            ..Default::default()
        });
        raw.custom_props.push(CustomProp {
            name: "Department".into(),
            kind: "lpwstr".into(),
            value: "Engineering".into(),
            ..Default::default()
        });
    });

    let cs = derive(&seeded, &after)
        .expect("derive succeeds")
        .expect("non-empty changeset");
    assert!(cs.carries_media());
    let cs_json = serde_json::to_string(&cs).unwrap();

    let applied = apply(&seeded, &cs_json, "[]", None).expect("apply derived changeset");
    assert!(applied.carries_media);
    assert_eq!(applied.doc.document(), after.document());
    assert!(applied.doc.is_macro_enabled());

    // Also test full-list replacement of revisions (e.g. accept-all clearing revisions).
    let cleared_revisions = mutate_doc(&applied.doc, |raw| {
        raw.revisions.clear();
    });
    let clear_cs = derive(&applied.doc, &cleared_revisions)
        .unwrap()
        .expect("clearing revisions emits field.set");
    assert!(clear_cs.edits.iter().any(|e| matches!(
        e,
        Edit::FieldSet {
            field: DocField::Revisions,
            ..
        }
    )));
    let reapplied = apply(
        &applied.doc,
        &serde_json::to_string(&clear_cs).unwrap(),
        "[]",
        None,
    )
    .unwrap();
    assert_eq!(reapplied.doc.document(), cleared_revisions.document());
}

#[test]
fn disjoint_block_splices_commute_with_index_shifting() {
    let (blank, _) = create_blank("Commute").unwrap();
    let base = mutate_doc(&blank, |raw| {
        raw.body = vec![
            para_block(Paragraph::with_text("P0", CharProps::default())),
            para_block(Paragraph::with_text("P1", CharProps::default())),
            para_block(Paragraph::with_text("P2", CharProps::default())),
            para_block(Paragraph::with_text("P3", CharProps::default())),
        ];
    });

    // Op A replaces P0 with two paragraphs [P0a, P0b] (net +1 block before P2).
    let after_a = mutate_doc(&base, |raw| {
        raw.body.splice(
            0..1,
            [
                para_block(Paragraph::with_text("P0a", CharProps::default())),
                para_block(Paragraph::with_text("P0b", CharProps::default())),
            ],
        );
    });
    // Op B replaces P2..=P3 with one paragraph [P2_merged] (net -1 block after P0).
    let after_b = mutate_doc(&base, |raw| {
        raw.body.splice(
            2..4,
            [para_block(Paragraph::with_text(
                "P2_merged",
                CharProps::default(),
            ))],
        );
    });

    let op_a = serde_json::to_string(&derive(&base, &after_a).unwrap().unwrap()).unwrap();
    let op_b = serde_json::to_string(&derive(&base, &after_b).unwrap().unwrap()).unwrap();

    // Order 1: A commits first, then B rebases over [A].
    let step_a = apply(&base, &op_a, "[]", None).unwrap();
    let a_then_b = apply(
        &step_a.doc,
        &op_b,
        &serde_json::to_string(&vec![&step_a.op]).unwrap(),
        None,
    )
    .unwrap();

    // Order 2: B commits first, then A rebases over [B].
    let step_b = apply(&base, &op_b, "[]", None).unwrap();
    let b_then_a = apply(
        &step_b.doc,
        &op_a,
        &serde_json::to_string(&vec![&step_b.op]).unwrap(),
        None,
    )
    .unwrap();

    assert_eq!(a_then_b.doc.document(), b_then_a.doc.document());
    let texts: Vec<String> = a_then_b
        .doc
        .document()
        .body
        .iter()
        .map(|b| match b.as_ref() {
            Block::Para(p) => p.plain_text(),
            Block::Table(_) => "<table/>".into(),
        })
        .collect();
    assert_eq!(texts, vec!["P0a", "P0b", "P1", "P2_merged"]);
}

#[test]
fn conflict_and_limit_rules_reject_ambiguous_or_invalid_operations() {
    let (blank, _) = create_blank("Conflicts").unwrap();
    let base = mutate_doc(&blank, |raw| {
        raw.body = vec![
            para_block(Paragraph::with_text("B0", CharProps::default())),
            para_block(Paragraph::with_text("B1", CharProps::default())),
            para_block(Paragraph::with_text("B2", CharProps::default())),
            para_block(Paragraph::with_text("B3", CharProps::default())),
        ];
        raw.parts.insert(
            20,
            Part {
                kind: PartKind::Header,
                blocks: vec![para_block(Paragraph::with_text("H0", CharProps::default()))],
                ..Default::default()
            },
        );
    });

    // 1a. Overlapping modification of the same block -> block_changed.
    let edit_b1_v1 = serde_json::to_string(&ChangeSet {
        model_version: MODEL_VERSION,
        edits: vec![Edit::BlocksSplice {
            story: StoryRef::Body,
            at: 1,
            delete: 1,
            insert: vec![Block::Para(Paragraph::with_text(
                "V1",
                CharProps::default(),
            ))],
        }],
    })
    .unwrap();
    let edit_b1_v2 = serde_json::to_string(&ChangeSet {
        model_version: MODEL_VERSION,
        edits: vec![Edit::BlocksSplice {
            story: StoryRef::Body,
            at: 1,
            delete: 1,
            insert: vec![Block::Para(Paragraph::with_text(
                "V2",
                CharProps::default(),
            ))],
        }],
    })
    .unwrap();
    let committed_v1 = apply(&base, &edit_b1_v1, "[]", None).unwrap();
    let prior_v1 = serde_json::to_string(&vec![&committed_v1.op]).unwrap();
    assert_eq!(
        apply(&committed_v1.doc, &edit_b1_v2, &prior_v1, None),
        Err(ApplyError::Conflict(Conflict::BlockChanged))
    );

    // 1b. Two pure insertions at the exact same `at` -> block_changed.
    let ins_at_1_a = serde_json::to_string(&ChangeSet {
        model_version: MODEL_VERSION,
        edits: vec![Edit::BlocksSplice {
            story: StoryRef::Body,
            at: 1,
            delete: 0,
            insert: vec![Block::Para(Paragraph::with_text(
                "IA",
                CharProps::default(),
            ))],
        }],
    })
    .unwrap();
    let ins_at_1_b = serde_json::to_string(&ChangeSet {
        model_version: MODEL_VERSION,
        edits: vec![Edit::BlocksSplice {
            story: StoryRef::Body,
            at: 1,
            delete: 0,
            insert: vec![Block::Para(Paragraph::with_text(
                "IB",
                CharProps::default(),
            ))],
        }],
    })
    .unwrap();
    let committed_ins = apply(&base, &ins_at_1_a, "[]", None).unwrap();
    let prior_ins = serde_json::to_string(&vec![&committed_ins.op]).unwrap();
    assert_eq!(
        apply(&committed_ins.doc, &ins_at_1_b, &prior_ins, None),
        Err(ApplyError::Conflict(Conflict::BlockChanged))
    );

    // 1c. Inserting strictly inside a deleted span (prior deletes 1..3, incoming inserts at 2) -> block_changed,
    // and symmetric case (prior inserts at 2, incoming deletes 1..3 across insertion point) -> block_changed.
    let del_span = serde_json::to_string(&ChangeSet {
        model_version: MODEL_VERSION,
        edits: vec![Edit::BlocksSplice {
            story: StoryRef::Body,
            at: 1,
            delete: 2,
            insert: Vec::new(),
        }],
    })
    .unwrap();
    let ins_inside = serde_json::to_string(&ChangeSet {
        model_version: MODEL_VERSION,
        edits: vec![Edit::BlocksSplice {
            story: StoryRef::Body,
            at: 2,
            delete: 0,
            insert: vec![Block::Para(Paragraph::with_text(
                "Mid",
                CharProps::default(),
            ))],
        }],
    })
    .unwrap();
    let c_del = apply(&base, &del_span, "[]", None).unwrap();
    assert_eq!(
        apply(
            &c_del.doc,
            &ins_inside,
            &serde_json::to_string(&vec![&c_del.op]).unwrap(),
            None
        ),
        Err(ApplyError::Conflict(Conflict::BlockChanged))
    );
    let c_ins = apply(&base, &ins_inside, "[]", None).unwrap();
    assert_eq!(
        apply(
            &c_ins.doc,
            &del_span,
            &serde_json::to_string(&vec![&c_ins.op]).unwrap(),
            None
        ),
        Err(ApplyError::Conflict(Conflict::BlockChanged))
    );

    // 2. Splicing a deleted or replaced part -> container_deleted / container_changed.
    let delete_part_20 = serde_json::to_string(&ChangeSet {
        model_version: MODEL_VERSION,
        edits: vec![Edit::EntryDelete {
            map: EntryMap::Parts,
            key: "20".into(),
        }],
    })
    .unwrap();
    let splice_part_20 = serde_json::to_string(&ChangeSet {
        model_version: MODEL_VERSION,
        edits: vec![Edit::BlocksSplice {
            story: StoryRef::Part(20),
            at: 0,
            delete: 1,
            insert: vec![Block::Para(Paragraph::with_text(
                "H1",
                CharProps::default(),
            ))],
        }],
    })
    .unwrap();
    let c_del_part = apply(&base, &delete_part_20, "[]", None).unwrap();
    assert_eq!(
        apply(
            &c_del_part.doc,
            &splice_part_20,
            &serde_json::to_string(&vec![&c_del_part.op]).unwrap(),
            None
        ),
        Err(ApplyError::Conflict(Conflict::ContainerDeleted))
    );

    // Reverse order: prior spliced part 20, incoming deletes or replaces part 20 -> container_changed.
    let c_splice_part = apply(&base, &splice_part_20, "[]", None).unwrap();
    assert_eq!(
        apply(
            &c_splice_part.doc,
            &delete_part_20,
            &serde_json::to_string(&vec![&c_splice_part.op]).unwrap(),
            None
        ),
        Err(ApplyError::Conflict(Conflict::ContainerChanged))
    );

    let put_part_20 = serde_json::to_string(&ChangeSet {
        model_version: MODEL_VERSION,
        edits: vec![Edit::EntryPut {
            map: EntryMap::Parts,
            key: "20".into(),
            value: serde_json::to_value(Part {
                kind: PartKind::Header,
                blocks: vec![para_block(Paragraph::with_text(
                    "Replaced",
                    CharProps::default(),
                ))],
                ..Default::default()
            })
            .unwrap(),
        }],
    })
    .unwrap();
    let c_put_part = apply(&base, &put_part_20, "[]", None).unwrap();
    assert_eq!(
        apply(
            &c_put_part.doc,
            &splice_part_20,
            &serde_json::to_string(&vec![&c_put_part.op]).unwrap(),
            None
        ),
        Err(ApplyError::Conflict(Conflict::ContainerChanged))
    );

    // 3. Same-key entry.put -> identifier_taken.
    let put_media_a = serde_json::to_string(&ChangeSet {
        model_version: MODEL_VERSION,
        edits: vec![Edit::EntryPut {
            map: EntryMap::Media,
            key: "pic1.png".into(),
            value: json!(BASE64.encode_to_string(b"abc")),
        }],
    })
    .unwrap();
    let c_media = apply(&base, &put_media_a, "[]", None).unwrap();
    assert_eq!(
        apply(
            &c_media.doc,
            &put_media_a,
            &serde_json::to_string(&vec![&c_media.op]).unwrap(),
            None
        ),
        Err(ApplyError::Conflict(Conflict::IdentifierTaken))
    );

    // 4. Concurrent revisions.append -> concurrent_revision.
    let rev_append = serde_json::to_string(&ChangeSet {
        model_version: MODEL_VERSION,
        edits: vec![Edit::RevisionsAppend {
            from: 0,
            items: vec![Revision {
                kind: RevisionKind::Insert,
                author: "Client".into(),
                date: String::new(),
                move_name: None,
            }],
        }],
    })
    .unwrap();
    let c_rev = apply(&base, &rev_append, "[]", Some("Bob")).unwrap();
    assert_eq!(
        apply(
            &c_rev.doc,
            &rev_append,
            &serde_json::to_string(&vec![&c_rev.op]).unwrap(),
            Some("Carol")
        ),
        Err(ApplyError::Conflict(Conflict::ConcurrentRevision))
    );

    // 5. Same field.set -> field_changed.
    let set_core_a = serde_json::to_string(&ChangeSet {
        model_version: MODEL_VERSION,
        edits: vec![Edit::FieldSet {
            field: DocField::Core,
            value: serde_json::to_value(wordcraft_doc::CoreProps {
                title: "Title A".into(),
                ..Default::default()
            })
            .unwrap(),
        }],
    })
    .unwrap();
    let set_core_b = serde_json::to_string(&ChangeSet {
        model_version: MODEL_VERSION,
        edits: vec![Edit::FieldSet {
            field: DocField::Core,
            value: serde_json::to_value(wordcraft_doc::CoreProps {
                title: "Title B".into(),
                ..Default::default()
            })
            .unwrap(),
        }],
    })
    .unwrap();
    let c_core = apply(&base, &set_core_a, "[]", None).unwrap();
    assert_eq!(
        apply(
            &c_core.doc,
            &set_core_b,
            &serde_json::to_string(&vec![&c_core.op]).unwrap(),
            None
        ),
        Err(ApplyError::Conflict(Conflict::FieldChanged))
    );

    // 5b. Concurrent `numbering` edits allocating colliding list IDs -> field_changed.
    let mut num_doc = (*base.document().numbering).clone();
    num_doc.nums.push(Num {
        id: 99,
        abstract_id: 0,
        start_overrides: Vec::new(),
        level_overrides: Vec::new(),
    });
    let set_numbering = serde_json::to_string(&ChangeSet {
        model_version: MODEL_VERSION,
        edits: vec![Edit::FieldSet {
            field: DocField::Numbering,
            value: serde_json::to_value(num_doc).unwrap(),
        }],
    })
    .unwrap();
    let c_num = apply(&base, &set_numbering, "[]", None).unwrap();
    assert_eq!(
        apply(
            &c_num.doc,
            &set_numbering,
            &serde_json::to_string(&vec![&c_num.op]).unwrap(),
            None
        ),
        Err(ApplyError::Conflict(Conflict::FieldChanged))
    );

    // 6. Future model_version -> ApplyError::FutureVersion.
    let future_json = json!({
        "model_version": 2,
        "edits": []
    })
    .to_string();
    assert_eq!(
        apply(&base, &future_json, "[]", None),
        Err(ApplyError::FutureVersion {
            found: 2,
            supported: MODEL_VERSION
        })
    );

    // 7. Oversized > 4 MiB operation -> ApplyError::Error(Error::Invalid(_)).
    let huge = format!(
        "{{\"model_version\":1,\"edits\":[],\"pad\":\"{}\"}}",
        "x".repeat(MAX_OP_BYTES + 32)
    );
    assert!(matches!(
        apply(&base, &huge, "[]", None),
        Err(ApplyError::Error(Error::Invalid(_)))
    ));

    // 8. Oversized > 2 MiB picture in media -> ApplyError::Error(Error::Invalid(_)).
    let big_pic = vec![7u8; MAX_PICTURE_BYTES + 16];
    let big_media_op = serde_json::to_string(&ChangeSet {
        model_version: MODEL_VERSION,
        edits: vec![Edit::EntryPut {
            map: EntryMap::Media,
            key: "huge.bin".into(),
            value: json!(BASE64.encode_to_string(&big_pic)),
        }],
    })
    .unwrap();
    assert!(matches!(
        apply(&base, &big_media_op, "[]", None),
        Err(ApplyError::Error(Error::Invalid(_)))
    ));
}

#[test]
fn post_rebase_marker_balance_rejects_broken_cross_paragraph_pairs() {
    let (blank, _) = create_blank("Markers").unwrap();

    // Build a 3-paragraph story with a cross-paragraph bookmark ("bm1"), comment (7),
    // field (FieldStart..FieldEnd), content control, and permission range (9).
    let make_marker_para = |obj: InlineObject| {
        let mut p = Paragraph::new();
        p.insert_object(0, obj, &CharProps::default()).unwrap();
        p
    };

    let balanced_doc = mutate_doc(&blank, |raw| {
        let mut p0 = Paragraph::new();
        p0.insert_object(
            0,
            InlineObject::BookmarkStart { name: "bm1".into() },
            &CharProps::default(),
        )
        .unwrap();
        p0.insert_object(
            p0.len(),
            InlineObject::CommentStart { id: 7 },
            &CharProps::default(),
        )
        .unwrap();
        p0.insert_object(
            p0.len(),
            InlineObject::FieldStart {
                instr: "TOC".into(),
                locked: false,
                dirty: false,
            },
            &CharProps::default(),
        )
        .unwrap();
        p0.insert_object(
            p0.len(),
            InlineObject::ControlStart {
                control: Box::new(ContentControl {
                    kind: ControlKind::RichText,
                    ..Default::default()
                }),
            },
            &CharProps::default(),
        )
        .unwrap();
        p0.insert_object(
            p0.len(),
            InlineObject::PermStart {
                id: 9,
                group: "everyone".into(),
                editor: String::new(),
            },
            &CharProps::default(),
        )
        .unwrap();

        let p1 = Paragraph::with_text("Middle spanned text", CharProps::default());

        let mut p2 = Paragraph::new();
        p2.insert_object(0, InlineObject::PermEnd { id: 9 }, &CharProps::default())
            .unwrap();
        p2.insert_object(p2.len(), InlineObject::ControlEnd, &CharProps::default())
            .unwrap();
        p2.insert_object(p2.len(), InlineObject::FieldEnd, &CharProps::default())
            .unwrap();
        p2.insert_object(
            p2.len(),
            InlineObject::CommentEnd { id: 7 },
            &CharProps::default(),
        )
        .unwrap();
        p2.insert_object(
            p2.len(),
            InlineObject::BookmarkEnd { name: "bm1".into() },
            &CharProps::default(),
        )
        .unwrap();

        raw.body = vec![para_block(p0), para_block(p1), para_block(p2)];
    });

    // Deleting p2 alone breaks all five cross-paragraph marker pairs -> unbalanced_markers.
    let drop_end = serde_json::to_string(&ChangeSet {
        model_version: MODEL_VERSION,
        edits: vec![Edit::BlocksSplice {
            story: StoryRef::Body,
            at: 2,
            delete: 1,
            insert: Vec::new(),
        }],
    })
    .unwrap();
    assert_eq!(
        apply(&balanced_doc, &drop_end, "[]", None),
        Err(ApplyError::Conflict(Conflict::UnbalancedMarkers))
    );

    // Also test each individual marker kind alone so every pairing rule is verified independently.
    for orphan in [
        InlineObject::FieldStart {
            instr: "DATE".into(),
            locked: false,
            dirty: false,
        },
        InlineObject::FieldEnd,
        InlineObject::ControlStart {
            control: Box::new(ContentControl::default()),
        },
        InlineObject::ControlEnd,
        InlineObject::CommentStart { id: 42 },
        InlineObject::CommentEnd { id: 42 },
        InlineObject::BookmarkStart { name: "x".into() },
        InlineObject::BookmarkEnd { name: "x".into() },
        InlineObject::PermStart {
            id: 3,
            group: "everyone".into(),
            editor: String::new(),
        },
        InlineObject::PermEnd { id: 3 },
    ] {
        let bad_insert = serde_json::to_string(&ChangeSet {
            model_version: MODEL_VERSION,
            edits: vec![Edit::BlocksSplice {
                story: StoryRef::Body,
                at: 1,
                delete: 0,
                insert: vec![Block::Para(make_marker_para(orphan))],
            }],
        })
        .unwrap();
        assert_eq!(
            apply(&balanced_doc, &bad_insert, "[]", None),
            Err(ApplyError::Conflict(Conflict::UnbalancedMarkers))
        );
    }
}

#[test]
fn server_stamps_authenticated_author_on_new_comments_and_revisions() {
    let (base, _) = create_blank("Author Stamp").unwrap();

    let incoming = ChangeSet {
        model_version: MODEL_VERSION,
        edits: vec![
            Edit::EntryPut {
                map: EntryMap::Parts,
                key: "50".into(),
                value: serde_json::to_value(Part {
                    kind: PartKind::Comment,
                    blocks: vec![para_block(Paragraph::with_text(
                        "Looks good!",
                        CharProps::default(),
                    ))],
                    ..Default::default()
                })
                .unwrap(),
            },
            Edit::EntryPut {
                map: EntryMap::Comments,
                key: "1".into(),
                value: serde_json::to_value(Comment {
                    author: "Spoofed Client".into(),
                    initials: "SC".into(),
                    date: "2026-11-11T12:00:00Z".into(),
                    parent: None,
                    resolved: false,
                    part: 50,
                    durable_id: None,
                    date_utc: Some("2026-11-11T12:00:00Z".into()),
                })
                .unwrap(),
            },
            Edit::RevisionsAppend {
                from: 0,
                items: vec![Revision {
                    kind: RevisionKind::Insert,
                    author: "Spoofed Client".into(),
                    date: "2026-11-11T12:00:00Z".into(),
                    move_name: None,
                }],
            },
        ],
    };

    let applied = apply(
        &base,
        &serde_json::to_string(&incoming).unwrap(),
        "[]",
        Some("Grace Hopper"),
    )
    .expect("apply with actor stamping");

    let doc_comment = applied.doc.document().comments.get(&1).unwrap();
    assert_eq!(doc_comment.author, "Grace Hopper");
    assert_eq!(doc_comment.initials, "GH");
    assert_eq!(applied.doc.document().revisions[0].author, "Grace Hopper");

    // Verify `applied.op` (stored in pod_office_ops) also carries the stamped author!
    let mut saw_stamped_comment = false;
    let mut saw_stamped_revision = false;
    for edit in &applied.op.edits {
        match edit {
            Edit::EntryPut {
                map: EntryMap::Comments,
                value,
                ..
            } => {
                let c: Comment = serde_json::from_value(value.clone()).unwrap();
                assert_eq!(c.author, "Grace Hopper");
                assert_eq!(c.initials, "GH");
                saw_stamped_comment = true;
            }
            Edit::RevisionsAppend { items, .. } => {
                assert_eq!(items[0].author, "Grace Hopper");
                saw_stamped_revision = true;
            }
            _ => {}
        }
    }
    assert!(saw_stamped_comment && saw_stamped_revision);
}

#[test]
fn to_document_converts_all_mapping_table_features_and_counts_omitted_and_downgraded() {
    let (blank, _) = create_blank("Rich Spec").unwrap();
    let png = make_png_bytes(10, 10, [255, 64, 64, 255]);

    let rich = mutate_doc(&blank, |raw| {
        // Media: two keys with identical PNG bytes to test SHA-256 deduplication and filename sanitization.
        raw.media
            .insert("../unsafe name/pic.png".into(), Arc::new(png.clone()));
        raw.media
            .insert("duplicate_copy.png".into(), Arc::new(png.clone()));

        // Numbering: list 1 = unordered bullet, list 2 = ordered starting at 1, list 3 = ordered starting at 3.
        let mut numbering = (*raw.numbering).clone();
        numbering.abstracts.push(AbstractNum {
            id: 100,
            levels: vec![
                Level {
                    start: 1,
                    format: NumFormat::Bullet,
                    text: "\u{2022}".into(),
                    ..Default::default()
                },
                Level {
                    start: 1,
                    format: NumFormat::Bullet,
                    text: "o".into(),
                    ..Default::default()
                },
            ],
            ..Default::default()
        });
        numbering.abstracts.push(AbstractNum {
            id: 101,
            levels: vec![Level {
                start: 1,
                format: NumFormat::Decimal,
                text: "%1.".into(),
                ..Default::default()
            }],
            ..Default::default()
        });
        numbering.nums.push(Num {
            id: 1,
            abstract_id: 100,
            start_overrides: Vec::new(),
            level_overrides: Vec::new(),
        });
        numbering.nums.push(Num {
            id: 2,
            abstract_id: 101,
            start_overrides: Vec::new(),
            level_overrides: Vec::new(),
        });
        numbering.nums.push(Num {
            id: 3,
            abstract_id: 101,
            start_overrides: vec![(0, 3)],
            level_overrides: Vec::new(),
        });
        raw.numbering = Arc::new(numbering);

        // Secondary parts: 1 header (omitted), 1 footnote (#40), 1 endnote (#41), 1 comment (#1, omitted).
        raw.parts.insert(
            30,
            Part {
                kind: PartKind::Header,
                blocks: vec![para_block(Paragraph::with_text(
                    "Running Header",
                    CharProps::default(),
                ))],
                ..Default::default()
            },
        );
        raw.parts.insert(
            40,
            Part {
                kind: PartKind::Footnote,
                blocks: vec![para_block(Paragraph::with_text(
                    "First footnote body",
                    CharProps::default(),
                ))],
                ..Default::default()
            },
        );
        raw.parts.insert(
            41,
            Part {
                kind: PartKind::Endnote,
                blocks: vec![para_block(Paragraph::with_text(
                    "First endnote body",
                    CharProps::default(),
                ))],
                ..Default::default()
            },
        );
        raw.parts.insert(
            42,
            Part {
                kind: PartKind::Comment,
                blocks: vec![para_block(Paragraph::with_text(
                    "Margin comment",
                    CharProps::default(),
                ))],
                ..Default::default()
            },
        );
        raw.comments.insert(
            1,
            Comment {
                author: "Reviewer".into(),
                initials: "R".into(),
                date: String::new(),
                parent: None,
                resolved: false,
                part: 42,
                durable_id: None,
                date_utc: None,
            },
        );

        // Revisions: 0 = Insert, 1 = Delete.
        raw.revisions.push(Revision {
            kind: RevisionKind::Insert,
            author: "A".into(),
            date: String::new(),
            move_name: None,
        });
        raw.revisions.push(Revision {
            kind: RevisionKind::Delete,
            author: "A".into(),
            date: String::new(),
            move_name: None,
        });

        let mut body: Vec<Arc<Block>> = Vec::new();

        // 1. Headings h1..h6 with alignment & indent.
        let mut h1 = Paragraph::with_text("Main Heading", CharProps::default()).styled("Heading1");
        h1.props.align = Some(Align::Center);
        body.push(para_block(h1));

        let mut h3 = Paragraph::with_text("Sub Heading", CharProps::default());
        h3.props.outline_level = Some(2); // 0-based -> h3
        h3.props.indent_left = Some(72.0); // 72pt / 36pt = indent="2"
        body.push(para_block(h3));

        // 2. Paragraph with inline marks, colors, highlights, safe/unsafe links, code run, tracked changes, and note refs.
        let mut p_marks = Paragraph::new();
        p_marks
            .insert_text(
                p_marks.len(),
                "Bold",
                &CharProps {
                    bold: Some(true),
                    ..Default::default()
                },
            )
            .unwrap();
        p_marks
            .insert_text(
                p_marks.len(),
                "Italic",
                &CharProps {
                    italic: Some(true),
                    ..Default::default()
                },
            )
            .unwrap();
        p_marks
            .insert_text(
                p_marks.len(),
                "Under",
                &CharProps {
                    underline: Some(Underline::Single),
                    ..Default::default()
                },
            )
            .unwrap();
        p_marks
            .insert_text(
                p_marks.len(),
                "Strike",
                &CharProps {
                    double_strike: Some(true),
                    ..Default::default()
                },
            )
            .unwrap();
        p_marks
            .insert_text(
                p_marks.len(),
                "a < b & bold_ignored",
                &CharProps {
                    font: Some("Consolas".into()),
                    bold: Some(true),
                    ..Default::default()
                },
            )
            .unwrap();
        p_marks
            .insert_text(
                p_marks.len(),
                "Sup",
                &CharProps {
                    vert_align: Some(VertAlign::Superscript),
                    ..Default::default()
                },
            )
            .unwrap();
        p_marks
            .insert_text(
                p_marks.len(),
                "Sub",
                &CharProps {
                    vert_align: Some(VertAlign::Subscript),
                    ..Default::default()
                },
            )
            .unwrap();
        p_marks
            .insert_text(
                p_marks.len(),
                "Marked",
                &CharProps {
                    highlight: Some(Highlight::Yellow),
                    ..Default::default()
                },
            )
            .unwrap();
        p_marks
            .insert_text(
                p_marks.len(),
                "Colored",
                &CharProps {
                    color: Some(TextColor::Rgb(Rgb(0x11, 0x22, 0x33))),
                    shading: Some(Rgb(0xAA, 0xBB, 0xCC)),
                    ..Default::default()
                },
            )
            .unwrap();
        p_marks
            .insert_text(
                p_marks.len(),
                "SafeLink",
                &CharProps {
                    link: Some("https://example.com/docs?a=1&b=2".into()),
                    ..Default::default()
                },
            )
            .unwrap();
        p_marks
            .insert_text(
                p_marks.len(),
                "UnsafeJs",
                &CharProps {
                    link: Some("javascript:alert(1)".into()),
                    ..Default::default()
                },
            )
            .unwrap();
        p_marks
            .insert_text(
                p_marks.len(),
                "AcceptedIns",
                &CharProps {
                    ins: Some(0),
                    ..Default::default()
                },
            )
            .unwrap();
        p_marks
            .insert_text(
                p_marks.len(),
                "DroppedDel",
                &CharProps {
                    del: Some(1),
                    ..Default::default()
                },
            )
            .unwrap();
        p_marks
            .insert_object(
                p_marks.len(),
                InlineObject::NoteRef {
                    kind: NoteKind::Footnote,
                    id: 40,
                    custom: String::new(),
                },
                &CharProps::default(),
            )
            .unwrap();
        p_marks
            .insert_object(
                p_marks.len(),
                InlineObject::NoteRef {
                    kind: NoteKind::Endnote,
                    id: 41,
                    custom: String::new(),
                },
                &CharProps::default(),
            )
            .unwrap();
        body.push(para_block(p_marks));

        // 3. Nested bullet list (level 0 -> level 1) + ordered list starting at 3.
        let mut li0 = Paragraph::with_text("Bullet parent", CharProps::default());
        li0.props.numbering = Some(NumRef { num: 1, level: 0 });
        let mut li1 = Paragraph::with_text("Bullet child", CharProps::default());
        li1.props.numbering = Some(NumRef { num: 1, level: 1 });
        let mut ol_item = Paragraph::with_text("Third step", CharProps::default());
        ol_item.props.numbering = Some(NumRef { num: 3, level: 0 });
        body.push(para_block(li0));
        body.push(para_block(li1));
        body.push(para_block(ol_item));

        // 4. Table with widths, header row (`<th>`), horizontal span (`colspan="2"`), vertical merge
        // (`rowspan="2"` with `VMerge::Continue` shadow cell omitted!), and cell `background`.
        let tbl = Table {
            grid: vec![90.0, 150.0, 120.0],
            rows: vec![
                Row {
                    props: RowProps {
                        header: true,
                        ..Default::default()
                    },
                    cells: vec![
                        Cell {
                            props: CellProps {
                                span: 2,
                                shading: Some(Rgb(0xEE, 0xF2, 0xFF)),
                                ..Default::default()
                            },
                            blocks: vec![para_block(Paragraph::with_text(
                                "Merged Header",
                                CharProps::default(),
                            ))],
                            controls: Default::default(),
                        },
                        Cell::with_text("H3"),
                    ],
                    controls: Default::default(),
                },
                Row {
                    props: RowProps::default(),
                    cells: vec![
                        Cell {
                            props: CellProps {
                                span: 1,
                                vmerge: VMerge::Restart,
                                ..Default::default()
                            },
                            blocks: vec![para_block(Paragraph::with_text(
                                "Tall Cell",
                                CharProps::default(),
                            ))],
                            controls: Default::default(),
                        },
                        Cell::with_text("R1C2"),
                        Cell::with_text("R1C3"),
                    ],
                    controls: Default::default(),
                },
                Row {
                    props: RowProps::default(),
                    cells: vec![
                        Cell {
                            props: CellProps {
                                span: 1,
                                vmerge: VMerge::Continue,
                                ..Default::default()
                            },
                            blocks: vec![para_block(Paragraph::with_text(
                                "ShadowIgnored",
                                CharProps::default(),
                            ))],
                            controls: Default::default(),
                        },
                        Cell::with_text("R2C2"),
                        Cell::with_text("R2C3"),
                    ],
                    controls: Default::default(),
                },
            ],
            ..Default::default()
        };
        body.push(Arc::new(Block::Table(tbl)));

        // 5. Standalone picture paragraph (<media />) with custom display size (120x80 pt vs 10x10 px).
        let mut p_media = Paragraph::new();
        p_media
            .insert_object(
                0,
                InlineObject::Image {
                    media: "../unsafe name/pic.png".into(),
                    w: 120.0,
                    h: 80.0,
                    alt: "Diagram".into(),
                    float: Float::default(),
                    crop: [0.0; 4],
                    fx: Default::default(),
                    ole: None,
                },
                &CharProps::default(),
            )
            .unwrap();
        body.push(para_block(p_media));

        // 6. Inline image + inline equation inside text paragraph.
        let mut p_inline = Paragraph::with_text("See icon ", CharProps::default());
        p_inline
            .insert_object(
                p_inline.len(),
                InlineObject::Image {
                    media: "duplicate_copy.png".into(),
                    w: 7.5, // 10px * 0.75 = 7.5pt natural size -> not custom-sized
                    h: 7.5,
                    alt: String::new(),
                    float: Float::default(),
                    crop: [0.0; 4],
                    fx: Default::default(),
                    ole: None,
                },
                &CharProps::default(),
            )
            .unwrap();
        p_inline
            .insert_text(p_inline.len(), " and formula ", &CharProps::default())
            .unwrap();
        p_inline
            .insert_object(
                p_inline.len(),
                InlineObject::Equation {
                    linear: "x^2+1".into(),
                    display: false,
                    math: Default::default(),
                },
                &CharProps::default(),
            )
            .unwrap();
        body.push(para_block(p_inline));

        // 7. Standalone display equation paragraph -> <math>...</math>.
        let mut p_math = Paragraph::new();
        let nodes = wordcraft_doc::math::parse_linear("a/b");
        p_math
            .insert_object(
                0,
                InlineObject::Equation {
                    linear: "a/b".into(),
                    display: true,
                    math: wordcraft_doc::math::Math {
                        nodes,
                        ..Default::default()
                    },
                },
                &CharProps::default(),
            )
            .unwrap();
        body.push(para_block(p_math));

        // 8. Omitted features: page break, section break, floating shape, chart graphic.
        let mut p_omitted =
            Paragraph::with_text(&format!("Before{PAGE_BREAK}After"), CharProps::default());
        p_omitted.props.page_break_before = Some(true);
        p_omitted.section = Some(Box::new(SectionProps::default()));
        p_omitted
            .insert_object(
                p_omitted.len(),
                InlineObject::Shape {
                    kind: ShapeKind::Rectangle,
                    w: 50.0,
                    h: 30.0,
                    fill: None,
                    stroke: None,
                    stroke_width: 1.0,
                    float: Float {
                        wrap: Wrap::Square,
                        h_rel: Anchor::Page,
                        v_rel: Anchor::Page,
                        ..Default::default()
                    },
                    story: None,
                    freeform: None,
                    effects: Default::default(),
                    extra: Default::default(),
                },
                &CharProps::default(),
            )
            .unwrap();
        p_omitted
            .insert_object(
                p_omitted.len(),
                InlineObject::Graphic {
                    w: 200.0,
                    h: 120.0,
                    alt: "Sales Chart".into(),
                    float: Float::default(),
                    graphic: Arc::new(Graphic {
                        kind: GraphicKind::Chart,
                        ..Default::default()
                    }),
                },
                &CharProps::default(),
            )
            .unwrap();
        body.push(para_block(p_omitted));

        raw.body = body;
    });

    let converted = to_document(&rich).expect("to_document succeeds");
    let xml = &converted.xml;

    assert!(xml.starts_with("<page>") && xml.ends_with("</page>"));
    assert!(xml.contains(r#"<h1 align="center">Main Heading</h1>"#));
    assert!(xml.contains(r#"<h3 indent="2">Sub Heading</h3>"#));
    assert!(xml.contains("<strong>Bold</strong>"));
    assert!(xml.contains("<em>Italic</em>"));
    assert!(xml.contains("<u>Under</u>"));
    assert!(xml.contains("<s>Strike</s>"));
    // Code span must escape `<` and `&` and MUST NOT nest `<strong>` inside `<code>`.
    assert!(xml.contains("<code>a &lt; b &amp; bold_ignored</code>"));
    assert!(xml.contains("<sup>Sup</sup>"));
    assert!(xml.contains("<sub>Sub</sub>"));
    assert!(xml.contains("<mark>Marked</mark>"));
    assert!(
        xml.contains(r#"<span style="color: #112233; background-color: #aabbcc">Colored</span>"#)
    );
    assert!(xml.contains(r#"<a href="https://example.com/docs?a=1&amp;b=2">SafeLink</a>"#));
    assert!(!xml.contains("javascript:alert"));
    assert!(xml.contains("UnsafeJs"));
    assert!(xml.contains("AcceptedIns"));
    assert!(!xml.contains("DroppedDel"));
    assert!(xml.contains("[1][2]"));

    // Nested bullet list and ordered list with start="3".
    assert!(
        xml.contains("<ul><li><p>Bullet parent</p><ul><li><p>Bullet child</p></li></ul></li></ul>")
    );
    assert!(xml.contains(r#"<ol start="3"><li><p>Third step</p></li></ol>"#));

    // Table structure: widths converted to integer px, colspan/rowspan emitted only when > 1, shadow VMerge::Continue omitted.
    assert!(xml.contains(r#"<table widths="120,200,160">"#));
    assert!(xml.contains(r##"<th colspan="2" background="#eef2ff"><p>Merged Header</p></th>"##));
    assert!(xml.contains("<th><p>H3</p></th>"));
    assert!(xml.contains(r#"<td rowspan="2"><p>Tall Cell</p></td>"#));
    assert!(!xml.contains("ShadowIgnored"));
    assert!(!xml.contains(r#"colspan="1""#));
    assert!(!xml.contains(r#"rowspan="1""#));

    // Deduplicated asset (both picture references share identical PNG bytes -> 1 ConvertedAsset).
    assert_eq!(converted.assets.len(), 1);
    let asset = &converted.assets[0];
    assert_eq!(asset.mime, "image/png");
    assert!(!asset.filename.contains('/') && !asset.filename.contains(".."));
    let expected_src = format!("ankole:asset/{}/{}", asset.sha256, asset.filename);
    assert!(xml.contains(&format!(
        r#"<media src="{expected_src}" kind="image" view="preview" mime="image/png" size="{}" title="Diagram" />"#,
        asset.bytes.len()
    )));
    assert!(xml.contains(&format!(r#"<img src="{expected_src}" />"#)));

    // Display math vs inline math.
    let expected_display_latex =
        wordcraft_doc::math_latex::to_latex(&wordcraft_doc::math::parse_linear("a/b"));
    let expected_inline_latex =
        wordcraft_doc::math_latex::to_latex(&wordcraft_doc::math::parse_linear("x^2+1"));
    assert!(xml.contains(&format!("<math>{expected_display_latex}</math>")));
    assert!(xml.contains(&format!("<code>{expected_inline_latex}</code>")));

    // Footnotes & endnotes appended at end after `<hr />`.
    assert!(xml.contains(
        "<hr /><ol><li><p>First footnote body</p></li><li><p>First endnote body</p></li></ol>"
    ));

    // Omitted & downgraded reports contain non-zero encountered counts only.
    assert_eq!(converted.report.omitted.get("headers_footers"), Some(&1));
    assert_eq!(converted.report.omitted.get("comments"), Some(&1));
    assert_eq!(converted.report.omitted.get("page_breaks"), Some(&2));
    assert_eq!(converted.report.omitted.get("section_breaks"), Some(&1));
    assert_eq!(converted.report.omitted.get("floating_shapes"), Some(&1));
    assert_eq!(converted.report.omitted.get("charts_smartart"), Some(&1));
    assert_eq!(
        converted.report.downgraded.get("custom_image_sizes"),
        Some(&1)
    );
    assert_eq!(
        converted.report.downgraded.get("inline_equations"),
        Some(&1)
    );

    // Blank document conversion produces empty report maps (zero-count keys omitted).
    let (clean_blank, _) = create_blank("Clean").unwrap();
    let clean_conv = to_document(&clean_blank).unwrap();
    assert_eq!(clean_conv.xml, "<page><p></p></page>");
    assert!(clean_conv.report.omitted.is_empty());
    assert!(clean_conv.report.downgraded.is_empty());
}

#[test]
fn agent_commands_inspect_find_render_and_pdf_work_with_confinement() {
    init_site_fonts(&[]);
    let (base, _) = create_blank("Agent Spec").unwrap();

    // 1. `commands` filters by query and never exposes blocked namespaces (`file.*`, `export.*`, `print.*`).
    let all_cmds = commands(None);
    let list = all_cmds.as_array().expect("commands returns JSON array");
    assert!(!list.is_empty());
    for entry in list {
        let id = entry["id"].as_str().unwrap_or_default();
        for forbidden in [
            "file.",
            "export.",
            "import.",
            "print.",
            "app.",
            "window.",
            "recovery.",
        ] {
            assert!(
                !id.starts_with(forbidden),
                "blocked command leaked into catalog: {id}"
            );
        }
    }
    let table_cmds = commands(Some("table"));
    assert!(!table_cmds.as_array().unwrap().is_empty());

    // 2. `apply_commands` rejects blocked commands and rolls back atomically on failed batches.
    assert!(
        apply_commands(
            &base,
            r#"[{"id":"file.open","params":{"path":"/etc/passwd"}}]"#,
            "Agent"
        )
        .is_err()
    );
    assert!(apply_commands(&base, r#"[{"id":"export.pdf","params":{}}]"#, "Agent").is_err());

    let atomic_fail = apply_commands(
        &base,
        r#"[
            {"id":"text.insert","params":{"text":"Should Roll Back"}},
            {"id":"nonexistent.command","params":{}}
        ]"#,
        "Agent",
    );
    assert!(atomic_fail.is_err());

    // 3. Valid `apply_commands` batch edits the document, stamps actor name on tracked changes/comments, and derives ChangeSet.
    let (edited, cs_opt, results) = apply_commands(
        &base,
        r#"[
            {"id":"review.trackChanges","params":{}},
            {"id":"text.insert","params":{"text":"Hello searchable world"}},
            {"id":"text.newParagraph","params":{}},
            {"id":"text.insert","params":{"text":"Second paragraph"}}
        ]"#,
        "Agent Bot",
    )
    .expect("valid command batch succeeds");
    assert_eq!(results.len(), 4);
    assert!(cs_opt.is_some());
    assert!(
        edited
            .document()
            .revisions
            .iter()
            .all(|r| r.author == "Agent Bot")
    );

    // 4. `inspect` returns title, counts, and block summaries (including range slicing).
    let info = inspect(&edited, "{}").expect("inspect full");
    assert_eq!(info["title"], "Agent Spec");
    assert_eq!(info["block_count"], 2);
    assert_eq!(info["track_changes"], true);
    assert_eq!(info["blocks"][0]["text"], "Hello searchable world");
    assert_eq!(info["blocks"][1]["text"], "Second paragraph");

    let sliced = inspect(&edited, r#"{"from_block":1,"to_block":2}"#).expect("inspect slice");
    assert_eq!(sliced["blocks"].as_array().unwrap().len(), 1);
    assert_eq!(sliced["blocks"][0]["index"], 1);

    // 5. `find` locates matches case-insensitively and case-sensitively with page & rect coordinates.
    let matches_ci = find(&edited, "SEARCHABLE", false);
    assert_eq!(matches_ci.len(), 1);
    assert_eq!(matches_ci[0].story, StoryRef::Body);
    assert_eq!(matches_ci[0].block_index, 0);
    assert_eq!(matches_ci[0].page_index, 0);
    assert!(matches_ci[0].snippet.contains("searchable"));
    assert!(!matches_ci[0].rects.is_empty());

    let matches_cs = find(&edited, "SEARCHABLE", true);
    assert!(matches_cs.is_empty());

    // 6. `render_page_rgba`, `render_page_png`, and `export_pdf`.
    let (w, h, rgba) = render_page_rgba(&edited, 0, 1.0).expect("render rgba");
    assert!(w > 0 && h > 0);
    assert_eq!(rgba.len(), (w as usize) * (h as usize) * 4);

    let png_bytes = render_page_png(&edited, 0, 1.0).expect("render png");
    assert!(png_bytes.starts_with(b"\x89PNG\r\n\x1a\n"));

    let pdf_bytes = export_pdf(&edited).expect("export pdf");
    assert!(pdf_bytes.starts_with(b"%PDF-"));
}

#[test]
fn conversion_preserves_restarted_and_continued_numbering() {
    let (blank, _) = create_blank("Numbered steps").unwrap();
    let doc = mutate_doc(&blank, |raw| {
        let numbering = Arc::make_mut(&mut raw.numbering);
        numbering.abstracts.push(AbstractNum {
            id: 100,
            levels: vec![Level {
                start: 1,
                format: NumFormat::Decimal,
                text: "%1.".into(),
                ..Default::default()
            }],
            ..Default::default()
        });
        for (id, start_overrides) in [(1, vec![]), (2, vec![(0, 1)])] {
            numbering.nums.push(Num {
                id,
                abstract_id: 100,
                start_overrides,
                level_overrides: vec![],
            });
        }
        raw.body = [
            ("A", Some(1)),
            ("B", Some(1)),
            ("C", Some(2)),
            ("D", Some(2)),
            ("Interruption", None),
            ("E", Some(2)),
        ]
        .into_iter()
        .map(|(text, num)| {
            let mut paragraph = Paragraph::with_text(text, CharProps::default());
            paragraph.props.numbering = num.map(|num| NumRef { num, level: 0 });
            para_block(paragraph)
        })
        .collect();
    });

    let reopened = open(&export_docx(&doc).unwrap(), "[]").unwrap();
    let converted = to_document(&reopened).unwrap();
    assert_eq!(
        converted.xml,
        concat!(
            "<page><ol><li><p>A</p></li><li><p>B</p></li></ol>",
            "<ol><li><p>C</p></li><li><p>D</p></li></ol>",
            "<p>Interruption</p><ol start=\"3\"><li><p>E</p></li></ol></page>"
        )
    );
}

#[test]
fn find_normalizes_compatibility_forms_and_preserves_source_ranges() {
    let (blank, _) = create_blank("Search").unwrap();
    let doc = mutate_doc(&blank, |raw| {
        raw.body = vec![para_block(Paragraph::with_text(
            "Ａﬃ cafe\u{301} ㄱㅏ",
            CharProps::default(),
        ))];
    });
    for (query, match_case) in [
        ("Affi", true),
        ("AFFI", false),
        ("café", true),
        ("가", true),
    ] {
        let matches = find(&doc, query, match_case);
        assert_eq!(matches.len(), 1, "{query}");
        assert_eq!(matches[0].snippet, "Ａﬃ cafe\u{301} ㄱㅏ");
        assert!(!matches[0].rects.is_empty(), "{query}");
    }
    assert!(find(&doc, "AFFI", true).is_empty());
}

#[test]
fn word_ime_survives_ack_and_disjoint_remote_edit() {
    let (_, bytes) = create_blank("Collaboration").unwrap();
    let mut editor = Editor::open(&bytes, "[]").unwrap();
    editor.insert_text("First").unwrap();
    editor.key_event("Enter", false, false, false).unwrap();
    let local = editor.commit_local_step().unwrap().unwrap();
    let acknowledgement = format!("[{local}]");

    editor.ime_preedit("ni", 2, 2).unwrap();
    editor.apply_remote(&acknowledgement, "[]").unwrap();
    assert!(editor.is_composing());
    assert!(editor.find("ni", true).unwrap().contains("ni"));
    assert_eq!(editor.commit_local_step().unwrap(), None);

    let mut collaborator = Editor::open(&bytes, &acknowledgement).unwrap();
    collaborator.insert_text("Remote ").unwrap();
    let remote = collaborator.commit_local_step().unwrap().unwrap();
    editor.apply_remote(&format!("[{remote}]"), "[]").unwrap();
    assert!(editor.is_composing());
    assert!(editor.find("ni", true).unwrap().contains("ni"));
    assert_eq!(editor.commit_local_step().unwrap(), None);

    editor.ime_commit("你").unwrap();
    let committed = editor.commit_local_step().unwrap().unwrap();
    assert!(committed.contains("你"));
    assert!(!committed.contains("Remote "));
    assert!(
        editor
            .find("Remote First", true)
            .unwrap()
            .contains("Remote First")
    );
}

#[test]
fn editor_supports_ime_undo_redo_gestures_and_collaborative_rebase() {
    let mut alice = Editor::create_blank("Collab Spec").expect("alice editor");
    alice.insert_text("First paragraph").unwrap();
    alice.key_event("Enter", false, false, false).unwrap();
    alice.insert_text("Second paragraph").unwrap();
    alice.key_event("Enter", false, false, false).unwrap();
    alice.insert_text("Third paragraph").unwrap();

    let init_step = alice
        .commit_local_step()
        .unwrap()
        .expect("initial step JSON");
    // Advance Alice's confirmed state with her committed op.
    alice
        .apply_remote(&format!("[{init_step}]"), "[]")
        .expect("ack alice initial step");
    let docx_bytes = alice.export_docx().unwrap();

    // Open Bob on the same document.
    let mut bob = Editor::open(&docx_bytes, "[]").expect("bob editor");
    let pages: serde_json::Value = serde_json::from_str(&bob.pages_info().unwrap()).unwrap();
    assert_eq!(pages.as_array().unwrap().len(), 1);
    let px = bob.page_pixel_size(0, 1.0).unwrap();
    assert_eq!(px.len(), 2);

    // Move Bob's caret to the third paragraph (block index 2) and start an IME composition.
    bob.key_event("ArrowDown", false, false, false).unwrap();
    bob.key_event("ArrowDown", false, false, false).unwrap();
    bob.ime_preedit("nihao", 5, 5).unwrap();
    assert!(bob.is_composing());
    assert!(
        !bob.has_local_changes(),
        "IME preedit must not advertise committable local changes"
    );
    assert_eq!(
        bob.commit_local_step().unwrap(),
        None,
        "commit_local_step must never commit during IME composition"
    );
    bob.ime_commit("你好 ").unwrap();
    assert!(!bob.is_composing());
    assert!(bob.has_local_changes());
    let pre_remote_caret: serde_json::Value =
        serde_json::from_str(&bob.caret_and_selection().unwrap()).unwrap();
    assert_eq!(pre_remote_caret["can_undo"], true);

    // Meanwhile Alice inserts a new paragraph at block index 0 before Bob's active draft in block 2.
    let mut alice2 = Editor::open(&docx_bytes, "[]").unwrap();
    alice2.key_event("Enter", false, false, false).unwrap();
    alice2.key_event("ArrowUp", false, false, false).unwrap();
    alice2.insert_text("Inserted at top").unwrap();
    let alice_op = alice2.commit_local_step().unwrap().unwrap();

    // Bob receives Alice's structural remote commit while holding his uncommitted local draft in block 2 -> shifts to block 3!
    let remote_res: serde_json::Value =
        serde_json::from_str(&bob.apply_remote(&format!("[{alice_op}]"), "[]").unwrap()).unwrap();
    assert_eq!(remote_res["draft_conflict"], false);
    assert_eq!(remote_res["active_block"], 3);

    // Structural remote commit clears personal Undo while preserving Bob's rebased active draft in block 3.
    let caret_json = bob.caret_and_selection().unwrap();
    let caret_val: serde_json::Value = serde_json::from_str(&caret_json).unwrap();
    assert_eq!(caret_val["block"], 3);
    assert_eq!(caret_val["can_undo"], false);

    let rects_json = bob.block_rects(r#""body""#, 3).unwrap();
    let rects_val: serde_json::Value = serde_json::from_str(&rects_json).unwrap();
    assert!(!rects_val.as_array().unwrap().is_empty());

    let pres_rects: serde_json::Value = serde_json::from_str(
        &bob.presence_selection_rects(&caret_json)
            .expect("presence rects"),
    )
    .unwrap();
    assert!(pres_rects.is_array());

    // Commit Bob's rebased draft, then type a new local edit and test personal Undo and Redo.
    let bob_step = bob.commit_local_step().unwrap().expect("bob draft step");
    assert!(bob_step.contains("你好"));
    bob.insert_text("world").unwrap();
    let typed_caret: serde_json::Value =
        serde_json::from_str(&bob.caret_and_selection().unwrap()).unwrap();
    assert_eq!(typed_caret["can_undo"], true);
    let _ = bob.commit_local_step().unwrap().expect("typed step");
    let undo_step = bob.undo().unwrap();
    assert!(undo_step.is_some());
    let redo_step = bob.redo().unwrap();
    assert!(redo_step.is_some());

    // Document-wide command (`review.trackChanges`) clears personal Undo history.
    bob.execute_command("review.trackChanges", "{}").unwrap();
    let after_cmd_caret: serde_json::Value =
        serde_json::from_str(&bob.caret_and_selection().unwrap()).unwrap();
    assert_eq!(after_cmd_caret["can_undo"], false);

    // Pointer selection, selected_text/selected_html, substituted_fonts, missing_pictures.
    bob.pointer_down(0, 80.0, 80.0, 3, false, false).unwrap();
    bob.pointer_move(0, 140.0, 80.0).unwrap();
    bob.pointer_up(0, 140.0, 80.0).unwrap();
    let _ = bob.selected_text();
    let _ = bob.selected_html();
    let subs: serde_json::Value = serde_json::from_str(&bob.substituted_fonts().unwrap()).unwrap();
    assert!(subs.is_array());
    let missing: serde_json::Value =
        serde_json::from_str(&bob.missing_pictures().unwrap()).unwrap();
    assert_eq!(missing, json!([]));
    assert_eq!(bob.load_embedded_fonts(), 0);
}
