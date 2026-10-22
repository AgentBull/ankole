use std::collections::BTreeMap;
use std::sync::LazyLock;

use quick_xml::{Reader, XmlVersion, events::Event};
use regex::Regex;
use serde::{Deserialize, Serialize};

pub type Result<T> = std::result::Result<T, String>;
pub type Attrs = BTreeMap<String, String>;
pub const SOURCE_LIMIT: usize = 8 * 1024 * 1024;
pub const NODE_LIMIT: usize = 100_000;
pub const DEPTH_LIMIT: usize = 128;
pub const SPAN_LIMIT: u32 = 9_999;
pub const FORMATS: [&str; 8] = ["strong", "em", "s", "u", "mark", "sub", "sup", "code"];

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Node {
    Text(String),
    Element(Element),
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Element {
    pub name: String,
    pub attrs: Attrs,
    pub children: Vec<Node>,
}

// Frozen elements use strings for text, as the editor does.
impl Serialize for Node {
    fn serialize<S: serde::Serializer>(
        &self,
        serializer: S,
    ) -> std::result::Result<S::Ok, S::Error> {
        match self {
            Self::Text(value) => value.serialize(serializer),
            Self::Element(value) => value.serialize(serializer),
        }
    }
}
impl<'de> Deserialize<'de> for Node {
    fn deserialize<D: serde::Deserializer<'de>>(
        deserializer: D,
    ) -> std::result::Result<Self, D::Error> {
        let value = serde_json::Value::deserialize(deserializer)?;
        if let Some(text) = value.as_str() {
            Ok(Self::Text(text.into()))
        } else {
            serde_json::from_value(value)
                .map(Self::Element)
                .map_err(serde::de::Error::custom)
        }
    }
}

pub fn element(name: impl Into<String>, attrs: Attrs, children: Vec<Node>) -> Element {
    Element {
        name: name.into(),
        attrs,
        children,
    }
}
pub fn valid_character(c: char) -> bool {
    matches!(c as u32, 9 | 10 | 13 | 0x20..=0xd7ff | 0xe000..=0xfffd | 0x10000..=0x10ffff)
}
fn layout(value: &str) -> bool {
    value.chars().all(|c| matches!(c, ' ' | '\t' | '\r' | '\n'))
}
fn name_valid(name: &str, attribute: bool) -> bool {
    static ELEMENT: LazyLock<Regex> =
        LazyLock::new(|| Regex::new(r"^\p{L}[\p{L}\p{N}_-]*$").expect("valid static regex"));
    static ATTRIBUTE: LazyLock<Regex> =
        LazyLock::new(|| Regex::new(r"^[\p{L}_][\p{L}\p{N}_-]*$").expect("valid static regex"));
    // Intersect the Markdown name grammar with XML 1.0 NameChar (the editor uses xmlchars).
    let xml_name = name.chars().all(|c| {
        matches!(c as u32,
        0x2d..=0x2e | 0x30..=0x3a | 0x41..=0x5a | 0x5f | 0x61..=0x7a | 0xb7 |
        0xc0..=0xd6 | 0xd8..=0xf6 | 0xf8..=0x2ff | 0x300..=0x37d | 0x37f..=0x1fff |
        0x200c..=0x200d | 0x203f..=0x2040 | 0x2070..=0x218f | 0x2c00..=0x2fef |
        0x3001..=0xd7ff | 0xf900..=0xfdcf | 0xfdf0..=0xfffd | 0x10000..=0xeffff)
    });
    if !xml_name {
        return false;
    }
    if attribute {
        name != "xmlns" && ATTRIBUTE.is_match(name)
    } else {
        ELEMENT.is_match(name)
    }
}

pub fn parse(source: &str) -> Result<Element> {
    if source.encode_utf16().count() > SOURCE_LIMIT {
        return Err("page source exceeds the UTF-16 limit".into());
    }
    if !source.chars().all(valid_character) {
        return Err("XML 1.0 contains an invalid character".into());
    }
    let mut reader = Reader::from_str(source);
    reader.config_mut().expand_empty_elements = true;
    let mut stack: Vec<Element> = Vec::new();
    let mut root = None;
    let mut elements = 0;
    let mut declaration = false;
    loop {
        match reader.read_event().map_err(|e| e.to_string())? {
            Event::Start(tag) => {
                elements += 1;
                if elements > NODE_LIMIT || stack.len() > DEPTH_LIMIT {
                    return Err("page node or depth limit exceeded".into());
                }
                if stack.is_empty() && root.is_some() {
                    return Err("multiple XML roots".into());
                }
                let name = tag.name().as_ref().to_owned();
                if !name_valid(&name, false) {
                    return Err("invalid element name".into());
                }
                let mut attrs = Attrs::new();
                for attribute in tag.attributes() {
                    let attribute = attribute.map_err(|e| e.to_string())?;
                    let key = attribute.key.as_ref().to_owned();
                    if !name_valid(&key, true) {
                        return Err("invalid attribute name".into());
                    }
                    if attribute.value.contains('<') {
                        return Err("XML attributes must escape less-than signs".into());
                    }
                    let value = attribute
                        .normalized_value(XmlVersion::Implicit1_0)
                        .map_err(|e| e.to_string())?
                        .into_owned();
                    attrs.insert(key, value);
                }
                stack.push(element(name, attrs, Vec::new()));
            }
            Event::End(_) => {
                let node = stack.pop().ok_or("surplus XML close tag")?;
                if let Some(parent) = stack.last_mut() {
                    parent.children.push(Node::Element(node));
                } else {
                    root = Some(node);
                }
            }
            Event::Text(value) => {
                if value.as_ref().contains("]]>") {
                    return Err("CDATA terminator in XML text".into());
                }
                add_text(&mut stack, value.xml10_content().into_owned())?;
            }
            Event::CData(value) => {
                if stack.is_empty() {
                    return Err("CDATA outside page".into());
                }
                add_text(&mut stack, value.xml10_content().into_owned())?;
            }
            Event::GeneralRef(value) => {
                let value = quick_xml::escape::unescape(&format!("&{};", value.as_ref()))
                    .map_err(|e| e.to_string())?
                    .into_owned();
                add_text(&mut stack, value)?;
            }
            Event::Decl(value) => {
                if declaration
                    || !source.trim_start_matches('\u{feff}').starts_with("<?xml")
                    || !stack.is_empty()
                    || root.is_some()
                    || reader.buffer_position() as usize != source.find("?>").unwrap_or(0) + 2
                {
                    return Err("XML declaration must be first".into());
                }
                declaration = true;
                if value.version().map_err(|e| e.to_string())? != "1.0" {
                    return Err("only XML 1.0 is supported".into());
                }
                if let Some(encoding) = value.encoding()
                    && !encoding
                        .map_err(|e| e.to_string())?
                        .eq_ignore_ascii_case("utf-8")
                {
                    return Err("XML encoding must be UTF-8".into());
                }
            }
            Event::Comment(_) | Event::PI(_) | Event::DocType(_) => {
                return Err(
                    "page XML does not support comments, processing instructions or DTD".into(),
                );
            }
            Event::Eof => break,
            Event::Empty(_) => unreachable!("expanded empty elements"),
        }
    }
    if !stack.is_empty() {
        return Err("unclosed XML element".into());
    }
    normalize(root.ok_or("missing page root")?)
}
fn add_text(stack: &mut [Element], value: String) -> Result<()> {
    if !value.chars().all(valid_character) {
        return Err("invalid XML character reference".into());
    }
    if let Some(parent) = stack.last_mut() {
        // Adjacent events (entities and CDATA) are one text node after XML parsing.
        if let Some(Node::Text(previous)) = parent.children.last_mut() {
            previous.push_str(&value);
        } else {
            parent.children.push(Node::Text(value));
        }
    } else if !layout(&value) {
        return Err("text outside page root".into());
    }
    Ok(())
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Content {
    Blocks,
    Inline,
    Text,
    Empty,
    Items,
    Rows,
    Cells,
    Unknown,
}
fn content(name: &str) -> Content {
    match name {
        "page" | "blockquote" | "li" | "th" | "td" | "callout" => Content::Blocks,
        "p" | "h1" | "h2" | "h3" | "h4" | "h5" | "h6" | "a" | "span" => Content::Inline,
        "pre" => Content::Text,
        "hr" | "embed" | "img" | "br" => Content::Empty,
        "ul" | "ol" => Content::Items,
        "table" => Content::Rows,
        "tr" => Content::Cells,
        value if FORMATS.contains(&value) => Content::Inline,
        _ => Content::Unknown,
    }
}
fn is_inline(name: &str) -> bool {
    matches!(name, "a" | "span" | "img" | "br") || FORMATS.contains(&name)
}
fn known(name: &str) -> bool {
    content(name) != Content::Unknown
}
fn allowed_attribute(name: &str, key: &str) -> bool {
    match name {
        "p" | "h1" | "h2" | "h3" | "h4" | "h5" | "h6" => {
            matches!(key, "align" | "indent" | "style")
        }
        "th" | "td" => matches!(key, "align" | "colspan" | "rowspan"),
        "ol" => key == "start",
        "li" => key == "task",
        "pre" => matches!(key, "lang" | "meta"),
        "callout" => key == "tone",
        "embed" => matches!(key, "ref" | "table" | "view"),
        "a" => matches!(key, "href" | "title"),
        "img" => matches!(key, "src" | "alt" | "title"),
        "span" => key == "style",
        _ => false,
    }
}
fn integer_text(value: &str, min: u32, max: u32) -> bool {
    !value.is_empty()
        && (value == "0" || !value.starts_with('0'))
        && value.bytes().all(|c| c.is_ascii_digit())
        && value.parse::<u32>().is_ok_and(|v| (min..=max).contains(&v))
}
fn attributes(node: &Element) -> Result<Attrs> {
    if node.name == "page" && !node.attrs.is_empty() {
        return Err("page has no attributes".into());
    }
    let mut result = Attrs::new();
    for (key, value) in &node.attrs {
        if !name_valid(key, true) || !value.chars().all(valid_character) {
            return Err("invalid XML attribute".into());
        }
        if allowed_attribute(&node.name, key) {
            let valid = match key.as_str() {
                "align" => ["left", "center", "right", "justify"].contains(&value.as_str()),
                "indent" => integer_text(value, 1, 999),
                "start" => integer_text(value, 0, 999_999_999),
                "colspan" | "rowspan" => integer_text(value, 1, SPAN_LIMIT),
                "task" => ["todo", "done"].contains(&value.as_str()),
                "tone" => ["info", "warning"].contains(&value.as_str()),
                _ => true,
            };
            if !valid {
                return Err(format!("invalid {} attribute {key}", node.name));
            }
            if (value.is_empty()
                && ["alt", "lang", "meta", "style", "title"].contains(&key.as_str()))
                || (value == "1"
                    && (key == "colspan"
                        || key == "rowspan"
                        || (key == "start" && node.name == "ol")))
            {
                continue;
            }
        }
        result.insert(key.clone(), value.clone());
    }
    let required = match node.name.as_str() {
        "a" => Some("href"),
        "img" => Some("src"),
        _ => None,
    };
    if required.is_some_and(|key| !result.contains_key(key)) {
        return Err("missing required attribute".into());
    }
    Ok(result)
}
fn count(depth: usize, count: &mut usize) -> Result<()> {
    *count += 1;
    if *count > NODE_LIMIT || depth > DEPTH_LIMIT {
        return Err("page node or depth limit exceeded".into());
    }
    Ok(())
}
pub fn normalize(root: Element) -> Result<Element> {
    if root.name != "page" {
        return Err("root element must be page".into());
    }
    normalize_element(root, None, 0, &mut 0)
}
fn normalize_element(
    node: Element,
    parent: Option<&str>,
    depth: usize,
    size: &mut usize,
) -> Result<Element> {
    count(depth, size)?;
    if !name_valid(&node.name, false) || (parent.is_some() && node.name == "page") {
        return Err("invalid or nested page element".into());
    }
    let valid_parent = match node.name.as_str() {
        "li" => matches!(parent, Some("ul" | "ol")),
        "tr" => parent == Some("table"),
        "th" | "td" => parent == Some("tr"),
        _ => true,
    };
    if !valid_parent {
        return Err(format!("invalid parent for {}", node.name));
    }
    let attrs = attributes(&node)?;
    let children = match content(&node.name) {
        Content::Inline => normalize_inline(node.children, &node.name, depth, size)?,
        Content::Empty => {
            if node
                .children
                .iter()
                .any(|child| !matches!(child,Node::Text(value) if value.is_empty()))
            {
                return Err("empty element has children".into());
            }
            Vec::new()
        }
        Content::Text => {
            let mut text = String::new();
            for child in node.children {
                count(depth + 1, size)?;
                match child {
                    Node::Text(value) if value.chars().all(valid_character) => {
                        text.push_str(&value)
                    }
                    _ => return Err("pre can contain text only".into()),
                }
            }
            if text.is_empty() {
                Vec::new()
            } else {
                vec![Node::Text(text)]
            }
        }
        Content::Unknown => unknown_children(node.children, &node.name, depth, size)?,
        kind => block_children(node.children, &node.name, kind, depth, size)?,
    };
    Ok(element(node.name, attrs, children))
}
fn block_children(
    children: Vec<Node>,
    parent: &str,
    kind: Content,
    depth: usize,
    size: &mut usize,
) -> Result<Vec<Node>> {
    let mut result: Vec<Node> = Vec::new();
    for child in children {
        let node = match child {
            Node::Text(value) if layout(&value) && value.chars().all(valid_character) => continue,
            Node::Text(_) => return Err("block content must be inside a block element".into()),
            Node::Element(node) => node,
        };
        let allowed = match kind {
            Content::Items => node.name == "li",
            Content::Rows => node.name == "tr",
            Content::Cells => matches!(node.name.as_str(), "th" | "td"),
            _ => !is_inline(&node.name),
        };
        if !allowed {
            return Err(format!("invalid child {} in {parent}", node.name));
        }
        let normalized = normalize_element(node, Some(parent), depth + 1, size)?;
        if matches!(normalized.name.as_str(), "ul" | "ol") && normalized.children.is_empty() {
            continue;
        }
        if let Some(Node::Element(previous)) = result.last_mut()
            && matches!(normalized.name.as_str(), "ul" | "ol")
            && previous.name == normalized.name
        {
            for (key, value) in normalized.attrs {
                if key == "start" {
                    continue;
                }
                if previous.attrs.get(&key).is_some_and(|old| old != &value) {
                    return Err("adjacent list attributes conflict".into());
                }
                previous.attrs.entry(key).or_insert(value);
            }
            previous.children.extend(normalized.children);
            continue;
        }
        result.push(Node::Element(normalized));
    }
    Ok(result)
}
fn unknown_children(
    children: Vec<Node>,
    parent: &str,
    depth: usize,
    size: &mut usize,
) -> Result<Vec<Node>> {
    let children: Vec<Node> = children
        .into_iter()
        .filter(|c| !matches!(c,Node::Text(t) if t.is_empty()))
        .collect();
    let inline = children.iter().any(|c| match c {
        Node::Text(t) => !layout(t),
        Node::Element(n) => is_inline(&n.name),
    });
    let block = children
        .iter()
        .any(|c| matches!(c,Node::Element(n) if known(&n.name) && !is_inline(&n.name)));
    if inline && block {
        return Err("unknown element mixes block and inline content".into());
    }
    if block {
        return block_children(children, parent, Content::Blocks, depth, size);
    }
    if !inline
        && children.iter().any(|c| matches!(c, Node::Element(_)))
        && children.iter().all(|c| {
            matches!(c, Node::Element(_)) || matches!(c,Node::Text(t) if t.contains(['\r','\n']))
        })
    {
        return children
            .into_iter()
            .filter_map(|c| {
                if let Node::Element(n) = c {
                    Some(normalize_element(n, Some(parent), depth + 1, size).map(Node::Element))
                } else {
                    None
                }
            })
            .collect();
    }
    normalize_inline(children, parent, depth, size)
}

#[derive(Clone, Default)]
struct Context {
    marks: Vec<String>,
    style: String,
    link: Option<Attrs>,
}
#[derive(Clone)]
struct Atom {
    value: Option<String>,
    node: Option<Element>,
    context: Context,
}
pub(super) fn join_style(outer: &str, inner: &str) -> String {
    if outer.trim_matches(js_whitespace).is_empty() {
        inner.into()
    } else if inner.trim_matches(js_whitespace).is_empty() {
        outer.into()
    } else {
        format!(
            "{outer}{} {inner}",
            if outer.trim_end_matches(js_whitespace).ends_with(';') {
                ""
            } else {
                ";"
            }
        )
    }
}
fn flatten(
    children: Vec<Node>,
    context: &Context,
    out: &mut Vec<Atom>,
    parent: &str,
    depth: usize,
    size: &mut usize,
) -> Result<()> {
    for child in children {
        let node = match child {
            Node::Text(value) => {
                count(depth, size)?;
                if !value.chars().all(valid_character) {
                    return Err("invalid XML character".into());
                }
                if !value.is_empty() {
                    out.push(Atom {
                        value: Some(value),
                        node: None,
                        context: context.clone(),
                    });
                }
                continue;
            }
            Node::Element(node) => node,
        };
        if !name_valid(&node.name, false) {
            return Err("invalid element name".into());
        }
        if known(&node.name) && !is_inline(&node.name) {
            return Err("block element in inline content".into());
        }
        if FORMATS.contains(&node.name.as_str()) && node.attrs.is_empty() {
            count(depth, size)?;
            let mut next = context.clone();
            next.marks = FORMATS
                .iter()
                .filter(|name| **name == node.name || context.marks.iter().any(|m| m == **name))
                .map(|s| (*s).into())
                .collect();
            flatten(node.children, &next, out, parent, depth + 1, size)?;
        } else if node.name == "span" && node.attrs.keys().all(|key| key == "style") {
            count(depth, size)?;
            let mut next = context.clone();
            next.style = join_style(
                &context.style,
                node.attrs.get("style").map_or("", String::as_str),
            );
            flatten(node.children, &next, out, parent, depth + 1, size)?;
        } else if node.name == "a" {
            count(depth, size)?;
            if context.link.is_some() {
                return Err("nested links".into());
            }
            let link = attributes(&node)?;
            let mut next = context.clone();
            next.link = Some(link.clone());
            let mut inner = Vec::new();
            flatten(node.children, &next, &mut inner, parent, depth + 1, size)?;
            if inner.is_empty() {
                out.push(Atom {
                    value: None,
                    node: Some(element("a", link, Vec::new())),
                    context: context.clone(),
                });
            } else {
                out.extend(inner);
            }
        } else {
            let atom_context = if matches!(node.name.as_str(), "br" | "img") {
                Context {
                    link: context.link.clone(),
                    ..Context::default()
                }
            } else {
                context.clone()
            };
            out.push(Atom {
                value: None,
                node: Some(normalize_element(node, Some(parent), depth, size)?),
                context: atom_context,
            });
        }
    }
    Ok(())
}
fn decorated(atom: &Atom) -> bool {
    atom.context
        .marks
        .iter()
        .any(|m| ["code", "u", "s", "mark"].contains(&m.as_str()))
}
fn neighbour(atoms: &[Atom], index: usize, own: &str, direction: isize) -> Option<char> {
    let edge = |value: &str, visible: bool| {
        let mut chars = value
            .chars()
            .filter(|c| visible || !matches!(c, ' ' | '\t' | '\r' | '\n'));
        if direction < 0 {
            chars.next_back()
        } else {
            chars.next()
        }
    };
    if let Some(c) = edge(own, false) {
        return Some(c);
    }
    let mut i = index as isize + direction;
    while i >= 0 && (i as usize) < atoms.len() {
        let atom = &atoms[i as usize];
        if let Some(node) = &atom.node {
            return if node.name == "br" { None } else { Some('x') };
        }
        if let Some(c) = edge(atom.value.as_deref().unwrap_or(""), decorated(atom)) {
            return Some(c);
        }
        i += direction;
    }
    None
}
fn convert_line_breaks(atoms: &mut [Atom]) {
    static BREAK: LazyLock<Regex> = LazyLock::new(|| {
        Regex::new(r"[ \t]*(?:\r\n|\r|\n)[ \t\r\n]*").expect("valid static regex")
    });
    static CODE_BREAK: LazyLock<Regex> =
        LazyLock::new(|| Regex::new(r"\r\n|\r|\n").expect("valid static regex"));
    static CLOSE: LazyLock<Regex> = LazyLock::new(|| {
        Regex::new(
            r"[\p{Han}\p{Hiragana}\p{Katakana}\u3000-\u303f\u30fc\ufe30-\ufe4f\uff00-\uffef]",
        )
        .expect("valid static regex")
    });
    for i in 0..atoms.len() {
        if !atoms[i]
            .value
            .as_deref()
            .is_some_and(|v| v.contains(['\r', '\n']))
        {
            continue;
        }
        let Some(value) = atoms[i].value.clone() else {
            continue;
        };
        let result = if atoms[i].context.marks.iter().any(|m| m == "code") {
            CODE_BREAK.replace_all(&value, " ").into_owned()
        } else {
            let mut out = String::new();
            let mut offset = 0;
            for found in BREAK.find_iter(&value) {
                out.push_str(&value[offset..found.start()]);
                let before = neighbour(atoms, i, &value[..found.start()], -1);
                let after = neighbour(atoms, i, &value[found.end()..], 1);
                if let (Some(before), Some(after)) = (before, after) {
                    let mut before_buf = [0u8; 4];
                    let mut after_buf = [0u8; 4];
                    if !(CLOSE.is_match(before.encode_utf8(&mut before_buf))
                        && CLOSE.is_match(after.encode_utf8(&mut after_buf)))
                    {
                        out.push(' ');
                    }
                }
                offset = found.end();
            }
            out.push_str(&value[offset..]);
            out
        };
        atoms[i].value = Some(result);
    }
}
fn normalize_inline(
    children: Vec<Node>,
    parent: &str,
    depth: usize,
    size: &mut usize,
) -> Result<Vec<Node>> {
    let mut atoms = Vec::new();
    flatten(
        children,
        &Context::default(),
        &mut atoms,
        parent,
        depth + 1,
        size,
    )?;
    convert_line_breaks(&mut atoms);
    let mut split = Vec::new();
    for atom in atoms {
        if let Some(value) = &atom.value
            && !atom.context.marks.iter().any(|m| m == "code")
            && atom
                .context
                .marks
                .iter()
                .any(|m| m == "strong" || m == "em")
        {
            let body = value.trim_matches(js_whitespace);
            let lead = value.len() - value.trim_start_matches(js_whitespace).len();
            let body_end = lead + body.len();
            for (part, plain) in [
                (&value[..lead], true),
                (&value[lead..body_end], false),
                (&value[body_end..], true),
            ] {
                if !part.is_empty() {
                    let mut item = atom.clone();
                    item.value = Some(part.into());
                    if plain {
                        item.context.marks.retain(|m| m != "strong" && m != "em");
                    }
                    split.push(item);
                }
            }
            continue;
        }
        split.push(atom);
    }
    let mut merged: Vec<Atom> = Vec::new();
    for atom in split {
        if atom.value.as_deref() == Some("") {
            continue;
        }
        if let Some(previous) = merged.last_mut()
            && previous.context.marks == atom.context.marks
            && previous.context.style == atom.context.style
            && previous.context.link == atom.context.link
            && let (Some(before), Some(after)) = (&mut previous.value, &atom.value)
        {
            before.push_str(after);
            continue;
        }
        merged.push(atom);
    }
    let mut result = Vec::new();
    let mut i = 0;
    while i < merged.len() {
        let style = &merged[i].context.style;
        let mut end = i + 1;
        while end < merged.len() && merged[end].context.style == *style {
            end += 1;
        }
        let children = formatted(&units(&merged[i..end]), &[]);
        if style.is_empty() {
            result.extend(children);
        } else {
            result.push(Node::Element(element(
                "span",
                Attrs::from([("style".into(), style.clone())]),
                children,
            )));
        }
        i = end;
    }
    Ok(result)
}
fn js_whitespace(c: char) -> bool {
    c == '\u{feff}' || (c.is_whitespace() && c != '\u{85}')
}
#[derive(Clone)]
struct Unit {
    atoms: Vec<Atom>,
    link: Option<Attrs>,
}
fn units(atoms: &[Atom]) -> Vec<Unit> {
    let mut result: Vec<Unit> = Vec::new();
    for atom in atoms {
        if let Some(previous) = result.last_mut()
            && atom.context.link.is_some()
            && previous.link == atom.context.link
        {
            previous.atoms.push(atom.clone());
            continue;
        }
        result.push(Unit {
            atoms: vec![atom.clone()],
            link: atom.context.link.clone(),
        });
    }
    result
}
fn blank(atom: &Atom) -> bool {
    atom.value
        .as_ref()
        .is_some_and(|v| !v.is_empty() && v.chars().all(js_whitespace))
}
fn neutral(mark: &str) -> bool {
    mark == "strong" || mark == "em"
}
fn has(unit: &Unit, mark: &str) -> bool {
    unit.atoms
        .iter()
        .any(|a| a.context.marks.iter().any(|m| m == mark))
        && unit
            .atoms
            .iter()
            .all(|a| a.context.marks.iter().any(|m| m == mark) || (neutral(mark) && blank(a)))
}
fn formatted(list: &[Unit], applied: &[&str]) -> Vec<Node> {
    let mut result: Vec<Node> = Vec::new();
    let mut i = 0;
    while i < list.len() {
        let mut best = None;
        let mut best_end = i;
        for mark in FORMATS {
            if mark == "code" || applied.contains(&mark) || !has(&list[i], mark) {
                continue;
            }
            let mut last = i + 1;
            for (j, unit) in list.iter().enumerate().skip(i + 1) {
                if has(unit, mark) {
                    last = j + 1;
                } else if !(neutral(mark) && unit.atoms.iter().all(blank)) {
                    break;
                }
            }
            if last > best_end {
                best = Some(mark);
                best_end = last;
            }
        }
        let node = if let Some(mark) = best {
            let mut next = applied.to_vec();
            next.push(mark);
            Node::Element(element(
                mark,
                Attrs::new(),
                formatted(&list[i..best_end], &next),
            ))
        } else {
            leaf(&list[i], applied)
        };
        match (result.last_mut(), node) {
            (Some(Node::Text(a)), Node::Text(b)) => a.push_str(&b),
            (_, node) => result.push(node),
        }
        i = if best.is_some() { best_end } else { i + 1 };
    }
    result
}
fn leaf(unit: &Unit, applied: &[&str]) -> Node {
    if let Some(link) = &unit.link {
        let children: Vec<Unit> = unit
            .atoms
            .iter()
            .map(|a| Unit {
                atoms: vec![a.clone()],
                link: None,
            })
            .collect();
        return Node::Element(element("a", link.clone(), formatted(&children, applied)));
    }
    let atom = &unit.atoms[0];
    let base = atom
        .node
        .clone()
        .map(Node::Element)
        .unwrap_or_else(|| Node::Text(atom.value.clone().unwrap_or_default()));
    if atom.context.marks.iter().any(|m| m == "code") {
        Node::Element(element("code", Attrs::new(), vec![base]))
    } else {
        base
    }
}

pub fn print(root: &Element) -> String {
    fn escape_into(value: &str, attribute: bool, out: &mut String) {
        for c in value.chars() {
            match c {
                '&' => out.push_str("&amp;"),
                '<' => out.push_str("&lt;"),
                '>' => out.push_str("&gt;"),
                '\r' => out.push_str("&#13;"),
                '"' if attribute => out.push_str("&quot;"),
                '\t' if attribute => out.push_str("&#9;"),
                '\n' if attribute => out.push_str("&#10;"),
                c => out.push(c),
            }
        }
    }
    fn write(node: &Element, out: &mut String) {
        out.push('<');
        out.push_str(&node.name);
        for (key, value) in &node.attrs {
            out.push(' ');
            out.push_str(key);
            out.push_str("=\"");
            escape_into(value, true, out);
            out.push('"');
        }
        if node.children.is_empty() {
            out.push_str(" />");
            return;
        }
        out.push('>');
        for child in &node.children {
            match child {
                Node::Text(t) => escape_into(t, false, out),
                Node::Element(n) => write(n, out),
            }
        }
        out.push_str("</");
        out.push_str(&node.name);
        out.push('>');
    }
    let mut result = String::new();
    write(root, &mut result);
    result
}
pub fn text_of(node: &Element) -> String {
    fn append(node: &Element, out: &mut String) {
        for child in &node.children {
            match child {
                Node::Text(t) => out.push_str(t),
                Node::Element(e) => append(e, out),
            }
        }
    }
    let mut out = String::new();
    append(node, &mut out);
    out
}
