use super::changeset::Section;
use super::document_schema::{DocNode, Marks, NodeKind};
use super::tree::Result;
use serde_json::{Value, json};

/// Block alignment preserves whole subtrees; changed blocks use the same
/// alignment on their children and text. Offsets always count UTF-16 units.
pub(super) fn changes(old: &DocNode, new: &DocNode) -> Result<Value> {
    if old == new {
        return Ok(json!([]));
    }
    let mut out = Changes::default();
    children(
        old.content.as_deref().unwrap_or_default(),
        new.content.as_deref().unwrap_or_default(),
        &mut out,
    );
    let changes = Value::Array(out.0);
    if super::changeset::apply(old, &changes)? != *new {
        return Err("document diff does not reproduce the target".into());
    }
    Ok(changes)
}

#[derive(Default)]
struct Changes(Vec<Value>);
impl Changes {
    fn retain(&mut self, len: usize) {
        if len == 0 {
            return;
        }
        if let Some(value) = self.0.last_mut().filter(|v| v.is_u64()) {
            *value = json!(value.as_u64().expect("retain length") + len as u64);
        } else {
            self.0.push(json!(len));
        }
    }
    fn replace(&mut self, len: usize, inserted: Vec<Value>) {
        if len == 0 && inserted.is_empty() {
            return;
        }
        if let Some(value) = self
            .0
            .last_mut()
            .filter(|v| matches!(Section::read(v), Ok(Section::Replace(..))))
        {
            let section = value.as_array_mut().expect("replacement section");
            section[0] = json!(section[0].as_u64().expect("replacement length") + len as u64);
            section[1]
                .as_array_mut()
                .expect("inserted nodes")
                .extend(inserted);
        } else {
            self.0.push(json!([len, inserted]));
        }
    }

    fn marks(&mut self, len: usize, old: &Marks, new: &Marks) {
        let mut modifications = Vec::new();
        for (source, target, action) in [(old, new, "remove"), (new, old, "add")] {
            for (name, value) in source {
                if target.get(name) == Some(value) {
                    continue;
                }
                let value = if name == "Comment" {
                    let other = target.get(name).and_then(Value::as_array);
                    let ids: Vec<_> = value
                        .as_array()
                        .expect("comment identifiers")
                        .iter()
                        .filter(|id| other.is_none_or(|other| !other.contains(id)))
                        .cloned()
                        .collect();
                    if ids.is_empty() {
                        continue;
                    }
                    Value::Array(ids)
                } else {
                    value.clone()
                };
                modifications.push(json!({action: name, "value": value}));
            }
        }
        if modifications.is_empty() {
            self.retain(len);
        } else if let Some(value) = self
            .0
            .last_mut()
            .filter(|value| value.get(1).and_then(Value::as_array) == Some(&modifications))
        {
            value[0] = json!(value[0].as_u64().expect("mark modification length") + len as u64);
        } else {
            self.0.push(json!([len, modifications]));
        }
    }
}

struct Payload<'a>(&'a DocNode);
impl PartialEq for Payload<'_> {
    fn eq(&self, other: &Self) -> bool {
        let (a, b) = (self.0, other.0);
        a.kind == b.kind
            && a.param == b.param
            && match (&a.content, &b.content) {
                (Some(a_children), Some(b_children)) => {
                    if matches!(
                        a.kind,
                        NodeKind::Paragraph
                            | NodeKind::Heading
                            | NodeKind::CodeBlock
                            | NodeKind::Mermaid
                    ) {
                        inline_units(a_children).eq(inline_units(b_children))
                    } else {
                        a_children
                            .iter()
                            .map(Payload)
                            .eq(b_children.iter().map(Payload))
                    }
                }
                (None, None) => true,
                _ => false,
            }
    }
}

fn children(old: &[DocNode], new: &[DocNode], out: &mut Changes) {
    let mut previous = (0, 0);
    // A mark can split a text run into several nodes without changing its payload.
    // Align blocks by their content so reanchoring between repeated paragraphs
    // changes marks in place instead of replacing the selected paragraph.
    let old_payload: Vec<_> = old.iter().map(Payload).collect();
    let new_payload: Vec<_> = new.iter().map(Payload).collect();
    for (a, b) in matches(&old_payload, &new_payload)
        .into_iter()
        .chain([(old.len(), new.len())])
    {
        let removed = &old[previous.0..a];
        let inserted = &new[previous.1..b];
        let paired = removed.len().min(inserted.len());
        for index in 0..paired {
            node(&removed[index], &inserted[index], out);
        }
        out.replace(
            removed[paired..].iter().map(DocNode::span).sum(),
            inserted[paired..].iter().map(DocNode::json).collect(),
        );
        if a < old.len() {
            node(&old[a], &new[b], out);
        }
        previous = (a + 1, b + 1);
    }
}

fn node(old: &DocNode, new: &DocNode, out: &mut Changes) {
    if old == new {
        out.retain(old.span());
    } else if compatible_container(old.kind, new.kind)
        && let (Some(a), Some(b)) = (&old.content, &new.content)
    {
        if old.kind == new.kind && old.param == new.param {
            out.marks(1, &old.marks, &new.marks);
        } else {
            // Retype the opening token. Replacing the subtree would detach concurrent
            // text inserted into it and discard anchors on its retained content.
            let opening = DocNode::new(new.kind, new.param.clone(), new.marks.clone(), None);
            out.replace(1, vec![opening.json()]);
        }
        if matches!(
            old.kind,
            NodeKind::Paragraph | NodeKind::Heading | NodeKind::CodeBlock | NodeKind::Mermaid
        ) {
            inline(a, b, out);
        } else {
            children(a, b, out);
        }
        out.retain(1);
    } else if old.kind == new.kind && old.param == new.param && old.content == new.content {
        out.marks(old.span(), &old.marks, &new.marks);
    } else {
        out.replace(old.span(), vec![new.json()]);
    }
}

/// These conversions keep the same child model, including pending peer edits.
fn compatible_container(old: NodeKind, new: NodeKind) -> bool {
    use NodeKind::{BulletList, Cell, HeaderCell, Heading, OrderedList, Paragraph};
    old == new
        || matches!(
            (old, new),
            (Paragraph | Heading, Paragraph | Heading)
                | (Cell | HeaderCell, Cell | HeaderCell)
                | (BulletList | OrderedList, BulletList | OrderedList)
        )
}

#[derive(Clone, Copy)]
struct InlineUnit<'a> {
    node: &'a DocNode,
    character: Option<char>,
}
impl PartialEq for InlineUnit<'_> {
    fn eq(&self, other: &Self) -> bool {
        match (self.character, other.character) {
            (Some(a), Some(b)) => a == b,
            (None, None) => Payload(self.node) == Payload(other.node),
            _ => false,
        }
    }
}
impl InlineUnit<'_> {
    fn len(&self) -> usize {
        self.character.map_or(1, char::len_utf16)
    }
}

fn inline_units(nodes: &[DocNode]) -> impl Iterator<Item = InlineUnit<'_>> {
    nodes.iter().flat_map(|node| {
        let text =
            (node.kind == NodeKind::Text).then(|| node.param.as_str().expect("text parameter"));
        text.unwrap_or_default()
            .chars()
            .map(Some)
            .chain(text.is_none().then_some(None))
            .map(move |character| InlineUnit { node, character })
    })
}

fn inline(old: &[DocNode], new: &[DocNode], out: &mut Changes) {
    fn inserted(units: &[InlineUnit<'_>]) -> Vec<Value> {
        let mut nodes: Vec<DocNode> = Vec::new();
        for unit in units {
            if let Some(character) = unit.character {
                if let Some(previous) = nodes.last_mut()
                    && previous.kind == NodeKind::Text
                    && previous.marks == unit.node.marks
                {
                    if let Value::String(text) = &mut previous.param {
                        text.push(character);
                    }
                } else {
                    let mut node = unit.node.clone();
                    node.param = json!(character.to_string());
                    nodes.push(node);
                }
            } else {
                nodes.push(unit.node.clone());
            }
        }
        nodes.iter().map(DocNode::json).collect()
    }
    // A scalar is indivisible, so a ChangeSet cannot split a surrogate pair.
    // Marked text shares one stream: changing a mark does not replace the
    // unchanged text that follows it in another inline node.
    let a: Vec<_> = inline_units(old).collect();
    let b: Vec<_> = inline_units(new).collect();
    let mut previous = (0, 0);
    for (x, y) in matches(&a, &b).into_iter().chain([(a.len(), b.len())]) {
        out.replace(
            a[previous.0..x].iter().map(InlineUnit::len).sum(),
            inserted(&b[previous.1..y]),
        );
        if x < a.len() {
            out.marks(a[x].len(), &a[x].node.marks, &b[y].node.marks);
        }
        previous = (x + 1, y + 1);
    }
}

/// Myers' bidirectional middle split uses linear working space. Recursion
/// returns matching coordinates, without retaining an edit-distance trace.
fn matches<T: PartialEq>(a: &[T], b: &[T]) -> Vec<(usize, usize)> {
    fn visit<T: PartialEq>(a: &[T], b: &[T], ax: usize, by: usize, out: &mut Vec<(usize, usize)>) {
        let prefix = a.iter().zip(b).take_while(|(a, b)| a == b).count();
        out.extend((0..prefix).map(|i| (ax + i, by + i)));
        let a = &a[prefix..];
        let b = &b[prefix..];
        let ax = ax + prefix;
        let by = by + prefix;
        let suffix = a
            .iter()
            .rev()
            .zip(b.iter().rev())
            .take_while(|(a, b)| a == b)
            .count();
        let mid_a = &a[..a.len() - suffix];
        let mid_b = &b[..b.len() - suffix];
        if !mid_a.is_empty()
            && !mid_b.is_empty()
            && let Some((x, y)) = split(mid_a, mid_b)
            && (x, y) != (0, 0)
            && (x, y) != (mid_a.len(), mid_b.len())
        {
            visit(&mid_a[..x], &mid_b[..y], ax, by, out);
            visit(&mid_a[x..], &mid_b[y..], ax + x, by + y, out);
        }
        out.extend((0..suffix).map(|i| (ax + mid_a.len() + i, by + mid_b.len() + i)));
    }
    let mut out = Vec::new();
    visit(a, b, 0, 0, &mut out);
    out
}

fn split<T: PartialEq>(a: &[T], b: &[T]) -> Option<(usize, usize)> {
    let n = a.len() as isize;
    let m = b.len() as isize;
    let max = (n + m + 1) / 2;
    let offset = max + 1;
    let index = |k: isize| (offset + k) as usize;
    let mut forward = vec![-1; (2 * max + 3) as usize];
    let mut reverse = forward.clone();
    forward[index(1)] = 0;
    reverse[index(1)] = 0;
    let delta = n - m;
    let odd = delta % 2 != 0;
    for d in 0..=max {
        for k in (-d..=d).step_by(2) {
            let mut x = if k == -d || (k != d && forward[index(k - 1)] < forward[index(k + 1)]) {
                forward[index(k + 1)]
            } else {
                forward[index(k - 1)] + 1
            };
            let mut y = x - k;
            while x >= 0 && y >= 0 && x < n && y < m && a[x as usize] == b[y as usize] {
                x += 1;
                y += 1;
            }
            forward[index(k)] = x;
            let opposite = delta - k;
            if odd
                && opposite.abs() < d
                && reverse[index(opposite)] >= 0
                && x + reverse[index(opposite)] >= n
            {
                return Some((x as usize, y as usize));
            }
        }
        for k in (-d..=d).step_by(2) {
            let mut x = if k == -d || (k != d && reverse[index(k - 1)] < reverse[index(k + 1)]) {
                reverse[index(k + 1)]
            } else {
                reverse[index(k - 1)] + 1
            };
            let mut y = x - k;
            while x >= 0
                && y >= 0
                && x < n
                && y < m
                && a[(n - x - 1) as usize] == b[(m - y - 1) as usize]
            {
                x += 1;
                y += 1;
            }
            reverse[index(k)] = x;
            let opposite = delta - k;
            if !odd
                && opposite.abs() <= d
                && forward[index(opposite)] >= 0
                && x + forward[index(opposite)] >= n
            {
                let x = forward[index(opposite)];
                return Some((x as usize, (x - opposite) as usize));
            }
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::matches;
    use crate::page_document::{annotate_comment, apply, diff, restore_comments, validate};
    use serde_json::{Value, json};

    const A: &str = "019a2b00-0000-7000-8000-000000000001";

    #[test]
    fn compatible_block_conversions_retain_their_content_tokens() {
        for (before, after, expected) in [
            (
                "<page><p>Hello world</p></page>",
                "<page><h1>Hello world</h1></page>",
                json!([[1, [{"type": "Heading"}]], 12]),
            ),
            (
                "<page><h1>Hello world</h1></page>",
                "<page><h2>Hello world</h2></page>",
                json!([[1, [{"type": "Heading", "param": 2}]], 12]),
            ),
            (
                "<page><h2>Hello world</h2></page>",
                "<page><p>Hello world</p></page>",
                json!([[1, [{"type": "Paragraph"}]], 12]),
            ),
            (
                "<page><table><tr><td><p>Hello</p></td></tr></table></page>",
                "<page><table><tr><th><p>Hello</p></th></tr></table></page>",
                json!([2, [1, [{"type": "HeaderCell"}]], 10]),
            ),
            (
                "<page><ul><li><p>Hello</p></li></ul></page>",
                "<page><ol start=\"3\"><li><p>Hello</p></li></ol></page>",
                json!([[1, [{"type": "OrderedList", "param": 3}]], 10]),
            ),
        ] {
            let changes = diff(before, after).unwrap();
            assert_eq!(changes, expected);
            assert_eq!(apply(before, &changes.to_string()).unwrap().xml, after);
        }
    }

    #[test]
    fn agent_heading_conversion_preserves_comments_and_granular_text_changes() {
        let marked = format!("<page><p><comment ids=\"{A}\">Hello</comment> world</p></page>");
        let target = "<page><h2>Hello team</h2></page>";
        let restored = restore_comments(&marked, target).unwrap();
        assert_eq!(
            restored.xml,
            format!("<page><h2><comment ids=\"{A}\">Hello</comment> team</h2></page>")
        );
        let changes = diff(&marked, &restored.xml).unwrap();
        assert_eq!(changes[0], json!([1, [{"type": "Heading", "param": 2}]]));
        assert!(
            changes
                .as_array()
                .unwrap()
                .iter()
                .any(|part| part.as_u64().is_some_and(|n| n >= 5))
        );
        assert_eq!(
            apply(&marked, &changes.to_string()).unwrap().xml,
            restored.xml
        );
    }

    #[test]
    fn native_mark_diffs_match_the_editor_ot_fixtures() {
        let samples: Value = serde_json::from_str(include_str!(
            "../../../../libs/ankole-editor/corpus/rust/mark-diffs.json"
        ))
        .unwrap();
        for sample in samples.as_array().unwrap() {
            let before = sample["before"].as_str().unwrap();
            let after = sample["after"].as_str().unwrap();
            let change = diff(before, after).unwrap();
            assert_eq!(change, sample["changes"], "{}", sample["name"]);
            assert_eq!(apply(before, &change.to_string()).unwrap().xml, after);
        }
    }

    #[test]
    fn native_structural_diffs_match_collaboration_recovery_fixtures() {
        let samples: Value = serde_json::from_str(include_str!(
            "../../../../libs/ankole-editor/corpus/rust/structural-diffs.json"
        ))
        .unwrap();
        for sample in samples.as_array().unwrap() {
            let before = sample["before"].as_str().unwrap();
            let after = sample["after"].as_str().unwrap();
            let change = diff(before, after).unwrap();
            assert_eq!(change, sample["changes"], "{}", sample["name"]);
            assert_eq!(apply(before, &change.to_string()).unwrap().xml, after);
        }
    }

    #[test]
    fn annotation_preserves_utf16_text_and_every_inline_leaf() {
        for (source, length) in [
            (
                "<page><p>a🙂<br /><img src=\"asset\" /><widget>label</widget></p></page>",
                6,
            ),
            ("<page><pre>a🙂\n  b</pre></page>", 7),
        ] {
            let annotated = annotate_comment(source, A, 1, 1 + length).unwrap();
            let change = diff(source, &annotated.xml).unwrap();
            assert_eq!(
                change,
                json!([1, [length, [{"add":"Comment", "value":[A]}]], 1])
            );
            assert_eq!(
                apply(source, &change.to_string()).unwrap().xml,
                annotated.xml
            );
            let removed = diff(&annotated.xml, source).unwrap();
            assert_eq!(
                removed,
                json!([1, [length, [{"remove":"Comment", "value":[A]}]], 1])
            );
        }
    }

    #[test]
    fn reanchoring_between_repeated_paragraphs_preserves_both_text_streams() {
        let source = "<page><p>Hello world</p><p>Hello world</p></page>";
        for length in [5, 11] {
            let before = annotate_comment(source, A, 1, 1 + length).unwrap();
            let after = annotate_comment(&before.xml, A, 14, 14 + length).unwrap();
            let change = diff(&before.xml, &after.xml).unwrap();
            assert_eq!(
                change,
                json!([1, [length, [{"remove":"Comment", "value":[A]}]], 13 - length,
                    [length, [{"add":"Comment", "value":[A]}]], 12 - length])
            );
            assert_eq!(
                apply(&before.xml, &change.to_string()).unwrap().xml,
                after.xml
            );
        }
    }

    #[test]
    fn replacements_do_not_merge_into_adjacent_mark_modifications() {
        for (before, after) in [
            (
                "<page><p>abc</p></page>",
                "<page><p><strong>a</strong>xc</p></page>",
            ),
            (
                "<page><p>abc</p></page>",
                "<page><p>x<strong>b</strong>z</p></page>",
            ),
            (
                "<page><p>abc</p></page>",
                "<page><p><strong>a</strong>c</p></page>",
            ),
            (
                "<page><p>abc</p></page>",
                "<page><p>a<strong>b</strong>xc</p></page>",
            ),
            (
                "<page><p>abc</p></page>",
                "<page><p align=\"center\">abc</p></page>",
            ),
        ] {
            let change = diff(before, after).unwrap();
            assert_eq!(
                apply(before, &change.to_string()).unwrap().xml,
                validate(after).unwrap().xml
            );
        }
    }

    #[test]
    fn middle_split_has_the_same_lcs_length_as_the_reference_table() {
        let strings: Vec<Vec<u8>> = (0..121)
            .map(|mut seed| {
                let mut value = Vec::new();
                while seed > 0 {
                    value.push(b'a' + ((seed - 1) % 3) as u8);
                    seed = (seed - 1) / 3;
                }
                value
            })
            .collect();
        for a in &strings {
            for b in &strings {
                let mut table = vec![vec![0; b.len() + 1]; a.len() + 1];
                for x in 0..a.len() {
                    for y in 0..b.len() {
                        table[x + 1][y + 1] = if a[x] == b[y] {
                            table[x][y] + 1
                        } else {
                            table[x][y + 1].max(table[x + 1][y])
                        };
                    }
                }
                let matched = matches(a, b);
                assert_eq!(matched.len(), table[a.len()][b.len()], "{a:?} {b:?}");
                assert!(matched.iter().all(|&(x, y)| a[x] == b[y]));
                assert!(
                    matched
                        .windows(2)
                        .all(|pair| pair[0].0 < pair[1].0 && pair[0].1 < pair[1].1)
                );
            }
        }
    }
}
