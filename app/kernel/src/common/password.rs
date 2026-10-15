use argon2::Argon2;
use argon2::password_hash::{
    Error as PasswordHashError, PasswordHasher, PasswordVerifier, phc::PasswordHash,
};

use crate::common::{KernelError, KernelResult};

pub fn argon2id_hash(password: &str) -> KernelResult<String> {
    Argon2::default()
        .hash_password(password.as_bytes())
        .map(|hash| hash.to_string())
        .map_err(|error| KernelError::new(format!("argon2id hash failed: {error}")))
}

pub fn argon2id_verify(password: &str, phc_hash: &str) -> KernelResult<bool> {
    let parsed = PasswordHash::new(phc_hash)
        .map_err(|error| KernelError::new(format!("invalid password hash: {error}")))?;

    match Argon2::default().verify_password(password.as_bytes(), &parsed) {
        Ok(()) => Ok(true),
        Err(PasswordHashError::PasswordInvalid) => Ok(false),
        Err(error) => Err(KernelError::new(format!("argon2id verify failed: {error}"))),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn verifies_existing_phc_hashes() {
        // Argon2id test vector from argon2 0.5.3.
        let hash = "$argon2id$v=19$m=65536,t=2,p=1$c29tZXNhbHQ$CTFhFdXPJO1aFaMaO6Mm5c8y7cJHAph8ArZWb2GRPPc";

        assert!(argon2id_verify("password", hash).unwrap());
        assert!(!argon2id_verify("wrong password", hash).unwrap());
    }
}
