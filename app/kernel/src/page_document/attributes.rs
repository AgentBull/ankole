//! Attribute value grammar shared by XML normalization and OT mark validation.
use super::document_schema::NodeKind;
use super::tree::{Attrs, Element, Result, SPAN_LIMIT, name_valid, valid_character};

pub(super) const DIAGRAM_VIEWS: [&str; 3] = ["both", "code", "diagram"];
pub(super) const DIAGRAM_THEMES: [&str; 3] = ["auto", "light", "dark"];
pub(super) const DIAGRAM_DOC_ATTRS: [&str; 2] = ["view", "theme"];

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) struct SourceDiagramSpec {
    pub tag: &'static str,
    pub kind: NodeKind,
    pub view_mark: &'static str,
    pub theme_mark: &'static str,
    pub doc_attrs: &'static [&'static str],
    #[cfg(feature = "markdown")]
    pub fence_lang: &'static str,
    #[cfg(feature = "markdown")]
    pub knowledge_attrs: Option<&'static [&'static str]>,
    #[cfg(feature = "markdown")]
    pub overview_label: &'static str,
}

pub(super) const SOURCE_DIAGRAMS: [SourceDiagramSpec; 2] = [
    SourceDiagramSpec {
        tag: "mermaid",
        kind: NodeKind::Mermaid,
        view_mark: "MermaidView",
        theme_mark: "MermaidTheme",
        doc_attrs: &DIAGRAM_DOC_ATTRS,
        #[cfg(feature = "markdown")]
        fence_lang: "mermaid",
        #[cfg(feature = "markdown")]
        knowledge_attrs: Some(&[]),
        #[cfg(feature = "markdown")]
        overview_label: "Mermaid block",
    },
    SourceDiagramSpec {
        tag: "infographic",
        kind: NodeKind::Infographic,
        view_mark: "InfographicView",
        theme_mark: "InfographicTheme",
        doc_attrs: &DIAGRAM_DOC_ATTRS,
        #[cfg(feature = "markdown")]
        fence_lang: "infographic",
        #[cfg(feature = "markdown")]
        knowledge_attrs: None,
        #[cfg(feature = "markdown")]
        overview_label: "Infographic block",
    },
];

pub(super) fn source_diagram_by_tag(tag: &str) -> Option<&'static SourceDiagramSpec> {
    SOURCE_DIAGRAMS.iter().find(|spec| spec.tag == tag)
}

pub(super) fn source_diagram_by_kind(kind: NodeKind) -> Option<&'static SourceDiagramSpec> {
    SOURCE_DIAGRAMS.iter().find(|spec| spec.kind == kind)
}

pub(super) fn is_source_diagram_tag(tag: &str) -> bool {
    source_diagram_by_tag(tag).is_some()
}

pub(super) fn source_diagram_mark(
    mark: &str,
) -> Option<(&'static SourceDiagramSpec, &'static str)> {
    SOURCE_DIAGRAMS.iter().find_map(|spec| {
        if spec.view_mark == mark {
            Some((spec, "view"))
        } else if spec.theme_mark == mark {
            Some((spec, "theme"))
        } else {
            None
        }
    })
}

#[cfg(feature = "markdown")]
pub(super) fn knowledge_source_diagram_by_tag(tag: &str) -> Option<&'static SourceDiagramSpec> {
    source_diagram_by_tag(tag).filter(|spec| spec.knowledge_attrs.is_some())
}

#[cfg(feature = "markdown")]
pub(super) fn knowledge_source_diagram_by_fence(lang: &str) -> Option<&'static SourceDiagramSpec> {
    SOURCE_DIAGRAMS
        .iter()
        .find(|spec| spec.knowledge_attrs.is_some() && spec.fence_lang == lang)
}

pub(super) fn valid_value(name: &str, key: &str, value: &str) -> bool {
    match key {
        "align" => ["left", "center", "right", "justify"].contains(&value),
        "indent" => integer_text(value, 1, 999),
        "width" => integer_text(value, 1, 9999),
        "widths" => table_widths(value),
        "layout" => value == "full",
        "background" => cell_background(value),
        "start" => integer_text(value, 0, 999_999_999),
        "colspan" | "rowspan" => integer_text(value, 1, SPAN_LIMIT),
        "task" => ["todo", "done"].contains(&value),
        "tone" => ["info", "warning", "success", "danger", "neutral"].contains(&value),
        "wrap" => value == "true",
        "view" if is_source_diagram_tag(name) => DIAGRAM_VIEWS.contains(&value),
        "view" if name == "media" => ["link", "title", "card", "preview"].contains(&value),
        "kind" if name == "media" => ["image", "video"].contains(&value),
        "height" if name == "embed" => integer_text(value, 160, 1600),
        "theme" if is_source_diagram_tag(name) => DIAGRAM_THEMES.contains(&value),
        "page" | "principal" if name == "mention" => !value.is_empty(),
        _ => true,
    }
}

fn allowed_attribute(name: &str, key: &str) -> bool {
    match name {
        "p" | "h1" | "h2" | "h3" | "h4" | "h5" | "h6" => {
            matches!(key, "align" | "indent" | "style")
        }
        "th" | "td" => matches!(key, "align" | "colspan" | "rowspan" | "background"),
        "table" => matches!(key, "widths" | "layout"),
        "ol" => key == "start",
        "column" => key == "width",
        "li" => key == "task",
        "pre" => matches!(key, "lang" | "meta" | "wrap"),
        tag if source_diagram_by_tag(tag).is_some() => {
            source_diagram_by_tag(tag).is_some_and(|spec| spec.doc_attrs.contains(&key))
        }
        "callout" => matches!(key, "tone" | "icon"),
        "embed" => matches!(
            key,
            "ref" | "table" | "view" | "href" | "title" | "description" | "image" | "height"
        ),
        "media" => matches!(
            key,
            "src" | "title" | "description" | "image" | "mime" | "size" | "kind" | "view"
        ),
        "a" => matches!(key, "href" | "title"),
        "img" => matches!(key, "src" | "alt" | "title"),
        "mention" => matches!(key, "page" | "principal"),
        "span" => key == "style",
        "comment" => key == "ids",
        _ => false,
    }
}
fn integer_text(value: &str, min: u32, max: u32) -> bool {
    !value.is_empty()
        && (value == "0" || !value.starts_with('0'))
        && value.bytes().all(|c| c.is_ascii_digit())
        && value.parse::<u32>().is_ok_and(|v| (min..=max).contains(&v))
}
pub(super) fn table_widths(value: &str) -> bool {
    value.split(',').all(|width| integer_text(width, 1, 9999))
}
pub(super) fn cell_background(value: &str) -> bool {
    value.len() == 7
        && value.starts_with('#')
        && value.as_bytes()[1..].iter().all(u8::is_ascii_hexdigit)
}
pub(super) fn normalize(node: &Element) -> Result<Attrs> {
    if node.name == "comment" {
        if node.attrs.len() != 1 {
            return Err("comment requires only ids".into());
        }
        let ids = super::comments::parse_ids(node.attrs.get("ids").ok_or("missing comment ids")?)?;
        return Ok(Attrs::from([("ids".into(), ids.join(" "))]));
    }
    if node.name == "page" && !node.attrs.is_empty() {
        return Err("page has no attributes".into());
    }
    let mut result = Attrs::new();
    for (key, value) in &node.attrs {
        if !name_valid(key, true) || !value.chars().all(valid_character) {
            return Err("invalid XML attribute".into());
        }
        let kept;
        let value = if key == "style" && allowed_attribute(&node.name, key) {
            kept = super::tree::kept_style(value);
            &kept
        } else {
            value
        };
        if allowed_attribute(&node.name, key) {
            let valid = valid_value(&node.name, key, value);
            if !valid {
                return Err(format!("invalid {} attribute {key}", node.name));
            }
            if (value.is_empty()
                && ["alt", "lang", "meta", "style", "title"].contains(&key.as_str()))
                || (node.name == "column" && key == "width" && value == "1000")
                || (value == "1"
                    && (key == "colspan"
                        || key == "rowspan"
                        || (key == "start" && node.name == "ol")))
                || (is_source_diagram_tag(&node.name)
                    && ((key == "view" && value == "both") || (key == "theme" && value == "auto")))
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
    if node.name == "mention" {
        let has_page = result.contains_key("page");
        let has_principal = result.contains_key("principal");
        if has_page == has_principal {
            return Err("mention requires exactly one of page or principal".into());
        }
    }
    Ok(result)
}
