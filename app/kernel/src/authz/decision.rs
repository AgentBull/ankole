use std::collections::{HashMap, HashSet};
use std::sync::{Arc, OnceLock};

use globset::GlobMatcher;
use serde::{Deserialize, Serialize};
use serde_json::Value as JSONValue;

use crate::authz::cel::{self, BoolEvalError};
use crate::authz::resource_pattern::{normalize_resource_for_glob, resource_pattern_matcher};
use crate::common::{KernelError, KernelResult, bounded_cache::BoundedCache};

/// The snapshot must already contain all DB state for the decision.
/// This module has no PostgreSQL, Redis, or external-service access.
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AuthzSnapshot {
    pub principal: SnapshotPrincipal,
    #[serde(rename = "staticGroupIDs")]
    pub static_group_ids: Vec<String>,
    pub computed_groups: Vec<SnapshotComputedGroup>,
    pub grants: Vec<SnapshotGrant>,
    pub resource: String,
    pub action: String,
    #[serde(default)]
    pub context: JSONValue,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AuthzBatchSnapshot {
    pub principal: SnapshotPrincipal,
    #[serde(rename = "staticGroupIDs")]
    pub static_group_ids: Vec<String>,
    pub computed_groups: Vec<SnapshotComputedGroup>,
    pub grants: Vec<SnapshotGrant>,
    pub resource: String,
    pub actions: Vec<String>,
    #[serde(default)]
    pub context: JSONValue,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DriveContextSnapshot {
    pub principal: SnapshotPrincipal,
    #[serde(rename = "staticGroupIDs")]
    pub static_group_ids: Vec<String>,
    pub computed_groups: Vec<SnapshotComputedGroup>,
    pub grants: Vec<SnapshotGrant>,
    #[serde(default)]
    pub context: JSONValue,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DriveContextDecision {
    pub status: String,
    #[serde(rename = "effectiveGroupIDs")]
    pub effective_group_ids: Vec<String>,
    #[serde(rename = "satisfiedGrantIDs")]
    pub satisfied_grant_ids: Vec<String>,
    pub diagnostics: Vec<AuthzDiagnostic>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AuthzCheck {
    pub resource: String,
    pub action: String,
    /// None uses all candidate grants. An empty list cannot grant permission.
    #[serde(default, rename = "grantIDs")]
    pub grant_ids: Option<Vec<String>>,
}

#[derive(Debug, Deserialize)]
pub struct AuthzChecksSnapshot {
    #[serde(flatten)]
    pub snapshot: AuthzBatchSnapshot,
    pub checks: Vec<AuthzCheck>,
}

#[derive(Debug, Serialize)]
pub struct AuthzCheckDecisions {
    pub allowed: Vec<bool>,
    pub diagnostics: Vec<AuthzDiagnostic>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SnapshotPrincipal {
    pub uid: String,
    #[serde(rename = "type")]
    pub principal_type: String,
    pub status: String,
    #[serde(default)]
    pub membership: Option<String>,
    #[serde(default)]
    pub display_name: Option<String>,
    #[serde(default, rename = "avatarURL")]
    pub avatar_url: Option<String>,
}

/// Computed group candidate loaded from `principal_groups`.
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SnapshotComputedGroup {
    pub id: String,
    pub condition: String,
}

/// Native still checks owner, action, resource pattern, and CEL condition. SQL
/// only prefilters enough to keep the snapshot small.
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SnapshotGrant {
    pub id: String,
    #[serde(default, rename = "principalUID")]
    pub principal_uid: Option<String>,
    #[serde(default, rename = "groupID")]
    pub group_id: Option<String>,
    #[serde(default)]
    pub has_source_node: bool,
    pub resource_pattern: String,
    pub action: String,
    pub condition: String,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AuthzDecision {
    pub status: String,
    pub diagnostics: Vec<AuthzDiagnostic>,
    #[serde(rename = "effectiveGroupIDs")]
    pub effective_group_ids: Vec<String>,
    pub denied_action: Option<String>,
}

/// Diagnostics do not make a request allowed. Invalid grants and groups fail closed
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

/// Shares compiled CEL programs across grants and computed groups that use the
/// same source.
static CONDITION_CACHE: OnceLock<BoundedCache<String, Arc<::cel::Program>>> = OnceLock::new();
/// Shares compiled matchers across grants with the same resource pattern.
static RESOURCE_PATTERN_CACHE: OnceLock<BoundedCache<String, Arc<GlobMatcher>>> = OnceLock::new();

// Prevents persisted CEL text from growing the process cache without a bound.
const MAX_CONDITION_CACHE_ENTRIES: usize = 1024;
// Prevents persisted resource patterns from growing the process cache without
// a bound.
const MAX_RESOURCE_PATTERN_CACHE_ENTRIES: usize = 1024;

/// Authorizes one exact action on one concrete resource.
pub fn authorize(snapshot: AuthzSnapshot) -> KernelResult<AuthzDecision> {
    authorize_one(&snapshot)
}

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

    let evaluator =
        GrantEvaluator::new(&snapshot.principal, &effective_group_ids, &snapshot.context)?;

    for action in &snapshot.actions {
        let (allowed, mut action_diagnostics) =
            evaluator.allows(&snapshot.grants, &snapshot.resource, action)?;

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

pub fn authorize_value(snapshot: JSONValue) -> KernelResult<JSONValue> {
    let snapshot: AuthzSnapshot = serde_json::from_value(snapshot)
        .map_err(|reason| KernelError::new(format!("invalid authz snapshot: {reason}")))?;
    let decision = authorize(snapshot)?;

    serde_json::to_value(decision)
        .map_err(|reason| KernelError::new(format!("failed to encode authz decision: {reason}")))
}

pub fn authorize_all_value(snapshot: JSONValue) -> KernelResult<JSONValue> {
    let snapshot: AuthzBatchSnapshot = serde_json::from_value(snapshot)
        .map_err(|reason| KernelError::new(format!("invalid authz batch snapshot: {reason}")))?;
    let decision = authorize_all(snapshot)?;

    serde_json::to_value(decision)
        .map_err(|reason| KernelError::new(format!("failed to encode authz decision: {reason}")))
}

/// Evaluates independent checks with one subject, group evaluation, and CEL environment.
pub fn authorize_checks(input: AuthzChecksSnapshot) -> KernelResult<AuthzCheckDecisions> {
    let snapshot = input.snapshot;
    let (effective_group_ids, mut diagnostics) = effective_group_ids(
        &snapshot.principal,
        &snapshot.static_group_ids,
        &snapshot.computed_groups,
    )?;
    let mut allowed = vec![false; input.checks.len()];

    if snapshot.principal.status == "active" {
        let evaluator =
            GrantEvaluator::new(&snapshot.principal, &effective_group_ids, &snapshot.context)?;
        let mut by_action: HashMap<&str, Vec<&SnapshotGrant>> = HashMap::new();
        let mut by_id = HashMap::new();
        for grant in &snapshot.grants {
            by_action.entry(&grant.action).or_default().push(grant);
            by_id.insert(grant.id.as_str(), grant);
        }

        for (check, allowed) in input.checks.iter().zip(&mut allowed) {
            if check.resource.is_empty() || check.action.is_empty() {
                continue;
            }
            let grants: Vec<_> = match &check.grant_ids {
                Some(ids) => ids
                    .iter()
                    .filter_map(|id| by_id.get(id.as_str()).copied())
                    .collect(),
                None => by_action
                    .get(check.action.as_str())
                    .cloned()
                    .unwrap_or_default(),
            };
            let (result, mut check_diagnostics) =
                evaluator.allows(grants, &check.resource, &check.action)?;
            *allowed = result;
            diagnostics.append(&mut check_diagnostics);
        }
    }

    let mut seen = HashSet::new();
    diagnostics.retain(|diagnostic| {
        seen.insert((
            diagnostic.kind.clone(),
            diagnostic.id.clone(),
            diagnostic.reason.clone(),
        ))
    });
    Ok(AuthzCheckDecisions {
        allowed,
        diagnostics,
    })
}

pub fn authorize_checks_value(snapshot: JSONValue) -> KernelResult<JSONValue> {
    let input = serde_json::from_value(snapshot)
        .map_err(|reason| KernelError::new(format!("invalid authz checks snapshot: {reason}")))?;
    serde_json::to_value(authorize_checks(input)?)
        .map_err(|reason| KernelError::new(format!("failed to encode authz checks: {reason}")))
}

pub fn evaluate_drive_context(
    snapshot: DriveContextSnapshot,
) -> KernelResult<DriveContextDecision> {
    if snapshot.principal.status != "active" {
        return Ok(DriveContextDecision {
            status: "principal_disabled".to_owned(),
            effective_group_ids: Vec::new(),
            satisfied_grant_ids: Vec::new(),
            diagnostics: Vec::new(),
        });
    }

    let (effective_group_ids, mut diagnostics) = effective_group_ids(
        &snapshot.principal,
        &snapshot.static_group_ids,
        &snapshot.computed_groups,
    )?;
    let groups = effective_group_ids.iter().map(String::as_str).collect();
    let context = cel::build_context(vec![
        ("principal", principal_to_json(&snapshot.principal)),
        ("context", normalized_context(&snapshot.context)),
    ])?;
    let mut satisfied_grant_ids = Vec::new();

    for grant in &snapshot.grants {
        let owned = if grant.has_source_node {
            grant.principal_uid.is_none() && grant.group_id.is_none()
        } else {
            grant_owned_by_subject(grant, &snapshot.principal.uid, &groups)
        };
        if !owned
            || grant.condition == "true"
            || !matches!(
                grant.action.as_str(),
                "node_view" | "node_contribute" | "node_edit" | "node_manage" | "node_comment"
            )
        {
            continue;
        }

        let program = match cached_condition_program(&grant.condition) {
            Ok(program) => program,
            Err(reason) => {
                diagnostics.push(grant_diagnostic(grant, "condition_compile", reason));
                continue;
            }
        };
        if let Err(reason) = cel::validate_drive_condition_program(&program) {
            diagnostics.push(grant_diagnostic(
                grant,
                "condition_variables",
                reason.to_string(),
            ));
            continue;
        }
        match cel::execute_bool(&program, &context) {
            Ok(true) => satisfied_grant_ids.push(grant.id.clone()),
            Ok(false) => {}
            Err(BoolEvalError::Execution(reason)) => {
                diagnostics.push(grant_diagnostic(grant, "condition_execution", reason));
            }
            Err(BoolEvalError::ResultType(reason)) => {
                diagnostics.push(grant_diagnostic(grant, "condition_result_type", reason));
            }
        }
    }

    satisfied_grant_ids.sort();
    satisfied_grant_ids.dedup();
    Ok(DriveContextDecision {
        status: "active".to_owned(),
        effective_group_ids,
        satisfied_grant_ids,
        diagnostics,
    })
}

pub fn evaluate_drive_context_value(snapshot: JSONValue) -> KernelResult<JSONValue> {
    let snapshot = serde_json::from_value(snapshot)
        .map_err(|reason| KernelError::new(format!("invalid drive context snapshot: {reason}")))?;
    serde_json::to_value(evaluate_drive_context(snapshot)?)
        .map_err(|reason| KernelError::new(format!("failed to encode drive context: {reason}")))
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

    let evaluator =
        GrantEvaluator::new(&snapshot.principal, &effective_group_ids, &snapshot.context)?;
    let (allowed, mut grant_diagnostics) =
        evaluator.allows(&snapshot.grants, &snapshot.resource, &snapshot.action)?;
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
        let program = match cached_condition_program(&group.condition) {
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

/// A grant can allow only after owner, exact action, resource pattern, and CEL
/// condition all match. Any invalid persisted pattern or condition is skipped
/// with diagnostics, and the default is deny.
struct GrantEvaluator<'a> {
    principal_uid: &'a str,
    effective_group_ids: HashSet<&'a str>,
    context: ::cel::Context<'static, 'static>,
}

impl<'a> GrantEvaluator<'a> {
    fn new(
        principal: &'a SnapshotPrincipal,
        effective_group_ids: &'a [String],
        request_context: &JSONValue,
    ) -> KernelResult<Self> {
        Ok(Self {
            principal_uid: &principal.uid,
            effective_group_ids: effective_group_ids.iter().map(String::as_str).collect(),
            context: cel::build_context(vec![
                ("principal", principal_to_json(principal)),
                ("context", normalized_context(request_context)),
            ])?,
        })
    }

    fn allows<'g>(
        &self,
        grants: impl IntoIterator<Item = &'g SnapshotGrant>,
        resource: &str,
        action: &str,
    ) -> KernelResult<(bool, Vec<AuthzDiagnostic>)> {
        let mut cel_context = self.context.new_inner_scope();
        cel_context.add_variable_from_value("resource", resource.to_owned());
        cel_context.add_variable_from_value("action", action.to_owned());
        let normalized_resource = normalize_resource_for_glob(resource);
        let mut diagnostics = Vec::new();

        for grant in grants {
            if grant.action != action
                || !grant_owned_by_subject(grant, self.principal_uid, &self.effective_group_ids)
            {
                continue;
            }

            match cached_resource_pattern_matches(&grant.resource_pattern, &normalized_resource) {
                Ok(false) => continue,
                Err(reason) => {
                    diagnostics.push(grant_diagnostic(grant, "resource_pattern", reason));
                    continue;
                }
                Ok(true) => {}
            }

            let program = match cached_condition_program(&grant.condition) {
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
}

fn grant_owned_by_subject(
    grant: &SnapshotGrant,
    principal_uid: &str,
    effective_group_ids: &HashSet<&str>,
) -> bool {
    if grant.has_source_node {
        return false;
    }
    match (&grant.principal_uid, &grant.group_id) {
        (Some(grant_principal_uid), None) => grant_principal_uid == principal_uid,
        (None, Some(group_id)) => effective_group_ids.contains(group_id.as_str()),
        _ => false,
    }
}

fn principal_to_json(principal: &SnapshotPrincipal) -> JSONValue {
    serde_json::json!({
        "uid": principal.uid,
        "type": principal.principal_type,
        "status": principal.status,
        "membership": principal.membership,
        "displayName": principal.display_name,
        "avatarURL": principal.avatar_url
    })
}

fn normalized_context(request_context: &JSONValue) -> JSONValue {
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

fn cached_condition_program(condition: &str) -> std::result::Result<Arc<::cel::Program>, String> {
    let cache = CONDITION_CACHE.get_or_init(|| BoundedCache::new(MAX_CONDITION_CACHE_ENTRIES));
    if let Some(program) = cache.get_cloned(condition) {
        return Ok(program);
    }

    let program = Arc::new(cel::compile_condition(condition).map_err(|reason| reason.to_string())?);
    cache.insert(condition.to_owned(), Arc::clone(&program));
    Ok(program)
}

fn cached_resource_pattern_matches(
    pattern: &str,
    normalized_resource: &str,
) -> std::result::Result<bool, String> {
    let matcher = cached_resource_pattern_matcher(pattern)?;
    Ok(matcher.is_match(normalized_resource))
}

fn cached_resource_pattern_matcher(pattern: &str) -> std::result::Result<Arc<GlobMatcher>, String> {
    let cache = RESOURCE_PATTERN_CACHE
        .get_or_init(|| BoundedCache::new(MAX_RESOURCE_PATTERN_CACHE_ENTRIES));
    if let Some(matcher) = cache.get_cloned(pattern) {
        return Ok(matcher);
    }

    let matcher = Arc::new(resource_pattern_matcher(pattern).map_err(|reason| reason.to_string())?);
    cache.insert(pattern.to_owned(), Arc::clone(&matcher));
    Ok(matcher)
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
    use serde_json::json;

    fn principal(status: &str, principal_type: &str) -> SnapshotPrincipal {
        SnapshotPrincipal {
            uid: "alice".to_owned(),
            principal_type: principal_type.to_owned(),
            status: status.to_owned(),
            membership: if principal_type == "human" {
                Some("member".to_owned())
            } else {
                None
            },
            display_name: None,
            avatar_url: None,
        }
    }

    fn pod_snapshot() -> JSONValue {
        json!({
            "principal": {
                "uid": "alice", "type": "human", "status": "active", "membership": "member"
            },
            "staticGroupIDs": ["static", "static"],
            "computedGroups": [{
                "id": "members",
                "condition": "principal.type == 'human' && principal.membership == 'member' && principal.status == 'active'"
            }],
            "context": {"ip": "10.0.0.1"},
            "grants": []
        })
    }

    fn pod_grant(id: &str, condition: &str) -> JSONValue {
        json!({
            "id": id, "principalUID": "alice", "resourcePattern": "drive:space:**",
            "action": "node_view", "condition": condition
        })
    }

    #[test]
    fn pod_context_evaluates_owned_conditional_grants_and_usersets() {
        let mut snapshot = pod_snapshot();
        let condition = "['10.0.0.1'].exists(ip, context.request.ip == ip)";
        let mut group = pod_grant("group", condition);
        group.as_object_mut().unwrap().remove("principalUID");
        group["groupID"] = json!("members");
        let mut userset = pod_grant("userset", condition);
        userset.as_object_mut().unwrap().remove("principalUID");
        userset["hasSourceNode"] = json!(true);
        let mut foreign = pod_grant("foreign", condition);
        foreign["principalUID"] = json!("bob");
        let mut mixed = userset.clone();
        mixed["id"] = json!("mixed");
        mixed["principalUID"] = json!("alice");
        let mut no_owner = pod_grant("no-owner", condition);
        no_owner.as_object_mut().unwrap().remove("principalUID");
        let mut non_pod = pod_grant("non-pod", condition);
        non_pod["action"] = json!("read");
        snapshot["grants"] = json!([
            pod_grant("direct", condition),
            group,
            userset,
            foreign,
            mixed,
            no_owner,
            non_pod,
            pod_grant("unconditional", "true"),
            pod_grant("false", "context.request.ip == 'other'")
        ]);

        let result = evaluate_drive_context_value(snapshot).unwrap();
        assert_eq!(result["status"], "active");
        assert_eq!(result["effectiveGroupIDs"], json!(["members", "static"]));
        assert_eq!(
            result["satisfiedGrantIDs"],
            json!(["direct", "group", "userset"])
        );
        assert_eq!(result["diagnostics"], json!([]));
    }

    #[test]
    fn pod_context_rejects_invalid_persisted_conditions() {
        let mut snapshot = pod_snapshot();
        snapshot["grants"] = json!([
            pod_grant("resource", "resource == 'drive:space'"),
            pod_grant("action", "action == 'node_view'"),
            pod_grant("malformed", "["),
            pod_grant("non-bool", "principal.uid"),
            pod_grant("execution", "context.request.missing == true")
        ]);
        let result = evaluate_drive_context_value(snapshot).unwrap();
        assert_eq!(result["satisfiedGrantIDs"], json!([]));
        let diagnostics: Vec<_> = result["diagnostics"]
            .as_array()
            .unwrap()
            .iter()
            .map(|diagnostic| {
                (
                    diagnostic["id"].as_str().unwrap(),
                    diagnostic["kind"].as_str().unwrap(),
                )
            })
            .collect();
        assert_eq!(
            diagnostics,
            vec![
                ("resource", "condition_variables"),
                ("action", "condition_variables"),
                ("malformed", "condition_compile"),
                ("non-bool", "condition_result_type"),
                ("execution", "condition_execution")
            ]
        );
    }

    #[test]
    fn guest_membership_and_disabled_status_do_not_seed_member_permissions() {
        let mut snapshot = pod_snapshot();
        snapshot["principal"]["membership"] = json!("guest");
        snapshot["grants"] = json!([pod_grant("guest", "principal.membership == 'guest'")]);
        let result = evaluate_drive_context_value(snapshot.clone()).unwrap();
        assert_eq!(result["effectiveGroupIDs"], json!(["static"]));
        assert_eq!(result["satisfiedGrantIDs"], json!(["guest"]));

        snapshot["principal"]["status"] = json!("disabled");
        let result = evaluate_drive_context_value(snapshot).unwrap();
        assert_eq!(result["status"], "principal_disabled");
        assert_eq!(result["effectiveGroupIDs"], json!([]));
        assert_eq!(result["satisfiedGrantIDs"], json!([]));
    }

    #[test]
    fn generic_authorization_rejects_usersets_and_exposes_null_membership() {
        let mut snapshot = pod_snapshot();
        snapshot["principal"]["type"] = json!("agent");
        snapshot["principal"]
            .as_object_mut()
            .unwrap()
            .remove("membership");
        snapshot["resource"] = json!("drive:space:node");
        snapshot["action"] = json!("node_view");
        let mut userset = pod_grant("userset", "true");
        userset["hasSourceNode"] = json!(true);
        snapshot["grants"] = json!([userset]);
        assert_eq!(authorize_value(snapshot.clone()).unwrap()["status"], "deny");

        snapshot["grants"] = json!([pod_grant("agent", "principal.membership == null")]);
        assert_eq!(authorize_value(snapshot).unwrap()["status"], "allow");
    }

    #[test]
    fn pod_context_rejects_malformed_snapshot_shapes() {
        for snapshot in [json!(null), json!({}), json!({"principal": true})] {
            assert!(evaluate_drive_context_value(snapshot).is_err());
        }
        let mut snapshot = pod_snapshot();
        let mut grant = pod_grant("invalid", "true");
        grant["hasSourceNode"] = json!("yes");
        snapshot["grants"] = json!([grant]);
        assert!(evaluate_drive_context_value(snapshot).is_err());
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
                has_source_node: false,
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
                has_source_node: false,
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
                has_source_node: false,
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
                has_source_node: false,
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

    #[test]
    fn condition_cache_reuses_source_and_stays_bounded() {
        clear_condition_cache();

        let first = cached_condition_program("principal.status == 'active'").unwrap();
        let second = cached_condition_program("principal.status == 'active'").unwrap();

        assert!(Arc::ptr_eq(&first, &second));

        for index in 0..=MAX_CONDITION_CACHE_ENTRIES {
            cached_condition_program(&format!(r#"principal.uid == "user-{index}""#)).unwrap();
        }

        assert_eq!(condition_cache_len(), MAX_CONDITION_CACHE_ENTRIES);
    }

    #[test]
    fn resource_pattern_cache_reuses_source_and_stays_bounded() {
        clear_resource_pattern_cache();

        let first = cached_resource_pattern_matcher("web_console:**").unwrap();
        let second = cached_resource_pattern_matcher("web_console:**").unwrap();

        assert!(Arc::ptr_eq(&first, &second));

        for index in 0..=MAX_RESOURCE_PATTERN_CACHE_ENTRIES {
            cached_resource_pattern_matcher(&format!("web_console:entry-{index}")).unwrap();
        }

        assert_eq!(
            resource_pattern_cache_len(),
            MAX_RESOURCE_PATTERN_CACHE_ENTRIES
        );
    }

    fn clear_condition_cache() {
        CONDITION_CACHE
            .get_or_init(|| BoundedCache::new(MAX_CONDITION_CACHE_ENTRIES))
            .clear();
    }

    fn clear_resource_pattern_cache() {
        RESOURCE_PATTERN_CACHE
            .get_or_init(|| BoundedCache::new(MAX_RESOURCE_PATTERN_CACHE_ENTRIES))
            .clear();
    }

    fn condition_cache_len() -> usize {
        CONDITION_CACHE
            .get_or_init(|| BoundedCache::new(MAX_CONDITION_CACHE_ENTRIES))
            .len()
    }

    fn resource_pattern_cache_len() -> usize {
        RESOURCE_PATTERN_CACHE
            .get_or_init(|| BoundedCache::new(MAX_RESOURCE_PATTERN_CACHE_ENTRIES))
            .len()
    }
}
