use napi_derive::napi;

#[napi(string_enum, js_name = "JWTAlgorithm")]
#[derive(Clone, Copy, Default)]
pub enum JWTAlgorithm {
  /// HMAC using SHA-256
  #[default]
  HS256,
  /// HMAC using SHA-384
  HS384,
  /// HMAC using SHA-512
  HS512,
  /// ECDSA using SHA-256
  ES256,
  /// ECDSA using SHA-384
  ES384,
  /// RSASSA-PKCS1-v1_5 using SHA-256
  RS256,
  /// RSASSA-PKCS1-v1_5 using SHA-384
  RS384,
  /// RSASSA-PKCS1-v1_5 using SHA-512
  RS512,
  /// RSASSA-PSS using SHA-256
  PS256,
  /// RSASSA-PSS using SHA-384
  PS384,
  /// RSASSA-PSS using SHA-512
  PS512,
  /// Edwards-curve Digital Signature Algorithm (EdDSA)
  EdDSA,
}

impl From<JWTAlgorithm> for jsonwebtoken::Algorithm {
  #[inline]
  fn from(value: JWTAlgorithm) -> Self {
    match value {
      JWTAlgorithm::ES256 => jsonwebtoken::Algorithm::ES256,
      JWTAlgorithm::ES384 => jsonwebtoken::Algorithm::ES384,
      JWTAlgorithm::EdDSA => jsonwebtoken::Algorithm::EdDSA,
      JWTAlgorithm::HS256 => jsonwebtoken::Algorithm::HS256,
      JWTAlgorithm::HS384 => jsonwebtoken::Algorithm::HS384,
      JWTAlgorithm::HS512 => jsonwebtoken::Algorithm::HS512,
      JWTAlgorithm::PS256 => jsonwebtoken::Algorithm::PS256,
      JWTAlgorithm::PS384 => jsonwebtoken::Algorithm::PS384,
      JWTAlgorithm::PS512 => jsonwebtoken::Algorithm::PS512,
      JWTAlgorithm::RS256 => jsonwebtoken::Algorithm::RS256,
      JWTAlgorithm::RS384 => jsonwebtoken::Algorithm::RS384,
      JWTAlgorithm::RS512 => jsonwebtoken::Algorithm::RS512,
    }
  }
}

impl From<jsonwebtoken::Algorithm> for JWTAlgorithm {
  #[inline]
  fn from(value: jsonwebtoken::Algorithm) -> Self {
    match value {
      jsonwebtoken::Algorithm::ES256 => JWTAlgorithm::ES256,
      jsonwebtoken::Algorithm::ES384 => JWTAlgorithm::ES384,
      jsonwebtoken::Algorithm::EdDSA => JWTAlgorithm::EdDSA,
      jsonwebtoken::Algorithm::HS256 => JWTAlgorithm::HS256,
      jsonwebtoken::Algorithm::HS384 => JWTAlgorithm::HS384,
      jsonwebtoken::Algorithm::HS512 => JWTAlgorithm::HS512,
      jsonwebtoken::Algorithm::PS256 => JWTAlgorithm::PS256,
      jsonwebtoken::Algorithm::PS384 => JWTAlgorithm::PS384,
      jsonwebtoken::Algorithm::PS512 => JWTAlgorithm::PS512,
      jsonwebtoken::Algorithm::RS256 => JWTAlgorithm::RS256,
      jsonwebtoken::Algorithm::RS384 => JWTAlgorithm::RS384,
      jsonwebtoken::Algorithm::RS512 => JWTAlgorithm::RS512,
    }
  }
}
