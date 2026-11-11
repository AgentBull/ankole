//! Unit and integration tests for `ankole_presentation`.

use std::io::{Cursor, Read as _};
use std::sync::Arc;

use deckcraft_geom::{Size, Xfrm};
use deckcraft_model::text::TextBody;
use deckcraft_model::{
    Comment, CustomShow, DrawGuide, KeptPart, MediaId, MediaItem, Section, Shape, ShapeId,
    ShapeKind, SlideId,
};
use image::{ImageBuffer, Rgba, RgbaImage};
use serde_json::{Value, json};

use crate::{
    ApplyError, ChangeSet, Conflict, DeckField, Edit, EditorState, Error, InsertedSlide,
    MAX_OP_BYTES, MAX_PICTURE_BYTES, MODEL_VERSION, PresentationDoc, apply, apply_commands,
    commands, create_blank, derive, export_pdf, export_pptx, export_pptx_with_checkpoint, find,
    init_site_fonts, inspect, open, open_with_checkpoint, render_slide_png, render_slide_rgba,
};

fn tiny_png_bytes() -> Vec<u8> {
    let img: RgbaImage = ImageBuffer::from_fn(4, 4, |x, y| {
        if (x + y) % 2 == 0 {
            Rgba([220, 40, 60, 255])
        } else {
            Rgba([30, 140, 240, 255])
        }
    });
    let mut out = Vec::new();
    img.write_to(&mut Cursor::new(&mut out), image::ImageFormat::Png)
        .expect("encode tiny PNG");
    out
}

fn assert_derive_roundtrip(before: &PresentationDoc, after: &PresentationDoc) -> ChangeSet {
    let cs = derive(before, after)
        .expect("derive succeeds")
        .expect("documents differ");
    let json_op = serde_json::to_string(&cs).expect("serialize changeset");
    let applied = apply(before, &json_op, "[]", None).expect("apply derived changeset");
    assert_eq!(
        applied.doc.presentation(),
        after.presentation(),
        "apply(before, derive(before, after)) must equal after"
    );
    cs
}

#[test]
fn create_blank_open_export_round_trip() {
    init_site_fonts(&[]);
    let (doc, pptx_bytes) = create_blank("Quarterly Review").expect("create blank");
    assert_eq!(doc.presentation().props.title, "Quarterly Review");
    assert_eq!(doc.presentation().slides.len(), 1);
    assert!(doc.warnings().is_empty());

    let opened = open(&pptx_bytes, "[]").expect("open blank pptx");
    assert_eq!(opened.presentation().props.title, "Quarterly Review");
    assert_eq!(opened.presentation().slides.len(), 1);
    assert_eq!(
        opened.presentation().slide_size,
        doc.presentation().slide_size
    );

    let reexported = export_pptx(&opened).expect("re-export pptx");
    let reopened = open(&reexported, "[]").expect("re-open exported pptx");
    assert_eq!(reopened.presentation(), opened.presentation());
}

fn assert_pure_ooxml_zip(bytes: &[u8]) {
    let mut archive = zip::ZipArchive::new(Cursor::new(bytes)).expect("valid zip archive");
    for idx in 0..archive.len() {
        let mut entry = archive.by_index(idx).expect("zip entry");
        let name = entry.name().expect("utf8 zip entry name").into_owned();
        assert!(
            !name.to_ascii_lowercase().contains("ankole"),
            "exported PPTX archive must not contain proprietary part {name:?}"
        );
        if name.ends_with(".xml") || name.ends_with(".rels") {
            let mut xml = String::new();
            entry.read_to_string(&mut xml).expect("UTF-8 XML part");
            assert!(
                !xml.to_ascii_lowercase().contains("ankole"),
                "exported PPTX part {name:?} must not contain proprietary ankole markup"
            );
        }
    }
}

#[test]
fn compacted_pptx_replays_edits_authored_before_reopen() {
    let (blank, blank_bytes) = create_blank("Stable identities").unwrap();
    assert_pure_ooxml_zip(&blank_bytes);
    let image = tiny_png_bytes();
    let (edited, _, _) = apply_commands(
        &blank,
        &json!([
            {"command":"insert.textBox","params":{"text":"Original slide", "rect":[40,50,300,80]}},
            {"command":"insert.picture","params":{
                "data":base64_simd::STANDARD.encode_to_string(&image),
                "name":"image.png","rect":[60,60,120,120]
            }},
            {"command":"slide.new","params":{"title":"Second slide"}},
            {"command":"slide.notes","params":{"text":"Creates a default PowerPoint notes master"}}
        ])
        .to_string(),
        "Author",
    )
    .unwrap();
    let target_id = edited.presentation().slides[0].id;
    let mut reordered = edited.presentation().clone();
    reordered.slides.reverse();
    let compacted = PresentationDoc::from_presentation(reordered, vec![]);
    let (bytes, checkpoint) = export_pptx_with_checkpoint(&compacted).unwrap();
    assert!(checkpoint.is_some());
    assert_pure_ooxml_zip(&bytes);
    let reopened = open_with_checkpoint(&bytes, "[]", checkpoint.as_deref()).unwrap();
    assert_eq!(
        reopened.presentation().next_id,
        compacted.presentation().next_id
    );
    for (before, after) in compacted
        .presentation()
        .slides
        .iter()
        .zip(&reopened.presentation().slides)
    {
        assert_eq!(before.id, after.id);
        assert_eq!(before.layout, after.layout);
    }
    let before = compacted.presentation().slide(target_id).unwrap();
    let after = reopened.presentation().slide(target_id).unwrap();
    assert_eq!(
        before
            .shapes
            .iter()
            .map(|shape| shape.id)
            .collect::<Vec<_>>(),
        after
            .shapes
            .iter()
            .map(|shape| shape.id)
            .collect::<Vec<_>>()
    );
    assert_eq!(
        reopened.presentation().media[0].id,
        compacted.presentation().media[0].id
    );
    assert_eq!(*reopened.presentation().media[0].data, image);
    assert!(reopened.presentation().notes_master.is_none());

    // Without a checkpoint (for example after an external PowerPoint save), the notes master in
    // the package is preserved rather than discarded.
    let external = open(&bytes, "[]").unwrap();
    assert!(external.presentation().notes_master.is_some());

    let mut with_notes = compacted.presentation().clone();
    with_notes.slide_mut(target_id).unwrap().notes = TextBody::from_text("Queued while compacting");
    let queued = derive(
        &compacted,
        &PresentationDoc::from_presentation(with_notes, vec![]),
    )
    .unwrap()
    .unwrap();
    let committed = apply(
        &reopened,
        &serde_json::to_string(&queued).unwrap(),
        "[]",
        None,
    )
    .unwrap();
    assert_eq!(
        committed
            .doc
            .presentation()
            .slide(target_id)
            .unwrap()
            .notes
            .text(),
        "Queued while compacting"
    );
    let tail = serde_json::to_string(&vec![queued]).unwrap();
    let replayed = open_with_checkpoint(&bytes, &tail, checkpoint.as_deref()).unwrap();
    assert_eq!(
        replayed
            .presentation()
            .slide(target_id)
            .unwrap()
            .notes
            .text(),
        "Queued while compacting"
    );
    assert_eq!(
        replayed.presentation().slides[0].notes.text(),
        "Creates a default PowerPoint notes master"
    );
}

#[test]
fn editor_missing_glyph_fonts_detects_cjk_without_polluting_substituted_fonts() {
    let mut baseline = EditorState::create_blank("Baseline").expect("blank editor");
    baseline
        .execute_command(
            "insert.textBox",
            &json!({"rect": [40.0, 50.0, 300.0, 80.0], "text": "Latin text only"}).to_string(),
        )
        .unwrap();
    let baseline_subs = baseline.substituted_fonts().unwrap();

    for (sample, expected) in [
        ("Latin text only", Vec::<&str>::new()),
        ("季度工作汇报", vec!["Noto Sans SC"]),
        ("日本語のテスト", vec!["Noto Sans JP"]),
        ("분기 보고서", vec!["Noto Sans KR"]),
        ("ㄅㄆㄇㄈ", vec!["Noto Sans TC"]),
    ] {
        let mut editor = EditorState::create_blank("CJK Deck").expect("blank editor");
        editor
            .execute_command(
                "insert.textBox",
                &json!({"rect": [40.0, 50.0, 300.0, 80.0], "text": sample}).to_string(),
            )
            .unwrap();
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
fn derive_and_apply_round_trip_across_all_mutation_kinds() {
    let (base, base_bytes) = create_blank("Deck Mutations").expect("create blank");

    // 1. Text edit, shape insert, move, delete, and speaker notes via headless commands.
    let (after_shapes, _, _) = apply_commands(
        &base,
        &json!([
            {"command": "insert.textBox", "params": {"rect": [40.0, 50.0, 300.0, 80.0], "text": "First callout"}},
            {"command": "shape.insert", "params": {"preset": "rect", "rect": [100.0, 180.0, 200.0, 120.0], "text": "Box A"}},
            {"command": "slide.notes", "params": {"text": "Remember customer metrics"}}
        ])
        .to_string(),
        "Test User",
    )
    .expect("shape insert commands");
    let cs_shapes = assert_derive_roundtrip(&base, &after_shapes);
    assert!(!cs_shapes.carries_media());

    // Move and delete a shape on the slide.
    let shape_to_delete = after_shapes.presentation().slides[0]
        .shapes
        .last()
        .expect("inserted shape")
        .id
        .0;
    let mut moved_pres = after_shapes.presentation().clone();
    {
        let slide = Arc::make_mut(&mut moved_pres.slides[0]);
        slide.shapes.retain(|s| s.id.0 != shape_to_delete);
        let first = slide.shapes.last_mut().expect("surviving textBox");
        first.xfrm = Some(Xfrm {
            x: 88.0,
            y: 99.0,
            w: 320.0,
            h: 90.0,
            ..Xfrm::default()
        });
        first.text = Some(TextBody::from_text("Updated callout text"));
    }
    let after_move_delete = PresentationDoc::from_presentation(moved_pres, Vec::new());
    let _ = assert_derive_roundtrip(&after_shapes, &after_move_delete);

    // 2. Slide insert, reorder, and delete.
    let (three_slides, _, _) = apply_commands(
        &after_move_delete,
        &json!([
            {"command": "slide.new", "params": {"title": "Slide Two", "body": "Second body"}},
            {"command": "slide.new", "params": {"title": "Slide Three", "body": "Third body"}}
        ])
        .to_string(),
        "Test User",
    )
    .expect("insert two slides");
    assert_eq!(three_slides.presentation().slides.len(), 3);
    let cs_insert = assert_derive_roundtrip(&after_move_delete, &three_slides);
    assert!(
        cs_insert
            .edits
            .iter()
            .any(|e| matches!(e, Edit::SlidesOrder { insert, .. } if insert.len() == 2))
    );

    // Reorder slides [2, 0] while deleting middle slide [1] and editing surviving slide [0].
    let mut reordered_pres = three_slides.presentation().clone();
    let s0 = Arc::clone(&reordered_pres.slides[0]);
    let s2 = Arc::clone(&reordered_pres.slides[2]);
    reordered_pres.slides = vec![s2, s0];
    Arc::make_mut(&mut reordered_pres.slides[1]).notes =
        TextBody::from_text("Edited while reordering");
    let after_reorder_delete = PresentationDoc::from_presentation(reordered_pres, Vec::new());
    let _ = assert_derive_roundtrip(&three_slides, &after_reorder_delete);

    // 3. Embedded PNG picture insertion: verify media.put base64 round-trip and pptx persistence.
    let png = tiny_png_bytes();
    let png_b64 = base64_simd::STANDARD.encode_to_string(&png);
    let (with_pic, pic_cs_opt, _) = apply_commands(
        &after_reorder_delete,
        &json!([
            {"command": "insert.picture", "params": {"data": png_b64, "name": "pixel.png", "rect": [60.0, 60.0, 120.0, 120.0]}}
        ])
        .to_string(),
        "Test User",
    )
    .expect("insert picture");
    let pic_cs = pic_cs_opt.expect("picture changeset emitted");
    assert!(pic_cs.carries_media());
    let applied_pic = apply(
        &after_reorder_delete,
        &serde_json::to_string(&pic_cs).expect("serialize pic cs"),
        "[]",
        None,
    )
    .expect("apply picture op");
    assert!(applied_pic.carries_media);
    assert_eq!(applied_pic.doc.presentation(), with_pic.presentation());
    assert_eq!(applied_pic.doc.presentation().media.len(), 1);
    assert_eq!(*applied_pic.doc.presentation().media[0].data, png);

    // Replay tail ops from original bytes and export -> open to prove media bytes survive end-to-end.
    let full_cs = derive(&base, &applied_pic.doc)
        .expect("derive full")
        .expect("non-empty");
    let tail_json = serde_json::to_string(&vec![full_cs]).expect("serialize tail");
    let replayed = open(&base_bytes, &tail_json).expect("open with tail ops");
    assert_eq!(replayed.presentation().media.len(), 1);
    assert_eq!(*replayed.presentation().media[0].data, png);
    let exported_with_pic = export_pptx(&replayed).expect("export with pic");
    let imported_with_pic = open(&exported_with_pic, "[]").expect("reopen exported pic pptx");
    assert_eq!(imported_with_pic.presentation().media.len(), 1);
    assert_eq!(*imported_with_pic.presentation().media[0].data, png);

    // 4. Deck-wide settings mutations.
    let mut deck_mut = applied_pic.doc.presentation().clone();
    deck_mut.slide_size = Size {
        width: 720.0,
        height: 540.0,
    };
    deck_mut.notes_size = Size {
        width: 540.0,
        height: 720.0,
    };
    deck_mut.props.subject = "Board Deck".into();
    deck_mut.show.loop_until_esc = true;
    deck_mut.header_footer.footer = true;
    deck_mut.header_footer.footer_text = "Confidential".into();
    deck_mut.first_slide_number = 3;
    deck_mut.sections.push(Section {
        name: "Intro".into(),
        slides: vec![deck_mut.slides[0].id],
    });
    deck_mut.custom_shows.push(CustomShow {
        name: "Short".into(),
        slides: vec![deck_mut.slides[0].id],
    });
    deck_mut.guides.push(DrawGuide {
        pos: 120.0,
        vertical: false,
    });
    deck_mut.tags.push(("CUSTOM_KEY".into(), "42".into()));
    deck_mut.kept_parts.push(KeptPart {
        name: "customXml/item1.xml".into(),
        content_type: "application/xml".into(),
        rel_type: String::new(),
        xml: "<item/>".into(),
        from_root: false,
    });
    Arc::make_mut(&mut deck_mut.masters[0]).name = "Custom Master".into();
    let after_deck = PresentationDoc::from_presentation(deck_mut, Vec::new());
    let _ = assert_derive_roundtrip(&applied_pic.doc, &after_deck);

    // Unchanged documents produce None.
    assert_eq!(derive(&after_deck, &after_deck).expect("derive self"), None);
}

#[test]
fn disjoint_slide_put_commutes_in_both_orders() {
    let (base, _) = create_blank("Commute Deck").expect("blank");
    let (two_slides, _, _) = apply_commands(
        &base,
        &json!([{"command": "slide.new", "params": {"title": "Second"}}]).to_string(),
        "Setup",
    )
    .expect("add slide 2");

    let slide_a_id = two_slides.presentation().slides[0].id;
    let slide_b_id = two_slides.presentation().slides[1].id;

    let mut pres_a = two_slides.presentation().clone();
    Arc::make_mut(&mut pres_a.slides[0]).notes = TextBody::from_text("Author A notes on slide 1");
    let doc_a = PresentationDoc::from_presentation(pres_a, Vec::new());
    let op_a = derive(&two_slides, &doc_a).unwrap().unwrap();
    let op_a_json = serde_json::to_string(&op_a).unwrap();

    let mut pres_b = two_slides.presentation().clone();
    Arc::make_mut(&mut pres_b.slides[1]).notes = TextBody::from_text("Author B notes on slide 2");
    let doc_b = PresentationDoc::from_presentation(pres_b, Vec::new());
    let op_b = derive(&two_slides, &doc_b).unwrap().unwrap();
    let op_b_json = serde_json::to_string(&op_b).unwrap();

    // Order 1: A commits first, then B rebases over [A].
    let after_a = apply(&two_slides, &op_a_json, "[]", None).unwrap();
    let a_then_b = apply(
        &after_a.doc,
        &op_b_json,
        &serde_json::to_string(&vec![after_a.op]).unwrap(),
        None,
    )
    .unwrap();

    // Order 2: B commits first, then A rebases over [B].
    let after_b = apply(&two_slides, &op_b_json, "[]", None).unwrap();
    let b_then_a = apply(
        &after_b.doc,
        &op_a_json,
        &serde_json::to_string(&vec![after_b.op]).unwrap(),
        None,
    )
    .unwrap();

    assert_eq!(a_then_b.doc.presentation(), b_then_a.doc.presentation());
    assert_eq!(
        a_then_b
            .doc
            .presentation()
            .slide(slide_a_id)
            .unwrap()
            .notes
            .text(),
        "Author A notes on slide 1"
    );
    assert_eq!(
        a_then_b
            .doc
            .presentation()
            .slide(slide_b_id)
            .unwrap()
            .notes
            .text(),
        "Author B notes on slide 2"
    );
}

#[test]
fn slides_order_and_surviving_slide_put_commute_in_both_orders() {
    let (base, _) = create_blank("Reorder Commute").expect("blank");
    let (two_slides, _, _) = apply_commands(
        &base,
        &json!([{"command": "slide.new", "params": {"title": "Second"}}]).to_string(),
        "Setup",
    )
    .expect("two slides");

    let s1 = two_slides.presentation().slides[0].id.0;
    let s2 = two_slides.presentation().slides[1].id.0;

    // Op A edits slide 1 content.
    let mut edited = two_slides.presentation().clone();
    Arc::make_mut(&mut edited.slides[0]).notes = TextBody::from_text("Updated S1");
    let op_put = derive(
        &two_slides,
        &PresentationDoc::from_presentation(edited, Vec::new()),
    )
    .unwrap()
    .unwrap();
    let op_put_json = serde_json::to_string(&op_put).unwrap();

    // Op B reverses slide order [s2, s1].
    let mut reordered = two_slides.presentation().clone();
    reordered.slides.reverse();
    let op_order = derive(
        &two_slides,
        &PresentationDoc::from_presentation(reordered, Vec::new()),
    )
    .unwrap()
    .unwrap();
    let op_order_json = serde_json::to_string(&op_order).unwrap();

    // Put first, then Order.
    let step1 = apply(&two_slides, &op_put_json, "[]", None).unwrap();
    let put_then_order = apply(
        &step1.doc,
        &op_order_json,
        &serde_json::to_string(&vec![step1.op]).unwrap(),
        None,
    )
    .unwrap();

    // Order first, then Put.
    let step2 = apply(&two_slides, &op_order_json, "[]", None).unwrap();
    let order_then_put = apply(
        &step2.doc,
        &op_put_json,
        &serde_json::to_string(&vec![step2.op]).unwrap(),
        None,
    )
    .unwrap();

    assert_eq!(
        put_then_order.doc.presentation(),
        order_then_put.doc.presentation()
    );
    let final_ids: Vec<u32> = put_then_order
        .doc
        .presentation()
        .slides
        .iter()
        .map(|s| s.id.0)
        .collect();
    assert_eq!(final_ids, vec![s2, s1]);
    assert_eq!(
        put_then_order
            .doc
            .presentation()
            .slide(SlideId(s1))
            .unwrap()
            .notes
            .text(),
        "Updated S1"
    );
}

#[test]
fn conflicts_versions_and_size_limits_are_enforced() {
    let (base, base_bytes) = create_blank("Conflicts").expect("blank");
    let (two_slides, _, _) = apply_commands(
        &base,
        &json!([{"command": "slide.new", "params": {"title": "Slide 2"}}]).to_string(),
        "Setup",
    )
    .expect("two slides");

    let s1_id = two_slides.presentation().slides[0].id.0;
    let s2_id = two_slides.presentation().slides[1].id.0;

    // 1. Concurrent slide.put on same slide -> slide_changed.
    let mut p1 = two_slides.presentation().clone();
    Arc::make_mut(&mut p1.slides[0]).notes = TextBody::from_text("Edit 1");
    let op1 = derive(
        &two_slides,
        &PresentationDoc::from_presentation(p1, Vec::new()),
    )
    .unwrap()
    .unwrap();

    let mut p2 = two_slides.presentation().clone();
    Arc::make_mut(&mut p2.slides[0]).notes = TextBody::from_text("Edit 2");
    let op2 = derive(
        &two_slides,
        &PresentationDoc::from_presentation(p2, Vec::new()),
    )
    .unwrap()
    .unwrap();

    let c1 = apply(
        &two_slides,
        &serde_json::to_string(&op1).unwrap(),
        "[]",
        None,
    )
    .unwrap();
    let err = apply(
        &c1.doc,
        &serde_json::to_string(&op2).unwrap(),
        &serde_json::to_string(&vec![c1.op.clone()]).unwrap(),
        None,
    )
    .unwrap_err();
    assert_eq!(err, ApplyError::Conflict(Conflict::SlideChanged));
    assert_eq!(Conflict::SlideChanged.as_str(), "slide_changed");

    // 2. slides.order deleting a slide edited by a prior slide.put -> slide_changed.
    let delete_s1 = ChangeSet {
        model_version: MODEL_VERSION,
        edits: vec![Edit::SlidesOrder {
            order: vec![s2_id],
            insert: vec![],
        }],
    };
    let err_del_edited = apply(
        &c1.doc,
        &serde_json::to_string(&delete_s1).unwrap(),
        &serde_json::to_string(&vec![c1.op]).unwrap(),
        None,
    )
    .unwrap_err();
    assert_eq!(err_del_edited, ApplyError::Conflict(Conflict::SlideChanged));

    // 3. slide.put on a slide deleted by a prior slides.order -> slide_deleted.
    let c_del = apply(
        &two_slides,
        &serde_json::to_string(&delete_s1).unwrap(),
        "[]",
        None,
    )
    .unwrap();
    let err_deleted = apply(
        &c_del.doc,
        &serde_json::to_string(&op2).unwrap(),
        &serde_json::to_string(&vec![c_del.op.clone()]).unwrap(),
        None,
    )
    .unwrap_err();
    assert_eq!(err_deleted, ApplyError::Conflict(Conflict::SlideDeleted));
    assert_eq!(Conflict::SlideDeleted.as_str(), "slide_deleted");

    // 4. Two concurrent slides.order -> slides_reordered.
    let reorder_other = ChangeSet {
        model_version: MODEL_VERSION,
        edits: vec![Edit::SlidesOrder {
            order: vec![s2_id, s1_id],
            insert: vec![],
        }],
    };
    let err_reordered = apply(
        &c_del.doc,
        &serde_json::to_string(&reorder_other).unwrap(),
        &serde_json::to_string(&vec![c_del.op]).unwrap(),
        None,
    )
    .unwrap_err();
    assert_eq!(
        err_reordered,
        ApplyError::Conflict(Conflict::SlidesReordered)
    );
    assert_eq!(Conflict::SlidesReordered.as_str(), "slides_reordered");

    // 5. Colliding newly allocated ShapeId / SlideId / MediaId -> identifier_taken,
    // while non-colliding ShapeId after a non-allocating prior op succeeds!
    let mut non_alloc_prior = two_slides.presentation().clone();
    Arc::make_mut(&mut non_alloc_prior.slides[0]).notes = TextBody::from_text("No ID allocated");
    let non_alloc_op = derive(
        &two_slides,
        &PresentationDoc::from_presentation(non_alloc_prior, Vec::new()),
    )
    .unwrap()
    .unwrap();
    let after_non_alloc = apply(
        &two_slides,
        &serde_json::to_string(&non_alloc_op).unwrap(),
        "[]",
        None,
    )
    .unwrap();

    // Allocate one new shape on slide 2 from `two_slides` (same next_id as before `non_alloc_op`).
    let mut add_shape_s2 = two_slides.presentation().clone();
    let new_shape_id = add_shape_s2.alloc_id().unwrap();
    Arc::make_mut(&mut add_shape_s2.slides[1])
        .shapes
        .push(Shape {
            id: ShapeId(new_shape_id),
            name: "Callout".into(),
            kind: ShapeKind::Shape,
            xfrm: Some(Xfrm {
                x: 10.0,
                y: 10.0,
                w: 100.0,
                h: 50.0,
                ..Xfrm::default()
            }),
            ..Shape::default()
        });
    let op_shape_s2 = derive(
        &two_slides,
        &PresentationDoc::from_presentation(add_shape_s2, Vec::new()),
    )
    .unwrap()
    .unwrap();

    // Succeeds against `non_alloc_op` because `new_shape_id` was not taken!
    let ok_commute = apply(
        &after_non_alloc.doc,
        &serde_json::to_string(&op_shape_s2).unwrap(),
        &serde_json::to_string(&vec![after_non_alloc.op]).unwrap(),
        None,
    )
    .expect("allocating op commutes with non-allocating edit on another slide");
    assert!(
        ok_commute
            .doc
            .presentation()
            .slide(SlideId(s2_id))
            .unwrap()
            .shapes
            .iter()
            .any(|s| s.id.0 == new_shape_id)
    );

    // Now collide: Author A allocates `new_shape_id` on slide 1, Author B allocates the same ID on slide 2.
    let mut add_shape_s1 = two_slides.presentation().clone();
    let colliding_id = add_shape_s1.alloc_id().unwrap();
    assert_eq!(colliding_id, new_shape_id);
    Arc::make_mut(&mut add_shape_s1.slides[0])
        .shapes
        .push(Shape {
            id: ShapeId(colliding_id),
            name: "A Shape".into(),
            kind: ShapeKind::Shape,
            ..Shape::default()
        });
    let op_shape_s1 = derive(
        &two_slides,
        &PresentationDoc::from_presentation(add_shape_s1, Vec::new()),
    )
    .unwrap()
    .unwrap();
    let after_s1_alloc = apply(
        &two_slides,
        &serde_json::to_string(&op_shape_s1).unwrap(),
        "[]",
        None,
    )
    .unwrap();

    let err_shape_taken = apply(
        &after_s1_alloc.doc,
        &serde_json::to_string(&op_shape_s2).unwrap(),
        &serde_json::to_string(&vec![after_s1_alloc.op.clone()]).unwrap(),
        None,
    )
    .unwrap_err();
    assert_eq!(
        err_shape_taken,
        ApplyError::Conflict(Conflict::IdentifierTaken)
    );
    assert_eq!(Conflict::IdentifierTaken.as_str(), "identifier_taken");

    // Colliding SlideId in slides.order insert -> identifier_taken.
    let mut bad_insert_slide = (*two_slides.presentation().slides[0]).clone();
    bad_insert_slide.id = SlideId(colliding_id);
    bad_insert_slide.shapes.clear();
    let op_bad_slide_id = ChangeSet {
        model_version: MODEL_VERSION,
        edits: vec![Edit::SlidesOrder {
            order: vec![s1_id, s2_id, colliding_id],
            insert: vec![InsertedSlide {
                id: colliding_id,
                value: bad_insert_slide,
            }],
        }],
    };
    let err_slide_id_taken = apply(
        &after_s1_alloc.doc,
        &serde_json::to_string(&op_bad_slide_id).unwrap(),
        &serde_json::to_string(&vec![after_s1_alloc.op.clone()]).unwrap(),
        None,
    )
    .unwrap_err();
    assert_eq!(
        err_slide_id_taken,
        ApplyError::Conflict(Conflict::IdentifierTaken)
    );

    // Colliding MediaId -> identifier_taken.
    let png_b64 = base64_simd::STANDARD.encode_to_string(tiny_png_bytes());
    let op_bad_media_id = ChangeSet {
        model_version: MODEL_VERSION,
        edits: vec![Edit::MediaPut {
            id: colliding_id,
            filename: "x.png".into(),
            mime: "image/png".into(),
            data: png_b64,
            link: None,
        }],
    };
    let err_media_taken = apply(
        &after_s1_alloc.doc,
        &serde_json::to_string(&op_bad_media_id).unwrap(),
        &serde_json::to_string(&vec![after_s1_alloc.op]).unwrap(),
        None,
    )
    .unwrap_err();
    assert_eq!(
        err_media_taken,
        ApplyError::Conflict(Conflict::IdentifierTaken)
    );

    // 6. Concurrent deck.set on the same field -> field_changed.
    let deck_op_a = ChangeSet {
        model_version: MODEL_VERSION,
        edits: vec![Edit::DeckSet {
            field: DeckField::FirstSlideNumber,
            value: json!(2),
        }],
    };
    let deck_op_b = ChangeSet {
        model_version: MODEL_VERSION,
        edits: vec![Edit::DeckSet {
            field: DeckField::FirstSlideNumber,
            value: json!(5),
        }],
    };
    let after_deck_a = apply(
        &two_slides,
        &serde_json::to_string(&deck_op_a).unwrap(),
        "[]",
        None,
    )
    .unwrap();
    let err_field = apply(
        &after_deck_a.doc,
        &serde_json::to_string(&deck_op_b).unwrap(),
        &serde_json::to_string(&vec![after_deck_a.op]).unwrap(),
        None,
    )
    .unwrap_err();
    assert_eq!(err_field, ApplyError::Conflict(Conflict::FieldChanged));
    assert_eq!(Conflict::FieldChanged.as_str(), "field_changed");

    // 7. FutureVersion (> 1) and model_version == 0.
    let future_json = r#"{"model_version":2,"edits":[{"kind":"unknown.future.edit"}]}"#;
    assert_eq!(
        apply(&two_slides, future_json, "[]", None).unwrap_err(),
        ApplyError::FutureVersion {
            found: 2,
            supported: MODEL_VERSION
        }
    );
    assert_eq!(
        open(&base_bytes, &format!("[{future_json}]")).unwrap_err(),
        ApplyError::FutureVersion {
            found: 2,
            supported: MODEL_VERSION
        }
    );
    let zero_json = r#"{"model_version":0,"edits":[]}"#;
    assert!(matches!(
        apply(&two_slides, zero_json, "[]", None).unwrap_err(),
        ApplyError::Error(Error::Invalid(_))
    ));

    // 8. > 4 MiB operation rejected, and > 2 MiB picture rejected.
    let huge_padding = "x".repeat(MAX_OP_BYTES + 128);
    let huge_op = format!(r#"{{"model_version":1,"edits":[],"pad":"{huge_padding}"}}"#);
    assert!(matches!(
        apply(&two_slides, &huge_op, "[]", None).unwrap_err(),
        ApplyError::Error(Error::Invalid(_))
    ));

    let oversized_pic = vec![0u8; MAX_PICTURE_BYTES + 1];
    let oversized_b64 = base64_simd::STANDARD.encode_to_string(&oversized_pic);
    let oversized_media_op = ChangeSet {
        model_version: MODEL_VERSION,
        edits: vec![Edit::MediaPut {
            id: 9999,
            filename: "huge.png".into(),
            mime: "image/png".into(),
            data: oversized_b64,
            link: None,
        }],
    };
    assert!(matches!(
        apply(
            &two_slides,
            &serde_json::to_string(&oversized_media_op).unwrap(),
            "[]",
            None
        )
        .unwrap_err(),
        ApplyError::Error(Error::Invalid(_))
    ));
}

#[test]
fn server_side_comment_author_stamping_preserves_existing_threads() {
    let (base, base_bytes) = create_blank("Comments").expect("blank");

    // Client spoofs "Mallory" when adding a comment; server stamps "Alice Chen" ("AC").
    let mut spoofed_pres = base.presentation().clone();
    Arc::make_mut(&mut spoofed_pres.slides[0])
        .comments
        .push(Comment {
            author: "Mallory".into(),
            initials: "M".into(),
            text: "Please check Q3 revenue".into(),
            date: "2026-11-11T09:00:00Z".into(),
            x: 100.0,
            y: 120.0,
            resolved: false,
            replies: vec![],
            shape: None,
        });
    let op_comment = derive(
        &base,
        &PresentationDoc::from_presentation(spoofed_pres, Vec::new()),
    )
    .unwrap()
    .unwrap();

    let applied_alice = apply(
        &base,
        &serde_json::to_string(&op_comment).unwrap(),
        "[]",
        Some("Alice Chen"),
    )
    .unwrap();
    let c0 = &applied_alice.doc.presentation().slides[0].comments[0];
    assert_eq!(c0.author, "Alice Chen");
    assert_eq!(c0.initials, "AC");

    // Replaying `applied_alice.op` produces identical stamped state.
    let replayed = open(
        &base_bytes,
        &serde_json::to_string(&vec![applied_alice.op]).unwrap(),
    )
    .unwrap();
    assert_eq!(
        replayed.presentation().slides[0].comments[0].author,
        "Alice Chen"
    );

    // Bob replies and tries to spoof Alice's parent author -> parent stays Alice Chen, reply becomes Bob Lee ("BL").
    let mut reply_pres = applied_alice.doc.presentation().clone();
    {
        let parent = &mut Arc::make_mut(&mut reply_pres.slides[0]).comments[0];
        parent.author = "Eve".into();
        parent.resolved = true;
        parent.replies.push(Comment {
            author: "Eve".into(),
            initials: "E".into(),
            text: "Verified against ledger".into(),
            date: "2026-11-11T09:05:00Z".into(),
            ..Comment::default()
        });
    }
    let op_reply = derive(
        &applied_alice.doc,
        &PresentationDoc::from_presentation(reply_pres, Vec::new()),
    )
    .unwrap()
    .unwrap();

    let applied_bob = apply(
        &applied_alice.doc,
        &serde_json::to_string(&op_reply).unwrap(),
        "[]",
        Some("Bob Lee"),
    )
    .unwrap();
    let thread = &applied_bob.doc.presentation().slides[0].comments[0];
    assert_eq!(thread.author, "Alice Chen");
    assert_eq!(thread.initials, "AC");
    assert!(thread.resolved);
    assert_eq!(thread.replies.len(), 1);
    assert_eq!(thread.replies[0].author, "Bob Lee");
    assert_eq!(thread.replies[0].initials, "BL");
}

#[test]
fn inspect_commands_apply_commands_confinement_find_render_and_pdf() {
    init_site_fonts(&[]);
    let (base, _) = create_blank("Product Launch").expect("blank");

    // 1. Safe commands catalogue excludes file.*, export.*, print.*, recovery.*, review.addToDictionary.
    let all_cmds = commands(None);
    let arr = all_cmds.as_array().expect("commands array");
    assert!(!arr.is_empty());
    for item in arr {
        let id = item["id"].as_str().unwrap();
        assert!(!id.starts_with("file."));
        assert!(!id.starts_with("export."));
        assert!(!id.starts_with("import."));
        assert!(!id.starts_with("print."));
        assert!(!id.starts_with("app."));
        assert!(!id.starts_with("window."));
        assert!(!id.starts_with("recovery."));
        assert!(!id.starts_with("macro."));
        assert_ne!(id, "review.addToDictionary");
    }
    let slide_cmds = commands(Some("slide.new"));
    assert!(
        slide_cmds
            .as_array()
            .unwrap()
            .iter()
            .any(|c| c["id"] == "slide.new")
    );

    // 2. apply_commands rejects blocked commands and empty batches.
    assert!(apply_commands(&base, "[]", "Agent").is_err());
    assert!(
        apply_commands(
            &base,
            &json!([{"command": "file.save", "params": {"path": "/tmp/nope.pptx"}}]).to_string(),
            "Agent"
        )
        .is_err()
    );

    // 3. apply_commands confines host file reads: reading an existing host temp file via `insert.picture` `path` MUST fail!
    let secret_path = std::env::temp_dir().join(format!(
        "ankole-pres-secret-test-{}.png",
        std::process::id()
    ));
    std::fs::write(&secret_path, tiny_png_bytes()).expect("write temp png");
    let confine_res = apply_commands(
        &base,
        &json!([{
            "command": "insert.picture",
            "params": {"path": secret_path.to_string_lossy()}
        }])
        .to_string(),
        "Agent",
    );
    let _ = std::fs::remove_file(&secret_path);
    assert!(
        confine_res.is_err(),
        "confined apply_commands must refuse reading host files outside its empty temp root"
    );

    // 4. Failed batch atomicity: if command 2 fails, command 1 does not commit.
    let atomic_err = apply_commands(
        &base,
        &json!([
            {"command": "slide.new", "params": {"title": "Should Roll Back"}},
            {"command": "nonexistent.command", "params": {}}
        ])
        .to_string(),
        "Agent",
    );
    assert!(atomic_err.is_err());
    assert_eq!(base.presentation().slides.len(), 1);

    // 5. Valid Agent batch adding shapes, a table, a second slide, notes, and a comment.
    let (populated, cs_opt, results) = apply_commands(
        &base,
        &json!([
            {"command": "insert.textBox", "params": {"rect": [50.0, 60.0, 400.0, 80.0], "text": "Ankole Keynote Alpha"}},
            {"command": "insert.table", "params": {"rows": 2, "cols": 2, "rect": [50.0, 180.0, 300.0, 120.0]}},
            {"command": "slide.notes", "params": {"text": "Speaker cue: mention Keynote"}},
            {"command": "comment.add", "params": {"text": "Ready for review"}},
            {"command": "slide.new", "params": {"title": "Roadmap Beta", "body": "Ship Presentation Pages"}}
        ])
        .to_string(),
        "Agent Bot",
    )
    .expect("valid batch");
    assert!(cs_opt.is_some());
    assert_eq!(results.len(), 5);
    assert_eq!(
        populated.presentation().slides[0].comments[0].author,
        "Agent Bot"
    );

    // Also add text inside a group shape and table cell to test `find` across groups and tables.
    let mut enriched = populated.presentation().clone();
    {
        let child_id = enriched.alloc_id().unwrap();
        let group_id = enriched.alloc_id().unwrap();
        let slide0 = Arc::make_mut(&mut enriched.slides[0]);
        for sh in &mut slide0.shapes {
            if let ShapeKind::Table(tbl) = &mut sh.kind {
                tbl.rows[0].cells[1].text = TextBody::from_text("MatrixCellTarget");
            }
        }
        slide0.shapes.push(Shape {
            id: ShapeId(group_id),
            name: "Cluster".into(),
            kind: ShapeKind::Group {
                children: vec![Shape {
                    id: ShapeId(child_id),
                    name: "NestedBadge".into(),
                    kind: ShapeKind::Shape,
                    text: Some(TextBody::from_text("GroupedToken")),
                    ..Shape::default()
                }],
                child: Xfrm {
                    x: 0.0,
                    y: 0.0,
                    w: 100.0,
                    h: 50.0,
                    ..Xfrm::default()
                },
            },
            ..Shape::default()
        });
    }
    let rich_doc = PresentationDoc::from_presentation(enriched, Vec::new());

    // 6. `find` across shapes, tables, groups, and speaker notes.
    let keynote_hits = find(&rich_doc, "keynote", false);
    assert_eq!(keynote_hits.len(), 2);
    assert!(
        keynote_hits
            .iter()
            .any(|h| !h.in_notes && h.shape_id.is_some())
    );
    assert!(
        keynote_hits
            .iter()
            .any(|h| h.in_notes && h.shape_id.is_none())
    );
    assert_eq!(find(&rich_doc, "keynote", true).len(), 0);
    assert_eq!(find(&rich_doc, "Keynote", true).len(), 2);
    assert_eq!(find(&rich_doc, "MatrixCellTarget", true).len(), 1);
    assert_eq!(find(&rich_doc, "GroupedToken", true).len(), 1);

    // 7. `inspect` full and filtered.
    let full_info = inspect(&rich_doc, "{}").expect("inspect all");
    assert_eq!(full_info["title"], "Product Launch");
    assert_eq!(full_info["slide_count"], 2);
    assert_eq!(full_info["slides"].as_array().unwrap().len(), 2);
    assert_eq!(full_info["slides"][0]["comments_count"], 1);

    let filtered = inspect(&rich_doc, r#"{"from_slide":1,"to_slide":1}"#).expect("inspect slide 1");
    let filtered_slides = filtered["slides"].as_array().unwrap();
    assert_eq!(filtered_slides.len(), 1);
    assert_eq!(filtered_slides[0]["index"], 1);
    assert_eq!(filtered_slides[0]["title"], "Roadmap Beta");

    // 8. `render_slide_png`, `render_slide_rgba`, and `export_pdf`.
    let (w, h, rgba) = render_slide_rgba(&rich_doc, 0, 0.5).expect("render rgba");
    assert!(w > 0 && h > 0);
    assert_eq!(rgba.len(), (w * h * 4) as usize);
    assert!(render_slide_rgba(&rich_doc, 99, 1.0).is_err());
    assert!(render_slide_rgba(&rich_doc, 0, 0.0).is_err());

    let png_out = render_slide_png(&rich_doc, 0, 0.5).expect("render png");
    assert!(png_out.starts_with(&[0x89, b'P', b'N', b'G']));

    let pdf_out = export_pdf(&rich_doc).expect("export pdf");
    assert!(pdf_out.starts_with(b"%PDF-"));
}

#[test]
fn editor_state_undo_redo_and_remote_rebase_workflow() {
    init_site_fonts(&[]);
    let (_, initial_bytes) = create_blank("Interactive Deck").expect("blank bytes");
    let mut editor = EditorState::open(&initial_bytes, "[]").expect("open blank in editor");
    assert_eq!(editor.active_slide(), 0);
    assert!(!editor.has_local_changes());

    let slides: Value = serde_json::from_str(&editor.slides_info().unwrap()).unwrap();
    let slide1_id = slides[0]["slide_id"].as_u64().unwrap() as u32;

    // Local notes edit -> commit -> personal undo -> redo.
    editor
        .set_slide_notes(slide1_id, "First draft note")
        .expect("set notes");
    assert!(editor.has_local_changes());
    let op1_json = editor
        .commit_local_step()
        .expect("commit step")
        .expect("op1 emitted");
    assert!(!editor.has_local_changes());

    // Server ACKs our own op1: Undo stack must survive our own ACK!
    let ack_report: Value =
        serde_json::from_str(&editor.apply_remote(&format!("[{op1_json}]"), "[]").unwrap())
            .unwrap();
    assert_eq!(ack_report["dropped_pending"], 0);
    assert_eq!(ack_report["draft_conflict"], false);

    let sel_after_ack: Value = serde_json::from_str(&editor.selection_info().unwrap()).unwrap();
    assert_eq!(sel_after_ack["can_undo"], true);
    assert_eq!(sel_after_ack["notes"], "First draft note");

    // Undo restores empty notes and emits a `slide.put` ChangeSet.
    let undo_op_json = editor.undo().expect("undo").expect("undo op");
    let sel_after_undo: Value = serde_json::from_str(&editor.selection_info().unwrap()).unwrap();
    assert_eq!(sel_after_undo["notes"], "");
    assert_eq!(sel_after_undo["can_redo"], true);

    // Redo puts "First draft note" back and emits a `slide.put` ChangeSet.
    let redo_op_json = editor.redo().expect("redo").expect("redo op");
    let sel_after_redo: Value = serde_json::from_str(&editor.selection_info().unwrap()).unwrap();
    assert_eq!(sel_after_redo["notes"], "First draft note");
    assert_eq!(sel_after_redo["can_undo"], true);

    // Acknowledge both undo and redo ops on the server.
    let _ = editor
        .apply_remote(&format!("[{undo_op_json},{redo_op_json}]"), "[]")
        .unwrap();
    let sel_still_undoable: Value =
        serde_json::from_str(&editor.selection_info().unwrap()).unwrap();
    assert_eq!(sel_still_undoable["can_undo"], true);

    // Foreign remote edit touching the same slide clears local Undo stack and conflicts with an uncommitted draft!
    editor
        .set_slide_notes(slide1_id, "Uncommitted local draft")
        .unwrap();
    let remote_doc = open(
        &initial_bytes,
        &format!("[{op1_json},{undo_op_json},{redo_op_json}]"),
    )
    .unwrap();
    let mut foreign_pres = remote_doc.presentation().clone();
    Arc::make_mut(&mut foreign_pres.slides[0]).notes = TextBody::from_text("Collaborator override");
    let foreign_cs = derive(
        &remote_doc,
        &PresentationDoc::from_presentation(foreign_pres, Vec::new()),
    )
    .unwrap()
    .unwrap();
    let foreign_json = serde_json::to_string(&vec![foreign_cs]).unwrap();

    let conflict_report: Value =
        serde_json::from_str(&editor.apply_remote(&foreign_json, "[]").unwrap()).unwrap();
    assert_eq!(conflict_report["draft_conflict"], true);
    assert_eq!(conflict_report["conflict_reason"], "slide_changed");

    let sel_after_conflict: Value =
        serde_json::from_str(&editor.selection_info().unwrap()).unwrap();
    assert_eq!(sel_after_conflict["can_undo"], false);
    assert_eq!(sel_after_conflict["notes"], "Collaborator override");

    // Verify pointer, key, selected_text, pixel size, embedded fonts, and deck-wide undo clearing.
    let px = editor.slide_pixel_size(1.0);
    assert_eq!(px.len(), 2);
    assert!(px[0] > 0 && px[1] > 0);

    editor
        .execute_command(
            "insert.textBox",
            r#"{"rect":[60,60,240,60],"text":"Selectable Hello"}"#,
        )
        .expect("insert textBox");
    assert_eq!(editor.selected_text(), "Selectable Hello");
    editor.key_event("Enter", "{}").unwrap();
    editor.execute_command("text.selectAll", "{}").unwrap();
    let selection: Value = serde_json::from_str(&editor.selection_info().unwrap()).unwrap();
    let quads = selection["text_quads"].as_array().unwrap();
    assert!(!quads.is_empty());
    assert_eq!(quads[0].as_array().unwrap().len(), 4);
    let _ = editor.commit_local_step().unwrap();

    // Deck-wide command (`slide.new`) clears personal Undo stack.
    editor
        .execute_command("slide.new", r#"{"title":"Second Slide"}"#)
        .expect("slide.new");
    let sel_after_new_slide: Value =
        serde_json::from_str(&editor.selection_info().unwrap()).unwrap();
    assert_eq!(sel_after_new_slide["can_undo"], false);
    assert_eq!(editor.active_slide(), 1);
    editor.set_active_slide(0).expect("switch back to slide 0");
    assert_eq!(editor.active_slide(), 0);
}

#[test]
fn embedded_font_loading_stays_isolated_to_editor() {
    let (base, _) = create_blank("Fonts").expect("blank");
    let mut pres = base.presentation().clone();
    let fid = pres.alloc_id().unwrap();
    pres.media.push(MediaItem {
        id: MediaId(fid),
        name: "font1.fntdata".into(),
        content_type: "application/x-fontdata".into(),
        data: Arc::new(vec![0u8; 32]),
        link: None,
    });
    let doc = PresentationDoc::from_presentation(pres, Vec::new());
    let pptx = export_pptx(&doc).unwrap();
    let editor = EditorState::open(&pptx, "[]").unwrap();
    // Invalid dummy font bytes safely return 0 faces without panicking.
    assert_eq!(editor.load_embedded_fonts(), 0);
    assert_eq!(EditorState::add_font(&[0u8; 16]), 0);
    let subst: Value = serde_json::from_str(&editor.substituted_fonts().unwrap()).unwrap();
    assert!(subst.is_array());
    let warns: Value = serde_json::from_str(&editor.warnings().unwrap()).unwrap();
    assert_eq!(warns, json!([]));
}

#[test]
fn editor_pointer_keyboard_pending_conflict_and_reset() {
    let (_, initial_bytes) = create_blank("Gestures & Pending").expect("blank");
    let mut editor = EditorState::open(&initial_bytes, "[]").expect("open");

    // Draw a rectangle via pointer tool, then enter text via Enter + character keys.
    editor
        .pointer_event(r#"{"kind":"down","x":100,"y":100,"tool":{"kind":"shape","preset":"rect"}}"#)
        .expect("pointer down");
    editor
        .pointer_event(r#"{"kind":"drag","x":300,"y":220}"#)
        .expect("pointer drag");
    editor
        .pointer_event(r#"{"kind":"up","x":300,"y":220}"#)
        .expect("pointer up");

    // Blocked shortcut (Cmd+O / Cmd+Z) is not executed inside `Session::key`.
    let blocked_key: Value =
        serde_json::from_str(&editor.key_event("o", r#"{"cmd":true}"#).unwrap()).unwrap();
    assert_eq!(blocked_key["handled"], false);

    // Enter starts text editing on the selected rectangle; typing coalesces into one Undo snapshot.
    let _ = editor.key_event("Enter", "{}").expect("enter text edit");
    let _ = editor.key_event("H", "{}").expect("type H");
    let _ = editor.key_event("i", "{}").expect("type i");
    let _ = editor.key_event("Escape", "{}").expect("exit text edit");

    let hits: Value = serde_json::from_str(&editor.find("Hi", true).unwrap()).unwrap();
    assert_eq!(hits.as_array().unwrap().len(), 1);

    // Commit pending op locally (without server ACK yet), then collide with a foreign remote op.
    let pending_op = editor.commit_local_step().unwrap().unwrap();

    let remote_base = open(&initial_bytes, "[]").unwrap();
    let mut foreign_pres = remote_base.presentation().clone();
    Arc::make_mut(&mut foreign_pres.slides[0]).notes = TextBody::from_text("Remote wins");
    let foreign_op = derive(
        &remote_base,
        &PresentationDoc::from_presentation(foreign_pres, Vec::new()),
    )
    .unwrap()
    .unwrap();

    let rebase_report: Value = serde_json::from_str(
        &editor
            .apply_remote(
                &serde_json::to_string(&vec![foreign_op]).unwrap(),
                &format!("[{pending_op}]"),
            )
            .unwrap(),
    )
    .unwrap();
    assert_eq!(rebase_report["dropped_pending"], 1);
    assert_eq!(rebase_report["draft_conflict"], false);
    assert_eq!(rebase_report["conflict_reason"], "slide_changed");

    // Draft a new local change, then reset_to_confirmed discards it cleanly.
    let slides: Value = serde_json::from_str(&editor.slides_info().unwrap()).unwrap();
    let s1_id = slides[0]["slide_id"].as_u64().unwrap() as u32;
    editor.set_slide_notes(s1_id, "Discard me").unwrap();
    assert!(editor.has_local_changes());
    editor.reset_to_confirmed();
    assert!(!editor.has_local_changes());
    let sel: Value = serde_json::from_str(&editor.selection_info().unwrap()).unwrap();
    assert_eq!(sel["notes"], "Remote wins");
}
