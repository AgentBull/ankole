use napi::{Error, Result, Status};
use napi_derive::napi;

use crate::common::crypto::jwt::header::JWTHeader;

#[napi]
pub fn jwt_decode_header(token: String) -> Result<JWTHeader> {
  jsonwebtoken::decode_header(&token)
    .map(Into::into)
    .map_err(|err| Error::new(Status::InvalidArg, format!("{err}")))
}
