use super::Knowledge;
use crate::page_document::diff;
use crate::page_document::tree::{self, Node};
use serde_json::{Map, Value};
use std::collections::BTreeSet;

/// Merge whole top-level blocks, leaving competing edits for the user to resolve.
pub fn merge(
    base_xml: &str,
    base_meta: &Value,
    current_xml: &str,
    current_meta: &Value,
    edited_xml: &str,
    edited_meta: &Value,
) -> tree::Result<Knowledge> {
    let metadata = merge_metadata(base_meta, current_meta, edited_meta)?;
    let blocks = |xml: &str| -> tree::Result<Vec<String>> {
        Ok(tree::parse(xml)?
            .children
            .iter()
            .filter_map(|node| match node {
                Node::Element(element) => Some(tree::print(element)),
                _ => None,
            })
            .collect())
    };
    let base = blocks(base_xml)?;
    let current = blocks(current_xml)?;
    let edited = blocks(edited_xml)?;
    let merged = merge_blocks(&base, &current, &edited)?;
    let page = super::validate(&format!("<page>{}</page>", merged.concat()))?;
    Ok(Knowledge {
        xml: page.xml,
        plain_text: page.plain_text,
        metadata,
    })
}

fn merge_metadata(
    base: &Value,
    current: &Value,
    edited: &Value,
) -> tree::Result<Map<String, Value>> {
    let base = base
        .as_object()
        .ok_or("knowledge metadata must be an object")?;
    let current = current
        .as_object()
        .ok_or("knowledge metadata must be an object")?;
    let edited = edited
        .as_object()
        .ok_or("knowledge metadata must be an object")?;
    let keys: BTreeSet<_> = base
        .keys()
        .chain(current.keys())
        .chain(edited.keys())
        .collect();
    let mut out = Map::new();
    for key in keys {
        if key == "upstream_state" {
            continue;
        }
        let original = base.get(key);
        let current_value = current.get(key);
        let edited_value = edited.get(key);
        let chosen = if current_value == original {
            edited_value
        } else if edited_value == original || current_value == edited_value {
            current_value
        } else {
            return Err("conflict".into());
        };
        if let Some(value) = chosen {
            out.insert(key.clone(), value.clone());
        }
    }
    Ok(out)
}

#[derive(PartialEq, Eq)]
struct Edit<'blocks> {
    start: usize,
    end: usize,
    insert: &'blocks [String],
}
fn edits<'a>(base: &[String], next: &'a [String], matched: Vec<(usize, usize)>) -> Vec<Edit<'a>> {
    let mut out = Vec::new();
    let (mut left, mut right) = (0, 0);
    for (x, y) in matched.into_iter().chain([(base.len(), next.len())]) {
        if x != left || y != right {
            out.push(Edit {
                start: left,
                end: x,
                insert: &next[right..y],
            });
        }
        (left, right) = (x + 1, y + 1);
    }
    out
}
// Repeated identical blocks can align to either occurrence. Accept a concurrent
// merge only if forward and reverse matching agree about the changed intervals.
fn unambiguous_edits<'a>(base: &[String], next: &'a [String]) -> tree::Result<Vec<Edit<'a>>> {
    let forward = edits(base, next, diff::matches(base, next));
    let reversed_base: Vec<_> = base.iter().rev().collect();
    let reversed_next: Vec<_> = next.iter().rev().collect();
    let reversed = diff::matches(&reversed_base, &reversed_next)
        .into_iter()
        .rev()
        .map(|(x, y)| (base.len() - 1 - x, next.len() - 1 - y))
        .collect();
    if forward != edits(base, next, reversed) {
        return Err("conflict".into());
    }
    Ok(forward)
}
fn merge_blocks(
    base: &[String],
    current: &[String],
    edited: &[String],
) -> tree::Result<Vec<String>> {
    if current == base {
        return Ok(edited.to_vec());
    }
    if edited == base {
        return Ok(current.to_vec());
    }
    let mut current_edits = unambiguous_edits(base, current)?;
    let edited_edits = unambiguous_edits(base, edited)?;
    for c in &current_edits {
        for e in &edited_edits {
            let overlap = if c.start == c.end || e.start == e.end {
                c.start <= e.end && e.start <= c.end
            } else {
                c.start < e.end && e.start < c.end
            };
            if overlap {
                return Err("conflict".into());
            }
        }
    }
    current_edits.extend(edited_edits);
    current_edits.sort_by_key(|e| e.start);
    let mut out = Vec::new();
    let mut at = 0;
    for edit in current_edits {
        out.extend_from_slice(&base[at..edit.start]);
        out.extend_from_slice(edit.insert);
        at = edit.end;
    }
    out.extend_from_slice(&base[at..]);
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    #[test]
    fn separate_sections_and_properties_merge_without_losing_either_author() {
        let base = "<page><h1>Plan</h1><p>one</p><h2>Next</h2><p>two</p></page>";
        let current = base.replace("one", "browser");
        let edited = base.replace("two", "agent");
        let result = merge(
            base,
            &json!({"owner":"A", "obsolete":1}),
            &current,
            &json!({"owner":"B", "obsolete":1}),
            &edited,
            &json!({"owner":"A", "new":true}),
        )
        .unwrap();
        assert!(result.xml.contains("browser"));
        assert!(result.xml.contains("agent"));
        assert_eq!(
            result.metadata,
            json!({"owner":"B", "new":true})
                .as_object()
                .unwrap()
                .clone()
        );
    }
    #[test]
    fn same_block_key_or_insertion_gap_conflicts() {
        let empty = json!({});
        assert_eq!(
            merge(
                "<page><p>a</p></page>",
                &empty,
                "<page><p>b</p></page>",
                &empty,
                "<page><p>c</p></page>",
                &empty
            )
            .unwrap_err(),
            "conflict"
        );
        assert_eq!(
            merge(
                "<page/>",
                &json!({"x":0}),
                "<page/>",
                &json!({"x":1}),
                "<page/>",
                &json!({"x":2})
            )
            .unwrap_err(),
            "conflict"
        );
        assert_eq!(
            merge(
                "<page><p>a</p></page>",
                &empty,
                "<page><p>b</p><p>a</p></page>",
                &empty,
                "<page><p>c</p><p>a</p></page>",
                &empty
            )
            .unwrap_err(),
            "conflict"
        );
    }
    #[test]
    fn identical_properties_merge_and_ambiguous_repeated_blocks_conflict() {
        let base = "<page><p>a</p><p>a</p><p>z</p></page>";
        let current = "<page><p>a</p><p>z</p></page>";
        let edited = "<page><p>a</p><p>a</p><p>new z</p></page>";
        assert_eq!(
            merge(base, &json!({}), current, &json!({}), edited, &json!({})).unwrap_err(),
            "conflict"
        );
        let result = merge(
            base,
            &json!({"x":0}),
            base,
            &json!({"x":1}),
            edited,
            &json!({"x":1}),
        )
        .unwrap();
        assert_eq!(result.metadata["x"], json!(1));
        assert_eq!(result.xml, edited);
    }
}
