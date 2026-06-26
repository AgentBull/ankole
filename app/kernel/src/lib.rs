//! Shared native kernel loaded by Bun through N-API and by Elixir through Rustler.
//!
//! The pure behavior lives in `core`; feature-gated modules only translate host
//! runtime types, naming, and errors into that shared implementation.

use mimalloc::MiMalloc;

// Native addons can be loaded by long-running host runtimes. Keeping the global
// allocator explicit makes allocator behavior the same for the N-API and NIF
// builds of this crate.
#[global_allocator]
static GLOBAL: MiMalloc = MiMalloc;

#[cfg(any(test, feature = "embed", feature = "napi", feature = "nif"))]
pub mod core;

#[cfg(any(test, feature = "embed", feature = "napi", feature = "nif"))]
pub mod authz;

#[cfg(any(test, feature = "embed", feature = "napi", feature = "nif"))]
pub mod runtime_fabric;

#[cfg(feature = "napi")]
mod napi_exports;

#[cfg(feature = "nif")]
mod nif_exports;
