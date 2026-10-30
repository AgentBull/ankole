use super::document_schema::{DocNode, Marks, NodeKind, is_container, validate_mark};
use super::tree::{self, Result};
use serde_json::{Value, json};

// Bound the input before DocNode::from_json clones parameters or builds a recursive document.
fn count_inserted(value: &Value, depth: usize, count: &mut usize) -> Result<()> {
    *count += 1;
    if *count > tree::NODE_LIMIT || depth > tree::DEPTH_LIMIT {
        return Err("inserted document node or depth limit exceeded".into());
    }
    if let Some(children) = value.get("content").and_then(Value::as_array) {
        for child in children {
            count_inserted(child, depth + 1, count)?;
        }
    }
    // Frozen unknown elements carry their children in param rather than content.
    if let Some(children) = value
        .get("param")
        .and_then(|p| p.get("children"))
        .and_then(Value::as_array)
    {
        for child in children {
            count_frozen(child, depth + 1, count)?;
        }
    }
    Ok(())
}
fn count_frozen(value: &Value, depth: usize, count: &mut usize) -> Result<()> {
    *count += 1;
    if *count > tree::NODE_LIMIT || depth > tree::DEPTH_LIMIT {
        return Err("inserted document node or depth limit exceeded".into());
    }
    if let Some(children) = value.get("children").and_then(Value::as_array) {
        for child in children {
            count_frozen(child, depth + 1, count)?;
        }
    }
    Ok(())
}

#[derive(Clone)]
enum Token {
    Open(DocNode),
    Close,
    Leaf(DocNode),
}
impl Token {
    fn len(&self) -> usize {
        match self {
            Self::Leaf(n) => n.span(),
            _ => 1,
        }
    }
}
fn tokens(node: &DocNode, out: &mut Vec<Token>) {
    if let Some(children) = &node.content {
        if node.kind != NodeKind::Doc {
            out.push(Token::Open(DocNode::new(
                node.kind,
                node.param.clone(),
                node.marks.clone(),
                Some(Vec::new()),
            )));
        }
        for child in children {
            tokens(child, out);
        }
        if node.kind != NodeKind::Doc {
            out.push(Token::Close);
        }
    } else {
        out.push(Token::Leaf(node.clone()));
    }
}
fn append_tokens(
    out: &mut Vec<Token>,
    depth: &mut usize,
    tokens: impl IntoIterator<Item = Token>,
) -> Result<()> {
    for token in tokens {
        match &token {
            Token::Open(_) => {
                *depth += 1;
                if *depth > tree::DEPTH_LIMIT + 1 {
                    return Err("document depth limit exceeded".into());
                }
            }
            Token::Close => {
                if *depth == 0 {
                    return Err("surplus close token".into());
                }
                *depth -= 1;
            }
            Token::Leaf(node) if node.kind == NodeKind::Text => {
                if let Some(Token::Leaf(previous)) = out.last_mut()
                    && previous.kind == NodeKind::Text
                    && previous.marks == node.marks
                    && let Value::String(text) = &mut previous.param
                    && let Some(suffix) = node.param.as_str()
                {
                    text.push_str(suffix);
                    continue;
                }
            }
            _ => {}
        }
        out.push(token);
    }
    Ok(())
}
fn parse_token(
    value: &Value,
    out: &mut Vec<Token>,
    inserted: &mut usize,
    depth: &mut usize,
) -> Result<()> {
    if value.as_str() == Some(".") {
        return append_tokens(out, depth, [Token::Close]);
    }
    count_inserted(value, 0, inserted)?;
    let node = DocNode::from_json(value)?;
    if is_container(node.kind) && value.get("content").is_none() {
        append_tokens(out, depth, [Token::Open(node)])?;
    } else {
        let mut inserted = Vec::new();
        tokens(&node, &mut inserted);
        append_tokens(out, depth, inserted)?;
    }
    Ok(())
}
fn slice_tokens(source: &[Token], from: usize, len: usize) -> Result<Vec<Token>> {
    let mut out = Vec::new();
    let mut offset: usize = 0;
    let end = from.checked_add(len).ok_or("change length overflow")?;
    for token in source {
        let next = offset + token.len();
        if offset < end && next > from {
            if offset >= from && next <= end {
                out.push(token.clone());
            } else if let Token::Leaf(node) = token {
                if node.kind == NodeKind::Text {
                    let start = from.saturating_sub(offset);
                    let stop = (end - offset).min(node.span());
                    let text = node.text_slice(start, stop)?;
                    let mut part = node.clone();
                    part.param = json!(text);
                    out.push(Token::Leaf(part));
                } else {
                    out.push(token.clone());
                }
            } else {
                out.push(token.clone());
            }
        }
        offset = next;
        if offset >= end {
            break;
        }
    }
    Ok(out)
}
/// A borrowed view of the wire format, shared by application and anchor preservation.
pub(super) enum Section<'a> {
    Retain(usize),
    Marks(usize, &'a [Value]),
    Replace(usize, &'a [Value]),
}
impl<'a> Section<'a> {
    pub(super) fn read(value: &'a Value) -> Result<Self> {
        if let Some(length) = value.as_u64() {
            return Ok(Self::Retain(
                usize::try_from(length).map_err(|_| "invalid change length")?,
            ));
        }
        let section = value
            .as_array()
            .filter(|s| s.len() == 2)
            .ok_or("invalid ChangeSet section")?;
        let length = usize::try_from(section[0].as_u64().ok_or("invalid change length")?)
            .map_err(|_| "invalid change length")?;
        let data = section[1].as_array().ok_or("invalid ChangeSet data")?;
        Ok(if is_mark_modification(data) {
            Self::Marks(length, data)
        } else {
            Self::Replace(length, data)
        })
    }
    fn source_len(&self) -> usize {
        match self {
            Self::Retain(n) | Self::Marks(n, _) | Self::Replace(n, _) => *n,
        }
    }
    fn preserves_source(&self) -> bool {
        !matches!(self, Self::Replace(..))
    }
}

pub(super) fn retained_ranges(changes: &Value) -> Result<Vec<(usize, usize)>> {
    let mut ranges: Vec<(usize, usize)> = Vec::new();
    let mut offset = 0usize;
    let mut continuing = false;
    for value in changes.as_array().ok_or("ChangeSet must be an array")? {
        let section = Section::read(value)?;
        let end = offset
            .checked_add(section.source_len())
            .ok_or("change length overflow")?;
        if section.preserves_source() {
            if let Some(last) = ranges
                .last_mut()
                .filter(|last| continuing && last.1 == offset)
            {
                last.1 = end;
            } else {
                ranges.push((offset, end));
            }
        }
        continuing = section.preserves_source();
        offset = end;
    }
    Ok(ranges)
}

fn is_mark_modification(data: &[Value]) -> bool {
    data.first()
        .is_some_and(|value| value.get("add").is_some() || value.get("remove").is_some())
}

pub fn apply(doc: &DocNode, changes: &Value) -> Result<DocNode> {
    let changes = changes.as_array().ok_or("ChangeSet must be an array")?;
    let mut source = Vec::new();
    tokens(doc, &mut source);
    let length: usize = source.iter().map(Token::len).sum();
    let mut offset: usize = 0;
    let mut output = Vec::new();
    let mut inserted = 0;
    let mut depth = 0;
    for section in changes {
        let section = Section::read(section)?;
        let len = section.source_len();
        if offset.checked_add(len).is_none_or(|end| end > length) {
            return Err("change exceeds document".into());
        }
        match section {
            Section::Retain(_) => {
                append_tokens(&mut output, &mut depth, slice_tokens(&source, offset, len)?)?;
            }
            Section::Marks(_, data) => {
                let mut kept = slice_tokens(&source, offset, len)?;
                for modification in data {
                    let (add, name) =
                        if let Some(name) = modification.get("add").and_then(Value::as_str) {
                            (true, name)
                        } else {
                            (
                                false,
                                modification
                                    .get("remove")
                                    .and_then(Value::as_str)
                                    .ok_or("invalid mark modification")?,
                            )
                        };
                    let value = modification.get("value").ok_or("missing mark value")?;
                    validate_mark(name, value)?;
                    for token in &mut kept {
                        let node = match token {
                            Token::Open(n) | Token::Leaf(n) => n,
                            Token::Close => return Err("mark modification on close token".into()),
                        };
                        if name == "Comment" {
                            super::comments::modify_mark(
                                node,
                                value.as_array().expect("validated comment identifiers"),
                                add,
                            );
                        } else if add {
                            node.marks.insert(name.into(), value.clone());
                        } else if node.marks.get(name) == Some(value) {
                            node.marks.remove(name);
                        }
                    }
                }
                append_tokens(&mut output, &mut depth, kept)?;
            }
            Section::Replace(_, data) => {
                for value in data {
                    parse_token(value, &mut output, &mut inserted, &mut depth)?;
                }
            }
        }
        offset += len;
    }
    if offset != length {
        return Err("ChangeSet does not cover document".into());
    }
    let mut stack = vec![DocNode::new(
        NodeKind::Doc,
        Value::Null,
        Marks::new(),
        Some(Vec::new()),
    )];
    for token in output {
        match token {
            Token::Open(node) => {
                if stack.len() > tree::DEPTH_LIMIT + 1 {
                    return Err("document depth limit exceeded".into());
                }
                stack.push(node);
            }
            Token::Close => {
                if stack.len() == 1 {
                    return Err("surplus close token".into());
                }
                let node = stack.pop().expect("stack has open container");
                node.validate()?;
                push_node(stack.last_mut().expect("stack has parent container"), node);
            }
            Token::Leaf(node) => {
                node.validate()?;
                push_node(stack.last_mut().expect("stack has parent container"), node);
            }
        }
    }
    if stack.len() != 1 {
        return Err("unclosed document plot".into());
    }
    let result = stack.pop().expect("stack has root document");
    result.validate()?;
    Ok(result)
}
fn push_node(parent: &mut DocNode, node: DocNode) {
    let children = parent
        .content
        .as_mut()
        .expect("container node has children");
    if node.kind == NodeKind::Text
        && let Some(previous) = children.last_mut()
        && previous.kind == NodeKind::Text
        && previous.marks == node.marks
    {
        if let Value::String(text) = &mut previous.param
            && let Some(suffix) = node.param.as_str()
        {
            text.push_str(suffix);
        }
        return;
    }
    children.push(node);
}
