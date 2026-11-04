use super::{export, parse};
#[cfg(any(feature = "nif", feature = "napi"))]
use crate::common;
use serde_json::{Value, json};

#[test]
fn frontmatter_is_business_data_and_deterministic() {
    let page = parse("---\nsummary: A\ncolors:\n  primary: '#123456'\ntags: [one, two]\n---\n\n# Heading\n\nA **fact**.").unwrap();
    assert_eq!(page.metadata["colors"]["primary"], "#123456");
    let markdown = export(&page.xml, &Value::Object(page.metadata.clone())).unwrap();
    let reparsed = parse(&markdown).unwrap();
    assert_eq!(reparsed.xml, page.xml);
    assert_eq!(reparsed.metadata, page.metadata);
    assert_eq!(
        export(&reparsed.xml, &Value::Object(reparsed.metadata)).unwrap(),
        markdown
    );
    assert!(markdown.find("colors:").unwrap() < markdown.find("summary:").unwrap());
}

#[test]
fn shared_corpus_roundtrips_without_losing_page_semantics() {
    let cases: Vec<Value> = serde_json::from_str(include_str!(
        "../../../../../libs/ankole-editor/corpus/knowledge.json"
    ))
    .unwrap();
    for case in cases {
        let name = case["name"].as_str().unwrap();
        let xml = case["xml"].as_str().unwrap();
        let canonical = super::validate(xml).unwrap();
        let markdown = export(xml, &json!({})).unwrap();
        assert_eq!(
            parse(&markdown).unwrap().xml,
            canonical.xml,
            "{name}: {markdown}"
        );
        assert_eq!(
            export(&parse(&markdown).unwrap().xml, &json!({})).unwrap(),
            markdown,
            "{name}"
        );
    }
}

#[test]
fn unsupported_doc_features_are_rejected() {
    for xml in [
        "<page><columns><column><p>A</p></column><column><p>B</p></column></columns></page>",
        "<page><embed href=\"https://example.org\"/></page>",
        "<page><p><comment ids=\"019a0000-0000-7000-8000-000000000001\">private</comment></p></page>",
        "<page><table widths=\"100,200\"><tr><th><p>A</p></th><th><p>B</p></th></tr></table></page>",
    ] {
        assert!(super::validate(xml).is_err(), "{xml}");
    }
}

#[test]
fn overview_reads_introduction_and_h2_skeleton() {
    let page =
        parse("Intro.\n\n## First\n\nLong body.\n\n### Detail\n\nMore.\n\n## Second\n\nTail.")
            .unwrap();
    let overview = super::overview(
        &page.xml,
        &json!({"summary":"Short","secret_internal_key":"not selected"}),
    )
    .unwrap();
    assert!(overview.contains("Intro."));
    assert!(overview.contains("## First"));
    assert!(overview.contains("## Second"));
    assert!(!overview.contains("Long body"));
    assert!(!overview.contains("secret_internal_key"));
}

#[test]
fn overview_bounds_long_unsectioned_notes_without_changing_the_full_page() {
    let body = "报价条件必须包含运费与有效日期。".repeat(2_000);
    let page = parse(&body).unwrap();
    let brief = super::overview(&page.xml, &json!({})).unwrap();
    assert!(brief.contains("Introduction shortened"));
    assert!(common::estimate_o200k_base_tokens(&brief) < 450);
    assert!(parse(&brief).is_ok());
    assert_eq!(export(&page.xml, &json!({})).unwrap().trim(), body);
}

#[test]
fn overview_keeps_every_heading_after_the_introduction_budget_is_spent() {
    let body = format!(
        "{}\n\n{}",
        "A\n\n".repeat(500),
        (0..50)
            .map(|i| format!("## Section {i}\n\nDetail {i}."))
            .collect::<Vec<_>>()
            .join("\n\n")
    );
    let page = parse(&body).unwrap();
    let brief = super::overview(&page.xml, &json!({})).unwrap();
    assert!(brief.contains("Introduction shortened"));
    assert!(common::estimate_o200k_base_tokens(brief.split("## Section 0").next().unwrap()) < 450);
    for i in 0..50 {
        assert!(brief.contains(&format!("## Section {i}")));
        assert!(!brief.contains(&format!("Detail {i}.")));
    }
}

#[test]
fn overview_folds_large_blocks_and_keeps_short_examples() {
    let long_code = "line of code\n".repeat(13);
    let long_table = "|cell|\n".repeat(7);
    let page = parse(&format!(
        "```sh\necho short\n```\n\n```txt\n{long_code}```\n\n|header|\n|---|\n{long_table}"
    ))
    .unwrap();
    let overview = super::overview(&page.xml, &json!({})).unwrap();
    assert!(overview.contains("echo short"));
    assert!(!overview.contains("line of code"));
    assert!(!overview.contains("cell"));
    assert!(overview.contains("Code block:"));
    assert!(overview.contains("Table: 8 rows"));
    let full = export(&page.xml, &json!({})).unwrap();
    assert!(full.contains("line of code"));
    assert!(full.contains("cell"));
}

#[test]
fn common_blocks_export_as_markdown_and_alerts_keep_icons() {
    let xml = "<page><callout tone=\"warning\" icon=\"⚠️\"><p>Warning.</p></callout><media src=\"https://example.org/a.png\" kind=\"image\" title=\"A\"/></page>";
    let markdown = export(xml, &json!({})).unwrap();
    assert!(markdown.starts_with("> [!WARNING]"), "{markdown}");
    assert!(markdown.contains("![]("), "{markdown}");
    assert_eq!(
        parse(&markdown).unwrap().xml,
        super::validate(xml).unwrap().xml
    );
}

#[test]
fn factory_contracts_and_skill_pages_are_readable_knowledge() {
    fn visit(path: &std::path::Path, errors: &mut Vec<String>) {
        for entry in std::fs::read_dir(path).unwrap() {
            let path = entry.unwrap().path();
            if path.is_dir() {
                visit(&path, errors);
            } else if path
                .file_name()
                .and_then(|name| name.to_str())
                .is_some_and(|name| {
                    matches!(
                        name,
                        "SKILL.md"
                            | "SOUL.md"
                            | "MISSION.md"
                            | "DESIGN.md"
                            | "ConfidentialityPolicy.md"
                    )
                })
            {
                let source = std::fs::read_to_string(&path).unwrap();
                if let Err(error) = parse(&source) {
                    errors.push(format!("{}: {error}", path.display()));
                }
            }
        }
    }
    let mut errors = vec![];
    visit(
        &std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../library"),
        &mut errors,
    );
    assert!(errors.is_empty(), "{}", errors.join("\n"));
}

#[test]
fn principal_markers_keep_email_uids_and_sentence_punctuation() {
    let parsed = parse("Ask @alice@example.com. Then @+8613800000000.").unwrap();
    assert!(
        parsed.xml.contains("principal=\"alice@example.com\" />."),
        "{}",
        parsed.xml
    );
    assert!(
        parsed.xml.contains("principal=\"+8613800000000\" />."),
        "{}",
        parsed.xml
    );
    assert_eq!(
        export(&parsed.xml, &json!({})).unwrap(),
        "Ask @alice@example.com. Then @+8613800000000."
    );
}

#[test]
fn markdown_link_titles_preserve_attribute_whitespace() {
    let page = parse("[Read](https://example.com \"first\tsecond\nthird\")").unwrap();
    assert!(
        page.xml.contains("title=\"first&#9;second&#10;third\""),
        "{}",
        page.xml
    );
    assert_eq!(
        parse(&export(&page.xml, &json!({})).unwrap()).unwrap().xml,
        page.xml
    );
}
