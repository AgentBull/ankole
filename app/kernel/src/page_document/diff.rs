use super::document::{DocNode, NodeKind};
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
        if let Some(value) = self.0.last_mut().filter(|v| v.is_array()) {
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
}

fn span(node: &DocNode) -> usize {
    if let Some(children) = &node.content {
        2 + children.iter().map(span).sum::<usize>()
    } else if node.kind == NodeKind::Text {
        node.param
            .as_str()
            .expect("text parameter")
            .encode_utf16()
            .count()
    } else {
        1
    }
}

fn children(old: &[DocNode], new: &[DocNode], out: &mut Changes) {
    let mut previous = (0, 0);
    for (a, b) in matches(old, new)
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
            removed[paired..].iter().map(span).sum(),
            inserted[paired..].iter().map(DocNode::json).collect(),
        );
        if a < old.len() {
            out.retain(span(&old[a]));
        }
        previous = (a + 1, b + 1);
    }
}

fn node(old: &DocNode, new: &DocNode, out: &mut Changes) {
    if old == new {
        out.retain(span(old));
    } else if old.kind == new.kind
        && old.param == new.param
        && old.marks == new.marks
        && let (Some(a), Some(b)) = (&old.content, &new.content)
    {
        out.retain(1);
        if matches!(
            old.kind,
            NodeKind::Paragraph | NodeKind::Heading | NodeKind::CodeBlock
        ) {
            inline(a, b, out);
        } else {
            children(a, b, out);
        }
        out.retain(1);
    } else {
        out.replace(span(old), vec![new.json()]);
    }
}

#[derive(Clone, Copy)]
struct InlineUnit<'a> {
    node: &'a DocNode,
    character: Option<char>,
}
impl PartialEq for InlineUnit<'_> {
    fn eq(&self, other: &Self) -> bool {
        match (self.character, other.character) {
            (Some(a), Some(b)) => a == b && self.node.marks == other.node.marks,
            (None, None) => self.node == other.node,
            _ => false,
        }
    }
}
impl InlineUnit<'_> {
    fn len(&self) -> usize {
        self.character.map_or(1, char::len_utf16)
    }
}

fn inline(old: &[DocNode], new: &[DocNode], out: &mut Changes) {
    fn units(nodes: &[DocNode]) -> Vec<InlineUnit<'_>> {
        nodes
            .iter()
            .flat_map(|node| {
                if node.kind == NodeKind::Text {
                    node.param
                        .as_str()
                        .expect("text parameter")
                        .chars()
                        .map(|character| InlineUnit {
                            node,
                            character: Some(character),
                        })
                        .collect()
                } else {
                    vec![InlineUnit {
                        node,
                        character: None,
                    }]
                }
            })
            .collect()
    }
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
    let a = units(old);
    let b = units(new);
    let mut previous = (0, 0);
    for (x, y) in matches(&a, &b).into_iter().chain([(a.len(), b.len())]) {
        out.replace(
            a[previous.0..x].iter().map(InlineUnit::len).sum(),
            inserted(&b[previous.1..y]),
        );
        if x < a.len() {
            out.retain(a[x].len());
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
