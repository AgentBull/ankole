use std::collections::{BTreeMap, BTreeSet};
use std::time::{SystemTime, UNIX_EPOCH};

use serde_json::{Map, Number, Value, json};
use uuid::Uuid;

use super::error::{StreamError, StreamErrorCode};
use super::spec::{ApiResolverKind, ResponseContext};

mod anthropic;
mod aws_bedrock_converse;
mod core;
mod embeddings;
mod google_embeddings;
mod google_gemini;
mod openai_chat;
mod openai_responses;
mod rerank;
mod standard;
#[cfg(test)]
mod tests;
mod web;

use self::anthropic::*;
use self::aws_bedrock_converse::*;
use self::core::ApiProtocol;
pub use self::core::ApiResolver;
use self::embeddings::*;
use self::google_embeddings::*;
use self::google_gemini::*;
use self::openai_chat::*;
use self::openai_responses::*;
use self::rerank::*;
use self::standard::*;
use self::web::*;
