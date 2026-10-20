//! The Node build adds the N-API link flags. The NIF build does not.

fn main() {
    #[cfg(feature = "napi")]
    napi_build::setup();
}
