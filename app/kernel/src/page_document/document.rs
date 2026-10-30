use super::document_schema::{
    DocNode, FORMATS, Marks, NodeKind, RESOURCE_FIELDS, freeze, pair_value, pairs, thaw,
};
use super::tree::{self, Attrs, Element, Node, Result, element};
use serde_json::{Value, json};

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
        "columns" | "column" => {
            kind = if node.name == "columns" {
                NodeKind::Columns
            } else {
                NodeKind::Column
            };
            marks = extras(
                attrs,
                if node.name == "column" {
                    &["width"]
                } else {
                    &[]
                },
            );
            if node.name == "column" {
                add_num_attr(&mut marks, attrs, "width", "ColumnWidth");
            }
            children = Some(blocks(node)?);
        }
        "blockquote" | "block" => {
            kind = if node.name == "block" {
                NodeKind::BlockGroup
            } else {
                NodeKind::Blockquote
            };
            marks = extras(attrs, &[]);
            children = Some(blocks(node)?);
        }
        "callout" => {
            kind = NodeKind::Callout;
            marks = extras(attrs, &["tone", "icon"]);
            add_str_attr(&mut marks, attrs, "tone", "CalloutTone");
            add_str_attr(&mut marks, attrs, "icon", "CalloutIcon");
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
        "pre" | "mermaid" => {
            if node.name == "pre" {
                kind = NodeKind::CodeBlock;
                marks = extras(attrs, &["lang", "meta", "wrap"]);
                add_str_attr(&mut marks, attrs, "lang", "CodeBlockLanguage");
                add_str_attr(&mut marks, attrs, "meta", "CodeMeta");
                add_str_attr(&mut marks, attrs, "wrap", "CodeWrap");
            } else {
                kind = NodeKind::Mermaid;
                marks = extras(attrs, &["view", "theme"]);
                add_str_attr(&mut marks, attrs, "view", "MermaidView");
                add_str_attr(&mut marks, attrs, "theme", "MermaidTheme");
            }
            let mut content = Vec::new();
            for text in from_inline(&node.children, &Marks::new(), "")? {
                let value = text.param.as_str().ok_or("invalid code text")?;
                for (index, line) in value.split('\n').enumerate() {
                    if index > 0 {
                        content.push(DocNode::new(
                            NodeKind::LineBreak,
                            Value::Null,
                            text.marks.clone(),
                            None,
                        ));
                    }
                    if !line.is_empty() {
                        content.push(DocNode::new(
                            NodeKind::Text,
                            json!(line),
                            text.marks.clone(),
                            None,
                        ));
                    }
                }
            }
            children = Some(content);
        }
        "math" => {
            kind = NodeKind::Math;
            marks = extras(attrs, &[]);
            param = json!(
                node.children
                    .iter()
                    .filter_map(|child| match child {
                        Node::Text(value) => Some(value.as_str()),
                        Node::Element(_) => None,
                    })
                    .collect::<String>()
            );
            children = None;
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
            marks = extras(
                attrs,
                if node.name == "table" {
                    &["widths", "layout"]
                } else {
                    &[]
                },
            );
            if node.name == "table" {
                add_str_attr(&mut marks, attrs, "widths", "TableWidths");
                add_str_attr(&mut marks, attrs, "layout", "TableLayout");
            }
            children = Some(blocks(node)?);
        }
        "td" | "th" => {
            kind = if node.name == "td" {
                NodeKind::Cell
            } else {
                NodeKind::HeaderCell
            };
            marks = extras(attrs, &["align", "colspan", "rowspan", "background"]);
            add_str_attr(&mut marks, attrs, "background", "CellBackground");
            add_str_attr(&mut marks, attrs, "align", "Align");
            add_num_attr(&mut marks, attrs, "colspan", "ColSpan");
            add_num_attr(&mut marks, attrs, "rowspan", "RowSpan");
            children = Some(blocks(node)?);
        }
        "media" | "bookmark" => {
            kind = if node.name == "media" {
                NodeKind::Media
            } else {
                NodeKind::Bookmark
            };
            marks = extras(attrs, &RESOURCE_FIELDS);
            for key in RESOURCE_FIELDS {
                add_str_attr(&mut marks, attrs, key, &format!("Resource_{key}"));
            }
            children = None;
        }
        "embed" => {
            kind = NodeKind::Embed;
            marks = extras(attrs, &["ref", "table", "view", "href", "title"]);
            for (key, name) in [
                ("ref", "EmbedRef"),
                ("table", "EmbedTable"),
                ("view", "EmbedView"),
                ("href", "EmbedHref"),
                ("title", "EmbedTitle"),
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
        } else if node.name == "comment" {
            let mut next = context.clone();
            let mut ids = next
                .get("Comment")
                .and_then(Value::as_array)
                .cloned()
                .unwrap_or_default();
            ids.extend(
                super::comments::parse_ids(&node.attrs["ids"])?
                    .into_iter()
                    .map(Value::String),
            );
            ids.sort_by(|a, b| a.as_str().cmp(&b.as_str()));
            ids.dedup();
            next.insert("Comment".into(), Value::Array(ids));
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
            for name in ["Link", "Comment"] {
                if let Some(value) = context.get(name) {
                    mark.insert(name.into(), value.clone());
                }
            }
            if node.name == "img" {
                let src = node.attrs.get("src").ok_or("missing img src")?;
                add_str_attr(&mut mark, &node.attrs, "alt", "ImageAlt");
                add_str_attr(&mut mark, &node.attrs, "title", "ImageTitle");
                out.push(DocNode::new(NodeKind::Image, json!(src), mark, None));
            } else {
                out.push(DocNode::new(NodeKind::LineBreak, Value::Null, mark, None));
            }
        } else if node.name == "mention" {
            let mut mark = extras(&node.attrs, &["page", "principal"]);
            for (key, value) in &marks {
                if key != "Link" {
                    mark.insert(key.clone(), value.clone());
                }
            }
            let param = if let Some(page) = node.attrs.get("page") {
                json!({ "page": page })
            } else if let Some(principal) = node.attrs.get("principal") {
                json!({ "principal": principal })
            } else {
                return Err("missing mention target".into());
            };
            out.push(DocNode::new(NodeKind::Mention, param, mark, None));
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
    let mut root = element("page", Attrs::new(), children);
    clean(&mut root);
    tree::normalize(root)
}
fn clean(node: &mut Element) {
    for value in node.attrs.values_mut() {
        value.retain(tree::valid_character);
    }
    for child in &mut node.children {
        match child {
            Node::Text(value) => value.retain(tree::valid_character),
            Node::Element(child) => clean(child),
        }
    }
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
        NodeKind::Media | NodeKind::Bookmark => {
            name = if node.kind == NodeKind::Media {
                "media"
            } else {
                "bookmark"
            }
            .into();
            for key in RESOURCE_FIELDS {
                restore(&mut attrs, node, key, &format!("Resource_{key}"));
            }
        }
        NodeKind::Math => {
            name = "math".into();
            if let Some(text) = node.param.as_str()
                && !text.is_empty()
            {
                children.push(Node::Text(text.into()));
            }
        }
        NodeKind::CodeBlock | NodeKind::Mermaid => {
            if node.kind == NodeKind::Mermaid {
                name = "mermaid".into();
                restore(&mut attrs, node, "view", "MermaidView");
                restore(&mut attrs, node, "theme", "MermaidTheme");
            } else {
                name = "pre".into();
                restore(&mut attrs, node, "lang", "CodeBlockLanguage");
                restore(&mut attrs, node, "meta", "CodeMeta");
                restore(&mut attrs, node, "wrap", "CodeWrap");
            }
            for leaf in node.content.as_deref().unwrap_or_default() {
                let value = Node::Text(if leaf.kind == NodeKind::Text {
                    leaf.param.as_str().unwrap_or("").to_owned()
                } else {
                    "\n".to_owned()
                });
                if let Some(ids) = leaf.marks.get("Comment").and_then(Value::as_array) {
                    children.push(Node::Element(element(
                        "comment",
                        Attrs::from([(
                            "ids".into(),
                            ids.iter()
                                .filter_map(Value::as_str)
                                .collect::<Vec<_>>()
                                .join(" "),
                        )]),
                        vec![value],
                    )));
                } else {
                    children.push(value);
                }
            }
        }
        _ => {
            name = match node.kind {
                NodeKind::Blockquote => "blockquote",
                NodeKind::BlockGroup => "block",
                NodeKind::Columns => "columns",
                NodeKind::Column => "column",
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
                ("width", "ColumnWidth"),
                ("widths", "TableWidths"),
                ("layout", "TableLayout"),
                ("background", "CellBackground"),
                ("align", "Align"),
                ("colspan", "ColSpan"),
                ("rowspan", "RowSpan"),
                ("tone", "CalloutTone"),
                ("icon", "CalloutIcon"),
                ("ref", "EmbedRef"),
                ("table", "EmbedTable"),
                ("view", "EmbedView"),
                ("href", "EmbedHref"),
                ("title", "EmbedTitle"),
            ] {
                restore(&mut attrs, node, key, mark);
            }
            for child in node.content.as_deref().unwrap_or_default() {
                children.push(Node::Element(to_block(child)?));
            }
        }
    }
    Ok(element(name, attrs, children))
}
fn to_inline(nodes: &[DocNode]) -> Result<Vec<Node>> {
    let mut result = Vec::new();
    for node in nodes {
        let mut value = match node.kind {
            NodeKind::Text => Node::Text(node.param.as_str().ok_or("invalid text")?.into()),
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
            NodeKind::Mention => {
                let mut attrs = attrs_back(node)?;
                let map = node.param.as_object().ok_or("invalid mention")?;
                if let Some(page) = map.get("page").and_then(Value::as_str) {
                    attrs.insert("page".into(), page.into());
                } else if let Some(principal) = map.get("principal").and_then(Value::as_str) {
                    attrs.insert("principal".into(), principal.into());
                } else {
                    return Err("invalid mention".into());
                }
                Node::Element(element("mention", attrs, Vec::new()))
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
        if let Some(ids) = node.marks.get("Comment").and_then(Value::as_array) {
            value = Node::Element(element(
                "comment",
                Attrs::from([(
                    "ids".into(),
                    ids.iter()
                        .filter_map(Value::as_str)
                        .collect::<Vec<_>>()
                        .join(" "),
                )]),
                vec![value],
            ));
        }
        result.push(value);
    }
    Ok(result)
}
