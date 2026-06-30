use std::collections::{HashMap, HashSet};
use std::sync::{Arc, Mutex, OnceLock};

use globset::GlobMatcher;
use serde::{Deserialize, Serialize};
use serde_json::Value as JsonValue;

use crate::authz::cel::{self, BoolEvalError};
use crate::authz::resource_pattern::{normalize_resource_for_glob, resource_pattern_matcher};
use crate::common::{KernelError, KernelResult};

/// Single-action authorization snapshot supplied by the host runtime.
///
/// The snapshot must already contain all DB state needed for the decision. This
/// module intentionally has no PostgreSQL, Redis, or external-service access.
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AuthzSnapshot {
    pub principal: SnapshotPrincipal,
    pub static_group_ids: Vec<String>,
    pub computed_groups: Vec<SnapshotComputedGroup>,
    pub grants: Vec<SnapshotGrant>,
    pub resource: String,
    pub action: String,
    #[serde(default)]
    pub context: JsonValue,
}

/// Batch authorization snapshot for multiple actions on the same resource.
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AuthzBatchSnapshot {
    pub principal: SnapshotPrincipal,
    pub static_group_ids: Vec<String>,
    pub computed_groups: Vec<SnapshotComputedGroup>,
    pub grants: Vec<SnapshotGrant>,
    pub resource: String,
    pub actions: Vec<String>,
    #[serde(default)]
    pub context: JsonValue,
}

/// Minimal Principal shape the native engine needs.
///
/// The field is called `principal_type` in Rust because `type` is reserved, but
/// serde maps it from the `type` JSON field produced by host callers.
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SnapshotPrincipal {
    pub uid: String,
    #[serde(rename = "type")]
    pub principal_type: String,
    pub status: String,
    #[serde(default)]
    pub display_name: Option<String>,
    #[serde(default)]
    pub avatar_url: Option<String>,
}

/// Computed group candidate loaded from `principal_groups`.
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SnapshotComputedGroup {
    pub id: String,
    pub condition: String,
}

/// Candidate permission grant loaded by the control plane.
///
/// Native still checks owner, action, resource pattern, and CEL condition; SQL
/// only prefilters enough to keep the snapshot small.
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SnapshotGrant {
    pub id: String,
    #[serde(default)]
    pub principal_uid: Option<String>,
    #[serde(default)]
    pub group_id: Option<String>,
    pub resource_pattern: String,
    pub action: String,
    pub condition: String,
}

/// Authorization decision returned to host runtimes.
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AuthzDecision {
    pub status: String,
    pub diagnostics: Vec<AuthzDiagnostic>,
    pub effective_group_ids: Vec<String>,
    pub denied_action: Option<String>,
}

/// Diagnostic for invalid persisted AuthZ data.
///
/// Diagnostics do not make a request allowed; invalid grants/groups fail closed
/// and are reported for logging.
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AuthzDiagnostic {
    pub kind: String,
    pub id: String,
    #[serde(default)]
    pub action: Option<String>,
    #[serde(default)]
    pub resource_pattern: Option<String>,
    pub reason: String,
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

/// Authorizes one exact action on one concrete resource.
pub fn authorize(snapshot: AuthzSnapshot) -> KernelResult<AuthzDecision> {
    authorize_one(&snapshot)
}

/// Authorizes every requested action against the same concrete resource.
///
/// The first denied action is returned so the caller can produce a useful domain
/// error while preserving default-deny behavior.
pub fn authorize_all(snapshot: AuthzBatchSnapshot) -> KernelResult<AuthzDecision> {
    if snapshot.actions.is_empty() {
        return Ok(decision("invalid_request", Vec::new(), Vec::new(), None));
    }

    let (effective_group_ids, mut diagnostics) = effective_group_ids(
        &snapshot.principal,
        &snapshot.static_group_ids,
        &snapshot.computed_groups,
    )?;

    if snapshot.principal.status != "active" {
        return Ok(decision(
            "principal_disabled",
            diagnostics,
            effective_group_ids,
            None,
        ));
    }

    for action in &snapshot.actions {
        let (allowed, mut action_diagnostics) = grants_allow(
            &snapshot.principal,
            &effective_group_ids,
            &snapshot.grants,
            &snapshot.resource,
            action,
            &snapshot.context,
        )?;

        diagnostics.append(&mut action_diagnostics);

        if !allowed {
            return Ok(decision(
                "deny",
                diagnostics,
                effective_group_ids,
                Some(action.clone()),
            ));
        }
    }

    Ok(decision("allow", diagnostics, effective_group_ids, None))
}

/// Decodes, evaluates, and encodes a single-action snapshot as host values.
pub fn authorize_value(snapshot: JsonValue) -> KernelResult<JsonValue> {
    let snapshot: AuthzSnapshot = serde_json::from_value(snapshot)
        .map_err(|reason| KernelError::new(format!("invalid authz snapshot: {reason}")))?;
    let decision = authorize(snapshot)?;

    serde_json::to_value(decision)
        .map_err(|reason| KernelError::new(format!("failed to encode authz decision: {reason}")))
}

/// Decodes, evaluates, and encodes a batch-action snapshot as host values.
pub fn authorize_all_value(snapshot: JsonValue) -> KernelResult<JsonValue> {
    let snapshot: AuthzBatchSnapshot = serde_json::from_value(snapshot)
        .map_err(|reason| KernelError::new(format!("invalid authz batch snapshot: {reason}")))?;
    let decision = authorize_all(snapshot)?;

    serde_json::to_value(decision)
        .map_err(|reason| KernelError::new(format!("failed to encode authz decision: {reason}")))
}

fn authorize_one(snapshot: &AuthzSnapshot) -> KernelResult<AuthzDecision> {
    if snapshot.action.is_empty() || snapshot.resource.is_empty() {
        return Ok(decision("invalid_request", Vec::new(), Vec::new(), None));
    }

    let (effective_group_ids, mut diagnostics) = effective_group_ids(
        &snapshot.principal,
        &snapshot.static_group_ids,
        &snapshot.computed_groups,
    )?;

    if snapshot.principal.status != "active" {
        return Ok(decision(
            "principal_disabled",
            diagnostics,
            effective_group_ids,
            None,
        ));
    }

    // Authorization starts with the subject lifecycle check above. Grants are
    // considered only for active Principals.
    let (allowed, mut grant_diagnostics) = grants_allow(
        &snapshot.principal,
        &effective_group_ids,
        &snapshot.grants,
        &snapshot.resource,
        &snapshot.action,
        &snapshot.context,
    )?;
    diagnostics.append(&mut grant_diagnostics);

    Ok(decision(
        if allowed { "allow" } else { "deny" },
        diagnostics,
        effective_group_ids,
        if allowed {
            None
        } else {
            Some(snapshot.action.clone())
        },
    ))
}

/// Combines static group ids with computed groups that evaluate to true.
///
/// Invalid computed conditions are diagnostics and do not add the group to the
/// effective set.
fn effective_group_ids(
    principal: &SnapshotPrincipal,
    static_group_ids: &[String],
    computed_groups: &[SnapshotComputedGroup],
) -> KernelResult<(Vec<String>, Vec<AuthzDiagnostic>)> {
    let principal_json = principal_to_json(principal);
    let context = cel::build_context(vec![("principal", principal_json)])?;
    let mut effective_group_ids = static_group_ids.to_vec();
    let mut diagnostics = Vec::new();

    for group in computed_groups {
        let program = match cached_condition_program(
            format!("computed_group:{}", group.id),
            &group.condition,
        ) {
            Ok(program) => program,
            Err(reason) => {
                diagnostics.push(computed_group_diagnostic(
                    group,
                    "computed_group_condition_compile",
                    reason,
                ));
                continue;
            }
        };

        match cel::execute_bool(&program, &context) {
            Ok(true) => effective_group_ids.push(group.id.clone()),
            Ok(false) => {}
            Err(BoolEvalError::Execution(reason)) => {
                diagnostics.push(computed_group_diagnostic(
                    group,
                    "computed_group_condition_execution",
                    reason,
                ));
            }
            Err(BoolEvalError::ResultType(reason)) => {
                diagnostics.push(computed_group_diagnostic(
                    group,
                    "computed_group_condition_result_type",
                    reason,
                ));
            }
        }
    }

    effective_group_ids.sort();
    effective_group_ids.dedup();
    Ok((effective_group_ids, diagnostics))
}

/// Evaluates candidate grants for one action.
///
/// A grant can allow only after owner, exact action, resource pattern, and CEL
/// condition all match. Any invalid persisted pattern/condition is skipped with
/// diagnostics, preserving default deny.
fn grants_allow(
    principal: &SnapshotPrincipal,
    effective_group_ids: &[String],
    grants: &[SnapshotGrant],
    resource: &str,
    action: &str,
    request_context: &JsonValue,
) -> KernelResult<(bool, Vec<AuthzDiagnostic>)> {
    let effective_group_ids: HashSet<&str> =
        effective_group_ids.iter().map(String::as_str).collect();
    let cel_context = cel::build_context(vec![
        ("principal", principal_to_json(principal)),
        ("resource", JsonValue::String(resource.to_owned())),
        ("action", JsonValue::String(action.to_owned())),
        ("context", normalized_context(request_context)),
    ])?;
    let mut diagnostics = Vec::new();

    for grant in grants {
        if grant.action != action
            || !grant_owned_by_subject(grant, &principal.uid, &effective_group_ids)
        {
            continue;
        }

        match cached_grant_resource_pattern_matches(grant, resource) {
            Ok(false) => continue,
            Err(reason) => {
                diagnostics.push(grant_diagnostic(grant, "resource_pattern", reason));
                continue;
            }
            Ok(true) => {}
        }

        let program =
            match cached_condition_program(format!("grant:{}", grant.id), &grant.condition) {
                Ok(program) => program,
                Err(reason) => {
                    diagnostics.push(grant_diagnostic(grant, "condition_compile", reason));
                    continue;
                }
            };

        match cel::execute_bool(&program, &cel_context) {
            Ok(true) => return Ok((true, diagnostics)),
            Ok(false) => {}
            Err(BoolEvalError::Execution(reason)) => {
                diagnostics.push(grant_diagnostic(grant, "condition_execution", reason));
            }
            Err(BoolEvalError::ResultType(reason)) => {
                diagnostics.push(grant_diagnostic(grant, "condition_result_type", reason));
            }
        }
    }

    Ok((false, diagnostics))
}

/// Checks the grant owner against the Principal UID or effective group set.
fn grant_owned_by_subject(
    grant: &SnapshotGrant,
    principal_uid: &str,
    effective_group_ids: &HashSet<&str>,
) -> bool {
    match (&grant.principal_uid, &grant.group_id) {
        (Some(grant_principal_uid), None) => grant_principal_uid == principal_uid,
        (None, Some(group_id)) => effective_group_ids.contains(group_id.as_str()),
        _ => false,
    }
}

/// Converts the Principal snapshot into the CEL-visible object.
fn principal_to_json(principal: &SnapshotPrincipal) -> JsonValue {
    serde_json::json!({
        "uid": principal.uid,
        "type": principal.principal_type,
        "status": principal.status,
        "displayName": principal.display_name,
        "avatarUrl": principal.avatar_url
    })
}

/// Namespaces caller context under `context.request` for CEL expressions.
fn normalized_context(request_context: &JsonValue) -> JsonValue {
    serde_json::json!({
        "request": request_context
    })
}

fn computed_group_diagnostic(
    group: &SnapshotComputedGroup,
    kind: &str,
    reason: String,
) -> AuthzDiagnostic {
    AuthzDiagnostic {
        kind: kind.to_owned(),
        id: group.id.clone(),
        action: None,
        resource_pattern: None,
        reason,
    }
}

fn grant_diagnostic(grant: &SnapshotGrant, kind: &str, reason: String) -> AuthzDiagnostic {
    AuthzDiagnostic {
        kind: kind.to_owned(),
        id: grant.id.clone(),
        action: Some(grant.action.clone()),
        resource_pattern: Some(grant.resource_pattern.clone()),
        reason,
    }
}

fn cached_condition_program(
    cache_key: String,
    condition: &str,
) -> std::result::Result<Arc<::cel::Program>, String> {
    if let Some(program) = lookup_cached_condition_program(&cache_key, condition) {
        return Ok(program);
    }

    let program = Arc::new(cel::compile_condition(condition).map_err(|reason| reason.to_string())?);
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

    if cached.condition == condition {
        Some(Arc::clone(&cached.program))
    } else {
        None
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
    grant: &SnapshotGrant,
    resource: &str,
) -> std::result::Result<bool, String> {
    let matcher = cached_grant_resource_pattern_matcher(grant)?;
    Ok(matcher.is_match(normalize_resource_for_glob(resource)))
}

fn cached_grant_resource_pattern_matcher(
    grant: &SnapshotGrant,
) -> std::result::Result<Arc<GlobMatcher>, String> {
    let cache_key = format!("grant:{}", grant.id);

    if let Some(matcher) =
        lookup_cached_resource_pattern_matcher(&cache_key, &grant.resource_pattern)
    {
        return Ok(matcher);
    }

    let matcher = Arc::new(
        resource_pattern_matcher(&grant.resource_pattern).map_err(|reason| reason.to_string())?,
    );
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

    if cached.pattern == pattern {
        Some(Arc::clone(&cached.matcher))
    } else {
        None
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

fn decision(
    status: &str,
    diagnostics: Vec<AuthzDiagnostic>,
    effective_group_ids: Vec<String>,
    denied_action: Option<String>,
) -> AuthzDecision {
    AuthzDecision {
        status: status.to_owned(),
        diagnostics,
        effective_group_ids,
        denied_action,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn principal(status: &str, principal_type: &str) -> SnapshotPrincipal {
        SnapshotPrincipal {
            uid: "alice".to_owned(),
            principal_type: principal_type.to_owned(),
            status: status.to_owned(),
            display_name: None,
            avatar_url: None,
        }
    }

    #[test]
    fn authorize_direct_grant_allows() {
        let snapshot = AuthzSnapshot {
            principal: principal("active", "human"),
            static_group_ids: Vec::new(),
            computed_groups: Vec::new(),
            grants: vec![SnapshotGrant {
                id: "grant-1".to_owned(),
                principal_uid: Some("alice".to_owned()),
                group_id: None,
                resource_pattern: "web_console".to_owned(),
                action: "read".to_owned(),
                condition: "true".to_owned(),
            }],
            resource: "web_console".to_owned(),
            action: "read".to_owned(),
            context: serde_json::json!({}),
        };

        let decision = authorize(snapshot).unwrap();
        assert_eq!(decision.status, "allow");
    }

    #[test]
    fn authorize_computed_group_grant_allows() {
        let snapshot = AuthzSnapshot {
            principal: principal("active", "human"),
            static_group_ids: Vec::new(),
            computed_groups: vec![SnapshotComputedGroup {
                id: "all_humans".to_owned(),
                condition: r#"principal.type == "human" && principal.status == "active""#
                    .to_owned(),
            }],
            grants: vec![SnapshotGrant {
                id: "grant-1".to_owned(),
                principal_uid: None,
                group_id: Some("all_humans".to_owned()),
                resource_pattern: "ai_agent:**".to_owned(),
                action: "invoke".to_owned(),
                condition: "true".to_owned(),
            }],
            resource: "ai_agent:default".to_owned(),
            action: "invoke".to_owned(),
            context: serde_json::json!({}),
        };

        let decision = authorize(snapshot).unwrap();
        assert_eq!(decision.status, "allow");
        assert_eq!(decision.effective_group_ids, vec!["all_humans"]);
    }

    #[test]
    fn non_boolean_condition_diagnoses_and_denies() {
        let snapshot = AuthzSnapshot {
            principal: principal("active", "human"),
            static_group_ids: Vec::new(),
            computed_groups: Vec::new(),
            grants: vec![SnapshotGrant {
                id: "grant-1".to_owned(),
                principal_uid: Some("alice".to_owned()),
                group_id: None,
                resource_pattern: "web_console".to_owned(),
                action: "read".to_owned(),
                condition: "principal.uid".to_owned(),
            }],
            resource: "web_console".to_owned(),
            action: "read".to_owned(),
            context: serde_json::json!({}),
        };

        let decision = authorize(snapshot).unwrap();
        assert_eq!(decision.status, "deny");
        assert_eq!(decision.diagnostics[0].kind, "condition_result_type");
    }

    #[test]
    fn batch_reports_first_denied_action() {
        let snapshot = AuthzBatchSnapshot {
            principal: principal("active", "human"),
            static_group_ids: Vec::new(),
            computed_groups: Vec::new(),
            grants: vec![SnapshotGrant {
                id: "grant-1".to_owned(),
                principal_uid: Some("alice".to_owned()),
                group_id: None,
                resource_pattern: "web_console".to_owned(),
                action: "read".to_owned(),
                condition: "true".to_owned(),
            }],
            resource: "web_console".to_owned(),
            actions: vec!["read".to_owned(), "write".to_owned()],
            context: serde_json::json!({}),
        };

        let decision = authorize_all(snapshot).unwrap();
        assert_eq!(decision.status, "deny");
        assert_eq!(decision.denied_action.as_deref(), Some("write"));
    }
}
