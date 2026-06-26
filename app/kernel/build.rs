/// Configures build hooks that only matter for the N-API flavor of the crate.
fn main() {
    println!("cargo:rerun-if-changed=proto/ankole/runtime_fabric/v1/envelope.proto");

    prost_build::compile_protos(
        &["proto/ankole/runtime_fabric/v1/envelope.proto"],
        &["proto"],
    )
    .expect("failed to compile runtime fabric protobuf definitions");

    #[cfg(feature = "napi")]
    {
        napi_build::setup();
    }

    #[cfg(all(feature = "napi", target_os = "macos"))]
    {
        // macOS N-API addons are loaded by the host process. Dynamic lookup lets
        // unresolved Node symbols bind at load time instead of at Rust link time.
        println!("cargo:rustc-link-arg=-Wl,-undefined,dynamic_lookup");
    }
}
