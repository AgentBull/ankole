use super::*;
use serde_json::{Value, json};

fn corpus() -> Value {
    serde_json::from_str(include_str!(
        "../../../../libs/ankole-editor/corpus/rust/index.json"
    ))
    .unwrap()
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
        ("color:red; /* open", "color:red; /* open"),
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
    ] {
        assert!(document_schema::validate_mark(name, &json!(valid)).is_ok());
        assert!(document_schema::validate_mark(name, &json!(invalid)).is_err());
        assert!(document_schema::validate_mark(name, &json!(42)).is_err());
    }
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
fn server_text_diff_keeps_unchanged_regions_between_edits() {
    let old = "<page><blockquote><p>alpha βeta gamma delta 😀 end</p></blockquote></page>";
    let new = "<page><blockquote><p>alpha BETA gamma DELTA 😀 end!</p></blockquote></page>";
    let changes = diff(old, new).unwrap();
    assert!(
        changes
            .as_array()
            .unwrap()
            .iter()
            .filter(|value| value.is_u64())
            .count()
            >= 3
    );
    assert_eq!(
        apply(old, &changes.to_string()).unwrap().xml,
        validate(new).unwrap().xml
    );
}

#[test]
fn inline_mark_changes_retain_formatted_and_surrounding_text() {
    let old = "<page><p>alpha beta gamma</p></page>";
    let new = "<page><p>alpha <strong>beta</strong> gamma</p></page>";
    let changes = diff(old, new).unwrap();
    assert_eq!(
        changes,
        json!([7, [4, [{"add": "Strong", "value": null}]], 7])
    );
    assert_eq!(
        apply(old, &changes.to_string()).unwrap().xml,
        validate(new).unwrap().xml
    );
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
