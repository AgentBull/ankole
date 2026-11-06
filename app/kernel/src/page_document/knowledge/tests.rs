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

#[test]
fn mermaid_fences_roundtrip_and_merge_in_knowledge_pages() {
    let markdown = "```mermaid\nflowchart TD\n  A[开始] --> B{继续?}\n```";
    let parsed = parse(markdown).unwrap();
    assert_eq!(
        parsed.xml,
        "<page><mermaid>flowchart TD\n  A[开始] --&gt; B{继续?}</mermaid></page>"
    );
    assert_eq!(export(&parsed.xml, &json!({})).unwrap(), markdown);

    let with_backticks = "````mermaid\nflowchart LR\n  A[\"```code```\"] --> B\n````";
    let parsed_backticks = parse(with_backticks).unwrap();
    assert_eq!(
        export(&parsed_backticks.xml, &json!({})).unwrap(),
        with_backticks
    );

    let empty_fence = "```mermaid\n```";
    let parsed_empty = parse(empty_fence).unwrap();
    assert_eq!(parsed_empty.xml, "<page><mermaid /></page>");
    assert_eq!(export(&parsed_empty.xml, &json!({})).unwrap(), empty_fence);

    let base = "<page><p>Intro</p><mermaid>flowchart LR\n  A --&gt; B</mermaid></page>";
    let current = "<page><p>Updated intro</p><mermaid>flowchart LR\n  A --&gt; B</mermaid></page>";
    let edited = "<page><p>Intro</p><mermaid>flowchart LR\n  A --&gt; C</mermaid></page>";
    let merged = super::merge(base, &json!({}), current, &json!({}), edited, &json!({})).unwrap();
    assert_eq!(
        merged.xml,
        "<page><p>Updated intro</p><mermaid>flowchart LR\n  A --&gt; C</mermaid></page>"
    );
}

#[test]
fn explicit_pre_mermaid_roundtrips_injectively_without_becoming_mermaid_element() {
    for xml in [
        "<page><pre lang=\"mermaid\">flowchart LR</pre></page>",
        "<page><pre lang=\"mermaid\">flowchart LR\n\n  A --&gt; B</pre><p>After</p></page>",
        "<page><pre lang=\"mermaid\" /><p>Following prose.</p></page>",
    ] {
        let canonical = super::validate(xml).unwrap();
        let exported = export(&canonical.xml, &json!({})).unwrap();
        assert!(
            !exported.starts_with("```mermaid"),
            "unexpected mermaid fence: {exported}"
        );
        let reparsed = parse(&exported).unwrap();
        assert_eq!(reparsed.xml, canonical.xml, "{exported}");
    }

    let with_meta =
        "<page><pre lang=\"mermaid\" meta=\"title=&quot;raw&quot;\">flowchart LR</pre></page>";
    let exported_meta = export(with_meta, &json!({})).unwrap();
    assert_eq!(exported_meta, "```mermaid title=\"raw\"\nflowchart LR\n```");
    assert_eq!(parse(&exported_meta).unwrap().xml, with_meta);
}

#[test]
fn infographic_stays_pre_fence_and_infographic_or_attributed_mermaid_xml_is_rejected() {
    let infographic_md = "```infographic\ninfographic list-row\n  data\n```";
    let parsed = parse(infographic_md).unwrap();
    assert_eq!(
        parsed.xml,
        "<page><pre lang=\"infographic\">infographic list-row\n  data</pre></page>"
    );
    assert_eq!(export(&parsed.xml, &json!({})).unwrap(), infographic_md);

    for invalid_xml in [
        "<page><infographic>infographic list-row</infographic></page>",
        "<page><infographic view=\"diagram\">infographic list-row</infographic></page>",
        "<page><mermaid view=\"code\">flowchart LR</mermaid></page>",
        "<page><mermaid view=\"diagram\">flowchart LR</mermaid></page>",
        "<page><mermaid theme=\"dark\">flowchart LR</mermaid></page>",
        "<page><mermaid theme=\"light\">flowchart LR</mermaid></page>",
        "<page><mermaid><b>flowchart LR</b></mermaid></page>",
        "<page><mermaid><strong>flowchart LR</strong></mermaid></page>",
        "<page><mermaid>flowchart LR<br />A --&gt; B</mermaid></page>",
        "<page><mermaid><comment ids=\"019a0000-0000-7000-8000-000000000001\">flowchart LR</comment></mermaid></page>",
    ] {
        assert!(super::validate(invalid_xml).is_err(), "{invalid_xml}");
        assert!(export(invalid_xml, &json!({})).is_err(), "{invalid_xml}");
    }
    assert!(parse("<infographic>infographic list-row</infographic>").is_err());
    assert!(parse("<mermaid view=\"code\">flowchart LR</mermaid>").is_err());
}

#[test]
fn overview_folds_long_mermaid_blocks_and_keeps_short_diagrams() {
    let short_diagram = "flowchart LR\n  A --> B";
    let long_diagram = std::iter::once("flowchart TD".to_owned())
        .chain((0..14).map(|i| format!("  N{i} --> N{}", i + 1)))
        .collect::<Vec<_>>()
        .join("\n");
    let page = parse(&format!(
        "```mermaid\n{short_diagram}\n```\n\n```mermaid\n{long_diagram}\n```"
    ))
    .unwrap();
    let brief = super::overview(&page.xml, &json!({})).unwrap();
    assert!(brief.contains("A --> B"), "{brief}");
    assert!(!brief.contains("N13 --> N14"), "{brief}");
    assert!(brief.contains("Mermaid block: 15 lines"), "{brief}");
    assert!(parse(&brief).is_ok(), "{brief}");

    let full = export(&page.xml, &json!({})).unwrap();
    assert!(full.contains("N13 --> N14"));
}
