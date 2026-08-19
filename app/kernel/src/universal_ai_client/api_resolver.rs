use std::collections::{BTreeMap, BTreeSet};
use std::time::{SystemTime, UNIX_EPOCH};

use serde_json::{Map, Number, Value, json};

use super::error::{StreamError, StreamErrorCode};
use super::spec::{APIResolverKind, ResponseContext};

mod anthropic;
mod aws_bedrock_converse;
mod core;
mod custom_tool_emulation;
mod embeddings;
mod google_embeddings;
mod google_gemini;
mod opaque_tool_fields;
mod openai_chat;
mod openai_responses;
mod openrouter_images;
mod reasoning_envelope;
mod rerank;
mod standard;
#[cfg(test)]
mod tests;
mod web;

use self::anthropic::*;
use self::aws_bedrock_converse::*;
use self::core::APIProtocol;
pub use self::core::APIResolver;
use self::custom_tool_emulation::*;
use self::embeddings::*;
use self::google_embeddings::*;
use self::google_gemini::*;
use self::opaque_tool_fields::*;
use self::openai_chat::*;
use self::openai_responses::*;
use self::openrouter_images::*;
use self::rerank::*;
pub(crate) use self::standard::*;
use self::web::*;

fn flattened_namespace_tool_name(namespace: &str, name: &str) -> String {
    let joined = if namespace.is_empty() || namespace == "functions" {
        name.to_string()
    } else if namespace.ends_with('_') || name.starts_with('_') {
        format!("{namespace}{name}")
    } else {
        format!("{namespace}__{name}")
    };

    const MAX_LENGTH: usize = 64;
    const DIGEST_LENGTH: usize = 12;
    const PREFIX_LENGTH: usize = MAX_LENGTH - DIGEST_LENGTH - 1;

    if !joined.is_empty()
        && joined.len() <= MAX_LENGTH
        && joined.bytes().all(provider_tool_name_byte)
    {
        return joined;
    }

    let prefix: String = joined
        .bytes()
        .take(PREFIX_LENGTH)
        .map(|byte| {
            if provider_tool_name_byte(byte) {
                char::from(byte)
            } else {
                '_'
            }
        })
        .collect();
    let digest = blake3::hash(joined.as_bytes()).to_hex().to_string();
    format!("{prefix}_{}", &digest[..DIGEST_LENGTH])
}

fn provider_tool_name_byte(byte: u8) -> bool {
    byte.is_ascii_alphanumeric() || matches!(byte, b'_' | b'-')
}
