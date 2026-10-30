use super::tree::{Attrs, Element, Node, Result, element};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::collections::BTreeMap;

pub(super) type Marks = BTreeMap<String, Value>;
// The core orders the marks by rank; readTree wraps them in that order.
pub(super) const FORMATS: [(&str, &str); 8] = [
    ("u", "Underline"),
    ("s", "Strikethrough"),
    ("mark", "Highlight"),
    ("sup", "Superscript"),
    ("sub", "Subscript"),
    ("em", "Emphasis"),
    ("strong", "Strong"),
    ("code", "Code"),
];
pub(super) const RESOURCE_FIELDS: [&str; 8] = [
    "src",
    "title",
    "description",
    "image",
    "mime",
    "size",
    "kind",
    "view",
];
fn resource_mark(name: &str) -> bool {
    name.strip_prefix("Resource_")
        .is_some_and(|field| RESOURCE_FIELDS.contains(&field))
}
fn is_format_mark(name: &str) -> bool {
    FORMATS.iter().any(|(_, mark)| *mark == name)
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum NodeKind {
    Doc,
    Paragraph,
    Heading,
    Blockquote,
    BlockGroup,
    Columns,
    Column,
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
    Mention,
    InlineElement,
    Text,
    Callout,
    Embed,
    Media,
    Bookmark,
    Math,
    Mermaid,
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
    /// Structural editor offsets count UTF-16 text units and opening/closing tokens.
    pub(super) fn span(&self) -> usize {
        if let Some(children) = &self.content {
            usize::from(self.kind != NodeKind::Doc) * 2
                + children.iter().map(Self::span).sum::<usize>()
        } else if self.kind == NodeKind::Text {
            self.param
                .as_str()
                .expect("text parameter")
                .encode_utf16()
                .count()
        } else {
            1
        }
    }

    pub(super) fn text_slice(&self, from: usize, to: usize) -> Result<String> {
        let units: Vec<u16> = self
            .param
            .as_str()
            .expect("text parameter")
            .encode_utf16()
            .collect();
        String::from_utf16(&units[from..to])
            .map_err(|_| "range splits a Unicode surrogate pair".into())
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
            NodeKind::Image | NodeKind::Math => self.param.is_string(),
            NodeKind::Mention => self.param.as_object().is_some_and(|map| {
                map.len() == 1
                    && (map.get("page").or_else(|| map.get("principal")))
                        .and_then(Value::as_str)
                        .is_some_and(|s| !s.is_empty())
            }),
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
        NodeKind::Text
        | NodeKind::Image
        | NodeKind::Mention
        | NodeKind::InlineElement
        | NodeKind::UnknownBlock
        | NodeKind::Math => None,
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
            | NodeKind::BlockGroup
            | NodeKind::Columns
            | NodeKind::Column
            | NodeKind::BulletList
            | NodeKind::OrderedList
            | NodeKind::ListItem
            | NodeKind::CodeBlock
            | NodeKind::Table
            | NodeKind::TableRow
            | NodeKind::Cell
            | NodeKind::HeaderCell
            | NodeKind::Callout
            | NodeKind::Mermaid
    )
}
fn inline(kind: NodeKind) -> bool {
    matches!(
        kind,
        NodeKind::Text
            | NodeKind::LineBreak
            | NodeKind::Image
            | NodeKind::Mention
            | NodeKind::InlineElement
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
                | NodeKind::Column
        )
}
fn child_allowed(parent: NodeKind, child: NodeKind) -> bool {
    match parent {
        NodeKind::Paragraph | NodeKind::Heading => inline(child),
        NodeKind::CodeBlock | NodeKind::Mermaid => {
            matches!(child, NodeKind::Text | NodeKind::LineBreak)
        }
        NodeKind::BulletList | NodeKind::OrderedList => child == NodeKind::ListItem,
        NodeKind::Table => child == NodeKind::TableRow,
        NodeKind::Columns => child == NodeKind::Column,
        NodeKind::TableRow => matches!(child, NodeKind::Cell | NodeKind::HeaderCell),
        _ => block(child),
    }
}
fn mark_target(name: &str, kind: NodeKind) -> bool {
    if is_format_mark(name) || name == "TextStyle" {
        return matches!(
            kind,
            NodeKind::Text | NodeKind::InlineElement | NodeKind::Mention
        );
    }
    match name {
        "Link" => matches!(
            kind,
            NodeKind::Text | NodeKind::LineBreak | NodeKind::Image | NodeKind::InlineElement
        ),
        "Comment" => inline(kind),
        "Align" => matches!(
            kind,
            NodeKind::Paragraph | NodeKind::Heading | NodeKind::Cell | NodeKind::HeaderCell
        ),
        "Indent" | "BlockStyle" => matches!(kind, NodeKind::Paragraph | NodeKind::Heading),
        "Task" => kind == NodeKind::ListItem,
        "ColumnWidth" => kind == NodeKind::Column,
        "CodeBlockLanguage" | "CodeMeta" | "CodeWrap" => kind == NodeKind::CodeBlock,
        "MermaidView" | "MermaidTheme" => kind == NodeKind::Mermaid,
        "ColSpan" | "RowSpan" | "CellBackground" => {
            matches!(kind, NodeKind::Cell | NodeKind::HeaderCell)
        }
        "TableWidths" | "TableLayout" => kind == NodeKind::Table,
        "ImageAlt" | "ImageTitle" => kind == NodeKind::Image,
        "PagePlaceholder" => kind == NodeKind::Paragraph,
        "CalloutTone" | "CalloutIcon" => kind == NodeKind::Callout,
        "EmbedRef" | "EmbedTable" | "EmbedView" | "EmbedHref" | "EmbedTitle" => {
            kind == NodeKind::Embed
        }
        name if resource_mark(name) => {
            matches!(kind, NodeKind::Media | NodeKind::Bookmark)
        }
        "Attrs" => !matches!(
            kind,
            NodeKind::Doc | NodeKind::Text | NodeKind::UnknownBlock | NodeKind::InlineElement
        ),
        _ => false,
    }
}
fn attribute_mark(name: &str) -> Option<(&'static str, &'static str, bool)> {
    Some(match name {
        "Resource_kind" => ("media", "kind", false),
        "Resource_view" => ("media", "view", false),
        "CodeWrap" => ("pre", "wrap", false),
        "TableWidths" => ("table", "widths", false),
        "TableLayout" => ("table", "layout", false),
        "CellBackground" => ("td", "background", false),
        "MermaidView" => ("mermaid", "view", false),
        "MermaidTheme" => ("mermaid", "theme", false),
        "Align" => ("p", "align", false),
        "Task" => ("li", "task", false),
        "CalloutTone" => ("callout", "tone", false),
        "Indent" => ("p", "indent", true),
        "ColumnWidth" => ("column", "width", true),
        "ColSpan" => ("td", "colspan", true),
        "RowSpan" => ("td", "rowspan", true),
        _ => return None,
    })
}
pub(super) fn validate_mark(name: &str, value: &Value) -> Result<()> {
    let valid = if is_format_mark(name) || name == "PagePlaceholder" {
        value.is_null()
    } else {
        match name {
            "Comment" => value.as_array().is_some_and(|ids| {
                !ids.is_empty()
                    && ids
                        .iter()
                        .all(|id| id.as_str().is_some_and(super::comments::valid_id))
                    && ids
                        .windows(2)
                        .all(|pair| pair[0].as_str() < pair[1].as_str())
            }),
            "TextStyle" | "BlockStyle" | "CodeBlockLanguage" | "CodeMeta" | "ImageAlt"
            | "ImageTitle" | "EmbedRef" | "EmbedTable" | "EmbedView" | "EmbedHref"
            | "EmbedTitle" | "CalloutIcon" => value.is_string(),
            name if attribute_mark(name).is_some() => {
                let (element, attribute, numeric) = attribute_mark(name).unwrap();
                if numeric {
                    value.as_u64().is_some_and(|v| {
                        super::attributes::valid_value(element, attribute, &v.to_string())
                    })
                } else {
                    value
                        .as_str()
                        .is_some_and(|v| super::attributes::valid_value(element, attribute, v))
                }
            }
            name if resource_mark(name) => value.is_string(),
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
pub(super) fn pairs(value: &Value) -> Result<Attrs> {
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
pub(super) fn pair_value(attrs: &Attrs) -> Value {
    Value::Array(attrs.iter().map(|(k, v)| json!([k, v])).collect())
}
pub(super) fn freeze(node: &Element) -> Value {
    json!({"name":node.name,"attrs":pair_value(&node.attrs),"children":node.children.iter().map(|c|match c{Node::Text(t)=>json!(t),Node::Element(n)=>freeze(n)}).collect::<Vec<_>>()})
}
pub(super) fn thaw(value: &Value) -> Result<Element> {
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
