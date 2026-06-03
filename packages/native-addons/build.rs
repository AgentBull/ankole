fn main() {
  napi_build::setup();

  #[cfg(target_os = "macos")]
  {
    println!("cargo:rustc-link-arg=-Wl,-undefined,dynamic_lookup");
  }
}
