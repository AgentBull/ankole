use argon2::Argon2;
use argon2::password_hash::{
    Error as PasswordHashError, PasswordHash, PasswordHasher, PasswordVerifier, SaltString,
};

use crate::common::{KernelError, KernelResult};

/// Hashes a password with Argon2id and returns a PHC-format string.
///
/// Each call generates a new random salt, so equal passwords produce
/// different strings. The string embeds the algorithm, version, parameters,
/// salt, and digest, so verification needs no other stored state.
pub fn argon2id_hash(password: &str) -> KernelResult<String> {
    let salt_bytes: [u8; 16] = rand::random();
    let salt = SaltString::encode_b64(&salt_bytes)
        .map_err(|error| KernelError::new(format!("argon2id salt failed: {error}")))?;

    Argon2::default()
        .hash_password(password.as_bytes(), &salt)
        .map(|hash| hash.to_string())
        .map_err(|error| KernelError::new(format!("argon2id hash failed: {error}")))
}

/// Verifies a password against a PHC-format Argon2id hash string.
///
/// Returns `false` for a password that does not match and an error for a
/// hash string that is not a valid PHC string.
pub fn argon2id_verify(password: &str, phc_hash: &str) -> KernelResult<bool> {
    let parsed = PasswordHash::new(phc_hash)
        .map_err(|error| KernelError::new(format!("invalid password hash: {error}")))?;

    match Argon2::default().verify_password(password.as_bytes(), &parsed) {
        Ok(()) => Ok(true),
        Err(PasswordHashError::Password) => Ok(false),
        Err(error) => Err(KernelError::new(format!("argon2id verify failed: {error}"))),
    }
}
