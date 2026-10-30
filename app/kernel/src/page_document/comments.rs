use super::document_schema::{DocNode, NodeKind};
use super::tree::{self, Result};
use super::{Page, changeset, diff, document, page};
use serde::Serialize;
use serde_json::{Value, json};
use std::collections::{BTreeMap, BTreeSet};

#[derive(Debug, Serialize)]
pub struct CommentedPage {
    pub xml: String,
    pub plain_text: String,
    pub quote: String,
}

pub(super) fn valid_id(id: &str) -> bool {
    let bytes = id.as_bytes();
    bytes.len() == 36
        && bytes[14] == b'7'
        && matches!(bytes[19], b'8' | b'9' | b'a' | b'b')
        && bytes.iter().enumerate().all(|(i, byte)| {
            if [8, 13, 18, 23].contains(&i) {
                *byte == b'-'
            } else {
                byte.is_ascii_digit() || (b'a'..=b'f').contains(byte)
            }
        })
}

pub(super) fn parse_ids(value: &str) -> Result<Vec<String>> {
    let mut ids: Vec<String> = value.split(' ').map(str::to_owned).collect();
    if ids.is_empty() || ids.iter().any(|id| !valid_id(id)) {
        return Err("invalid comment thread identifiers".into());
    }
    ids.sort();
    ids.dedup();
    Ok(ids)
}

pub(super) fn modify_mark(node: &mut DocNode, values: &[Value], add: bool) {
    let mut ids = node
        .marks
        .get("Comment")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    if add {
        ids.extend_from_slice(values);
    } else {
        ids.retain(|id| !values.contains(id));
    }
    ids.sort_by(|a, b| a.as_str().cmp(&b.as_str()));
    ids.dedup();
    if ids.is_empty() {
        node.marks.remove("Comment");
    } else {
        node.marks.insert("Comment".into(), Value::Array(ids));
    }
}

fn remove_marks(node: &mut DocNode, id: Option<&str>) {
    if let Some(id) = id {
        modify_mark(node, &[json!(id)], false);
    } else {
        node.marks.remove("Comment");
    }
    if let Some(children) = &mut node.content {
        for child in children {
            remove_marks(child, id);
        }
    }
}

fn read(source: &str) -> Result<DocNode> {
    document::page_document_normalized(&tree::parse(source)?)
}

pub fn comment_info(source: &str) -> Result<Value> {
    let mut doc = read(source)?;
    let mut ids = BTreeSet::new();
    fn collect(node: &DocNode, ids: &mut BTreeSet<String>) {
        if let Some(mark) = node.marks.get("Comment").and_then(Value::as_array) {
            ids.extend(mark.iter().filter_map(Value::as_str).map(str::to_owned));
        }
        if let Some(children) = &node.content {
            for child in children {
                collect(child, ids);
            }
        }
    }
    collect(&doc, &mut ids);
    remove_marks(&mut doc, None);
    Ok(json!({"ids": ids, "stripped_xml": page(document::read_tree(&doc)?)?.xml}))
}

pub fn remove_comment(source: &str, id: &str) -> Result<Page> {
    if !valid_id(id) {
        return Err("invalid comment thread identifier".into());
    }
    let mut doc = read(source)?;
    remove_marks(&mut doc, Some(id));
    page(document::read_tree(&doc)?)
}

/// Ranges use the same structural tokens and UTF-16 offsets as a Wordgard ChangeSet.
pub fn annotate_comment(source: &str, id: &str, from: usize, to: usize) -> Result<CommentedPage> {
    if !valid_id(id) {
        return Err("invalid comment thread identifier".into());
    }
    let mut doc = read(source)?;
    let length = doc
        .content
        .as_ref()
        .unwrap()
        .iter()
        .map(DocNode::span)
        .sum::<usize>();
    if from >= to || to > length {
        return Err("invalid comment selection".into());
    }
    remove_marks(&mut doc, Some(id));
    let mut quote = String::new();
    let mut count = 0;
    let children = doc.content.take().unwrap();
    doc.content = Some(annotate_nodes(
        children, 0, from, to, id, &mut quote, &mut count,
    )?);
    if count == 0 {
        return Err("select text to anchor the comment".into());
    }
    let result = page(document::read_tree(&doc)?)?;
    Ok(CommentedPage {
        xml: result.xml,
        plain_text: result.plain_text,
        quote,
    })
}

fn annotate_nodes(
    nodes: Vec<DocNode>,
    mut offset: usize,
    from: usize,
    to: usize,
    id: &str,
    quote: &mut String,
    count: &mut usize,
) -> Result<Vec<DocNode>> {
    let mut out = Vec::new();
    for mut node in nodes {
        let end = offset + node.span();
        if from >= end || to <= offset {
            out.push(node);
            offset = end;
            continue;
        }
        if let Some(children) = node.content.take() {
            let mut part = String::new();
            node.content = Some(annotate_nodes(
                children,
                offset + 1,
                from,
                to,
                id,
                &mut part,
                count,
            )?);
            if !part.is_empty() {
                if !quote.is_empty() {
                    quote.push('\n');
                }
                quote.push_str(&part);
            }
            out.push(node);
        } else if node.kind == NodeKind::Text {
            let length = node.span();
            let start = from.saturating_sub(offset);
            let stop = (to - offset).min(length);
            for (a, b, selected) in [
                (0, start, false),
                (start, stop, true),
                (stop, length, false),
            ] {
                if a == b {
                    continue;
                }
                let text = node.text_slice(a, b)?;
                let mut leaf = node.clone();
                if selected {
                    modify_mark(&mut leaf, &[json!(id)], true);
                    quote.push_str(&text);
                    *count += 1;
                }
                leaf.param = json!(text);
                out.push(leaf);
            }
        } else if matches!(
            node.kind,
            NodeKind::LineBreak | NodeKind::Image | NodeKind::InlineElement | NodeKind::Mention
        ) {
            modify_mark(&mut node, &[json!(id)], true);
            if node.kind == NodeKind::LineBreak {
                quote.push('\n');
            }
            if node.kind == NodeKind::Image {
                quote.push_str(
                    node.marks
                        .get("ImageAlt")
                        .and_then(Value::as_str)
                        .unwrap_or_default(),
                );
            }
            if node.kind == NodeKind::InlineElement {
                quote.push_str(&tree::text_of(&super::document_schema::thaw(&node.param)?));
            }
            if node.kind == NodeKind::Mention {
                quote.push('@');
            }
            *count += 1;
            out.push(node);
        } else {
            out.push(node);
        }
        offset = end;
    }
    Ok(out)
}

/// Apply content changes to the current marked document. Old snapshots cannot revive anchors.
pub fn restore_comments(current: &str, target: &str) -> Result<Page> {
    let mut current = read(current)?;
    let mut before = current.clone();
    let mut after = read(target)?;
    remove_marks(&mut before, None);
    remove_marks(&mut after, None);
    let change = diff::changes(&before, &after)?;
    let restored = if change.as_array().is_some_and(Vec::is_empty) {
        current
    } else {
        clear_modified_anchors(&mut current, &change)?;
        changeset::apply(&current, &change)?
    };
    page(document::read_tree(&restored)?)
}

fn each_leaf(node: &mut DocNode, from: usize, visit: &mut impl FnMut(&mut DocNode, usize)) {
    let content_from = from + usize::from(node.kind != NodeKind::Doc);
    if let Some(children) = &mut node.content {
        let mut offset = content_from;
        for child in children {
            let length = child.span();
            each_leaf(child, offset, visit);
            offset += length;
        }
    } else {
        visit(node, from);
    }
}

/// A source replacement must retain a complete anchored run. Matching scattered letters
/// in rewritten prose does not establish that the discussion still refers to that prose.
fn clear_modified_anchors(current: &mut DocNode, change: &Value) -> Result<()> {
    let retained = changeset::retained_ranges(change)?;
    let mut runs = BTreeMap::<String, Vec<(usize, usize)>>::new();
    each_leaf(current, 0, &mut |leaf, from| {
        for id in leaf
            .marks
            .get("Comment")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .filter_map(Value::as_str)
        {
            let ranges = runs.entry(id.to_owned()).or_default();
            let to = from + leaf.span();
            if let Some(last) = ranges.last_mut().filter(|last| last.1 == from) {
                last.1 = to;
            } else {
                ranges.push((from, to));
            }
        }
    });
    for ranges in runs.values_mut() {
        ranges.retain(|(from, to)| !retained.iter().any(|(a, b)| a <= from && b >= to));
    }
    each_leaf(current, 0, &mut |leaf, from| {
        let ids: Vec<Value> = leaf
            .marks
            .get("Comment")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .filter(|id| {
                runs.get(id.as_str().unwrap())
                    .is_some_and(|ranges| ranges.iter().any(|(a, b)| *a <= from && from < *b))
            })
            .cloned()
            .collect();
        modify_mark(leaf, &ids, false);
    });
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    const A: &str = "019a2b00-0000-7000-8000-000000000001";
    const B: &str = "019a2b00-0000-7000-8000-000000000002";

    #[test]
    fn annotation_quote_overlap_and_reanchor_are_canonical() {
        let first = annotate_comment("<page><p>one 🙂 two</p></page>", A, 1, 7).unwrap();
        assert_eq!(first.quote, "one 🙂");
        assert_eq!(
            first.xml,
            format!("<page><p><comment ids=\"{A}\">one 🙂</comment> two</p></page>")
        );
        let second = annotate_comment(&first.xml, B, 1, 7).unwrap();
        assert_eq!(comment_info(&second.xml).unwrap()["ids"], json!([A, B]));
        let reanchored = annotate_comment(&second.xml, A, 8, 11).unwrap();
        assert_eq!(reanchored.quote, "two");
        assert_eq!(
            reanchored.xml,
            format!(
                "<page><p><comment ids=\"{B}\">one 🙂</comment> <comment ids=\"{A}\">two</comment></p></page>"
            )
        );
        assert!(annotate_comment(&first.xml, A, 5, 6).is_err());
        let code = annotate_comment("<page><pre>code\n  next</pre></page>", A, 3, 8).unwrap();
        assert_eq!(code.quote, "de\n  ");
        assert_eq!(
            code.xml,
            format!("<page><pre>co<comment ids=\"{A}\">de\n  </comment>next</pre></page>")
        );
        let list = annotate_comment(
            "<page><ul><li><p>one</p></li><li><p>two</p></li></ul></page>",
            A,
            3,
            13,
        )
        .unwrap();
        assert_eq!(list.quote, "one\ntwo");
        let mention = annotate_comment(
            "<page><p>见 <mention page=\"019a2b00-0000-7000-8000-000000000099\" /> 详情</p></page>",
            A,
            3,
            4,
        )
        .unwrap();
        assert_eq!(mention.quote, "@");
        assert_eq!(
            mention.xml,
            format!(
                "<page><p>见 <comment ids=\"{A}\"><mention page=\"019a2b00-0000-7000-8000-000000000099\" /></comment> 详情</p></page>"
            )
        );
    }

    #[test]
    fn restore_keeps_current_anchors_and_never_resurrects_historical_marks() {
        let current =
            format!("<page><p><comment ids=\"{A}\">retained</comment></p><p>new</p></page>");
        let target =
            format!("<page><p><comment ids=\"{B}\">retained</comment></p><p>old</p></page>");
        let restored = restore_comments(&current, &target).unwrap();
        assert_eq!(
            restored.xml,
            format!("<page><p><comment ids=\"{A}\">retained</comment></p><p>old</p></page>")
        );
        assert!(
            comment_info(
                &restore_comments(&current, "<page><p /></page>")
                    .unwrap()
                    .xml
            )
            .unwrap()["ids"]
                .as_array()
                .unwrap()
                .is_empty()
        );
        assert_eq!(
            comment_info(&current).unwrap()["stripped_xml"],
            "<page><p>retained</p><p>new</p></page>"
        );
    }

    #[test]
    fn formatting_changes_preserve_complete_current_comment_runs() {
        let current = format!("<page><p><comment ids=\"{A}\">hello world</comment></p></page>");
        let restored = restore_comments(
            &current,
            "<page><p align=\"center\">h<strong>ello</strong> world</p></page>",
        )
        .unwrap();
        assert_eq!(
            restored.xml,
            format!(
                "<page><p align=\"center\"><comment ids=\"{A}\">h<strong>ello</strong> world</comment></p></page>"
            )
        );
        let replaced = restore_comments(&current, "<page><p>hello new world</p></page>").unwrap();
        assert_eq!(replaced.xml, "<page><p>hello new world</p></page>");
    }

    #[test]
    fn mermaid_comment_anchors_survive_serialization() {
        let source = "<page><mermaid>flowchart TD\nA --&gt; B</mermaid></page>";
        let annotated = annotate_comment(source, A, 14, 21).unwrap();
        assert_eq!(annotated.quote, "A --> B");
        assert_eq!(comment_info(&annotated.xml).unwrap()["ids"], json!([A]));
        assert_eq!(
            comment_info(&annotated.xml).unwrap()["stripped_xml"],
            source
        );
        let restored = restore_comments(&annotated.xml, source).unwrap();
        assert_eq!(restored.xml, annotated.xml);
    }

    #[test]
    fn source_replacement_drops_fragmented_matches_but_keeps_other_complete_runs() {
        let current = format!(
            "<page><p><comment ids=\"{A}\">Original</comment> body</p><p><comment ids=\"{A}\">retained</comment></p></page>"
        );
        let restored = restore_comments(
            &current,
            "<page><p>Unrelated replacement</p><p>retained</p></page>",
        )
        .unwrap();
        assert_eq!(
            restored.xml,
            format!(
                "<page><p>Unrelated replacement</p><p><comment ids=\"{A}\">retained</comment></p></page>"
            )
        );
        let only_replacement =
            restore_comments(&current, "<page><p>Unrelated replacement</p></page>").unwrap();
        assert!(
            comment_info(&only_replacement.xml).unwrap()["ids"]
                .as_array()
                .unwrap()
                .is_empty()
        );
    }

    #[test]
    fn apply_uses_set_semantics_for_overlapping_comment_marks() {
        let source = format!("<page><p><comment ids=\"{A}\">text</comment></p></page>");
        let added = super::super::apply(
            &source,
            &json!([1,[4,[{"add":"Comment","value":[B]}]],1]).to_string(),
        )
        .unwrap();
        assert_eq!(comment_info(&added.xml).unwrap()["ids"], json!([A, B]));
        let removed = super::super::apply(
            &added.xml,
            &json!([1,[4,[{"remove":"Comment","value":[A]}]],1]).to_string(),
        )
        .unwrap();
        assert_eq!(
            removed.xml,
            format!("<page><p><comment ids=\"{B}\">text</comment></p></page>")
        );
    }
}
