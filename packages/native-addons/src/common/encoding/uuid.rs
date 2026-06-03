use napi::bindgen_prelude::*;
use napi_derive::napi;
use radix_fmt::*;
use uuid::Uuid;

/// Make UUID v4 string shorted
/// @param uuid_v4 UUID v4 string
/// @returns shorted UUID v4 string
///
#[napi(js_name = "UUIDShorten")]
pub fn js_uuid_shorten(uuid_v4: String) -> Result<String> {
  Uuid::parse_str(&uuid_v4)
    .map_err(|e| Error::new(Status::GenericFailure, e.to_string()))
    .map(uuid_shorten)
}

/// Generate shorted UUID v4 string
/// @returns shorted UUID v4 string
#[napi(js_name = "genShortUUID")]
pub fn short_uuid_gen() -> String {
  uuid_shorten(Uuid::new_v4())
}

/// Generate UUID v4 string
/// @returns uuid v4
#[napi(js_name = "genUUID")]
pub fn gen_uuid() -> String {
  Uuid::new_v4().to_string()
}

// Generate UUID v7 string
// @returns uuid v7
#[napi(js_name = "genUUIDv7")]
pub fn gen_uuid_v7() -> String {
  Uuid::now_v7().to_string()
}

/// Generate Base36-encoded UUID v4 string
#[napi(js_name = "genBase36UUID")]
pub fn gen_base36_uuid() -> String {
  radix_36(Uuid::new_v4().as_u128()).to_string()
}

/// Expand shorted UUID v4 string
/// @param shorted_uuid shorted UUID v4 string
/// @returns standard UUID v4 string
#[napi(js_name = "shortUUIDExpand")]
pub fn short_uuid_expand(short_uuid: String) -> Result<String> {
  let mut uuid_buf = [0u8; 16];
  bs58::decode(short_uuid)
    .onto(&mut uuid_buf)
    .map_err(|e| Error::new(Status::GenericFailure, e.to_string()))
    .map(|_| Uuid::from_bytes(uuid_buf).as_hyphenated().to_string())
}

/// Internal function to make uuid object shorted
fn uuid_shorten(uuid: Uuid) -> String {
  bs58::encode(uuid.as_simple().as_ref()).into_string()
}
