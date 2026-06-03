#![deny(clippy::all)]
#![allow(dead_code)]

mod algorithm;
mod claims;
mod decode;
mod header;
mod sign;
mod validation;
mod verify;

pub use algorithm::JWTAlgorithm;
pub use claims::Claims;
pub use decode::jwt_decode_header;
pub use header::JWTHeader;
pub use sign::{jwt_sign, jwt_sign_sync};
pub use validation::JWTValidation;
pub use verify::{jwt_verify, jwt_verify_sync};
