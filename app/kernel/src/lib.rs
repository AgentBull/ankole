//! Native behavior lives in host-neutral modules.
//! Feature-gated modules only translate host runtime types, naming, and errors.

use mimalloc::MiMalloc;

// Native addons can be loaded by long-running host runtimes. Keeping the global
// allocator explicit gives the NIF build one allocation policy.
#[global_allocator]
static GLOBAL: MiMalloc = MiMalloc;

#[cfg(any(
    test,
    feature = "nif",
    feature = "universal_ai_client",
    feature = "object_store",
    feature = "model_image"
))]
pub mod common;

#[cfg(any(test, feature = "nif"))]
pub mod authz;

#[cfg(feature = "brain_markdoc")]
pub mod brain_markdoc;

#[cfg(feature = "markdown")]
pub mod markdown;

#[cfg(any(test, feature = "nif"))]
pub mod signals;

#[cfg(feature = "object_store")]
pub mod object_store;

#[cfg(feature = "model_image")]
pub mod model_image;

#[cfg(feature = "program_runner")]
pub mod program_runner;

#[cfg(feature = "universal_ai_client")]
pub mod universal_ai_client;

#[cfg(feature = "nif")]
mod nif_exports;
