use super::document::{self, Dialect};
use crate::page_document::tree::{self, Attrs, Element, Node, Result};
use comrak::nodes::{AlertType, AstNode, ListType, NodeValue, TableAlignment};
use comrak::{Arena, Options};
use regex::Regex;
use std::sync::LazyLock;

pub(super) fn body(source: &str, dialect: Dialect) -> Result<Element> {
    let folded;
    let source = if dialect == Dialect::Document {
        folded = fold_diagram_wrappers(source);
        folded.as_str()
    } else {
        source
    };
    let arena = Arena::new();
    let mut options = Options::default();
    options.extension.table = true;
    options.extension.tasklist = true;
    options.extension.strikethrough = true;
    options.extension.alerts = true;
    let ast = comrak::parse_document(&arena, source, &options);
    let root = tree::normalize(tree::element("page", Attrs::new(), blocks(ast, dialect)?))?;
    document::validate_tree(&root, dialect)?;
    Ok(root)
}

fn blocks<'a>(node: &'a AstNode<'a>, dialect: Dialect) -> Result<Vec<Node>> {
    node.children()
        .map(|child| block(child, dialect))
        .collect::<Result<Vec<_>>>()
        .map(|items| items.into_iter().flatten().collect())
}

fn block<'a>(node: &'a AstNode<'a>, dialect: Dialect) -> Result<Vec<Node>> {
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
        NodeValue::BlockQuote => ("blockquote".into(), blocks(node, dialect)?),
        NodeValue::List(list) => {
            let ordered = list.list_type == ListType::Ordered;
            if ordered && list.start != 1 {
                attrs.insert("start".into(), list.start.to_string());
            }
            (
                (if ordered { "ol" } else { "ul" }).into(),
                blocks(node, dialect)?,
            )
        }
        NodeValue::Item(_) => ("li".into(), blocks(node, dialect)?),
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
            ("li".into(), blocks(node, dialect)?)
        }
        NodeValue::CodeBlock(code) => {
            let (lang, meta) = code.info.split_once(' ').unwrap_or((&code.info, ""));
            let content = code
                .literal
                .strip_suffix('\n')
                .unwrap_or(&code.literal)
                .to_owned();
            if let Some(wrapped) = meta.strip_prefix(WRAPPED_DIAGRAM)
                && let Some(spec) = document::diagram_by_fence(lang, dialect)
            {
                let wrapper = tree::parse(&format!("<page><{} {wrapped}/></page>", spec.tag))?;
                if let Some(Node::Element(diagram)) = wrapper.children.into_iter().next() {
                    attrs = diagram.attrs;
                }
                (spec.tag.into(), vec![Node::Text(content)])
            } else if meta.is_empty()
                && let Some(spec) = document::diagram_by_fence(lang, dialect)
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
            ("callout".into(), blocks(node, dialect)?)
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

/// Marks a diagram fence folded from a wrapper; Markdown text cannot contain this character.
const WRAPPED_DIAGRAM: char = '\u{1}';

/// Document Markdown carries a diagram's `view` and `theme` by wrapping its fence in the
/// diagram tag. CommonMark would end that HTML block at the first blank line of the diagram,
/// so each complete wrapper is folded into its fence, with the tag's attributes in the info
/// string after `WRAPPED_DIAGRAM`. Ordinary fenced code passes through untouched.
fn fold_diagram_wrappers(source: &str) -> String {
    static OPEN: LazyLock<Regex> = LazyLock::new(|| {
        Regex::new(r#"^ {0,3}<(mermaid|infographic)((?:\s+[a-z]+="[^"<>]*")*)\s*>\s*$"#)
            .expect("static diagram wrapper expression")
    });
    let lines: Vec<&str> = source.split_inclusive('\n').collect();
    let mut out = String::with_capacity(source.len());
    let mut index = 0;
    while index < lines.len() {
        if let Some((mark, width, _)) = fence_open(lines[index]) {
            out.push_str(lines[index]);
            index += 1;
            while index < lines.len() {
                out.push_str(lines[index]);
                index += 1;
                if fence_close(lines[index - 1], mark, width) {
                    break;
                }
            }
            continue;
        }
        let folded = OPEN.captures(lines[index].trim_end()).and_then(|open| {
            let tag = open.get(1).expect("tag group").as_str();
            let opener = skip_blank(&lines, index + 1);
            let (mark, width, info) = fence_open(lines.get(opener)?)?;
            if info != tag {
                return None;
            }
            let mut closer = opener + 1;
            while !fence_close(lines.get(closer)?, mark, width) {
                closer += 1;
            }
            let end = skip_blank(&lines, closer + 1);
            (lines.get(end)?.trim() == format!("</{tag}>")).then(|| {
                let marks = mark.to_string().repeat(width);
                let attrs = open.get(2).expect("attribute group").as_str().trim();
                let body = lines[opener + 1..closer].concat();
                (
                    format!("{marks}{tag} {WRAPPED_DIAGRAM}{attrs}\n{body}{marks}\n"),
                    end + 1,
                )
            })
        });
        if let Some((fence, next)) = folded {
            out.push_str(&fence);
            index = next;
        } else {
            out.push_str(lines[index]);
            index += 1;
        }
    }
    out
}

fn skip_blank(lines: &[&str], mut index: usize) -> usize {
    while lines.get(index).is_some_and(|line| line.trim().is_empty()) {
        index += 1;
    }
    index
}

/// A CommonMark fence opener: its marker, run length, and info string.
fn fence_open(line: &str) -> Option<(char, usize, &str)> {
    let trimmed = line.trim_start_matches(' ');
    if line.len() - trimmed.len() > 3 {
        return None;
    }
    let mark = trimmed.chars().next().filter(|c| *c == '`' || *c == '~')?;
    let width = trimmed.chars().take_while(|c| *c == mark).count();
    let info = trimmed[width..].trim();
    (width >= 3 && !(mark == '`' && info.contains('`'))).then_some((mark, width, info))
}

fn fence_close(line: &str, mark: char, width: usize) -> bool {
    let trimmed = line.trim_start_matches(' ');
    line.len() - trimmed.len() <= 3
        && trimmed.chars().take_while(|c| *c == mark).count() >= width
        && trimmed.trim_start_matches(mark).trim().is_empty()
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
