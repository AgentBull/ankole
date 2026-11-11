use std::collections::{BTreeMap, BTreeSet};
use std::time::{SystemTime, UNIX_EPOCH};

use serde_json::{Map, Number, Value, json};

use super::error::{StreamError, StreamErrorCode};
use super::spec::{APIResolverKind, ConversionPolicy, ResponseContext};

mod amazon;
mod anthropic;
pub(crate) mod anthropic_v2026;
mod audio;
mod aws_bedrock_converse;
mod cloudflare_images;
pub(crate) mod cohere_rerank;
pub mod core;
mod custom_tool_emulation;
mod decision;
pub(crate) mod embeddings;
pub(crate) mod google_embeddings;
pub(crate) mod google_images;
mod ocr;
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
mod usage;
mod web;

use self::amazon::*;
use self::anthropic::*;
use self::anthropic_v2026::*;
use self::audio::*;
use self::aws_bedrock_converse::*;
pub(crate) use self::cloudflare_images::image_mime;
use self::cloudflare_images::*;
use self::cohere_rerank::CohereRerank;
pub use self::core::{APIProtocol, APIResolver};
use self::custom_tool_emulation::*;
use self::decision::*;
use self::embeddings::*;
use self::google_embeddings::GoogleEmbeddings;
use self::google_images::GoogleImages;
use self::ocr::*;
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
pub(crate) use self::usage::*;
use self::web::*;
