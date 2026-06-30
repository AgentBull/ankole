//! Host-neutral kernel primitives shared by N-API and Rustler bindings.

mod crypto;
mod encoding;
mod error;
mod ids;
mod jwt;
mod phone;
mod zstd_block;

pub use crypto::{aead_decrypt, aead_encrypt, derive_key, generate_key};
pub use encoding::{
    any_ascii, base58_decode, base58_encode, base64_url_safe_decode, base64_url_safe_encode,
    bs58_hash, crc32, crc32_hex, generic_hash, xxh3_128_file_hex, xxh3_128_hex,
};
pub use error::{KernelError, KernelResult};
pub use ids::{gen_base36_uuid, gen_short_uuid, gen_uuid, gen_uuid_v7};
pub use jwt::{jwt_decode_header, jwt_sign, jwt_verify};
pub use phone::phone_normalize_e164;
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
            bs58_hash(b"bullx", None).unwrap(),
            "9ZWpCkNYVXH91wFYb4cygXBxLe2xwsK9rBTVxwPMicWZ"
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
        assert_eq!(base58_encode(b"Hello World!"), "2NEpo7TZRRrLZSi2U");
        assert_eq!(base58_decode("2NEpo7TZRRrLZSi2U").unwrap(), b"Hello World!");
        assert_eq!(base64_url_safe_encode(b"bullx"), "YnVsbHg");
        assert_eq!(base64_url_safe_decode("YnVsbHg").unwrap(), b"bullx");
    }

    #[test]
    fn text_crc_and_uuid_helpers_match_expected_shapes() {
        assert_eq!(any_ascii("Björk"), "Bjork");
        assert_eq!(crc32("TestCase😊".as_bytes(), None), 1_198_634_863);
        assert_eq!(crc32_hex("TestCase😊".as_bytes(), None), "4771b76f");
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
        assert!(
            gen_base36_uuid()
                .chars()
                .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit())
        );
        assert!(
            gen_short_uuid()
                .chars()
                .all(|c| "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz".contains(c))
        );
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

        let header = jwt_decode_header(&token).unwrap();
        let header: serde_json::Value = serde_json::from_str(&header).unwrap();
        assert_eq!(header["algorithm"], "HS256");
        assert_eq!(header["key_id"], "test-key");
    }
}
