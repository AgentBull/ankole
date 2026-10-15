use tiktoken_rs::o200k_base_singleton;

/// Budgeting only. This does not select a concrete model.
pub fn estimate_o200k_base_tokens(text: &str) -> u64 {
    o200k_base_singleton().count_with_special_tokens(text) as u64
}
