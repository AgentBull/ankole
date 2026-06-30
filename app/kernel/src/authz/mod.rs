//! Pure authorization rule engine shared by Bun and Elixir callers.
//!
//! This module evaluates explicit snapshots only. It does not know how to load
//! Principals, groups, grants, or request context from PostgreSQL or any host
//! runtime state.

#![allow(dead_code, unused_imports)]

mod cel;
mod decision;
mod resource_pattern;

pub use cel::validate_condition_source;
pub use decision::{
    AuthzBatchSnapshot, AuthzDecision, AuthzDiagnostic, AuthzSnapshot, SnapshotComputedGroup,
    SnapshotGrant, SnapshotPrincipal, authorize, authorize_all, authorize_all_value,
    authorize_value,
};
pub use resource_pattern::{pattern_matches, validate_pattern_source};
