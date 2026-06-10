use comrak::nodes::{AstNode, ListType, NodeValue, TableAlignment};
use comrak::{Arena, Options, parse_document};
use napi_derive::napi;
use serde_json::{Map, Value, json};

fn gfm_options() -> Options<'static> {
  let mut options = Options::default();
  options.extension.table = true;
  options.extension.strikethrough = true;
  options.extension.autolink = true;
  options.extension.tasklist = true;
  options
}

fn children<'a>(node: &'a AstNode<'a>) -> Vec<Value> {
  node.children().filter_map(to_mdast).collect()
}

fn text_of<'a>(node: &'a AstNode<'a>) -> String {
  let mut out = String::new();
  for child in node.descendants() {
    if let NodeValue::Text(text) = &child.data.borrow().value {
      out.push_str(text);
    }
  }
  out
}

fn node(kind: &str, extra: Map<String, Value>) -> Value {
  let mut map = Map::new();
  map.insert("type".to_string(), Value::String(kind.to_string()));
  map.extend(extra);
  Value::Object(map)
}

fn parent(kind: &str, kids: Vec<Value>, extra: Map<String, Value>) -> Value {
  let mut map = Map::new();
  map.insert("type".to_string(), Value::String(kind.to_string()));
  map.extend(extra);
  map.insert("children".to_string(), Value::Array(kids));
  Value::Object(map)
}

fn to_mdast<'a>(ast: &'a AstNode<'a>) -> Option<Value> {
  let value = &ast.data.borrow().value;
  Some(match value {
    NodeValue::Document => parent("root", children(ast), Map::new()),
    NodeValue::Paragraph => parent("paragraph", children(ast), Map::new()),
    NodeValue::Text(text) => node("text", {
      let mut m = Map::new();
      m.insert("value".into(), json!(text));
      m
    }),
    NodeValue::SoftBreak => node("text", {
      let mut m = Map::new();
      m.insert("value".into(), json!("\n"));
      m
    }),
    NodeValue::LineBreak => node("break", Map::new()),
    NodeValue::Strong => parent("strong", children(ast), Map::new()),
    NodeValue::Emph => parent("emphasis", children(ast), Map::new()),
    NodeValue::Strikethrough => parent("delete", children(ast), Map::new()),
    NodeValue::Code(code) => node("inlineCode", {
      let mut m = Map::new();
      m.insert("value".into(), json!(code.literal));
      m
    }),
    NodeValue::CodeBlock(block) => node("code", {
      let mut m = Map::new();
      let lang = block.info.split_whitespace().next().unwrap_or("");
      m.insert(
        "lang".into(),
        if lang.is_empty() {
          Value::Null
        } else {
          json!(lang)
        },
      );
      m.insert(
        "value".into(),
        json!(block.literal.strip_suffix('\n').unwrap_or(&block.literal)),
      );
      m
    }),
    NodeValue::Link(link) => parent("link", children(ast), {
      let mut m = Map::new();
      m.insert("url".into(), json!(link.url));
      m.insert(
        "title".into(),
        if link.title.is_empty() {
          Value::Null
        } else {
          json!(link.title)
        },
      );
      m
    }),
    NodeValue::Image(image) => node("image", {
      let mut m = Map::new();
      m.insert("url".into(), json!(image.url));
      m.insert(
        "title".into(),
        if image.title.is_empty() {
          Value::Null
        } else {
          json!(image.title)
        },
      );
      m.insert("alt".into(), json!(text_of(ast)));
      m
    }),
    NodeValue::Heading(heading) => parent("heading", children(ast), {
      let mut m = Map::new();
      m.insert("depth".into(), json!(heading.level));
      m
    }),
    NodeValue::List(list) => parent("list", children(ast), {
      let mut m = Map::new();
      let ordered = list.list_type == ListType::Ordered;
      m.insert("ordered".into(), json!(ordered));
      m.insert(
        "start".into(),
        if ordered {
          json!(list.start)
        } else {
          Value::Null
        },
      );
      m.insert("spread".into(), json!(!list.tight));
      m
    }),
    NodeValue::Item(_) => parent("listItem", children(ast), {
      let mut m = Map::new();
      m.insert("spread".into(), json!(false));
      m.insert("checked".into(), Value::Null);
      m
    }),
    NodeValue::TaskItem(checked) => parent("listItem", children(ast), {
      let mut m = Map::new();
      m.insert("spread".into(), json!(false));
      m.insert("checked".into(), json!(checked.is_some()));
      m
    }),
    NodeValue::BlockQuote => parent("blockquote", children(ast), Map::new()),
    NodeValue::ThematicBreak => node("thematicBreak", Map::new()),
    NodeValue::Table(table) => parent("table", children(ast), {
      let mut m = Map::new();
      let align: Vec<Value> = table
        .alignments
        .iter()
        .map(|alignment| match alignment {
          TableAlignment::Left => json!("left"),
          TableAlignment::Right => json!("right"),
          TableAlignment::Center => json!("center"),
          TableAlignment::None => Value::Null,
        })
        .collect();
      m.insert("align".into(), Value::Array(align));
      m
    }),
    NodeValue::TableRow(_) => parent("tableRow", children(ast), Map::new()),
    NodeValue::TableCell => parent("tableCell", children(ast), Map::new()),
    NodeValue::HtmlBlock(html) => node("html", {
      let mut m = Map::new();
      m.insert(
        "value".into(),
        json!(html.literal.strip_suffix('\n').unwrap_or(&html.literal)),
      );
      m
    }),
    NodeValue::HtmlInline(html) => node("html", {
      let mut m = Map::new();
      m.insert("value".into(), json!(html));
      m
    }),
    // Nodes without a stable mdast mapping degrade to their children wrapped in
    // a paragraph-free fragment; unknown leaves are dropped.
    _ => {
      let kids = children(ast);
      if kids.is_empty() {
        return None;
      }
      if kids.len() == 1 {
        return Some(kids.into_iter().next().unwrap());
      }
      parent("paragraph", kids, Map::new())
    }
  })
}

/// Parses GFM markdown into an mdast-shaped JSON tree (`{type: "root", ...}`).
/// Replaces the unified/remark dependency tree for outbound-message projection.
#[napi(ts_return_type = "Record<string, unknown>")]
pub fn parse_markdown_ast(markdown: String) -> Value {
  let arena = Arena::new();
  let root = parse_document(&arena, &markdown, &gfm_options());
  to_mdast(root).unwrap_or_else(|| json!({ "type": "root", "children": [] }))
}
