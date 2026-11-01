//! Native behavior lives in host-neutral modules.
//! Feature-gated modules only translate host runtime types, naming, and errors.

#[cfg(all(feature = "nif", feature = "napi"))]
compile_error!("enable the nif feature or the napi feature, not both");

// The NIF build uses mimalloc. The Node addon uses the host allocator.
#[cfg(not(feature = "napi"))]
use mimalloc::MiMalloc;

#[cfg(not(feature = "napi"))]
#[global_allocator]
static GLOBAL: MiMalloc = MiMalloc;

#[cfg(any(
    test,
    feature = "nif",
    feature = "napi",
    feature = "web_proxy",
    feature = "universal_ai_client",
    feature = "object_store",
    feature = "model_image"
))]
pub mod common;

#[cfg(feature = "web_proxy")]
pub mod web_proxy;

#[cfg(any(test, feature = "nif"))]
pub mod authz;

#[cfg(any(test, feature = "nif"))]
pub mod brain_chunker;

#[cfg(feature = "brain_markdoc")]
pub mod brain_markdoc;

#[cfg(feature = "markdown")]
pub mod markdown;

#[cfg(any(test, feature = "nif"))]
pub mod signals;

#[cfg(any(test, feature = "nif"))]
pub mod page_document;

#[cfg(feature = "object_store")]
pub mod object_store;

#[cfg(feature = "model_image")]
pub mod model_image;

#[cfg(feature = "universal_ai_client")]
pub mod universal_ai_client;

// BEAM provides the NIF symbols. Rust test binaries run the host-neutral modules.
#[cfg(all(feature = "nif", not(test)))]
mod nif_exports;

#[cfg(feature = "napi")]
#[cfg_attr(
    test,
    allow(
        dead_code,
        reason = "Node-API registration is disabled in Rust test binaries; Bun tests call the exports"
    )
)]
mod napi_exports;
