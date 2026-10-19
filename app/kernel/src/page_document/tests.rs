use super::*;
use serde_json::{Value, json};

fn corpus() -> Value {
    serde_json::from_str(include_str!(
        "../../../../libs/ankole-editor/corpus/rust/index.json"
    ))
    .unwrap()
}

#[test]
fn span_marks_follow_xml_attribute_limits() {
    for name in ["ColSpan", "RowSpan"] {
        for value in [0, 10_000] {
            assert!(document::validate_mark(name, &json!(value)).is_err());
        }
        for value in [1, 9999] {
            assert!(document::validate_mark(name, &json!(value)).is_ok());
        }
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
