//! Shared native kernel loaded by Bun through N-API and by Elixir through Rustler.
//!
//! Shared behavior lives in `common`, `authz`, and `runtime_fabric`;
//! feature-gated modules only translate host runtime types, naming, and errors.

use mimalloc::MiMalloc;

#[cfg(all(feature = "nif_dev", feature = "nif_prod"))]
compile_error!("nif_dev and nif_prod are mutually exclusive");

// Native addons can be loaded by long-running host runtimes. Keeping the global
// allocator explicit makes allocator behavior the same for the N-API and NIF
// builds of this crate.
#[global_allocator]
static GLOBAL: MiMalloc = MiMalloc;

#[cfg(any(
    test,
    feature = "napi",
    feature = "nif_dev",
    feature = "nif_prod",
    feature = "universal_ai_client"
))]
pub mod common;

#[cfg(any(test, feature = "napi", feature = "nif_dev", feature = "nif_prod"))]
pub mod authz;

#[cfg(any(test, feature = "napi", feature = "nif_dev", feature = "nif_prod"))]
pub mod runtime_fabric;

#[cfg(any(test, feature = "napi", feature = "nif_dev", feature = "nif_prod"))]
pub mod signals_gateway;

#[cfg(feature = "universal_ai_client")]
pub mod universal_ai_client;

#[cfg(feature = "napi")]
mod napi_exports;

#[cfg(any(feature = "nif_dev", feature = "nif_prod"))]
mod nif_exports;
