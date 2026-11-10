use std::collections::{BTreeMap, BTreeSet};
use std::time::{SystemTime, UNIX_EPOCH};

use serde_json::{Map, Number, Value, json};

use super::error::{StreamError, StreamErrorCode};
use super::spec::{APIResolverKind, ConversionPolicy, ResponseContext};

mod anthropic;
pub(crate) mod anthropic_v2026;
mod aws_bedrock_converse;
pub(crate) mod cohere_rerank;
pub mod core;
mod custom_tool_emulation;
pub(crate) mod embeddings;
pub(crate) mod google_embeddings;
pub(crate) mod google_images;
mod opaque_tool_fields;
mod openai_chat;
pub(crate) mod openai_embeddings;
pub(crate) mod openai_images;
mod openai_responses;
pub(crate) mod openrouter_images;
mod reasoning_envelope;
pub(crate) mod rerank;
mod standard;
#[cfg(test)]
mod tests;
mod tool_identity;
mod web;

use self::anthropic::*;
use self::anthropic_v2026::*;
use self::aws_bedrock_converse::*;
use self::cohere_rerank::CohereRerank;
pub use self::core::{APIProtocol, APIResolver};
use self::custom_tool_emulation::*;
use self::embeddings::*;
use self::google_embeddings::GoogleEmbeddings;
use self::google_images::GoogleImages;
use self::opaque_tool_fields::*;
use self::openai_chat::*;
use self::openai_embeddings::OpenAIEmbeddings;
use self::openai_images::{
    OpenAIImages, resolve_normalized_image_mask, resolve_normalized_image_references,
};
use self::openai_responses::*;
use self::openrouter_images::*;
use self::rerank::*;
pub(crate) use self::standard::*;
use self::tool_identity::*;
use self::web::*;
