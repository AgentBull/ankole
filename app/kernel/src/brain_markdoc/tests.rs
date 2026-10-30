use super::*;

fn error(source: &str) -> AnalysisError {
    analyze(source).expect_err("source must be rejected")
}

#[test]
fn splits_root_audience_blocks_without_changing_content_bytes() {
    let source = concat!(
        "# 明湖 AI\r\n",
        "public\r\n",
        "{% audience scope=\"principal:alice\" %}\r\n",
        "private\r\n",
        "{% /audience %}\r\n",
        "tail"
    );

    let analysis = analyze(source).unwrap();
    assert_eq!(
        analysis.segments,
        vec![
            Segment {
                scope: "world".to_string(),
                text: "# 明湖 AI\r\npublic\r\n".to_string(),
                tagged: false,
            },
            Segment {
                scope: "principal:alice".to_string(),
                text: "\nprivate\r\n".to_string(),
                tagged: true,
            },
            Segment {
                scope: "world".to_string(),
                text: "\ntail".to_string(),
                tagged: false,
            },
        ]
    );
}

#[test]
fn rejects_a_close_tag_that_only_looks_real_inside_a_fence() {
    let source = concat!(
        "{% audience scope=\"principal:alice\" %}\n",
        "private\n",
        "~~~markdoc\n",
        "{% /audience %}\n",
        "~~~\n",
        "tail that must stay private\n"
    );

    assert_eq!(
        error(source),
        AnalysisError {
            code: "unclosed_audience_tag",
            line: 1,
        }
    );
}

#[test]
fn treats_fenced_and_indented_tag_text_as_code() {
    for source in [
        "```markdoc\n{% audience scope=\"world\" %}\n{% /audience %}\n```\n",
        "~~~ text\n{% audience scope=\"world\" %}\n{% /audience %}\n~~~~\n",
        "    {% audience scope=\"world\" %}\n    {% /audience %}\n",
        "- item\n\n  ```markdoc\n  {% audience scope=\"world\" %}\n  ```\n",
    ] {
        let analysis = analyze(source).unwrap();
        assert_eq!(analysis.segments.len(), 1);
        assert_eq!(analysis.segments[0].scope, "world");
        assert_eq!(analysis.segments[0].text, source);
        assert!(!analysis.segments[0].tagged);
    }
}

#[test]
fn treats_crlf_code_fences_containing_audience_tags_identically_to_lf() {
    for source in [
        "```markdoc\r\n{% audience scope=\"world\" %}\r\n{% /audience %}\r\n```\r\n",
        "~~~ text\r\n{% audience scope=\"world\" %}\r\n{% /audience %}\r\n~~~~\r\n",
        "    {% audience scope=\"world\" %}\r\n    {% /audience %}\r\n",
        "- item\r\n\r\n  ```markdoc\r\n  {% audience scope=\"world\" %}\r\n  ```\r\n",
    ] {
        let analysis = analyze(source).unwrap();
        assert_eq!(
            analysis.segments,
            vec![Segment {
                scope: "world".to_string(),
                text: source.to_string(),
                tagged: false,
            }]
        );
    }

    assert_eq!(
        error(concat!(
            "{% audience scope=\"principal:alice\" %}\r\n",
            "private\r\n",
            "```markdoc\r\n",
            "{% /audience %}\r\n",
            "```\r\n",
            "tail\r\n"
        )),
        AnalysisError {
            code: "unclosed_audience_tag",
            line: 1,
        }
    );
}

#[test]
fn distinguishes_explicit_world_tags_from_unwrapped_prose() {
    for unwrapped in [
        "Plain top-level prose\n",
        "Inline `{% audience scope=\"world\" %}` literal\n",
        "```\n{% audience scope=\"world\" %}\n{% /audience %}\n```\n",
    ] {
        let decoded: serde_json::Value =
            serde_json::from_str(&analyze_json(unwrapped).unwrap()).unwrap();
        assert_eq!(
            decoded["segments"],
            serde_json::json!([
                {
                    "scope": "world",
                    "text": unwrapped,
                    "tagged": false,
                }
            ])
        );
    }

    let mixed = concat!(
        "Lead prose\n",
        "{% audience scope=\"world\" %}\n",
        "Explicit world block\n",
        "{% /audience %}\n",
        "Trailing prose"
    );
    let decoded: serde_json::Value = serde_json::from_str(&analyze_json(mixed).unwrap()).unwrap();
    assert_eq!(
        decoded["segments"],
        serde_json::json!([
            {
                "scope": "world",
                "text": "Lead prose\n",
                "tagged": false,
            },
            {
                "scope": "world",
                "text": "\nExplicit world block\n",
                "tagged": true,
            },
            {
                "scope": "world",
                "text": "\nTrailing prose",
                "tagged": false,
            }
        ])
    );
}

#[test]
fn treats_inline_and_multiline_code_span_tag_text_as_code() {
    for source in [
        "`{% audience scope=\"world\" %}` and `{% /audience %}`\n",
        "`\n{% audience scope=\"world\" %}\n{% /audience %}\n`\n",
    ] {
        assert_eq!(analyze(source).unwrap().segments[0].text, source);
    }
}

#[test]
fn rejects_every_non_root_or_non_block_tag_shape() {
    for (source, line) in [
        ("prefix {% audience scope=\"world\" %}\n", 1),
        ("# {% audience scope=\"world\" %}\n", 1),
        ("> {% /audience %}\n", 1),
        ("- {% audience scope=\"world\" %}\n", 1),
        ("  {% audience scope=\"world\" %}\n", 1),
        ("<div>\n{% audience scope=\"world\" %}\n</div>\n", 2),
        ("text\ncontinued {% /audience %}\n", 2),
        ("{% audience scope='world' %}\n", 1),
    ] {
        assert_eq!(
            error(source),
            AnalysisError {
                code: "misplaced_audience_tag",
                line,
            },
            "source: {source:?}"
        );
    }
}

#[test]
fn reports_pairing_errors_at_the_decisive_line() {
    assert_eq!(
        error("{% /audience %}\n"),
        AnalysisError {
            code: "unopened_audience_tag",
            line: 1,
        }
    );
    assert_eq!(
        error("x\n{% audience scope=\"world\" %}\ny\n"),
        AnalysisError {
            code: "unclosed_audience_tag",
            line: 2,
        }
    );
    assert_eq!(
        error(concat!(
            "{% audience scope=\"world\" %}\n",
            "{% audience scope=\"group:a\" %}\n",
            "{% /audience %}\n",
            "{% /audience %}\n"
        )),
        AnalysisError {
            code: "nested_audience_tag",
            line: 2,
        }
    );
}

#[test]
fn extracts_wikilinks_from_ast_in_document_order() {
    let source = concat!(
        "[[companies/acme]] [[people/alice|Alice]] [[companies/acme]]\n",
        "`[[inline/code]]`\n",
        "```\n[[block/code]]\n```\n"
    );

    assert_eq!(
        analyze(source).unwrap().wikilinks,
        vec!["companies/acme".to_string(), "people/alice".to_string()]
    );
}

#[test]
fn encodes_grammar_errors_as_normal_json_results() {
    assert_eq!(
        analyze_json("{% /audience %}").unwrap(),
        r#"{"error":{"code":"unopened_audience_tag","line":1}}"#
    );
}

#[test]
fn shares_audience_contract_cases_with_console_preview() {
    let cases: serde_json::Value =
        serde_json::from_str(include_str!("../../test/fixtures/brain_markdoc.json")).unwrap();

    for case in cases.as_array().unwrap() {
        let actual: serde_json::Value =
            serde_json::from_str(&analyze_json(case["source"].as_str().unwrap()).unwrap()).unwrap();
        if case.get("error").is_some() {
            assert_eq!(actual["error"], case["error"], "case: {}", case["name"]);
        } else {
            let projected: Vec<serde_json::Value> = actual["segments"]
                .as_array()
                .unwrap()
                .iter()
                .map(|segment| {
                    assert!(
                        segment["tagged"].is_boolean(),
                        "case: {} missing boolean tagged",
                        case["name"]
                    );
                    serde_json::json!({
                        "scope": segment["scope"],
                        "text": segment["text"],
                    })
                })
                .collect();
            assert_eq!(
                serde_json::Value::Array(projected),
                case["segments"],
                "case: {}",
                case["name"]
            );
        }
    }
}
