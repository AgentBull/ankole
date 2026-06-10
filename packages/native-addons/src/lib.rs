use mimalloc::MiMalloc;

/// mimalloc is a compact general purpose allocator with excellent performance.
/// https://github.com/microsoft/mimalloc
#[global_allocator]
static GLOBAL: MiMalloc = MiMalloc;

pub mod authz;
pub mod common;
pub mod content_guard;
pub mod markdown;
pub mod media;
pub mod recall;
pub mod schedule;
pub mod tls;
