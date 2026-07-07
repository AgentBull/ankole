//! Host-neutral kernel primitives shared by N-API and Rustler bindings.

pub(crate) mod bounded_cache;
mod crypto;
mod diff;
mod encoding;
mod error;
mod hash;
mod ids;
mod jwt;
mod phone;
mod token;
mod zstd_block;

pub use crypto::{aead_decrypt, aead_encrypt, derive_key, generate_key};
pub use diff::unified_text_diff;
pub use encoding::{base64_url_safe_decode, base64_url_safe_encode};
pub use error::{KernelError, KernelResult};
pub use hash::{generic_hash, xxh3_128_file_hex, xxh3_128_hex};
pub use ids::{gen_uuid, gen_uuid_v7};
pub use jwt::{jwt_sign, jwt_verify};
pub use phone::phone_normalize_e164;
pub use token::estimate_o200k_base_tokens;
pub use zstd_block::{zstd_compress_block, zstd_decompress_block};

#[cfg(test)]
mod tests {
    use super::*;

    const AEAD_KEY: &str = "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f";
    const AEAD_CIPHERTEXT: &str = "vveE4WxRjp0KO8YVx7o09aQ5_q9ZzqX2.gb1S9PmqEp_5UuejAzvKErXrdE4-sQ";

    #[test]
    fn hash_vectors_match_existing_native_addons() {
        assert_eq!(
            generic_hash(b"bullx", None).unwrap(),
            "7f31cabae40697f9404428671c582d3c1f80c8a13d0741f4be8c9b856fcc0706"
        );
        assert_eq!(
            derive_key(b"seed", "tenant-A", Some("scope-a")),
            "0553f445a2fb3dfc0fab4efa1e1ed31ef6a103277286cf63874904e341ee0d20"
        );
    }

    #[test]
    fn aead_round_trip_preserves_binary_payloads() {
        let encrypted = aead_encrypt(b"api-key-\0-with-bytes", AEAD_KEY).unwrap();

        assert_eq!(
            aead_decrypt(&encrypted, AEAD_KEY).unwrap(),
            b"api-key-\0-with-bytes"
        );
        assert_eq!(aead_decrypt(AEAD_CIPHERTEXT, AEAD_KEY).unwrap(), b"secret");
    }

    #[test]
    fn encoding_vectors_match_existing_native_addons() {
        assert_eq!(base64_url_safe_encode(b"bullx"), "YnVsbHg");
        assert_eq!(base64_url_safe_decode("YnVsbHg").unwrap(), b"bullx");
    }

    #[test]
    fn text_crc_and_uuid_helpers_match_expected_shapes() {
        assert_eq!(
            xxh3_128_hex(b"TestCase"),
            "7b16fe7c3e492b87d9615265f0856cec"
        );
        assert_eq!(
            phone_normalize_e164("+1 415 555 2671").unwrap(),
            "+14155552671"
        );
        assert!(phone_normalize_e164("13800000000").is_err());
        assert_eq!(generate_key().len(), 64);
        assert!(gen_uuid().contains('-'));
        assert!(gen_uuid_v7().contains("-7"));
    }

    #[test]
    fn o200k_base_token_estimator_counts_known_text() {
        assert_eq!(estimate_o200k_base_tokens("Hello world"), 2);
        assert!(estimate_o200k_base_tokens("记忆系统") > 0);
    }

    #[test]
    fn jwt_helpers_sign_verify_and_decode_header() {
        let key = b"jwt-secret";
        let token = jwt_sign(
            r#"{"iss":"ankole.control_plane","aud":"ankole.web_console","sub":"human-1","exp":4102444800,"token_use":"access"}"#,
            key,
            r#"{"algorithm":"HS256","key_id":"test-key"}"#,
        )
        .unwrap();

        let claims = jwt_verify(
            &token,
            key,
            r#"{"algorithms":["HS256"],"iss":["ankole.control_plane"],"aud":["ankole.web_console"],"sub":"human-1"}"#,
        )
        .unwrap();
        let claims: serde_json::Value = serde_json::from_str(&claims).unwrap();

        assert_eq!(claims["sub"], "human-1");
        assert_eq!(claims["token_use"], "access");
    }
}
