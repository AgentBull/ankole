use napi::bindgen_prelude::*;
use napi_derive::napi;

mod cel;
mod decision;
mod resource_pattern;

pub use decision::{authz_authorize, authz_authorize_all};

/// Validates CEL syntax for grants or computed-group conditions.
#[napi]
pub fn authz_validate_condition(condition: String) -> Result<bool> {
  cel::validate_condition_source(&condition)?;
  Ok(true)
}

/// Validates persisted resource-pattern syntax.
#[napi]
pub fn authz_validate_resource_pattern(pattern: String) -> Result<bool> {
  resource_pattern::validate_pattern_source(&pattern)?;
  Ok(true)
}

/// Matches one persisted resource pattern against one concrete request resource.
#[napi]
pub fn authz_match_resource_pattern(pattern: String, resource: String) -> Result<bool> {
  resource_pattern::pattern_matches(&pattern, &resource)
}
