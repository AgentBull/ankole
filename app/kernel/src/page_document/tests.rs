use super::*;
use serde_json::{Value, json};

fn corpus() -> Value {
    serde_json::from_str(include_str!(
        "../../../../libs/ankole-editor/corpus/rust/index.json"
    ))
    .unwrap()
}

#[test]
fn principal_rename_decodes_xml_entities_and_preserves_other_attributes_and_text() {
    let source = "<page><p>o'connor&amp;co@example.com<mention label=\"Owner\" principal=\"o'connor&amp;co@example.com\" /><mention page=\"o'connor&amp;co@example.com\" /></p></page>";
    let renamed =
        rename_principal(source, "o'connor&co@example.com", "new'&co@example.com").unwrap();
    assert_eq!(
        renamed.xml,
        source.replacen(
            "principal=\"o'connor&amp;co@example.com\"",
            "principal=\"new'&amp;co@example.com\"",
            1
        )
    );
}

#[test]
fn kept_style_ignores_css_comments() {
    for (style, kept) in [
        (
            "color:red; /* note */ background-color:blue; margin:0",
            "color:red; background-color:blue",
        ),
        (
            "color:red; /* note */ background-color:blue",
            "color:red; /* note */ background-color:blue",
        ),
        ("color:red; /* open", "color:red"),
        ("/* only */ margin:0", ""),
    ] {
        assert_eq!(tree::kept_style(style), kept, "{style}");
    }
}

#[test]
fn span_marks_follow_xml_attribute_limits() {
    for name in ["ColSpan", "RowSpan"] {
        for value in [0, 10_000] {
            assert!(document_schema::validate_mark(name, &json!(value)).is_err());
        }
        for value in [1, 9999] {
            assert!(document_schema::validate_mark(name, &json!(value)).is_ok());
        }
    }
}

#[test]
fn resource_marks_follow_xml_attribute_limits() {
    for (name, valid, invalid) in [
        ("Resource_kind", "video", "audio"),
        ("Resource_view", "preview", "grid"),
        ("EmbedHeight", "640", "120"),
    ] {
        assert!(document_schema::validate_mark(name, &json!(valid)).is_ok());
        assert!(document_schema::validate_mark(name, &json!(invalid)).is_err());
        assert!(document_schema::validate_mark(name, &json!(42)).is_err());
    }
    let resized = r#"<page><embed height="640" href="https://figma.com/file/abc" title="Design Spec" /></page>"#;
    let plain = r#"<page><embed href="https://figma.com/file/abc" title="Design Spec" /></page>"#;
    assert_eq!(validate(resized).unwrap().xml, resized);
    assert!(
        validate(r#"<page><embed height="120" href="https://figma.com/file/abc" /></page>"#)
            .is_err()
    );
    assert!(
        validate(r#"<page><embed height="1601" href="https://figma.com/file/abc" /></page>"#)
            .is_err()
    );
    let delta = diff(plain, resized).unwrap();
    assert_eq!(apply(plain, &delta.to_string()).unwrap().xml, resized);
}

#[test]
fn shared_xml_and_documents_match_the_editor() {
    for sample in corpus()["xml"].as_array().unwrap() {
        let name = sample["name"].as_str().unwrap();
        let root =
            tree::parse(sample["xml"].as_str().unwrap()).unwrap_or_else(|e| panic!("{name}: {e}"));
        let doc =
            document::page_document_normalized(&root).unwrap_or_else(|e| panic!("{name}: {e}"));
        assert_eq!(doc.json(), sample["document"], "{name} document");
        let back = document::read_tree(&doc).unwrap_or_else(|e| panic!("{name}: {e}"));
        assert_eq!(
            tree::print(&back),
            sample["canonicalXml"].as_str().unwrap(),
            "{name} XML"
        );
    }
}
#[test]
fn shared_invalid_xml_is_rejected() {
    for sample in corpus()["invalid"].as_array().unwrap() {
        assert!(
            validate(sample["xml"].as_str().unwrap()).is_err(),
            "{}",
            sample["name"]
        );
    }
}
#[test]
fn continuous_batches_match_both_xml_and_the_client_memory() {
    for sample in corpus()["edits"].as_array().unwrap() {
        let name = sample["name"].as_str().unwrap();
        let mut xml = sample["initialXml"].as_str().unwrap().to_owned();
        let batches = sample["batches"].as_array().unwrap();
        let steps = sample["steps"].as_array().unwrap();
        assert!(batches.len() > 1);
        for (index, (batch, step)) in batches.iter().zip(steps).enumerate() {
            let result = apply(&xml, &batch["changes"].to_string())
                .unwrap_or_else(|e| panic!("{name} batch {index}: {e}; {}", batch["changes"]));
            assert_eq!(
                result.xml,
                step["xml"].as_str().unwrap(),
                "{name} batch {index} XML"
            );
            let doc =
                document::page_document_normalized(&tree::parse(&result.xml).unwrap()).unwrap();
            assert_eq!(
                doc.json(),
                step["document"],
                "{name} batch {index} in-memory document"
            );
            xml = result.xml;
        }
    }
}
#[test]
fn all_three_limits_accept_the_boundary_and_reject_one_over() {
    for sample in corpus()["boundaries"].as_array().unwrap() {
        let source: String = sample["parts"]
            .as_array()
            .unwrap()
            .iter()
            .map(|p| {
                p["text"]
                    .as_str()
                    .unwrap()
                    .repeat(p["count"].as_u64().unwrap() as usize)
            })
            .collect();
        let parsed = tree::parse(&source);
        assert_eq!(
            parsed.is_ok(),
            sample["error"].is_null(),
            "{}: {:?}",
            sample["name"],
            parsed.err()
        );
    }
}

#[test]
fn changes_json_depth_is_bounded_independently_of_document_depth() {
    std::thread::Builder::new()
        .stack_size(8 * 1024 * 1024)
        .spawn(|| {
            let source = format!("{}null{}", "[".repeat(512), "]".repeat(512));
            assert!(decode_changes(&source).is_ok());
            assert!(
                decode_changes(&format!("[{source}]"))
                    .unwrap_err()
                    .contains("JSON depth")
            );
            assert!(decode_changes(&format!("{source} true")).is_err());
            assert!(decode_changes(r#"["escaped \\\" [ { "]"#).is_ok());
            assert!(decode_changes("[}").is_err());
        })
        .unwrap()
        .join()
        .unwrap();
}

#[test]
fn maximum_depth_diff_crosses_json_before_application() {
    std::thread::Builder::new()
        .stack_size(8 * 1024 * 1024)
        .spawn(|| {
            let target = format!(
                "<page>{}<p>a</p>{}</page>",
                "<blockquote>".repeat(126),
                "</blockquote>".repeat(126)
            );
            let changes = diff("<page />", &target).unwrap().to_string();
            assert_eq!(apply("<page />", &changes).unwrap().xml, target);
        })
        .unwrap()
        .join()
        .unwrap();
}
#[test]
fn changes_reject_invalid_shapes_and_unprepared_normalization() {
    let xml = "<page><p>a b</p></page>";
    assert!(apply(xml, "[9999]").is_err());
    assert!(apply(xml, "[5]").is_ok());
    assert!(
        apply(
            xml,
            &json!([1,[2,[{"add":"Strong","value":null}]],2]).to_string()
        )
        .is_err()
    );
    assert!(
        apply(
            xml,
            &json!([[5,[{"type":"Paragraph","content":[{"type":"Table","content":[]}]}]]])
                .to_string()
        )
        .is_err()
    );
}
#[test]
fn derives_search_text() {
    let result=validate(r#"<page><h1>标题</h1><p><a href="ankole:page/linked">正文</a></p><embed ref="child" /></page>"#).unwrap();
    assert_eq!(result.plain_text, "标题\n正文");

    let rich = validate(
        r#"<page><h1>参考资料</h1><embed href="https://docs.stripe.com/webhooks" view="card" title="Stripe Webhooks" description="Signature verification guide" /><media src="ankole:attachment/raw-uuid" title="架构总览图.png" description="2026 Q4 拓扑" kind="image" /><embed href="https://figma.com/file/abc" title="Design Spec" /><p>说明<img src="https://example.com/a.png" alt="流程图" /></p></page>"#,
    )
    .unwrap();
    assert_eq!(
        rich.plain_text,
        "参考资料\nStripe Webhooks\nSignature verification guide\nhttps://docs.stripe.com/webhooks\n架构总览图.png\n2026 Q4 拓扑\nDesign Spec\nhttps://figma.com/file/abc\n说明 流程图"
    );
}

#[test]
#[ignore = "run the editor test:rust command to generate shared property cases"]
fn generated_continuous_batches() {
    let path = std::env::var("ANKOLE_PAGE_PROPERTY_CASES").expect("generated corpus path");
    let cases: Value = serde_json::from_str(&std::fs::read_to_string(path).unwrap()).unwrap();
    for sample in cases.as_array().unwrap() {
        let mut xml = sample["initialXml"].as_str().unwrap().to_owned();
        for (index, (batch, step)) in sample["batches"]
            .as_array()
            .unwrap()
            .iter()
            .zip(sample["steps"].as_array().unwrap())
            .enumerate()
        {
            let result = apply(&xml, &batch["changes"].to_string())
                .unwrap_or_else(|error| panic!("{} batch {index}: {error}", sample["name"]));
            assert_eq!(
                result.xml,
                step["xml"].as_str().unwrap(),
                "{} batch {index}",
                sample["name"]
            );
            let doc =
                document::page_document_normalized(&tree::parse(&result.xml).unwrap()).unwrap();
            assert_eq!(
                doc.json(),
                step["document"],
                "{} batch {index}",
                sample["name"]
            );
            xml = result.xml;
        }
    }
}

#[test]
fn insertions_stop_at_the_document_budget_before_building_the_tree() {
    let too_many: Vec<_> = (0..tree::NODE_LIMIT + 1)
        .map(|_| json!({"type":"Paragraph", "content": []}))
        .collect();
    let doc = document::page_document_normalized(&tree::parse("<page />").unwrap()).unwrap();
    assert!(
        changeset::apply(
            &doc,
            &json!([[doc.content.as_ref().unwrap().len() * 2, too_many]])
        )
        .unwrap_err()
        .contains("node or depth limit")
    );
}

#[test]
fn surplus_close_tokens_are_rejected_while_reading_the_batch() {
    assert!(
        apply("<page />", &json!([[2, [".", ".", "."]]]).to_string())
            .unwrap_err()
            .contains("surplus close")
    );
}

#[test]
fn server_diff_preserves_paragraphs_and_utf16_selection_offsets() {
    let old = "<page><p>Before</p><p>需求😀尾</p><p>After</p></page>";
    let new = "<page><p>Before</p><p>需求😁尾</p><p>After</p><p>API</p></page>";
    let changes = diff(old, new).unwrap();
    assert_eq!(changes[0], 11); // Whole first paragraph, then paragraph open and two CJK units.
    assert_eq!(changes[1], json!([2, [{"type": "Text", "param": "😁"}]]));
    assert_eq!(
        apply(old, &changes.to_string()).unwrap().xml,
        validate(new).unwrap().xml
    );
    assert_eq!(diff(new, new).unwrap(), json!([]));
}

#[test]
fn server_draft_rebase_deltas_match_the_browser_corpus() {
    let samples: Value = serde_json::from_str(include_str!(
        "../../../../libs/ankole-editor/corpus/rust/draft-rebase.json"
    ))
    .unwrap();
    for sample in samples.as_array().unwrap() {
        let before = sample["before"].as_str().unwrap();
        let after = sample["after"].as_str().unwrap();
        assert_eq!(diff(before, after).unwrap(), sample["changes"]);
        assert_eq!(
            apply(before, &sample["changes"].to_string()).unwrap().xml,
            after
        );
    }
}

#[test]
fn server_diff_reproduces_every_pair_of_corpus_documents() {
    let corpus = corpus();
    let sources: Vec<&str> = corpus["xml"]
        .as_array()
        .unwrap()
        .iter()
        .map(|sample| sample["xml"].as_str().unwrap())
        .collect();
    for old in &sources {
        for new in &sources {
            let changes = diff(old, new).unwrap_or_else(|error| panic!("{old} -> {new}: {error}"));
            // Empty changes are the idempotent server result, not an apply batch.
            if changes == json!([]) {
                assert_eq!(validate(old).unwrap().xml, validate(new).unwrap().xml);
            } else {
                assert_eq!(
                    apply(old, &changes.to_string()).unwrap().xml,
                    validate(new).unwrap().xml
                );
            }
        }
    }
}

#[test]
fn table_presentation_round_trips_through_the_production_document_codec() {
    let xml = r##"<page><table layout="full" widths="120,240"><tr><th background="#deedfc"><p>A</p></th><th><p>B</p></th></tr><tr><td colspan="2"><p>C</p></td></tr></table></page>"##;
    let root = tree::parse(xml).unwrap();
    let doc = document::page_document_normalized(&root).unwrap();
    assert_eq!(tree::print(&document::read_tree(&doc).unwrap()), xml);
    let plain = r#"<page><table><tr><th><p>A</p></th><th><p>B</p></th></tr><tr><td colspan="2"><p>C</p></td></tr></table></page>"#;
    let changes = diff(plain, xml).unwrap();
    assert_eq!(apply(plain, &changes.to_string()).unwrap().xml, xml);
    let reverse = diff(xml, plain).unwrap();
    assert_eq!(apply(xml, &reverse.to_string()).unwrap().xml, plain);
    for (name, valid, invalid) in [
        ("TableWidths", "25,9999", "0,100"),
        ("TableLayout", "full", "wide"),
        ("CellBackground", "#DdeeFF", "red"),
    ] {
        assert!(document_schema::validate_mark(name, &json!(valid)).is_ok());
        assert!(document_schema::validate_mark(name, &json!(invalid)).is_err());
    }
}

#[test]
fn identity_changes_retains_the_normalized_document_span() {
    assert_eq!(identity_changes("<page />").unwrap(), "[2]");
    let empty_doc = document::page_document_normalized(&tree::parse("<page />").unwrap()).unwrap();
    assert_eq!(
        changeset::apply(&empty_doc, &json!([2])).unwrap(),
        empty_doc
    );
    assert_eq!(apply("<page />", "[2]").unwrap().xml, "<page />");

    let rich = concat!(
        "<page>",
        "<h1>Heading 🙂🧪</h1>",
        r#"<p>Lead <strong>bold</strong> <a href="https://example.com" title="Link">anchor</a> "#,
        r#"<img alt="diagram" src="ankole:asset/pic.png" /> and <mention page="019a2b00-0000-7000-8000-000000000001" /></p>"#,
        r##"<table layout="full" widths="160,240"><tr><th background="#deedfc"><p>Col 1</p></th><th><p>Col 2 🧪</p></th></tr>"##,
        r#"<tr><td><p>Cell A</p></td><td><p>Cell B 🙂</p></td></tr></table>"#,
        r#"<embed href="https://example.com/embed" title="Frame" />"#,
        r#"<math>E = mc^2</math>"#,
        "</page>"
    );
    let identity_str = identity_changes(rich).unwrap();
    let identity: Value = serde_json::from_str(&identity_str).unwrap();
    let span = identity.as_array().unwrap()[0].as_u64().unwrap();
    assert!(span > 2);

    let normalized = document::page_document_normalized(&tree::parse(rich).unwrap()).unwrap();
    assert_eq!(
        changeset::apply(&normalized, &identity).unwrap(),
        normalized
    );
    assert_eq!(
        apply(rich, &identity_str).unwrap().xml,
        validate(rich).unwrap().xml
    );
    assert!(identity_changes("<page><p><table /></p></page>").is_err());
}

#[test]
fn read_tree_strips_invalid_xml10_characters_across_all_nodes_marks_and_frozen_elements() {
    let dirty = "\u{0000}\u{000b}\u{000c}\u{fffe}";
    let doc = document_schema::DocNode::from_json(&json!({
        "type": "Doc",
        "content": [
            {
                "type": "Math",
                "param": format!("x + {dirty}y"),
                "marks": {
                    "Attrs": [["data-note", format!("m{dirty}1")]]
                }
            },
            {
                "type": "Paragraph",
                "content": [
                    {
                        "type": "Text",
                        "param": format!("hello{dirty}"),
                        "marks": {
                            "Link": [
                                ["href", format!("https://example.com/{dirty}path")],
                                ["title", format!("ti{dirty}tle")]
                            ],
                            "TextStyle": format!("color: red;{dirty}")
                        }
                    },
                    {
                        "type": "Image",
                        "param": format!("https://example.com/{dirty}img.png"),
                        "marks": {
                            "ImageAlt": format!("al{dirty}t"),
                            "ImageTitle": format!("im{dirty}g"),
                            "Attrs": [["data-id", format!("i{dirty}d")]]
                        }
                    },
                    {
                        "type": "LineBreak",
                        "marks": {
                            "Attrs": [["data-br", format!("b{dirty}r")]]
                        }
                    },
                    {
                        "type": "InlineElement",
                        "param": {
                            "name": "badge",
                            "attrs": [["label", format!("in{dirty}line")]],
                            "children": [format!("chip{dirty}")]
                        }
                    }
                ]
            },
            {
                "type": "Callout",
                "marks": {
                    "CalloutTone": "info",
                    "CalloutIcon": format!("💡{dirty}")
                },
                "content": [
                    {
                        "type": "Table",
                        "content": [
                            {
                                "type": "TableRow",
                                "content": [
                                    {
                                        "type": "Cell",
                                        "content": [
                                            {
                                                "type": "Paragraph",
                                                "content": [{"type": "Text", "param": format!("cell{dirty}")}]
                                            }
                                        ]
                                    }
                                ]
                            }
                        ]
                    }
                ]
            },
            {
                "type": "UnknownBlock",
                "param": {
                    "name": "custom-widget",
                    "attrs": [["config", format!("a{dirty}b")]],
                    "children": [
                        format!("body{dirty}"),
                        {
                            "name": "nested-part",
                            "attrs": [["k", format!("v{dirty}")]],
                            "children": [format!("deep{dirty}")]
                        }
                    ]
                }
            }
        ]
    }))
    .unwrap();

    let element_tree = document::read_tree(&doc).unwrap();
    let xml = tree::print(&element_tree);
    assert!(!xml.chars().any(|ch| !tree::valid_character(ch)));
    let reparsed = tree::parse(&xml).unwrap();
    assert_eq!(tree::print(&reparsed), xml);
    assert!(xml.contains("<math data-note=\"m1\">x + y</math>"));
    assert!(
        xml.contains(
            r#"<span style="color: red;"><a href="https://example.com/path" title="title">hello</a></span>"#
        ),
        "xml: {xml}"
    );
    assert!(xml.contains(
        r#"<img alt="alt" data-id="id" src="https://example.com/img.png" title="img" />"#
    ));
    assert!(xml.contains(
        r#"<custom-widget config="ab">body<nested-part k="v">deep</nested-part></custom-widget>"#
    ));
}

#[test]
fn infographic_codec_normalizes_attributes_and_multiline_source() {
    let default_xml = "<page><infographic view=\"both\" theme=\"auto\">infographic list-row\n  data\n    - label A &amp; B</infographic></page>";
    let validated = validate(default_xml).unwrap();
    assert_eq!(
        validated.xml,
        "<page><infographic>infographic list-row\n  data\n    - label A &amp; B</infographic></page>"
    );
    assert_eq!(
        validated.plain_text,
        "infographic list-row\n  data\n    - label A & B"
    );

    let styled_xml = "<page><p>Lead</p><infographic view=\"diagram\" theme=\"dark\">infographic list-row\n  data</infographic><p>Tail</p></page>";
    let styled_page = validate(styled_xml).unwrap();
    assert_eq!(
        styled_page.xml,
        "<page><p>Lead</p><infographic theme=\"dark\" view=\"diagram\">infographic list-row\n  data</infographic><p>Tail</p></page>"
    );
    assert_eq!(
        styled_page.plain_text,
        "Lead\ninfographic list-row\n  data\nTail"
    );

    let root = tree::parse(&styled_page.xml).unwrap();
    let doc = document::page_document_normalized(&root).unwrap();
    assert_eq!(
        doc.content.as_ref().unwrap()[1].json(),
        json!({
            "type": "Infographic",
            "param": null,
            "marks": {
                "InfographicTheme": "dark",
                "InfographicView": "diagram"
            },
            "content": [
                { "type": "Text", "param": "infographic list-row" },
                { "type": "LineBreak" },
                { "type": "Text", "param": "  data" }
            ]
        })
    );
    let roundtrip = document_schema::DocNode::from_json(&doc.json()).unwrap();
    assert_eq!(roundtrip, doc);
    assert_eq!(
        tree::print(&document::read_tree(&roundtrip).unwrap()),
        styled_page.xml
    );

    let empty = validate("<page><infographic></infographic></page>").unwrap();
    assert_eq!(empty.xml, "<page><infographic /></page>");
    let empty_doc = document::page_document_normalized(&tree::parse(&empty.xml).unwrap()).unwrap();
    assert_eq!(
        empty_doc.json(),
        json!({
            "type": "Doc",
            "content": [{ "type": "Infographic", "content": [] }]
        })
    );

    for invalid in [
        "<page><infographic view=\"split\">a</infographic></page>",
        "<page><infographic theme=\"neon\">a</infographic></page>",
        "<page><infographic><strong>a</strong></infographic></page>",
        "<page><infographic>a<br />b</infographic></page>",
    ] {
        assert!(validate(invalid).is_err(), "{invalid}");
    }
    let extra_attr = "<page><infographic data-note=\"1\">a</infographic></page>";
    let extra_doc = document::page_document_normalized(&tree::parse(extra_attr).unwrap()).unwrap();
    assert_eq!(
        tree::print(&document::read_tree(&extra_doc).unwrap()),
        extra_attr
    );
    assert!(document_schema::validate_mark("InfographicView", &json!("diagram")).is_ok());
    assert!(document_schema::validate_mark("InfographicTheme", &json!("dark")).is_ok());
    assert!(document_schema::validate_mark("InfographicView", &json!("split")).is_err());
    assert!(document_schema::validate_mark("InfographicTheme", &json!("neon")).is_err());
    assert!(
        document_schema::DocNode::from_json(&json!({
            "type": "Infographic",
            "param": null,
            "marks": { "MermaidView": "diagram" },
            "content": []
        }))
        .is_err()
    );
    assert!(
        document_schema::DocNode::from_json(&json!({
            "type": "Mermaid",
            "param": null,
            "marks": { "InfographicView": "diagram" },
            "content": []
        }))
        .is_err()
    );
}

#[test]
fn infographic_diff_and_comments_preserve_marks_and_inline_runs() {
    const THREAD: &str = "019a2b00-0000-7000-8000-000000000001";
    let plain =
        "<page><infographic>infographic list-row\n  data\n    - item 1</infographic></page>";
    let styled = "<page><infographic theme=\"dark\" view=\"diagram\">infographic list-row\n  data\n    - item 1</infographic></page>";

    let attr_diff = diff(plain, styled).unwrap();
    assert_eq!(
        attr_diff,
        json!([
            [
                1,
                [
                    { "add": "InfographicTheme", "value": "dark" },
                    { "add": "InfographicView", "value": "diagram" }
                ]
            ],
            41
        ])
    );
    assert_eq!(apply(plain, &attr_diff.to_string()).unwrap().xml, styled);

    let edited = "<page><infographic theme=\"dark\" view=\"diagram\">infographic list-row\n  data\n    - item 2</infographic></page>";
    let line_diff = diff(styled, edited).unwrap();
    assert_eq!(
        line_diff,
        json!([40, [1, [{ "type": "Text", "param": "2" }]], 1])
    );
    assert_eq!(apply(styled, &line_diff.to_string()).unwrap().xml, edited);

    let annotated = annotate_comment(plain, THREAD, 13, 27).unwrap();
    assert_eq!(annotated.quote, "list-row\n  dat");
    let restored = restore_comments(&annotated.xml, edited).unwrap();
    assert_eq!(
        restored.xml,
        format!(
            "<page><infographic theme=\"dark\" view=\"diagram\">infographic <comment ids=\"{THREAD}\">list-row\n  dat</comment>a\n    - item 2</infographic></page>"
        )
    );
    assert_eq!(remove_comment(&restored.xml, THREAD).unwrap().xml, edited);
}

#[test]
fn sections_preserves_inline_heading_text_and_rich_block_offsets() {
    let xml = concat!(
        "<page>",
        "<p>① Intro oﬃce</p>",
        "<h2>Cust<strong>om</strong> <code>Section</code></h2>",
        "<p>Reviewneedle below</p>",
        "<h3>Links &amp; Media</h3>",
        r#"<embed href="https://docs.example.com/runbook" view="card" title="Incident Runbook" description="Bookmarkneedle" />"#,
        "</page>"
    );
    let parsed = super::sections(xml).unwrap();
    assert_eq!(parsed.sections.len(), 2);
    assert_eq!(parsed.sections[0].level, 2);
    assert_eq!(parsed.sections[0].heading, "Custom Section");
    assert_eq!(parsed.sections[1].level, 3);
    assert_eq!(parsed.sections[1].heading, "Links & Media");

    let needle_pos = parsed.plain_text.find("Reviewneedle").unwrap();
    assert!(needle_pos >= parsed.sections[0].start_byte);
    assert!(needle_pos < parsed.sections[1].start_byte);

    let card_pos = parsed.plain_text.find("Bookmarkneedle").unwrap();
    assert!(card_pos >= parsed.sections[1].start_byte);
}

#[test]
fn diffs_unknown_legacy_bookmark_into_unified_embed_card() {
    let old = r#"<page><p>Before</p><bookmark src="https://example.com/doc" title="Example" description="Summary" image="https://example.com/og.png" /><p>After</p></page>"#;
    let new = r#"<page><p>Before</p><embed description="Summary" href="https://example.com/doc" image="https://example.com/og.png" title="Example" view="card" /><p>After</p></page>"#;
    let changes = super::diff(old, new).unwrap();
    let applied = apply(old, &serde_json::to_string(&changes).unwrap()).unwrap();
    assert_eq!(applied.xml, new);
    assert_eq!(
        applied.plain_text,
        "Before\nExample\nSummary\nhttps://example.com/doc\nAfter"
    );
}
