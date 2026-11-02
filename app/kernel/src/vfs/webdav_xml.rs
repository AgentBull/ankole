use quick_xml::Reader;
use quick_xml::events::Event;
use serde::Deserialize;
use std::fmt::Write;

/// Metadata supplied by Files for one DAV resource; bodies stay in object storage.
#[derive(Debug, Deserialize)]
pub struct Entry {
    pub href: String,
    pub name: String,
    pub collection: bool,
    pub size: u64,
    pub etag: String,
    #[serde(default)]
    pub fingerprint: String,
    pub modified: String,
    pub content_type: String,
    pub node_id: String,
    #[serde(default)]
    pub stat_on_lookup: bool,
}

/// Validate the supported PROPFIND document without retaining its property tree.
pub fn request(source: &str, method: &str) -> Result<(), String> {
    if source.is_empty() && method == "PROPFIND" {
        return Ok(());
    }
    let mut reader = Reader::from_str(source);
    reader.config_mut().expand_empty_elements = true;
    let mut propfind_root = false;
    let mut depth = 0;
    let mut roots = 0;
    loop {
        match reader.read_event().map_err(|e| e.to_string())? {
            Event::Start(tag) => {
                if depth == 0 {
                    roots += 1;
                    propfind_root = tag.local_name().as_ref() == "propfind";
                }
                depth += 1;
            }
            Event::End(_) => depth -= 1,
            Event::DocType(_) | Event::PI(_) => {
                return Err("DAV does not accept DTD or processing instructions".into());
            }
            Event::GeneralRef(value) => {
                quick_xml::escape::unescape(&format!("&{};", value.as_ref()))
                    .map_err(|e| e.to_string())?;
            }
            Event::Eof => break,
            _ => {}
        }
    }
    if depth != 0 || roots != 1 || !propfind_root {
        return Err("invalid DAV request document".into());
    }
    Ok(())
}

/// Encode DAV metadata with escaped names and the fingerprints used by the cache.
#[must_use]
pub fn multistatus(entries: &[Entry]) -> String {
    let mut out = String::from(
        "<?xml version=\"1.0\" encoding=\"utf-8\"?><d:multistatus xmlns:d=\"DAV:\" xmlns:a=\"urn:ankole:vfs\">",
    );
    for entry in entries {
        out.push_str("<d:response>");
        property(&mut out, "d:href", &entry.href);
        out.push_str("<d:propstat><d:prop>");
        property(&mut out, "d:displayname", &entry.name);
        if entry.collection {
            out.push_str("<d:resourcetype><d:collection/></d:resourcetype>");
        } else {
            out.push_str("<d:resourcetype/>");
        }
        write!(
            out,
            "<d:getcontentlength>{}</d:getcontentlength>",
            entry.size
        )
        .expect("writing to a String cannot fail");
        property(&mut out, "d:getetag", &entry.etag);
        property(&mut out, "a:fingerprint", &entry.fingerprint);
        property(&mut out, "d:getlastmodified", &entry.modified);
        property(&mut out, "d:getcontenttype", &entry.content_type);
        property(&mut out, "a:node-id", &entry.node_id);
        if entry.stat_on_lookup {
            out.push_str("<a:stat-on-lookup>true</a:stat-on-lookup>");
        }
        out.push_str("</d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>");
    }
    out.push_str("</d:multistatus>");
    out
}

fn property(out: &mut String, tag: &str, value: &str) {
    write!(out, "<{tag}>{}</{tag}>", quick_xml::escape::escape(value))
        .expect("writing to a String cannot fail");
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn rejects_entities_and_accepts_namespace_prefixes() {
        assert!(
            request(
                "<d:propfind xmlns:d=\"DAV:\"><d:allprop/></d:propfind>",
                "PROPFIND"
            )
            .is_ok()
        );
        assert!(
            request(
                "<!DOCTYPE x [<!ENTITY e SYSTEM 'file:///etc/passwd'>]><propfind/>",
                "PROPFIND"
            )
            .is_err()
        );
        assert!(request("<propfind/><propfind/>", "PROPFIND").is_err());
    }
}
