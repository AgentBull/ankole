use super::document::{self, Dialect};
use super::read;
use crate::page_document::tree::{self, Attrs, Element, Node, Result};

pub(super) fn body(root: &Element, dialect: Dialect) -> Result<String> {
    root.children
        .iter()
        .map(|child| {
            let Node::Element(node) = child else {
                return Err("knowledge page contains bare text".into());
            };
            let candidate = block(node, dialect)?;
            let expected =
                tree::normalize(tree::element("page", Attrs::new(), vec![child.clone()]))?;
            // Markdown's delimiter and whitespace rules are not injective. The OKF superset
            // accepts the same restricted XML vocabulary for these uncommon representations.
            if read::body(&candidate, dialect).is_ok_and(|actual| actual == expected) {
                Ok(candidate)
            } else {
                Ok(raw_xml_block(node))
            }
        })
        .collect::<Result<Vec<_>>>()
        .map(|parts| parts.join("\n\n"))
}

fn block(node: &Element, dialect: Dialect) -> Result<String> {
    let result = match node.name.as_str() {
        "p" => inline(&node.children)?,
        "h1" | "h2" | "h3" | "h4" | "h5" | "h6" => format!(
            "{} {}",
            "#".repeat(node.name[1..].parse().map_err(|_| "invalid heading")?),
            inline(&node.children)?
        ),
        "hr" => "***".into(),
        "blockquote" => quote(&body(node, dialect)?),
        "callout" => {
            let alert = match node.attrs.get("tone").map(String::as_str) {
                Some("success") => "TIP",
                Some("warning") => "WARNING",
                Some("danger") => "CAUTION",
                Some("neutral") => "IMPORTANT",
                _ => "NOTE",
            };
            let icon = node
                .attrs
                .get("icon")
                .map(|icon| {
                    format!(
                        " {{icon={}}}",
                        serde_json::to_string(icon).expect("string JSON")
                    )
                })
                .unwrap_or_default();
            quote(&format!("[!{alert}]{icon}\n{}", body(node, dialect)?))
        }
        "ul" | "ol" => {
            let start = node
                .attrs
                .get("start")
                .and_then(|value| value.parse::<usize>().ok())
                .unwrap_or(1);
            let mut items = Vec::new();
            for (index, child) in node.children.iter().enumerate() {
                let Node::Element(item) = child else {
                    return Err("invalid list item".into());
                };
                let marker = if node.name == "ol" {
                    format!("{}. ", start + index)
                } else {
                    "- ".into()
                };
                let task = match item.attrs.get("task").map(String::as_str) {
                    Some("todo") => "[ ] ",
                    Some("done") => "[x] ",
                    _ => "",
                };
                let content = body(item, dialect)?;
                let mut lines = content.split('\n');
                let first = lines.next().unwrap_or_default();
                let mut output = format!("{marker}{task}{first}");
                for line in lines {
                    output.push_str(&format!("\n{}{line}", " ".repeat(marker.len())));
                }
                items.push(output);
            }
            items.join("\n")
        }
        "pre" => {
            if !node.attrs.contains_key("meta")
                && node
                    .attrs
                    .get("lang")
                    .is_some_and(|lang| document::diagram_by_fence(lang, dialect).is_some())
            {
                raw_xml_block(node)
            } else {
                let info = [node.attrs.get("lang"), node.attrs.get("meta")]
                    .into_iter()
                    .flatten()
                    .cloned()
                    .collect::<Vec<_>>()
                    .join(" ");
                fenced_code(&info, &text(&node.children))
            }
        }
        tag if document::diagram_by_tag(tag, dialect).is_some() => {
            let spec = document::diagram_by_tag(tag, dialect).expect("checked source diagram tag");
            let fence = fenced_code(spec.fence_lang, &text(&node.children));
            if node.attrs.is_empty() {
                fence
            } else {
                // A document keeps `view` and `theme` on a diagram tag that wraps the fence.
                let open = tree::print(&tree::element(tag, node.attrs.clone(), vec![]));
                let open = open.strip_suffix(" />").unwrap_or(&open);
                format!("{open}>\n{fence}\n</{tag}>")
            }
        }
        "table" => table(node)?,
        "media" => {
            let Some(src) = node.attrs.get("src") else {
                return Ok(tree::print(node));
            };
            let description = node
                .attrs
                .get("description")
                .map(String::as_str)
                .unwrap_or_default();
            format!(
                "![{}]({}{})",
                escape(description),
                destination(src),
                title(node)
            )
        }
        _ => raw_xml_block(node),
    };
    Ok(result)
}

fn fenced_code(info: &str, text: &str) -> String {
    let fence = "`".repeat(
        text.split(|c| c != '`')
            .map(str::len)
            .max()
            .unwrap_or(0)
            .max(2)
            + 1,
    );
    if text.is_empty() {
        format!("{fence}{info}\n{fence}")
    } else {
        format!("{fence}{info}\n{text}\n{fence}")
    }
}

fn raw_xml_block(node: &Element) -> String {
    let printed = tree::print(node);
    // CommonMark type-1 HTML blocks (<pre>) only close on an explicit </pre> tag.
    if node.name == "pre"
        && node.children.is_empty()
        && let Some(prefix) = printed.strip_suffix(" />")
    {
        format!("{prefix}></pre>")
    } else {
        printed
    }
}

fn table(node: &Element) -> Result<String> {
    let mut rows = Vec::new();
    for (index, row) in node.children.iter().enumerate() {
        let Node::Element(row) = row else {
            return Err("invalid table row".into());
        };
        let mut cells = Vec::new();
        let mut alignments = Vec::new();
        for cell in &row.children {
            let Node::Element(cell) = cell else {
                return Err("invalid table cell".into());
            };
            let Some(Node::Element(p)) = cell.children.first() else {
                return Err("missing cell paragraph".into());
            };
            cells.push(inline(&p.children)?.replace('|', "\\|"));
            alignments.push(match cell.attrs.get("align").map(String::as_str) {
                Some("left") => ":---",
                Some("right") => "---:",
                Some("center") => ":---:",
                _ => "---",
            });
        }
        rows.push(format!("| {} |", cells.join(" | ")));
        if index == 0 {
            rows.push(format!("| {} |", alignments.join(" | ")));
        }
    }
    Ok(rows.join("\n"))
}

fn quote(value: &str) -> String {
    value
        .split('\n')
        .map(|line| format!("> {line}"))
        .collect::<Vec<_>>()
        .join("\n")
}

fn inline(nodes: &[Node]) -> Result<String> {
    nodes
        .iter()
        .map(|node| match node {
            Node::Text(value) => Ok(escape(value)),
            Node::Element(node) => {
                let content = inline(&node.children)?;
                Ok(match node.name.as_str() {
                    "strong" => format!("**{content}**"),
                    "em" => format!("*{content}*"),
                    "s" => format!("~~{content}~~"),
                    "code" => {
                        let content = text(&node.children);
                        let fence = "`".repeat(
                            content.split(|c| c != '`').map(str::len).max().unwrap_or(0) + 1,
                        );
                        let pad = content.starts_with('`')
                            || content.ends_with('`')
                            || (content.starts_with(' ')
                                && content.ends_with(' ')
                                && !content.trim().is_empty());
                        if pad {
                            format!("{fence} {content} {fence}")
                        } else {
                            format!("{fence}{content}{fence}")
                        }
                    }
                    "br" => "\\\n".into(),
                    "a" => {
                        let href = node.attrs.get("href").ok_or("missing link href")?;
                        let title = title(node);
                        format!("[{content}]({}{title})", destination(href))
                    }
                    "img" => format!(
                        "![{}]({}{})",
                        escape(
                            node.attrs
                                .get("alt")
                                .map(String::as_str)
                                .unwrap_or_default()
                        ),
                        destination(node.attrs.get("src").ok_or("missing image src")?),
                        title(node)
                    ),
                    "mention" => {
                        if let Some(uid) = node.attrs.get("principal") {
                            format!("@{uid}")
                        } else {
                            let page = node.attrs.get("page").ok_or("missing mention target")?;
                            format!("[{}](ankole:page/{})", escape(page), destination(page))
                        }
                    }
                    _ => tree::print(node),
                })
            }
        })
        .collect::<Result<Vec<_>>>()
        .map(|parts| parts.join(""))
}

fn text(nodes: &[Node]) -> String {
    nodes
        .iter()
        .map(|node| match node {
            Node::Text(text) => text.clone(),
            Node::Element(node) => text(&node.children),
        })
        .collect()
}
fn title(node: &Element) -> String {
    node.attrs
        .get("title")
        .map(|title| format!(" \"{}\"", title.replace('\\', "\\\\").replace('"', "\\\"")))
        .unwrap_or_default()
}
fn destination(value: &str) -> String {
    value
        .replace(' ', "%20")
        .replace('(', "\\(")
        .replace(')', "\\)")
}
fn escape(value: &str) -> String {
    let mut out = String::new();
    for ch in value.chars() {
        if "\\`*[]_~<>#".contains(ch) {
            out.push('\\');
        }
        out.push(ch);
    }
    out
}
