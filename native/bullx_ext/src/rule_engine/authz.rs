//! CEL-driven authorization:
//!
//! - **Computed groups**: each group carries a CEL condition over the
//!   principal; matching group IDs are returned (evaluation is exhaustive).
//! - **Grants**: each grant carries a resource glob plus a CEL condition;
//!   the first grant matching both wins as `Allow`, otherwise `Deny`.
//!
//! Per-rule failures (compile errors, runtime errors, non-bool results)
//! surface as diagnostics instead of halting the whole evaluation.

use globset::{GlobBuilder, GlobMatcher};
use rustler::{Encoder, Env, NifResult, Term};
use serde_json::Value as JsonValue;
use std::collections::HashMap;
use std::sync::{Arc, Mutex, OnceLock};

use crate::encoding::error;
use crate::rule_engine::cel::{
  self, BoolEvalError, require_field, require_json_string_field, require_map, require_object,
  require_string_field, term_to_json,
};

mod atoms {
  rustler::atoms! {
    ok,
    allow,
    deny,
    resource_pattern,
    condition_compile,
    condition_execution,
    condition_result_type,
  }
}

#[rustler::nif(schedule = "DirtyCpu")]
pub fn authz_resource_pattern_validate(pattern: Term<'_>) -> NifResult<bool> {
  let pattern: String = pattern
    .decode()
    .map_err(|_| error("resource_pattern must be a string"))?;

  resource_pattern_matcher(&pattern).map_err(error)?;
  Ok(true)
}

#[rustler::nif(schedule = "DirtyCpu")]
pub fn authz_cel_eval_computed_groups<'a>(
  env: Env<'a>,
  principal_env: Term<'a>,
  loaded_groups: Term<'a>,
) -> NifResult<Term<'a>> {
  let principal_env = decode_principal_env(principal_env)?;
  let loaded_groups = decode_loaded_computed_groups(loaded_groups)?;
  let decision = eval_computed_groups(&principal_env, &loaded_groups)?;

  Ok(
    (
      atoms::ok(),
      decision.matching_group_ids,
      encode_invalid_computed_groups(decision.invalid_groups),
    )
      .encode(env),
  )
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

struct PrincipalEnv {
  principal: JsonValue,
}

struct LoadedComputedGroup {
  id: String,
  condition: String,
}

struct LoadedGrant {
  id: String,
  resource_pattern: String,
  condition: String,
}

struct CachedCondition {
  condition: String,
  program: Arc<::cel::Program>,
}

struct CachedResourcePattern {
  pattern: String,
  matcher: Arc<GlobMatcher>,
}

static CONDITION_CACHE: OnceLock<Mutex<HashMap<String, CachedCondition>>> = OnceLock::new();
static RESOURCE_PATTERN_CACHE: OnceLock<Mutex<HashMap<String, CachedResourcePattern>>> =
  OnceLock::new();

#[derive(Debug, Eq, PartialEq)]
enum InvalidGrantKind {
  ResourcePattern,
  ConditionCompile,
  ConditionExecution,
  ConditionResultType,
}

struct InvalidComputedGroup {
  id: String,
  kind: InvalidGrantKind,
  reason: String,
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

struct ComputedGroupDecision {
  matching_group_ids: Vec<String>,
  invalid_groups: Vec<InvalidComputedGroup>,
}

/// Evaluate every group's CEL condition against `principal_env` and collect
/// the IDs whose condition returned `true`. Exhaustive — every group is
/// checked, no short-circuit.
fn eval_computed_groups(
  principal_env: &PrincipalEnv,
  loaded_groups: &[LoadedComputedGroup],
) -> NifResult<ComputedGroupDecision> {
  let context = cel::build_context(vec![("principal", principal_env.principal.clone())])?;
  let mut matching_group_ids = Vec::new();
  let mut invalid_groups = Vec::new();

  for group in loaded_groups {
    let program =
      match cached_condition_program(computed_group_condition_key(group), &group.condition) {
        Ok(program) => program,
        Err(reason) => {
          invalid_groups.push(invalid_computed_group(
            group,
            InvalidGrantKind::ConditionCompile,
            reason,
          ));
          continue;
        }
      };

    match cel::execute_bool(&program, &context) {
      Ok(true) => matching_group_ids.push(group.id.clone()),
      Ok(false) => {}
      Err(BoolEvalError::Execution(reason)) => {
        invalid_groups.push(invalid_computed_group(
          group,
          InvalidGrantKind::ConditionExecution,
          reason,
        ));
      }
      Err(BoolEvalError::ResultType(reason)) => {
        invalid_groups.push(invalid_computed_group(
          group,
          InvalidGrantKind::ConditionResultType,
          reason,
        ));
      }
    }
  }

  Ok(ComputedGroupDecision {
    matching_group_ids,
    invalid_groups,
  })
}

/// Default-deny. First grant whose pattern matches AND condition evaluates
/// to `true` returns `Allow` (short-circuit); otherwise `Deny`. Per-grant
/// failures surface in `invalid_grants` regardless of outcome.
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
    match cached_grant_resource_pattern_matches(grant, &authz_env.resource) {
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

    let program = match cached_condition_program(grant_condition_key(grant), &grant.condition) {
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

fn invalid_computed_group(
  group: &LoadedComputedGroup,
  kind: InvalidGrantKind,
  reason: String,
) -> InvalidComputedGroup {
  InvalidComputedGroup {
    id: group.id.clone(),
    kind,
    reason,
  }
}

fn invalid_grant(grant: &LoadedGrant, kind: InvalidGrantKind, reason: String) -> InvalidGrant {
  InvalidGrant {
    id: grant.id.clone(),
    kind,
    resource_pattern: grant.resource_pattern.clone(),
    reason,
  }
}

fn encode_invalid_computed_groups(
  invalid_groups: Vec<InvalidComputedGroup>,
) -> Vec<(String, rustler::Atom, String)> {
  invalid_groups
    .into_iter()
    .map(|invalid_group| {
      (
        invalid_group.id,
        encode_invalid_kind(invalid_group.kind),
        invalid_group.reason,
      )
    })
    .collect()
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

fn computed_group_condition_key(group: &LoadedComputedGroup) -> String {
  format!("computed_group:{}", group.id)
}

fn grant_condition_key(grant: &LoadedGrant) -> String {
  format!("grant:{}", grant.id)
}

fn grant_resource_pattern_key(grant: &LoadedGrant) -> String {
  format!("grant:{}", grant.id)
}

fn cached_condition_program(
  cache_key: String,
  condition: &str,
) -> Result<Arc<::cel::Program>, String> {
  if let Some(program) = lookup_cached_condition_program(&cache_key, condition) {
    return Ok(program);
  }

  let program = Arc::new(cel::compile_condition(condition)?);
  store_cached_condition_program(cache_key, condition, &program);
  Ok(program)
}

fn lookup_cached_condition_program(
  cache_key: &str,
  condition: &str,
) -> Option<Arc<::cel::Program>> {
  let cache = CONDITION_CACHE.get_or_init(|| Mutex::new(HashMap::new()));
  let guard = cache.try_lock().ok()?;
  let cached = guard.get(cache_key)?;

  match cached.condition == condition {
    true => Some(Arc::clone(&cached.program)),
    false => None,
  }
}

fn store_cached_condition_program(
  cache_key: String,
  condition: &str,
  program: &Arc<::cel::Program>,
) {
  let cache = CONDITION_CACHE.get_or_init(|| Mutex::new(HashMap::new()));

  if let Ok(mut guard) = cache.try_lock() {
    guard.insert(
      cache_key,
      CachedCondition {
        condition: condition.to_owned(),
        program: Arc::clone(program),
      },
    );
  }
}

fn cached_grant_resource_pattern_matches(
  grant: &LoadedGrant,
  resource: &str,
) -> Result<bool, String> {
  let matcher = cached_grant_resource_pattern_matcher(grant)?;
  Ok(matcher.is_match(normalize_resource_for_glob(resource)))
}

fn cached_grant_resource_pattern_matcher(grant: &LoadedGrant) -> Result<Arc<GlobMatcher>, String> {
  let cache_key = grant_resource_pattern_key(grant);

  if let Some(matcher) = lookup_cached_resource_pattern_matcher(&cache_key, &grant.resource_pattern)
  {
    return Ok(matcher);
  }

  let matcher = Arc::new(resource_pattern_matcher(&grant.resource_pattern)?);
  store_cached_resource_pattern_matcher(cache_key, &grant.resource_pattern, &matcher);
  Ok(matcher)
}

fn lookup_cached_resource_pattern_matcher(
  cache_key: &str,
  pattern: &str,
) -> Option<Arc<GlobMatcher>> {
  let cache = RESOURCE_PATTERN_CACHE.get_or_init(|| Mutex::new(HashMap::new()));
  let guard = cache.try_lock().ok()?;
  let cached = guard.get(cache_key)?;

  match cached.pattern == pattern {
    true => Some(Arc::clone(&cached.matcher)),
    false => None,
  }
}

fn store_cached_resource_pattern_matcher(
  cache_key: String,
  pattern: &str,
  matcher: &Arc<GlobMatcher>,
) {
  let cache = RESOURCE_PATTERN_CACHE.get_or_init(|| Mutex::new(HashMap::new()));

  if let Ok(mut guard) = cache.try_lock() {
    guard.insert(
      cache_key,
      CachedResourcePattern {
        pattern: pattern.to_owned(),
        matcher: Arc::clone(matcher),
      },
    );
  }
}

#[cfg(test)]
fn resource_pattern_matches(pattern: &str, resource: &str) -> Result<bool, String> {
  let matcher = resource_pattern_matcher(pattern)?;
  Ok(matcher.is_match(normalize_resource_for_glob(resource)))
}

fn resource_pattern_matcher(pattern: &str) -> Result<GlobMatcher, String> {
  if pattern.is_empty() {
    return Err("must not be empty".to_owned());
  }

  let normalized = normalize_resource_for_glob(pattern);

  GlobBuilder::new(&normalized)
    .literal_separator(true)
    .build()
    .map_err(|reason| format!("invalid resource glob: {reason}"))
    .map(|glob| glob.compile_matcher())
}

/// Map `:` (the project's segment separator, e.g. `workspace:a:b`) to `/`
/// so globset's path-aware matching applies — `*` won't span segments and
/// `**` can be used to span them explicitly.
fn normalize_resource_for_glob(value: &str) -> String {
  value.replace(':', "/")
}

fn decode_authz_env(term: Term<'_>) -> NifResult<AuthzEnv> {
  let map = require_map(term, "env")?;

  let principal = term_to_json(require_field(&map, "principal")?)?;
  require_object(&principal, "principal")?;
  require_json_string_field(&principal, "uid", "principal")?;
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

fn decode_principal_env(term: Term<'_>) -> NifResult<PrincipalEnv> {
  let map = require_map(term, "principal env")?;

  let principal = term_to_json(require_field(&map, "principal")?)?;
  require_object(&principal, "principal")?;
  require_json_string_field(&principal, "uid", "principal")?;
  require_json_string_field(&principal, "type", "principal")?;
  require_json_string_field(&principal, "status", "principal")?;

  Ok(PrincipalEnv { principal })
}

fn decode_loaded_computed_groups(term: Term<'_>) -> NifResult<Vec<LoadedComputedGroup>> {
  let iter: rustler::types::list::ListIterator = term
    .decode()
    .map_err(|_| crate::encoding::error("loaded_groups must be a list"))?;

  let mut groups = Vec::new();

  for group in iter {
    let map = require_map(group, "loaded computed group")?;

    groups.push(LoadedComputedGroup {
      id: require_string_field(&map, "id")?,
      condition: require_string_field(&map, "condition")?,
    });
  }

  Ok(groups)
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
  fn eval_computed_groups_returns_matching_ids_and_invalids() {
    let principal_env = PrincipalEnv {
      principal: json!({
        "uid": "authz-test-principal",
        "type": "human",
        "status": "active"
      }),
    };

    let groups = vec![
      LoadedComputedGroup {
        id: "human".to_owned(),
        condition: r#"principal.type == "human""#.to_owned(),
      },
      LoadedComputedGroup {
        id: "agent".to_owned(),
        condition: r#"principal.type == "agent""#.to_owned(),
      },
      LoadedComputedGroup {
        id: "invalid".to_owned(),
        condition: "principal.uid".to_owned(),
      },
    ];

    let decision =
      eval_computed_groups(&principal_env, &groups).expect("computed groups should evaluate");

    assert_eq!(decision.matching_group_ids, vec!["human".to_owned()]);
    assert_eq!(decision.invalid_groups.len(), 1);
    assert_eq!(
      decision.invalid_groups[0].kind,
      InvalidGrantKind::ConditionResultType
    );
  }

  #[test]
  fn resource_pattern_matches_globs() {
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
    assert!(resource_pattern_matches("workspace:*", "workspace:a").unwrap());
    assert!(!resource_pattern_matches("workspace:*", "workspace:a:b").unwrap());
    assert!(resource_pattern_matches("workspace:*", "workspace:").unwrap());
    assert!(resource_pattern_matches("workspace:**", "workspace:a:b").unwrap());
    assert!(resource_pattern_matches("workspace:**:member", "workspace:a:b:member").unwrap());
    assert!(!resource_pattern_matches("workspace:**:member", "workspace:a:b:viewer").unwrap());
    assert!(resource_pattern_matches("", "web_console").is_err());
    assert!(resource_pattern_matches("[", "web_console").is_err());
  }

  #[test]
  fn cached_condition_program_reuses_until_condition_changes() {
    let (first, second) = eventually_reused_condition_program("test:condition-cache", "true");
    let changed = cached_condition_program("test:condition-cache".to_owned(), "false").unwrap();

    assert!(Arc::ptr_eq(&first, &second));
    assert!(!Arc::ptr_eq(&first, &changed));
  }

  #[test]
  fn cached_resource_pattern_matcher_reuses_until_pattern_changes() {
    let grant = LoadedGrant {
      id: "resource-pattern-cache".to_owned(),
      resource_pattern: "workspace:*".to_owned(),
      condition: "true".to_owned(),
    };

    let (first, second) = eventually_reused_resource_pattern_matcher(&grant);

    let changed = LoadedGrant {
      resource_pattern: "workspace:**".to_owned(),
      ..grant
    };

    let changed_matcher = cached_grant_resource_pattern_matcher(&changed).unwrap();

    assert!(Arc::ptr_eq(&first, &second));
    assert!(!Arc::ptr_eq(&first, &changed_matcher));
  }

  fn eventually_reused_condition_program(
    cache_key: &str,
    condition: &str,
  ) -> (Arc<::cel::Program>, Arc<::cel::Program>) {
    for _attempt in 0..100 {
      let first = cached_condition_program(cache_key.to_owned(), condition).unwrap();
      let second = cached_condition_program(cache_key.to_owned(), condition).unwrap();

      if Arc::ptr_eq(&first, &second) {
        return (first, second);
      }
    }

    panic!("condition program cache did not reuse after repeated attempts");
  }

  fn eventually_reused_resource_pattern_matcher(
    grant: &LoadedGrant,
  ) -> (Arc<GlobMatcher>, Arc<GlobMatcher>) {
    for _attempt in 0..100 {
      let first = cached_grant_resource_pattern_matcher(grant).unwrap();
      let second = cached_grant_resource_pattern_matcher(grant).unwrap();

      if Arc::ptr_eq(&first, &second) {
        return (first, second);
      }
    }

    panic!("resource pattern cache did not reuse after repeated attempts");
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
        condition: "principal.uid".to_owned(),
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
        "uid": "authz-test-principal",
        "type": "human",
        "status": "active"
      }),
      action: "read".to_owned(),
      resource: "web_console".to_owned(),
      context,
    }
  }
}
