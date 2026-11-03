use blake3::Hasher;
use csv::{Position, Reader, StringRecord, WriterBuilder};
use serde_json::{Map, Value};
use std::collections::HashSet;
use std::fs::{self, File, OpenOptions};
use std::io::{BufReader, SeekFrom};
use uuid::Uuid;

/// Parse the dot-directory grammar independently of the database schema. The
/// caller resolves business names through the owning Base table definitions.
#[must_use]
pub fn pipeline(parts: &[String]) -> Value {
    let mut stages = Vec::new();
    let mut i = 0;
    while i < parts.len() {
        let arity = match parts[i].as_str() {
            ".filter" => 2,
            ".order" | ".columns" | ".first" | ".last" | ".views" => 1,
            _ => break,
        };
        if parts.len() < i + arity + 1 {
            break;
        }
        stages.push(serde_json::json!({"op":parts[i], "args":parts[i+1..i+arity+1]}));
        i += arity + 1;
    }
    serde_json::json!({"stages": stages, "rest": parts[i..]})
}

/// Append one bounded query batch to a local immutable snapshot. No complete
/// table or serialized export is retained on the BEAM heap.
pub fn export_chunk(
    path: &str,
    format: &str,
    columns: &[String],
    rows: &[Value],
    first: bool,
    last: bool,
) -> Result<u64, String> {
    use std::io::Write;

    let mut file = OpenOptions::new()
        .create(true)
        .write(true)
        .truncate(first)
        .append(!first)
        .open(path)
        .map_err(|e| e.to_string())?;
    match format {
        "csv" | "tsv" => {
            let mut writer = WriterBuilder::new()
                .delimiter(if format == "tsv" { b'\t' } else { b',' })
                .from_writer(&mut file);
            if first {
                writer.write_record(columns).map_err(|e| e.to_string())?;
            }
            for row in rows {
                let values: Vec<String> = columns
                    .iter()
                    .map(|name| match &row[name] {
                        Value::Null => String::new(),
                        Value::String(s) => s.clone(),
                        value => value.to_string(),
                    })
                    .collect();
                writer.write_record(values).map_err(|e| e.to_string())?;
            }
            writer.flush().map_err(|e| e.to_string())?;
        }
        "json" | "jsonl" => {
            if first && format == "json" {
                file.write_all(b"[").map_err(|e| e.to_string())?;
            }
            for (index, row) in rows.iter().enumerate() {
                if format == "json" && (!first || index > 0) {
                    file.write_all(b",").map_err(|e| e.to_string())?;
                }
                serde_json::to_writer(&mut file, row).map_err(|e| e.to_string())?;
                if format == "jsonl" {
                    file.write_all(b"\n").map_err(|e| e.to_string())?;
                }
            }
            if last && format == "json" {
                file.write_all(b"]\n").map_err(|e| e.to_string())?;
            }
        }
        _ => return Err("unsupported export format".into()),
    }
    file.metadata().map(|m| m.len()).map_err(|e| e.to_string())
}

/// A byte cursor survives multiline CSV records. Each call returns at most
/// 200 records, matching the Base owner's transaction batch limit.
pub fn import_chunk(path: &str, format: &str, offset: u64) -> Result<Value, String> {
    use std::io::{BufRead, Seek};

    let file = File::open(path).map_err(|e| e.to_string())?;
    let mut rows = Vec::new();
    let next = match format {
        "csv" => {
            let mut reader = Reader::from_reader(file);
            let header = reader.headers().map_err(|e| e.to_string())?.clone();
            if header.iter().collect::<HashSet<_>>().len() != header.len() {
                return Err("duplicate CSV columns".into());
            }
            if offset > 0 {
                let mut position = Position::new();
                position.set_byte(offset);
                reader.seek(position).map_err(|e| e.to_string())?;
            }
            let mut record = StringRecord::new();
            while rows.len() < 200 && reader.read_record(&mut record).map_err(|e| e.to_string())? {
                rows.push(Value::Object(
                    header
                        .iter()
                        .zip(record.iter())
                        .map(|(k, v)| (k.to_owned(), Value::String(v.to_owned())))
                        .collect(),
                ));
            }
            reader.position().byte()
        }
        "jsonl" => {
            let mut reader = BufReader::new(file);
            reader
                .seek(SeekFrom::Start(offset))
                .map_err(|e| e.to_string())?;
            let mut line = String::new();
            while rows.len() < 200 {
                line.clear();
                if reader.read_line(&mut line).map_err(|e| e.to_string())? == 0 {
                    break;
                }
                if line.trim().is_empty() {
                    continue;
                }
                let value: Value = serde_json::from_str(&line).map_err(|e| e.to_string())?;
                if !value.is_object() {
                    return Err("import rows must be JSON objects".into());
                }
                rows.push(value);
            }
            reader.stream_position().map_err(|e| e.to_string())?
        }
        _ => return Err("unsupported import format".into()),
    };
    let complete = next >= fs::metadata(path).map_err(|e| e.to_string())?.len();
    Ok(serde_json::json!({"rows": rows, "cursor": next, "complete": complete}))
}

/// Both maps must contain exactly the changed columns. field_cas checks their union.
pub fn record_patch(base: &Value, next: &Value) -> Result<Value, String> {
    let base = base.as_object().ok_or("base must be an object")?;
    let next = next.as_object().ok_or("next must be an object")?;
    let versions = base
        .get("_versions")
        .and_then(Value::as_object)
        .ok_or("missing base versions")?;
    let mut data = Map::new();
    let mut expected = Map::new();
    for key in base.keys().chain(next.keys()) {
        if matches!(key.as_str(), "_id" | "_versions") || base.get(key) == next.get(key) {
            continue;
        }
        data.insert(key.clone(), next.get(key).cloned().unwrap_or(Value::Null));
        expected.insert(
            key.clone(),
            versions.get(key).cloned().unwrap_or(Value::Null),
        );
    }
    Ok(serde_json::json!({"data": data, "expected_versions": expected}))
}

/// Derive replay-stable UUIDv7 row IDs, spilling the sequence into timestamp bits.
pub fn import_id(
    tenant: &str,
    table: &str,
    request: &str,
    millis: u64,
    row: u64,
) -> Result<String, String> {
    let timestamp = millis
        .checked_add(row >> 12)
        .filter(|n| *n < 1 << 48)
        .ok_or("invalid UUIDv7 timestamp")?;
    let mut hash = Hasher::new_derive_key("ankole:base:import");
    for id in [tenant, table, request] {
        hash.update(Uuid::parse_str(id).map_err(|e| e.to_string())?.as_bytes());
    }
    hash.update(&row.to_be_bytes());
    let mut bytes = [0u8; 16];
    bytes[..6].copy_from_slice(&timestamp.to_be_bytes()[2..]);
    bytes[6] = 0x70 | ((row >> 8) & 15) as u8;
    bytes[7] = row as u8;
    bytes[8..].copy_from_slice(&hash.finalize().as_bytes()[..8]);
    bytes[8] = 0x80 | (bytes[8] & 63);
    Ok(Uuid::from_bytes(bytes).to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    #[test]
    fn disjoint_column_updates_do_not_compare_unmodified_versions() {
        assert_eq!(
            record_patch(
                &json!({"a":1,"b":2,"_versions":{"a":4,"b":5}}),
                &json!({"a":3,"b":2})
            )
            .unwrap(),
            json!({"data":{"a":3},"expected_versions":{"a":4}})
        );
    }
    #[test]
    fn import_ids_preserve_order_across_millisecond_overflow_and_replay() {
        let id = "019a3d91-c673-7000-8000-000000000001";
        let ids: Vec<_> = (0..5000)
            .map(|row| import_id(id, id, id, 100, row).unwrap())
            .collect();
        assert!(ids.windows(2).all(|pair| pair[0] < pair[1]));
        assert_eq!(ids[4096], import_id(id, id, id, 100, 4096).unwrap());
    }
}
