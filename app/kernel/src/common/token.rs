use tiktoken_rs::o200k_base_singleton;

/// Estimates token count with the provider-neutral o200k_base vocabulary.
///
/// This is a budgeting primitive only. It intentionally does not infer or
/// select a concrete LLM model.
pub fn estimate_o200k_base_tokens(text: &str) -> u64 {
    o200k_base_singleton().count_with_special_tokens(text) as u64
}
