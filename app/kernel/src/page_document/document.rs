use super::tree::{self, Attrs, Element, Node, Result, element};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::collections::BTreeMap;

pub(super) type Marks = BTreeMap<String, Value>;
// The core orders the marks by rank; readTree wraps them in that order.
const FORMATS: [(&str, &str); 8] = [
    ("u", "Underline"),
    ("s", "Strikethrough"),
    ("mark", "Highlight"),
    ("sup", "Superscript"),
    ("sub", "Subscript"),
    ("em", "Emphasis"),
    ("strong", "Strong"),
    ("code", "Code"),
];
fn is_format_mark(name: &str) -> bool {
    FORMATS.iter().any(|(_, mark)| *mark == name)
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum NodeKind {
    Doc,
    Paragraph,
    Heading,
    Blockquote,
    BulletList,
    OrderedList,
    ListItem,
    CodeBlock,
    HorizontalRule,
    Table,
    TableRow,
    Cell,
    HeaderCell,
    UnknownBlock,
    LineBreak,
    Image,
    InlineElement,
    Text,
    Callout,
    Embed,
}
impl std::fmt::Display for NodeKind {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(formatter, "{self:?}")
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct DocNode {
    pub kind: NodeKind,
    pub param: Value,
    pub marks: Marks,
    pub content: Option<Vec<DocNode>>,
}
impl DocNode {
    pub fn new(kind: NodeKind, param: Value, marks: Marks, content: Option<Vec<Self>>) -> Self {
        Self {
            kind,
            param,
            marks,
            content,
        }
    }
    pub fn json(&self) -> Value {
        let mut result = serde_json::Map::new();
        result.insert("type".into(), json!(self.kind));
        let default = default_param(self.kind);
        if !self.marks.is_empty() || default.as_ref() != Some(&self.param) {
            result.insert("param".into(), self.param.clone());
        }
        if !self.marks.is_empty() {
            result.insert("marks".into(), json!(self.marks));
        }
        if let Some(children) = &self.content {
            result.insert(
                "content".into(),
                Value::Array(children.iter().map(Self::json).collect()),
            );
        }
        Value::Object(result)
    }
    pub fn from_json(value: &Value) -> Result<Self> {
        let kind = value
            .get("type")
            .and_then(Value::as_str)
            .ok_or("missing node type")?;
        let kind = serde_json::from_value::<NodeKind>(json!(kind))
            .map_err(|_| format!("unknown node type {kind}"))?;
        let param = value
            .get("param")
            .cloned()
            .or_else(|| default_param(kind))
            .ok_or("missing node parameter")?;
        let marks: Marks = if let Some(marks) = value.get("marks") {
            serde_json::from_value(marks.clone()).map_err(|e| e.to_string())?
        } else {
            Marks::new()
        };
        let children = if is_container(kind) {
            Some(if let Some(children) = value.get("content") {
                children
                    .as_array()
                    .ok_or("invalid node content")?
                    .iter()
                    .map(Self::from_json)
                    .collect::<Result<_>>()?
            } else {
                Vec::new()
            })
        } else {
            None
        };
        let result = Self::new(kind, param, marks, children);
        result.validate()?;
        Ok(result)
    }
    pub fn validate(&self) -> Result<()> {
        let valid = match self.kind {
            NodeKind::Text => self.param.as_str().is_some_and(|s| !s.is_empty()),
            NodeKind::Heading => self.param.as_u64().is_some_and(|v| (1..=6).contains(&v)),
            NodeKind::OrderedList => self.param.is_number(),
            NodeKind::Image => self.param.is_string(),
            NodeKind::InlineElement | NodeKind::UnknownBlock => thaw(&self.param).is_ok(),
            _ => self.param.is_null(),
        };
        if !valid {
            return Err(format!("invalid node parameter {}", self.kind));
        }
        for (name, value) in &self.marks {
            validate_mark(name, value)?;
            if !mark_target(name, self.kind) {
                return Err(format!("mark {name} cannot target {}", self.kind));
            }
        }
        if let Some(children) = &self.content {
            if !is_container(self.kind) {
                return Err("leaf has children".into());
            }
            for child in children {
                child.validate()?;
                if !child_allowed(self.kind, child.kind) {
                    return Err(format!("invalid {} child {}", self.kind, child.kind));
                }
            }
        } else if is_container(self.kind) {
            return Err("plot is missing children".into());
        }
        Ok(())
    }
}
fn default_param(kind: NodeKind) -> Option<Value> {
    match kind {
        NodeKind::Heading | NodeKind::OrderedList => Some(json!(1)),
        NodeKind::Text | NodeKind::Image | NodeKind::InlineElement | NodeKind::UnknownBlock => None,
        _ => Some(Value::Null),
    }
}
pub fn is_container(kind: NodeKind) -> bool {
    matches!(
        kind,
        NodeKind::Doc
            | NodeKind::Paragraph
            | NodeKind::Heading
            | NodeKind::Blockquote
            | NodeKind::BulletList
            | NodeKind::OrderedList
            | NodeKind::ListItem
            | NodeKind::CodeBlock
            | NodeKind::Table
            | NodeKind::TableRow
            | NodeKind::Cell
            | NodeKind::HeaderCell
            | NodeKind::Callout
    )
}
fn inline(kind: NodeKind) -> bool {
    matches!(
        kind,
        NodeKind::Text | NodeKind::LineBreak | NodeKind::Image | NodeKind::InlineElement
    )
}
fn block(kind: NodeKind) -> bool {
    !inline(kind)
        && !matches!(
            kind,
            NodeKind::Doc
                | NodeKind::TableRow
                | NodeKind::Cell
                | NodeKind::HeaderCell
                | NodeKind::ListItem
        )
}
fn child_allowed(parent: NodeKind, child: NodeKind) -> bool {
    match parent {
        NodeKind::Paragraph | NodeKind::Heading => inline(child),
        NodeKind::CodeBlock => matches!(child, NodeKind::Text | NodeKind::LineBreak),
        NodeKind::BulletList | NodeKind::OrderedList => child == NodeKind::ListItem,
        NodeKind::Table => child == NodeKind::TableRow,
        NodeKind::TableRow => matches!(child, NodeKind::Cell | NodeKind::HeaderCell),
        _ => block(child),
    }
}
fn mark_target(name: &str, kind: NodeKind) -> bool {
    if is_format_mark(name) || name == "TextStyle" {
        return matches!(kind, NodeKind::Text | NodeKind::InlineElement);
    }
    match name {
        "Link" => inline(kind),
        "Align" => matches!(
            kind,
            NodeKind::Paragraph | NodeKind::Heading | NodeKind::Cell | NodeKind::HeaderCell
        ),
        "Indent" | "BlockStyle" => matches!(kind, NodeKind::Paragraph | NodeKind::Heading),
        "Task" => kind == NodeKind::ListItem,
        "CodeBlockLanguage" | "CodeMeta" => kind == NodeKind::CodeBlock,
        "ColSpan" | "RowSpan" => matches!(kind, NodeKind::Cell | NodeKind::HeaderCell),
        "ImageAlt" | "ImageTitle" => kind == NodeKind::Image,
        "PagePlaceholder" => kind == NodeKind::Paragraph,
        "CalloutTone" => kind == NodeKind::Callout,
        "EmbedRef" | "EmbedTable" | "EmbedView" => kind == NodeKind::Embed,
        "Attrs" => !matches!(
            kind,
            NodeKind::Doc | NodeKind::Text | NodeKind::UnknownBlock | NodeKind::InlineElement
        ),
        _ => false,
    }
}
pub(super) fn validate_mark(name: &str, value: &Value) -> Result<()> {
    let valid = if is_format_mark(name) || name == "PagePlaceholder" {
        value.is_null()
    } else {
        match name {
            "TextStyle" | "BlockStyle" | "CodeBlockLanguage" | "CodeMeta" | "ImageAlt"
            | "ImageTitle" | "EmbedRef" | "EmbedTable" | "EmbedView" => value.is_string(),
            "Align" => value
                .as_str()
                .is_some_and(|s| ["left", "center", "right", "justify"].contains(&s)),
            "Task" => value
                .as_str()
                .is_some_and(|s| ["todo", "done"].contains(&s)),
            "CalloutTone" => value
                .as_str()
                .is_some_and(|s| ["info", "warning"].contains(&s)),
            "Indent" => value.as_u64().is_some_and(|v| (1..=999).contains(&v)),
            "ColSpan" | "RowSpan" => value
                .as_u64()
                .is_some_and(|v| (1..=u64::from(tree::SPAN_LIMIT)).contains(&v)),
            "Attrs" | "Link" => pairs(value)
                .is_ok_and(|a| !a.is_empty() && (name != "Link" || a.contains_key("href"))),
            _ => false,
        }
    };
    if valid {
        Ok(())
    } else {
        Err(format!("invalid mark {name}"))
    }
}
fn pairs(value: &Value) -> Result<Attrs> {
    let pairs = value.as_array().ok_or("attribute pairs must be an array")?;
    let mut result = Attrs::new();
    let mut previous: Option<&str> = None;
    for pair in pairs {
        let pair = pair
            .as_array()
            .filter(|p| p.len() == 2)
            .ok_or("invalid attribute pair")?;
        let name = pair[0].as_str().ok_or("invalid attribute name")?;
        let value = pair[1].as_str().ok_or("invalid attribute value")?;
        if previous.is_some_and(|old| old >= name) {
            return Err("attribute pairs must be sorted and unique".into());
        }
        previous = Some(name);
        result.insert(name.into(), value.into());
    }
    Ok(result)
}
fn pair_value(attrs: &Attrs) -> Value {
    Value::Array(attrs.iter().map(|(k, v)| json!([k, v])).collect())
}
fn extras(attrs: &Attrs, known: &[&str]) -> Marks {
    let attrs: Attrs = attrs
        .iter()
        .filter(|(k, _)| !known.contains(&k.as_str()))
        .map(|(k, v)| (k.clone(), v.clone()))
        .collect();
    if attrs.is_empty() {
        Marks::new()
    } else {
        Marks::from([("Attrs".into(), pair_value(&attrs))])
    }
}
fn add_str_attr(marks: &mut Marks, attrs: &Attrs, key: &str, mark: &str) {
    if let Some(value) = attrs.get(key) {
        marks.insert(mark.into(), json!(value));
    }
}
fn add_num_attr(marks: &mut Marks, attrs: &Attrs, key: &str, mark: &str) {
    if let Some(value) = attrs.get(key) {
        marks.insert(mark.into(), json!(value.parse::<u64>().unwrap_or(0)));
    }
}
fn freeze(node: &Element) -> Value {
    json!({"name":node.name,"attrs":pair_value(&node.attrs),"children":node.children.iter().map(|c|match c{Node::Text(t)=>json!(t),Node::Element(n)=>freeze(n)}).collect::<Vec<_>>()})
}
fn thaw(value: &Value) -> Result<Element> {
    let name = value
        .get("name")
        .and_then(Value::as_str)
        .ok_or("invalid frozen element")?;
    let attrs = pairs(value.get("attrs").ok_or("missing frozen attributes")?)?;
    let children = value
        .get("children")
        .and_then(Value::as_array)
        .ok_or("invalid frozen children")?
        .iter()
        .map(|child| {
            if let Some(s) = child.as_str() {
                Ok(Node::Text(s.into()))
            } else {
                thaw(child).map(Node::Element)
            }
        })
        .collect::<Result<_>>()?;
    Ok(element(name, attrs, children))
}
/** The caller has already normalized and validated this page tree. */
pub fn page_document_normalized(page: &Element) -> Result<DocNode> {
    let mut children = page
        .children
        .iter()
        .map(|c| {
            if let Node::Element(n) = c {
                from_block(n)
            } else {
                Err("page text".into())
            }
        })
        .collect::<Result<Vec<_>>>()?;
    if children.is_empty() {
        children.push(DocNode::new(
            NodeKind::Paragraph,
            Value::Null,
            Marks::from([("PagePlaceholder".into(), Value::Null)]),
            Some(Vec::new()),
        ));
    }
    let doc = DocNode::new(NodeKind::Doc, Value::Null, Marks::new(), Some(children));
    doc.validate()?;
    Ok(doc)
}
fn blocks(node: &Element) -> Result<Vec<DocNode>> {
    node.children
        .iter()
        .map(|child| {
            if let Node::Element(n) = child {
                from_block(n)
            } else {
                Err("block contains text".into())
            }
        })
        .collect()
}
fn from_block(node: &Element) -> Result<DocNode> {
    let attrs = &node.attrs;
    let mut marks;
    let kind;
    let mut param = Value::Null;
    let children;
    match node.name.as_str() {
        "p" | "h1" | "h2" | "h3" | "h4" | "h5" | "h6" => {
            kind = if node.name == "p" {
                NodeKind::Paragraph
            } else {
                NodeKind::Heading
            };
            if kind == NodeKind::Heading {
                param = json!(node.name[1..].parse::<u32>().expect("heading tag h1..h6"));
            }
            marks = extras(attrs, &["align", "indent", "style"]);
            add_str_attr(&mut marks, attrs, "align", "Align");
            add_num_attr(&mut marks, attrs, "indent", "Indent");
            add_str_attr(&mut marks, attrs, "style", "BlockStyle");
            children = Some(from_inline(&node.children, &Marks::new(), "")?);
        }
        "blockquote" => {
            kind = NodeKind::Blockquote;
            marks = extras(attrs, &[]);
            children = Some(blocks(node)?);
        }
        "callout" => {
            kind = NodeKind::Callout;
            marks = extras(attrs, &["tone"]);
            add_str_attr(&mut marks, attrs, "tone", "CalloutTone");
            children = Some(blocks(node)?);
        }
        "ul" | "ol" => {
            kind = if node.name == "ul" {
                NodeKind::BulletList
            } else {
                NodeKind::OrderedList
            };
            if kind == NodeKind::OrderedList {
                param = json!(
                    attrs
                        .get("start")
                        .and_then(|v| v.parse::<u32>().ok())
                        .unwrap_or(1)
                );
            }
            marks = extras(
                attrs,
                if kind == NodeKind::OrderedList {
                    &["start"]
                } else {
                    &[]
                },
            );
            children = Some(blocks(node)?);
        }
        "li" => {
            kind = NodeKind::ListItem;
            marks = extras(attrs, &["task"]);
            add_str_attr(&mut marks, attrs, "task", "Task");
            children = Some(blocks(node)?);
        }
        "pre" => {
            kind = NodeKind::CodeBlock;
            marks = extras(attrs, &["lang", "meta"]);
            add_str_attr(&mut marks, attrs, "lang", "CodeBlockLanguage");
            add_str_attr(&mut marks, attrs, "meta", "CodeMeta");
            let value = tree::text_of(node);
            let mut content = Vec::new();
            for (index, line) in value.split('\n').enumerate() {
                if index > 0 {
                    content.push(DocNode::new(
                        NodeKind::LineBreak,
                        Value::Null,
                        Marks::new(),
                        None,
                    ));
                }
                if !line.is_empty() {
                    content.push(DocNode::new(
                        NodeKind::Text,
                        json!(line),
                        Marks::new(),
                        None,
                    ));
                }
            }
            children = Some(content);
        }
        "hr" => {
            kind = NodeKind::HorizontalRule;
            marks = extras(attrs, &[]);
            children = None;
        }
        "table" | "tr" => {
            kind = if node.name == "table" {
                NodeKind::Table
            } else {
                NodeKind::TableRow
            };
            marks = extras(attrs, &[]);
            children = Some(blocks(node)?);
        }
        "td" | "th" => {
            kind = if node.name == "td" {
                NodeKind::Cell
            } else {
                NodeKind::HeaderCell
            };
            marks = extras(attrs, &["align", "colspan", "rowspan"]);
            add_str_attr(&mut marks, attrs, "align", "Align");
            add_num_attr(&mut marks, attrs, "colspan", "ColSpan");
            add_num_attr(&mut marks, attrs, "rowspan", "RowSpan");
            children = Some(blocks(node)?);
        }
        "embed" => {
            kind = NodeKind::Embed;
            marks = extras(attrs, &["ref", "table", "view"]);
            for (key, name) in [
                ("ref", "EmbedRef"),
                ("table", "EmbedTable"),
                ("view", "EmbedView"),
            ] {
                add_str_attr(&mut marks, attrs, key, name);
            }
            children = None;
        }
        _ => {
            kind = NodeKind::UnknownBlock;
            param = freeze(node);
            marks = Marks::new();
            children = None;
        }
    }
    Ok(DocNode::new(kind, param, marks, children))
}
fn from_inline(nodes: &[Node], context: &Marks, style: &str) -> Result<Vec<DocNode>> {
    let mut out = Vec::new();
    for node in nodes {
        let mut marks = context.clone();
        if !style.is_empty() {
            marks.insert("TextStyle".into(), json!(style));
        }
        let node = match node {
            Node::Text(t) => {
                out.push(DocNode::new(NodeKind::Text, json!(t), marks, None));
                continue;
            }
            Node::Element(n) => n,
        };
        if let Some((_, name)) = FORMATS
            .iter()
            .find(|(xml, _)| *xml == node.name && node.attrs.is_empty())
        {
            let mut next = context.clone();
            next.insert((*name).into(), Value::Null);
            out.extend(from_inline(&node.children, &next, style)?);
        } else if node.name == "span" && node.attrs.keys().all(|key| key == "style") {
            let inner = node.attrs.get("style").map_or("", String::as_str);
            let joined = tree::join_style(style, inner);
            out.extend(from_inline(&node.children, context, &joined)?);
        } else if node.name == "a" && !node.children.is_empty() {
            let mut next = context.clone();
            next.insert("Link".into(), pair_value(&node.attrs));
            out.extend(from_inline(&node.children, &next, style)?);
        } else if node.name == "br" || node.name == "img" {
            let mut mark = extras(
                &node.attrs,
                if node.name == "img" {
                    &["src", "alt", "title"]
                } else {
                    &[]
                },
            );
            if let Some(link) = context.get("Link") {
                mark.insert("Link".into(), link.clone());
            }
            if node.name == "img" {
                let src = node.attrs.get("src").ok_or("missing img src")?;
                add_str_attr(&mut mark, &node.attrs, "alt", "ImageAlt");
                add_str_attr(&mut mark, &node.attrs, "title", "ImageTitle");
                out.push(DocNode::new(NodeKind::Image, json!(src), mark, None));
            } else {
                out.push(DocNode::new(NodeKind::LineBreak, Value::Null, mark, None));
            }
        } else {
            out.push(DocNode::new(
                NodeKind::InlineElement,
                freeze(node),
                marks,
                None,
            ));
        }
    }
    Ok(out)
}
fn attrs_back(node: &DocNode) -> Result<Attrs> {
    node.marks
        .get("Attrs")
        .map(pairs)
        .unwrap_or_else(|| Ok(Attrs::new()))
}
fn restore(attrs: &mut Attrs, node: &DocNode, key: &str, mark: &str) {
    if let Some(value) = node.marks.get(mark) {
        attrs.insert(
            key.into(),
            value
                .as_str()
                .map(str::to_owned)
                .unwrap_or_else(|| value.to_string()),
        );
    }
}
pub fn read_tree(doc: &DocNode) -> Result<Element> {
    doc.validate()?;
    if doc.kind != NodeKind::Doc {
        return Err("expected document".into());
    }
    let mut children = Vec::new();
    for node in doc.content.as_deref().unwrap_or_default() {
        if node.content.as_ref().is_some_and(Vec::is_empty)
            && node.marks.contains_key("PagePlaceholder")
        {
            continue;
        }
        children.push(Node::Element(to_block(node)?));
    }
    tree::normalize(element("page", Attrs::new(), children))
}
fn to_block(node: &DocNode) -> Result<Element> {
    let mut attrs = attrs_back(node)?;
    let mut children = Vec::new();
    let name;
    match node.kind {
        NodeKind::Paragraph | NodeKind::Heading => {
            name = if node.kind == NodeKind::Paragraph {
                "p".into()
            } else {
                format!("h{}", node.param)
            };
            for (key, mark) in [
                ("align", "Align"),
                ("indent", "Indent"),
                ("style", "BlockStyle"),
            ] {
                restore(&mut attrs, node, key, mark);
            }
            children = to_inline(node.content.as_deref().unwrap_or_default())?;
        }
        NodeKind::UnknownBlock => return thaw(&node.param),
        NodeKind::CodeBlock => {
            name = "pre".into();
            restore(&mut attrs, node, "lang", "CodeBlockLanguage");
            restore(&mut attrs, node, "meta", "CodeMeta");
            let value: String = node
                .content
                .as_deref()
                .unwrap_or_default()
                .iter()
                .map(|n| {
                    if n.kind == NodeKind::Text {
                        n.param.as_str().unwrap_or("")
                    } else {
                        "\n"
                    }
                })
                .collect();
            if !value.is_empty() {
                children.push(Node::Text(value));
            }
        }
        _ => {
            name = match node.kind {
                NodeKind::Blockquote => "blockquote",
                NodeKind::BulletList => "ul",
                NodeKind::OrderedList => "ol",
                NodeKind::ListItem => "li",
                NodeKind::HorizontalRule => "hr",
                NodeKind::Table => "table",
                NodeKind::TableRow => "tr",
                NodeKind::Cell => "td",
                NodeKind::HeaderCell => "th",
                NodeKind::Callout => "callout",
                NodeKind::Embed => "embed",
                _ => return Err("unexpected block node".into()),
            }
            .into();
            if node.kind == NodeKind::OrderedList && node.param != json!(1) {
                attrs.insert("start".into(), node.param.to_string());
            }
            for (key, mark) in [
                ("task", "Task"),
                ("align", "Align"),
                ("colspan", "ColSpan"),
                ("rowspan", "RowSpan"),
                ("tone", "CalloutTone"),
                ("ref", "EmbedRef"),
                ("table", "EmbedTable"),
                ("view", "EmbedView"),
            ] {
                restore(&mut attrs, node, key, mark);
            }
            for child in node.content.as_deref().unwrap_or_default() {
                children.push(Node::Element(to_block(child)?));
            }
        }
    }
    for value in attrs.values_mut() {
        value.retain(tree::valid_character);
    }
    Ok(element(name, attrs, children))
}
fn to_inline(nodes: &[DocNode]) -> Result<Vec<Node>> {
    let mut result = Vec::new();
    for node in nodes {
        let mut value = match node.kind {
            NodeKind::Text => Node::Text(
                node.param
                    .as_str()
                    .ok_or("invalid text")?
                    .chars()
                    .filter(|c| tree::valid_character(*c))
                    .collect(),
            ),
            NodeKind::LineBreak => Node::Element(element("br", attrs_back(node)?, Vec::new())),
            NodeKind::Image => {
                let mut attrs = attrs_back(node)?;
                attrs.insert(
                    "src".into(),
                    node.param.as_str().ok_or("invalid image")?.into(),
                );
                restore(&mut attrs, node, "alt", "ImageAlt");
                restore(&mut attrs, node, "title", "ImageTitle");
                Node::Element(element("img", attrs, Vec::new()))
            }
            NodeKind::InlineElement => Node::Element(thaw(&node.param)?),
            _ => return Err("unexpected inline node".into()),
        };
        for (name, mark) in FORMATS {
            if node.marks.contains_key(mark) {
                value = Node::Element(element(name, Attrs::new(), vec![value]));
            }
        }
        if let Some(style) = node
            .marks
            .get("TextStyle")
            .and_then(Value::as_str)
            .filter(|s| !s.is_empty())
        {
            value = Node::Element(element(
                "span",
                Attrs::from([("style".into(), style.into())]),
                vec![value],
            ));
        }
        if let Some(link) = node.marks.get("Link") {
            value = Node::Element(element("a", pairs(link)?, vec![value]));
        }
        result.push(value);
    }
    Ok(result)
}
