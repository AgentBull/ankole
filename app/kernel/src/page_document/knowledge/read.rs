use super::document;
use crate::page_document::tree::{self, Attrs, Element, Node, Result};
use comrak::nodes::{AlertType, AstNode, ListType, NodeValue, TableAlignment};
use comrak::{Arena, Options};
use regex::Regex;
use std::sync::LazyLock;

pub(super) fn body(source: &str) -> Result<Element> {
    let arena = Arena::new();
    let mut options = Options::default();
    options.extension.table = true;
    options.extension.tasklist = true;
    options.extension.strikethrough = true;
    options.extension.alerts = true;
    let ast = comrak::parse_document(&arena, source, &options);
    let root = tree::normalize(tree::element("page", Attrs::new(), blocks(ast)?))?;
    document::validate_tree(&root)?;
    Ok(root)
}

fn blocks<'a>(node: &'a AstNode<'a>) -> Result<Vec<Node>> {
    node.children()
        .map(block)
        .collect::<Result<Vec<_>>>()
        .map(|items| items.into_iter().flatten().collect())
}

fn block<'a>(node: &'a AstNode<'a>) -> Result<Vec<Node>> {
    let data = node.data.borrow();
    let mut attrs = Attrs::new();
    let (tag, children) = match &data.value {
        NodeValue::Paragraph => {
            if let Some(child) = node.first_child().filter(|_| node.children().count() == 1)
                && let NodeValue::Image(image) = &child.data.borrow().value
            {
                attrs.insert("kind".into(), "image".into());
                attrs.insert("src".into(), image.url.clone());
                if !image.title.is_empty() {
                    attrs.insert("title".into(), image.title.clone());
                }
                let description = child
                    .children()
                    .map(|child| match &child.data.borrow().value {
                        NodeValue::Text(text) => text.to_string(),
                        _ => String::new(),
                    })
                    .collect::<String>();
                if !description.is_empty() {
                    attrs.insert("description".into(), description);
                }
                ("media".into(), vec![])
            } else {
                ("p".into(), inline(node)?)
            }
        }
        NodeValue::Heading(h) => (format!("h{}", h.level), inline(node)?),
        NodeValue::ThematicBreak => ("hr".into(), vec![]),
        NodeValue::BlockQuote => ("blockquote".into(), blocks(node)?),
        NodeValue::List(list) => {
            let ordered = list.list_type == ListType::Ordered;
            if ordered && list.start != 1 {
                attrs.insert("start".into(), list.start.to_string());
            }
            ((if ordered { "ol" } else { "ul" }).into(), blocks(node)?)
        }
        NodeValue::Item(_) => ("li".into(), blocks(node)?),
        NodeValue::TaskItem(task) => {
            attrs.insert(
                "task".into(),
                if task.symbol.is_some() {
                    "done"
                } else {
                    "todo"
                }
                .into(),
            );
            ("li".into(), blocks(node)?)
        }
        NodeValue::CodeBlock(code) => {
            let (lang, meta) = code.info.split_once(' ').unwrap_or((&code.info, ""));
            let content = code
                .literal
                .strip_suffix('\n')
                .unwrap_or(&code.literal)
                .to_owned();
            if meta.is_empty()
                && let Some(spec) =
                    crate::page_document::attributes::knowledge_source_diagram_by_fence(lang)
            {
                (spec.tag.into(), vec![Node::Text(content)])
            } else {
                if !lang.is_empty() {
                    attrs.insert("lang".into(), lang.into());
                }
                if !meta.is_empty() {
                    attrs.insert("meta".into(), meta.into());
                }
                ("pre".into(), vec![Node::Text(content)])
            }
        }
        NodeValue::Alert(alert) => {
            let tone = match alert.alert_type {
                AlertType::Note => "info",
                AlertType::Tip => "success",
                AlertType::Important => "neutral",
                AlertType::Warning => "warning",
                AlertType::Caution => "danger",
            };
            attrs.insert("tone".into(), tone.into());
            if let Some(title) = &alert.title {
                if let Some(json) = title
                    .strip_prefix("{icon=")
                    .and_then(|s| s.strip_suffix('}'))
                {
                    let icon: String = serde_json::from_str(json).map_err(|e| e.to_string())?;
                    attrs.insert("icon".into(), icon);
                } else {
                    return Err(
                        "knowledge alerts use an icon attribute; place titles in their body".into(),
                    );
                }
            }
            ("callout".into(), blocks(node)?)
        }
        NodeValue::Table(table) => {
            let mut rows = Vec::new();
            for (row_index, row) in node.children().enumerate() {
                let mut cells = Vec::new();
                for (column, cell) in row.children().enumerate() {
                    let mut attrs = Attrs::new();
                    let alignment = match table.alignments.get(column) {
                        Some(TableAlignment::Left) => Some("left"),
                        Some(TableAlignment::Right) => Some("right"),
                        Some(TableAlignment::Center) => Some("center"),
                        _ => None,
                    };
                    if let Some(alignment) = alignment {
                        attrs.insert("align".into(), alignment.into());
                    }
                    cells.push(Node::Element(tree::element(
                        if row_index == 0 { "th" } else { "td" },
                        attrs,
                        vec![Node::Element(tree::element(
                            "p",
                            Attrs::new(),
                            inline(cell)?,
                        ))],
                    )));
                }
                rows.push(Node::Element(tree::element("tr", Attrs::new(), cells)));
            }
            ("table".into(), rows)
        }
        NodeValue::HtmlBlock(html) => {
            return tree::parse(&format!("<page>{}</page>", html.literal))
                .map(|root| root.children);
        }
        value => return Err(format!("unsupported knowledge Markdown block: {value:?}")),
    };
    Ok(vec![Node::Element(tree::element(tag, attrs, children))])
}

fn inline<'a>(node: &'a AstNode<'a>) -> Result<Vec<Node>> {
    // XML fragments preserve the allowed page inline vocabulary, including literals that
    // Markdown cannot distinguish from a mention or emphasis delimiter.
    let mut xml = String::new();
    for child in node.children() {
        xml.push_str(&inline_xml(child)?);
    }
    let parsed = tree::parse(&format!("<page><p>{xml}</p></page>"))?;
    match parsed.children.into_iter().next() {
        Some(Node::Element(p)) => Ok(p.children),
        _ => Ok(vec![]),
    }
}

fn inline_xml<'a>(node: &'a AstNode<'a>) -> Result<String> {
    let data = node.data.borrow();
    let text = match &data.value {
        NodeValue::Text(value) => mention_text(value),
        NodeValue::SoftBreak => "\n".into(),
        NodeValue::LineBreak => "<br/>".into(),
        NodeValue::Code(code) => format!("<code>{}</code>", escape(&code.literal, false)),
        NodeValue::HtmlInline(value) => value.clone(),
        NodeValue::Strong | NodeValue::Emph | NodeValue::Strikethrough => {
            let tag = match data.value {
                NodeValue::Strong => "strong",
                NodeValue::Emph => "em",
                _ => "s",
            };
            let children = node
                .children()
                .map(inline_xml)
                .collect::<Result<Vec<_>>>()?
                .join("");
            format!("<{tag}>{children}</{tag}>")
        }
        NodeValue::Link(link) => {
            if let Some(page) = link.url.strip_prefix("ankole:page/") {
                format!("<mention page=\"{}\"/>", escape(page, true))
            } else if let Some(uid) = link.url.strip_prefix("ankole:principal/") {
                format!("<mention principal=\"{}\"/>", escape(uid, true))
            } else {
                let children = node
                    .children()
                    .map(inline_xml)
                    .collect::<Result<Vec<_>>>()?
                    .join("");
                format!(
                    "<a href=\"{}\" title=\"{}\">{children}</a>",
                    escape(&link.url, true),
                    escape(&link.title, true)
                )
            }
        }
        NodeValue::Image(image) => {
            let alt = node
                .children()
                .map(|child| match &child.data.borrow().value {
                    NodeValue::Text(text) => text.to_string(),
                    _ => String::new(),
                })
                .collect::<String>();
            format!(
                "<img src=\"{}\" alt=\"{}\" title=\"{}\"/>",
                escape(&image.url, true),
                escape(&alt, true),
                escape(&image.title, true)
            )
        }
        value => return Err(format!("unsupported knowledge Markdown inline: {value:?}")),
    };
    Ok(text)
}

fn mention_text(value: &str) -> String {
    static MENTION: LazyLock<Regex> = LazyLock::new(|| {
        Regex::new(r"(^|[\s（(])@([+\p{L}\p{N}_](?:[\p{L}\p{N}_.@+-]*[\p{L}\p{N}_-])?)")
            .expect("static mention expression")
    });
    let mut out = String::new();
    let mut offset = 0;
    for capture in MENTION.captures_iter(value) {
        let whole = capture.get(0).expect("full match");
        out.push_str(&escape(&value[offset..whole.start()], false));
        out.push_str(&escape(&capture[1], false));
        out.push_str(&format!(
            "<mention principal=\"{}\"/>",
            escape(&capture[2], true)
        ));
        offset = whole.end();
    }
    out.push_str(&escape(&value[offset..], false));
    out
}

fn escape(value: &str, attribute: bool) -> String {
    let mut escaped = String::with_capacity(value.len());
    tree::escape_into(value, attribute, &mut escaped);
    escaped
}
