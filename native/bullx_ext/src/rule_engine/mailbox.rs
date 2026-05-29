//! MailBox delivery-rule CEL evaluation. Rules have a condition over a routing
//! context and a priority for deterministic evaluation order. MailBox fan-out is
//! owned by Elixir, which can call this matcher for one or more candidate rules.

use ::cel::Context;
use rustler::{Encoder, Env, NifResult, Term};
use serde_json::Value as JsonValue;

use crate::encoding::error;
use crate::rule_engine::cel::{
  self, BoolEvalError, require_field, require_map, require_string_field, term_to_json,
};

mod atoms {
  rustler::atoms! {
    matched,
    no_match,
    error,
    condition_compile,
    condition_execution,
    condition_result_type,
  }
}

/// Match `routing_context` against priority-sorted candidate `rules`, returning
/// `{:matched, rule_id, diagnostics}` on the first satisfied candidate or
/// `{:no_match, diagnostics}` if none match. Per-rule compile or execution
/// failures accumulate as diagnostics without halting evaluation.
#[rustler::nif(schedule = "DirtyCpu")]
pub fn mailbox_match_delivery_rule<'a>(
  env: Env<'a>,
  rules: Term<'a>,
  routing_context: Term<'a>,
) -> NifResult<Term<'a>> {
  let rules = decode_rules(rules)?;
  let routing_context = term_to_json(routing_context)?;
  let context = build_mailbox_context(&routing_context)?;
  let mut diagnostics = Vec::new();

  for rule in rules {
    let program = match cel::compile_condition(&rule.match_expr) {
      Ok(program) => program,
      Err(reason) => {
        diagnostics.push(encode_diagnostic(
          &rule.id,
          atoms::condition_compile(),
          reason,
        ));
        continue;
      }
    };

    match cel::execute_bool(&program, &context) {
      Ok(true) => return Ok((atoms::matched(), rule.id, diagnostics).encode(env)),
      Ok(false) => {}
      Err(BoolEvalError::Execution(reason)) => {
        diagnostics.push(encode_diagnostic(
          &rule.id,
          atoms::condition_execution(),
          reason,
        ));
      }
      Err(BoolEvalError::ResultType(reason)) => {
        diagnostics.push(encode_diagnostic(
          &rule.id,
          atoms::condition_result_type(),
          reason,
        ));
      }
    }
  }

  Ok((atoms::no_match(), diagnostics).encode(env))
}

struct MailboxDeliveryRule {
  id: String,
  priority: i64,
  match_expr: String,
}

fn decode_rules(term: Term<'_>) -> NifResult<Vec<MailboxDeliveryRule>> {
  let iter: rustler::types::list::ListIterator =
    term.decode().map_err(|_| error("rules must be a list"))?;

  let mut rules = Vec::new();

  for rule_term in iter {
    let map = require_map(rule_term, "route rule")?;

    rules.push(MailboxDeliveryRule {
      id: require_string_field(&map, "id")?,
      priority: require_field(&map, "priority")?
        .decode()
        .map_err(|_| error("route rule priority must be an integer"))?,
      match_expr: require_string_field(&map, "match_expr")?,
    });
  }

  sort_rules_by_priority(&mut rules);
  Ok(rules)
}

fn sort_rules_by_priority(rules: &mut [MailboxDeliveryRule]) {
  rules.sort_by_key(|rule| (rule.priority, rule.id.clone()));
}

fn build_mailbox_context(routing_context: &JsonValue) -> NifResult<Context<'static>> {
  let object = routing_context
    .as_object()
    .ok_or_else(|| error("routing_context must be a map"))?;

  let variables = object
    .iter()
    .map(|(key, value)| (key.as_str(), value.clone()))
    .collect();

  cel::build_context(variables)
}

fn encode_diagnostic(
  rule_id: &str,
  kind: rustler::Atom,
  reason: String,
) -> (String, rustler::Atom, String) {
  (rule_id.to_owned(), kind, reason)
}

#[cfg(test)]
mod tests {
  use super::*;

  #[test]
  fn decode_rules_sorts_by_priority() {
    let mut rules = vec![
      MailboxDeliveryRule {
        id: "b".to_owned(),
        priority: 2,
        match_expr: "true".to_owned(),
      },
      MailboxDeliveryRule {
        id: "a".to_owned(),
        priority: 1,
        match_expr: "true".to_owned(),
      },
    ];

    sort_rules_by_priority(&mut rules);

    assert_eq!(rules[0].id, "a");
  }

  #[test]
  fn duplicate_priorities_are_sorted_by_rule_id() {
    let rules = vec![
      MailboxDeliveryRule {
        id: "a".to_owned(),
        priority: 1,
        match_expr: "true".to_owned(),
      },
      MailboxDeliveryRule {
        id: "b".to_owned(),
        priority: 1,
        match_expr: "true".to_owned(),
      },
    ];

    let mut rules = rules;
    sort_rules_by_priority(&mut rules);

    assert_eq!(rules[0].id, "a");
    assert_eq!(rules[1].id, "b");
  }
}
