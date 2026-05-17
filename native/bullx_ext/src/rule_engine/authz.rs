use rustler::{Encoder, Env, NifResult, Term};
use serde_json::Value as JsonValue;

use crate::rule_engine::cel::{
  self, BoolEvalError, require_field, require_json_string_field, require_map, require_object,
  require_string_field, term_to_json,
};

mod atoms {
  rustler::atoms! {
    allow,
    deny,
    resource_pattern,
    condition_compile,
    condition_execution,
    condition_result_type,
  }
}

#[rustler::nif(schedule = "DirtyCpu")]
pub fn authz_cel_eval_loaded_grants<'a>(
  env: Env<'a>,
  authz_env: Term<'a>,
  loaded_grants: Term<'a>,
) -> NifResult<Term<'a>> {
  let authz_env = decode_authz_env(authz_env)?;
  let loaded_grants = decode_loaded_grants(loaded_grants)?;
  let decision = eval_loaded_grants(&authz_env, &loaded_grants)?;

  let result = match decision {
    LoadedGrantDecision::Allow(invalid_grants) => {
      (atoms::allow(), encode_invalid_grants(invalid_grants))
    }
    LoadedGrantDecision::Deny(invalid_grants) => {
      (atoms::deny(), encode_invalid_grants(invalid_grants))
    }
  };

  Ok(result.encode(env))
}

struct AuthzEnv {
  principal: JsonValue,
  action: String,
  resource: String,
  context: JsonValue,
}

struct LoadedGrant {
  id: String,
  resource_pattern: String,
  condition: String,
}

#[derive(Debug, Eq, PartialEq)]
enum InvalidGrantKind {
  ResourcePattern,
  ConditionCompile,
  ConditionExecution,
  ConditionResultType,
}

struct InvalidGrant {
  id: String,
  kind: InvalidGrantKind,
  resource_pattern: String,
  reason: String,
}

enum LoadedGrantDecision {
  Allow(Vec<InvalidGrant>),
  Deny(Vec<InvalidGrant>),
}

fn eval_loaded_grants(
  authz_env: &AuthzEnv,
  loaded_grants: &[LoadedGrant],
) -> NifResult<LoadedGrantDecision> {
  let context = cel::build_context(vec![
    ("principal", authz_env.principal.clone()),
    ("action", JsonValue::String(authz_env.action.clone())),
    ("resource", JsonValue::String(authz_env.resource.clone())),
    ("context", authz_env.context.clone()),
  ])?;

  let mut invalid_grants = Vec::new();

  for grant in loaded_grants {
    match resource_pattern_matches(&grant.resource_pattern, &authz_env.resource) {
      Ok(false) => continue,
      Err(reason) => {
        invalid_grants.push(invalid_grant(
          grant,
          InvalidGrantKind::ResourcePattern,
          reason,
        ));
        continue;
      }
      Ok(true) => {}
    }

    let program = match cel::compile_condition(&grant.condition) {
      Ok(program) => program,
      Err(reason) => {
        invalid_grants.push(invalid_grant(
          grant,
          InvalidGrantKind::ConditionCompile,
          reason,
        ));
        continue;
      }
    };

    match cel::execute_bool(&program, &context) {
      Ok(true) => return Ok(LoadedGrantDecision::Allow(invalid_grants)),
      Ok(false) => {}
      Err(BoolEvalError::Execution(reason)) => {
        invalid_grants.push(invalid_grant(
          grant,
          InvalidGrantKind::ConditionExecution,
          reason,
        ));
      }
      Err(BoolEvalError::ResultType(reason)) => {
        invalid_grants.push(invalid_grant(
          grant,
          InvalidGrantKind::ConditionResultType,
          reason,
        ));
      }
    }
  }

  Ok(LoadedGrantDecision::Deny(invalid_grants))
}

fn invalid_grant(grant: &LoadedGrant, kind: InvalidGrantKind, reason: String) -> InvalidGrant {
  InvalidGrant {
    id: grant.id.clone(),
    kind,
    resource_pattern: grant.resource_pattern.clone(),
    reason,
  }
}

fn encode_invalid_grants(
  invalid_grants: Vec<InvalidGrant>,
) -> Vec<(String, rustler::Atom, String, String)> {
  invalid_grants
    .into_iter()
    .map(|invalid_grant| {
      (
        invalid_grant.id,
        encode_invalid_kind(invalid_grant.kind),
        invalid_grant.resource_pattern,
        invalid_grant.reason,
      )
    })
    .collect()
}

fn encode_invalid_kind(kind: InvalidGrantKind) -> rustler::Atom {
  match kind {
    InvalidGrantKind::ResourcePattern => atoms::resource_pattern(),
    InvalidGrantKind::ConditionCompile => atoms::condition_compile(),
    InvalidGrantKind::ConditionExecution => atoms::condition_execution(),
    InvalidGrantKind::ConditionResultType => atoms::condition_result_type(),
  }
}

fn resource_pattern_matches(pattern: &str, resource: &str) -> Result<bool, String> {
  validate_resource_pattern(pattern)?;

  let mut wildcard_matches = pattern.match_indices('*');

  match (wildcard_matches.next(), wildcard_matches.next()) {
    (None, _) => Ok(pattern == resource),
    (Some((wildcard_index, _)), None) => {
      let prefix = &pattern[..wildcard_index];
      let suffix = &pattern[wildcard_index + 1..];

      Ok(
        resource.len() >= prefix.len() + suffix.len()
          && resource.starts_with(prefix)
          && resource.ends_with(suffix),
      )
    }
    (Some(_), Some(_)) => Err("must contain at most one '*'".to_owned()),
  }
}

fn validate_resource_pattern(pattern: &str) -> Result<(), String> {
  if pattern.is_empty() {
    return Err("must not be empty".to_owned());
  }

  if pattern.matches('*').count() > 1 {
    return Err("must contain at most one '*'".to_owned());
  }

  Ok(())
}

fn decode_authz_env(term: Term<'_>) -> NifResult<AuthzEnv> {
  let map = require_map(term, "env")?;

  let principal = term_to_json(require_field(&map, "principal")?)?;
  require_object(&principal, "principal")?;
  require_json_string_field(&principal, "id", "principal")?;
  require_json_string_field(&principal, "type", "principal")?;
  require_json_string_field(&principal, "status", "principal")?;

  let action = require_string_field(&map, "action")?;
  let resource = require_string_field(&map, "resource")?;
  let context = term_to_json(require_field(&map, "context")?)?;
  require_object(&context, "context")?;

  Ok(AuthzEnv {
    principal,
    action,
    resource,
    context,
  })
}

fn decode_loaded_grants(term: Term<'_>) -> NifResult<Vec<LoadedGrant>> {
  let iter: rustler::types::list::ListIterator = term
    .decode()
    .map_err(|_| crate::encoding::error("loaded_grants must be a list"))?;

  let mut grants = Vec::new();

  for grant in iter {
    let map = require_map(grant, "loaded grant")?;

    grants.push(LoadedGrant {
      id: require_string_field(&map, "id")?,
      resource_pattern: require_string_field(&map, "resource_pattern")?,
      condition: require_string_field(&map, "condition")?,
    });
  }

  Ok(grants)
}

#[cfg(test)]
mod tests {
  use super::*;
  use serde_json::json;

  #[test]
  fn resource_pattern_matches_exact_and_single_wildcard_edges() {
    assert!(resource_pattern_matches("web_console", "web_console").unwrap());
    assert!(!resource_pattern_matches("web_console", "other").unwrap());
    assert!(resource_pattern_matches("*", "").unwrap());
    assert!(resource_pattern_matches("*", "anything").unwrap());
    assert!(resource_pattern_matches("a*", "a").unwrap());
    assert!(resource_pattern_matches("*a", "a").unwrap());
    assert!(resource_pattern_matches("a*a", "aa").unwrap());
    assert!(!resource_pattern_matches("a*a", "a").unwrap());
    assert!(!resource_pattern_matches("ab*bc", "abc").unwrap());
    assert!(resource_pattern_matches("ab*bc", "abbc").unwrap());
    assert!(resource_pattern_matches("workspace:*", "workspace:a:b").unwrap());
    assert!(resource_pattern_matches("workspace:*", "workspace:").unwrap());
    assert!(resource_pattern_matches("", "web_console").is_err());
    assert!(resource_pattern_matches("web**", "web_console").is_err());
  }

  #[test]
  fn eval_loaded_grants_skips_mismatches_records_invalids_and_short_circuits() {
    let authz_env = authz_env(json!({
      "request": {
        "business_hours": true
      }
    }));

    let grants = vec![
      LoadedGrant {
        id: "mismatch".to_owned(),
        resource_pattern: "other".to_owned(),
        condition: "not valid cel".to_owned(),
      },
      LoadedGrant {
        id: "invalid".to_owned(),
        resource_pattern: "web_*".to_owned(),
        condition: "not valid cel".to_owned(),
      },
      LoadedGrant {
        id: "allow".to_owned(),
        resource_pattern: "web_*".to_owned(),
        condition: "context.request.business_hours".to_owned(),
      },
      LoadedGrant {
        id: "after_allow".to_owned(),
        resource_pattern: "web_*".to_owned(),
        condition: "not valid cel".to_owned(),
      },
    ];

    let decision = eval_loaded_grants(&authz_env, &grants).expect("loaded grants should evaluate");

    match decision {
      LoadedGrantDecision::Allow(invalid_grants) => {
        assert_eq!(invalid_grants.len(), 1);
        assert_eq!(invalid_grants[0].id, "invalid");
        assert_eq!(invalid_grants[0].kind, InvalidGrantKind::ConditionCompile);
      }
      LoadedGrantDecision::Deny(_) => panic!("expected allow decision"),
    }
  }

  #[test]
  fn eval_loaded_grants_reports_non_boolean_and_execution_errors() {
    let authz_env = authz_env(json!({"request": {}}));

    let grants = vec![
      LoadedGrant {
        id: "non_bool".to_owned(),
        resource_pattern: "web_*".to_owned(),
        condition: "principal.id".to_owned(),
      },
      LoadedGrant {
        id: "missing".to_owned(),
        resource_pattern: "web_*".to_owned(),
        condition: "context.request.business_hours".to_owned(),
      },
    ];

    let decision = eval_loaded_grants(&authz_env, &grants).expect("loaded grants should evaluate");

    match decision {
      LoadedGrantDecision::Deny(invalid_grants) => {
        assert_eq!(invalid_grants.len(), 2);
        assert_eq!(
          invalid_grants[0].kind,
          InvalidGrantKind::ConditionResultType
        );
        assert_eq!(invalid_grants[1].kind, InvalidGrantKind::ConditionExecution);
      }
      LoadedGrantDecision::Allow(_) => panic!("expected deny decision"),
    }
  }

  fn authz_env(context: JsonValue) -> AuthzEnv {
    AuthzEnv {
      principal: json!({
        "id": "019dc9bc-0000-7000-8000-000000000001",
        "type": "human",
        "status": "active"
      }),
      action: "read".to_owned(),
      resource: "web_console".to_owned(),
      context,
    }
  }
}
