use std::collections::{BTreeMap, BTreeSet};
use std::time::{SystemTime, UNIX_EPOCH};

use serde_json::{Map, Number, Value, json};

use super::error::{StreamError, StreamErrorCode};
use super::spec::{APIResolverKind, ResponseContext};

mod anthropic;
mod aws_bedrock_converse;
mod core;
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
