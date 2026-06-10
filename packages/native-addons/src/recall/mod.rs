use std::collections::{HashMap, HashSet};

use napi::bindgen_prelude::*;
use napi_derive::napi;
use serde::{Deserialize, Serialize};
use serde_json::Value as JsonValue;

const DEFAULT_LIMIT: usize = 10;
const DEFAULT_RRF_K: f64 = 60.0;
const DEFAULT_RECENCY_HALF_LIFE_DAYS: f64 = 30.0;
const DEFAULT_MMR_LAMBDA: f64 = 0.78;
const DEFAULT_BM25_WEIGHT: f64 = 1.0;
const DEFAULT_VECTOR_WEIGHT: f64 = 1.1;
const MAX_TEXT_CHARS_FOR_SIMILARITY: usize = 1_000;

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct RecallSnapshot {
  #[serde(default = "default_limit")]
  limit: usize,
  #[serde(default)]
  now_ms: Option<f64>,
  #[serde(default)]
  options: RecallOptions,
  candidates: Vec<RecallCandidate>,
}

#[derive(Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
struct RecallOptions {
  #[serde(default)]
  rrf_k: Option<f64>,
  #[serde(default)]
  recency_half_life_days: Option<f64>,
  #[serde(default)]
  mmr_lambda: Option<f64>,
  #[serde(default)]
  route_weights: HashMap<String, f64>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct RecallCandidate {
  id: String,
  #[serde(default)]
  route_ranks: HashMap<String, f64>,
  #[serde(default)]
  sent_at_ms: Option<f64>,
  #[serde(default)]
  text: Option<String>,
  #[serde(default)]
  dedupe_key: Option<String>,
  #[serde(default)]
  window_key: Option<String>,
  #[serde(default)]
  metadata_signals: MetadataSignals,
}

#[derive(Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
struct MetadataSignals {
  #[serde(default)]
  same_current_room: bool,
  #[serde(default)]
  is_dm: bool,
  #[serde(default)]
  addressed_or_mentioned: bool,
  #[serde(default)]
  author_is_requester: bool,
  #[serde(default)]
  author_is_agent: bool,
  #[serde(default)]
  has_link: bool,
  #[serde(default)]
  has_attachment: bool,
  #[serde(default)]
  ambient_observed_only: bool,
}

#[derive(Debug)]
struct PreparedCandidate {
  id: String,
  dedupe_key: Option<String>,
  window_key: Option<String>,
  trigrams: HashSet<String>,
  rrf: f64,
  recency: f64,
  metadata_boost: f64,
  relevance: f64,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct RecallRerankResponse {
  results: Vec<RecallRerankItem>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct RecallRerankItem {
  id: String,
  score: f64,
  score_breakdown: RecallScoreBreakdown,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct RecallScoreBreakdown {
  rrf: f64,
  recency: f64,
  metadata_boost: f64,
  relevance: f64,
  mmr_penalty: f64,
}

/// Reranks chat recall candidates with RRF, recency decay, metadata weighting,
/// and MMR de-duplication. The TypeScript layer supplies all database/provider
/// facts; native remains a deterministic pure function.
#[napi(ts_args_type = "snapshot: any", ts_return_type = "any")]
pub fn recall_rerank(snapshot: JsonValue) -> Result<JsonValue> {
  let snapshot: RecallSnapshot = serde_json::from_value(snapshot).map_err(|reason| {
    Error::new(
      Status::InvalidArg,
      format!("invalid recall snapshot: {reason}"),
    )
  })?;

  if snapshot.limit == 0 {
    return response(Vec::new());
  }

  let prepared = prepare_candidates(&snapshot);
  let ranked = mmr_rank(prepared, snapshot.limit, mmr_lambda(&snapshot.options));
  response(ranked)
}

fn prepare_candidates(snapshot: &RecallSnapshot) -> Vec<PreparedCandidate> {
  let now_ms = snapshot.now_ms.unwrap_or(0.0);
  let rrf_k = snapshot.options.rrf_k.unwrap_or(DEFAULT_RRF_K).max(1.0);
  let half_life_days = snapshot
    .options
    .recency_half_life_days
    .unwrap_or(DEFAULT_RECENCY_HALF_LIFE_DAYS)
    .max(0.001);

  snapshot
    .candidates
    .iter()
    .filter(|candidate| !candidate.id.is_empty())
    .map(|candidate| {
      let rrf = rrf_score(candidate, &snapshot.options.route_weights, rrf_k);
      let recency = recency_score(candidate.sent_at_ms, now_ms, half_life_days);
      let metadata_boost = metadata_boost(&candidate.metadata_signals);
      let relevance = ((0.80 * rrf + 0.20 * recency) * (1.0 + metadata_boost)).clamp(0.0, 1.0);

      PreparedCandidate {
        id: candidate.id.clone(),
        dedupe_key: candidate.dedupe_key.clone(),
        window_key: candidate.window_key.clone(),
        trigrams: trigrams(candidate.text.as_deref().unwrap_or_default()),
        rrf,
        recency,
        metadata_boost,
        relevance,
      }
    })
    .collect()
}

fn rrf_score(candidate: &RecallCandidate, route_weights: &HashMap<String, f64>, rrf_k: f64) -> f64 {
  let mut weighted_score = 0.0;
  let best_possible = rrf_best_possible(route_weights, rrf_k);

  for (route, rank) in &candidate.route_ranks {
    if *rank < 1.0 {
      continue;
    }
    let weight = route_weight(route_weights, route);
    if weight <= 0.0 {
      continue;
    }
    weighted_score += weight * (1.0 / (rrf_k + rank));
  }

  if best_possible == 0.0 {
    0.0
  } else {
    (weighted_score / best_possible).clamp(0.0, 1.0)
  }
}

fn rrf_best_possible(route_weights: &HashMap<String, f64>, rrf_k: f64) -> f64 {
  [
    route_weight(route_weights, "bm25"),
    route_weight(route_weights, "vector"),
  ]
  .into_iter()
  .filter(|weight| *weight > 0.0)
  .map(|weight| weight * (1.0 / (rrf_k + 1.0)))
  .sum()
}

fn route_weight(route_weights: &HashMap<String, f64>, route: &str) -> f64 {
  route_weights
    .get(route)
    .copied()
    .unwrap_or_else(|| match route {
      "bm25" => DEFAULT_BM25_WEIGHT,
      "vector" => DEFAULT_VECTOR_WEIGHT,
      _ => 1.0,
    })
}

fn recency_score(sent_at_ms: Option<f64>, now_ms: f64, half_life_days: f64) -> f64 {
  let Some(sent_at_ms) = sent_at_ms else {
    return 0.25;
  };
  if now_ms <= 0.0 {
    return 0.25;
  }

  let half_life_ms = half_life_days * 86_400_000.0;
  let age_ms = (now_ms - sent_at_ms).max(0.0);
  f64::powf(0.5, age_ms / half_life_ms)
    .max(0.05)
    .clamp(0.0, 1.0)
}

fn metadata_boost(signals: &MetadataSignals) -> f64 {
  let mut boost: f64 = 0.0;
  if signals.same_current_room {
    boost += 0.08;
  }
  if signals.is_dm {
    boost += 0.06;
  }
  if signals.addressed_or_mentioned {
    boost += 0.05;
  }
  if signals.author_is_requester {
    boost += 0.04;
  }
  if signals.author_is_agent {
    boost += 0.03;
  }
  if signals.has_link {
    boost += 0.02;
  }
  if signals.has_attachment {
    boost += 0.02;
  }
  if signals.ambient_observed_only {
    boost -= 0.04;
  }

  boost.clamp(-0.15, 0.25)
}

fn mmr_rank(
  mut remaining: Vec<PreparedCandidate>,
  limit: usize,
  lambda: f64,
) -> Vec<RecallRerankItem> {
  let mut selected: Vec<PreparedCandidate> = Vec::new();
  let mut output = Vec::new();

  while !remaining.is_empty() && output.len() < limit {
    let mut best_index = 0;
    let mut best_score = f64::NEG_INFINITY;
    let mut best_penalty = 0.0;

    for (index, candidate) in remaining.iter().enumerate() {
      let penalty = selected
        .iter()
        .map(|item| similarity(candidate, item))
        .fold(0.0_f64, f64::max);
      let score = lambda * candidate.relevance - (1.0 - lambda) * penalty;
      if score > best_score {
        best_index = index;
        best_score = score;
        best_penalty = penalty;
      }
    }

    let item = remaining.swap_remove(best_index);
    output.push(RecallRerankItem {
      id: item.id.clone(),
      score: best_score.max(0.0),
      score_breakdown: RecallScoreBreakdown {
        rrf: item.rrf,
        recency: item.recency,
        metadata_boost: item.metadata_boost,
        relevance: item.relevance,
        mmr_penalty: best_penalty,
      },
    });
    selected.push(item);
  }

  output
}

fn similarity(a: &PreparedCandidate, b: &PreparedCandidate) -> f64 {
  if same_non_empty(a.dedupe_key.as_deref(), b.dedupe_key.as_deref()) {
    return 1.0;
  }

  let mut score: f64 = 0.0;
  if same_non_empty(a.window_key.as_deref(), b.window_key.as_deref()) {
    score = score.max(0.35);
  }
  score.max(jaccard(&a.trigrams, &b.trigrams))
}

fn same_non_empty(a: Option<&str>, b: Option<&str>) -> bool {
  matches!((a, b), (Some(a), Some(b)) if !a.is_empty() && a == b)
}

fn jaccard(a: &HashSet<String>, b: &HashSet<String>) -> f64 {
  if a.is_empty() || b.is_empty() {
    return 0.0;
  }

  let intersection = a.intersection(b).count() as f64;
  let union = a.union(b).count() as f64;
  if union == 0.0 {
    0.0
  } else {
    intersection / union
  }
}

fn trigrams(input: &str) -> HashSet<String> {
  let chars: Vec<char> = input.chars().take(MAX_TEXT_CHARS_FOR_SIMILARITY).collect();
  if chars.is_empty() {
    return HashSet::new();
  }
  if chars.len() < 3 {
    return HashSet::from([chars.iter().collect()]);
  }

  chars
    .windows(3)
    .map(|window| window.iter().collect::<String>())
    .collect()
}

fn mmr_lambda(options: &RecallOptions) -> f64 {
  options
    .mmr_lambda
    .unwrap_or(DEFAULT_MMR_LAMBDA)
    .clamp(0.0, 1.0)
}

fn default_limit() -> usize {
  DEFAULT_LIMIT
}

fn response(results: Vec<RecallRerankItem>) -> Result<JsonValue> {
  serde_json::to_value(RecallRerankResponse { results }).map_err(|reason| {
    Error::new(
      Status::GenericFailure,
      format!("failed to encode recall rerank response: {reason}"),
    )
  })
}
