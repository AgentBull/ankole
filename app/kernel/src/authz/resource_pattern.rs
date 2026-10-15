use globset::{GlobBuilder, GlobMatcher};

use crate::common::{KernelError, KernelResult};

pub fn validate_pattern_source(pattern: &str) -> KernelResult<()> {
    resource_pattern_matcher(pattern).map(|_| ())
}

pub fn pattern_matches(pattern: &str, resource: &str) -> KernelResult<bool> {
    let matcher = resource_pattern_matcher(pattern)?;
    Ok(matcher.is_match(normalize_resource_for_glob(resource)))
}

/// Ankole `:` segments become `/`. `*` stays in one segment and `**` can cross segments.
pub fn resource_pattern_matcher(pattern: &str) -> KernelResult<GlobMatcher> {
    if pattern.is_empty() {
        return Err(KernelError::new("resource_pattern must not be empty"));
    }

    GlobBuilder::new(&normalize_resource_for_glob(pattern))
        .literal_separator(true)
        .build()
        .map_err(|reason| KernelError::new(format!("invalid resource glob: {reason}")))
        .map(|glob| glob.compile_matcher())
}

pub fn normalize_resource_for_glob(value: &str) -> String {
    value.replace(':', "/")
}
