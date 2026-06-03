use globset::{GlobBuilder, GlobMatcher};
use napi::bindgen_prelude::*;

/// Validates persisted resource-pattern syntax without matching a request.
pub fn validate_pattern_source(pattern: &str) -> Result<()> {
  resource_pattern_matcher(pattern).map(|_| ())
}

/// Returns whether a persisted resource pattern matches a concrete request key.
pub fn pattern_matches(pattern: &str, resource: &str) -> Result<bool> {
  let matcher = resource_pattern_matcher(pattern)?;
  Ok(matcher.is_match(normalize_resource_for_glob(resource)))
}

/// Compiles BullX resource patterns through globset.
///
/// BullX uses `:` as the resource hierarchy separator. Internally the pattern is
/// translated to `/` and globset is configured with literal separators so `*`
/// stays within one segment and `**` can cross segment boundaries.
pub fn resource_pattern_matcher(pattern: &str) -> Result<GlobMatcher> {
  if pattern.is_empty() {
    return Err(Error::new(
      Status::InvalidArg,
      "resource_pattern must not be empty".to_owned(),
    ));
  }

  GlobBuilder::new(&normalize_resource_for_glob(pattern))
    .literal_separator(true)
    .build()
    .map_err(|reason| {
      Error::new(
        Status::InvalidArg,
        format!("invalid resource glob: {reason}"),
      )
    })
    .map(|glob| glob.compile_matcher())
}

/// Converts BullX resource separators to globset path separators.
pub fn normalize_resource_for_glob(value: &str) -> String {
  value.replace(':', "/")
}
