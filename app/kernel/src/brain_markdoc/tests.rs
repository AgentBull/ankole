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
            },
            Segment {
                scope: "principal:alice".to_string(),
                text: "\nprivate\r\n".to_string(),
            },
            Segment {
                scope: "world".to_string(),
                text: "\ntail".to_string(),
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
    }
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
