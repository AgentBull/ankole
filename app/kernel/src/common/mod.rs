//! Host-neutral kernel primitives shared by N-API and Rustler bindings.

pub(crate) mod bounded_cache;
mod crypto;
mod diff;
mod encoding;
mod error;
mod hash;
mod ids;
mod jwt;
mod password;
mod phone;
mod search;
mod token;
mod transliteration;
mod web_url;
mod zstd_block;

pub use crypto::{aead_decrypt, aead_encrypt, derive_key, generate_key};
pub use diff::unified_text_diff;
pub use encoding::{base64_url_safe_decode, base64_url_safe_encode};
pub use error::{KernelError, KernelResult};
pub use hash::{generic_hash, xxh3_128_file_hex, xxh3_128_hex};
pub use ids::{gen_uuid, gen_uuid_v7};
pub use jwt::{jwt_sign, jwt_sign_pem, jwt_verify, jwt_verify_jwk};
pub use password::{argon2id_hash, argon2id_verify};
pub use phone::phone_normalize_e164;
pub use search::{ReciprocalRankFusionResult, reciprocal_rank_fusion};
pub use token::estimate_o200k_base_tokens;
pub use transliteration::any_ascii;
pub use web_url::{HostClass, WebURLFacts, web_url_facts};
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
    fn argon2id_hash_round_trips_and_rejects_wrong_passwords() {
        let hash = argon2id_hash("correct horse battery staple").unwrap();

        assert!(hash.starts_with("$argon2id$v=19$"));
        assert!(argon2id_verify("correct horse battery staple", &hash).unwrap());
        assert!(!argon2id_verify("wrong password", &hash).unwrap());
    }

    #[test]
    fn argon2id_hash_generates_a_new_salt_per_call() {
        let first = argon2id_hash("same password").unwrap();
        let second = argon2id_hash("same password").unwrap();

        assert_ne!(first, second);
        assert!(argon2id_verify("same password", &first).unwrap());
        assert!(argon2id_verify("same password", &second).unwrap());
    }

    #[test]
    fn argon2id_verify_rejects_malformed_hash_strings() {
        assert!(argon2id_verify("password", "not a phc string").is_err());
        assert!(argon2id_verify("password", "$argon2id$v=19$not*valid*salt").is_err());
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

    // Throwaway 2048-bit RSA pair generated for this test; it protects nothing.
    const TEST_RSA_PRIVATE_KEY_PEM: &str = "-----BEGIN PRIVATE KEY-----
MIIEvAIBADANBgkqhkiG9w0BAQEFAASCBKYwggSiAgEAAoIBAQC+gCGds9mjKTXp
QnkwFc1fTxxdhHe7YBBUJf+vLMMS0pTL49TOTb0xJ/fZ/QB1iN0KppO9rxdzxWDv
sN4HM1UaIPEpmBjY+nevh7Ta9kdKQgXlpZd87Otz5kewmqE6Z/WFET0uMCjpnB7j
xnJ4f0xooXQFtXnJTxZbd53Q6CUKBFPE7WiKAh5HCteuJnQgOcEdqRjRelcBxEIE
d8KoDshIsSzyoD68AGGVBnQbaRqoYnyHULjGgHapqyIqoa7zPv/dHIfYzXhRRJcb
+klyqde7hfNAtbmJxaxpOAwdB7uSL+7YV9V1Aqx0NtgGkefSmT+vWtoWYSzeYMBP
jEC9FlOFAgMBAAECggEAVRS47swiiaKgN1u+8GDsZoLYslO1ffQ7lrmZ5kzhmwh9
+En7A2Do/IlTQwKiL9w+jME0/uSyXrxqvOKLZz/f5FmOG/uYLWBAEB9WAO05jcrL
A3PfoqXVyt+waQnGtGU13IaEgppzy1I04ZoCChsgryJcxSf2CpjN7XARBfqIgF4D
YncHS9JkTgtiC8ojHgmf302uWtbdofNjqbjG/VoP+KzJu9OsTtbn/p7ktmgWhviO
Jqmqs5b/LQq3laHrYFB7fViurG3XHozRL8aQ4R7MnlaclwB5th1SQcBV5q++7t87
5qyy/uld/iFPZmC3TfIO/DM3Jg+e7xEyBuM4bFgRyQKBgQD8OOkNSwvjVfW/80IV
DPxixFxj2z1lunbzY5YxOn/yqXmvMpfCNl2qc8o1TfUBrjVOe/N/HL0HtPEwXbS2
T0QzRUPccpi29HELQR67yP0r+z6u8Rbq/v7W4B7Wjd99yfTE+jw2q77rPevUW53p
nYkKDDqV1xIC2iXA9DwpzdRjFwKBgQDBWpAI3gEyYlkMrqDcUY7vnUdW+Js40KAM
ldJ3SxbBcmUSljtRYakpp/iJ1UzxDO+vP9w1HyO0VIPjR2BOhpgFlaiHz2Z9a0aL
BxAYNGQvXuxDgn8EXFxNfQqEylqxR0s2+FvNbJHZmcufNlA3Gp7Z578jMXLW+Xi3
4eNGo9OPwwKBgA4d0U1hKeUrZnm7z7MF6wpMGy+rkaAj84xjwoA22fpm6dyYZE4G
ZO+pU2PwXQofCfS+kz5GCX5o7iba18ZsYVDNS6MG9u0meT08A9BWy3Suty9rZvD4
HKNCH/e6MQwFRaHQr5YPvrvD13MnPYtZudXKIW1JgESQmRRXlxZv4rc5AoGAblvg
Zg9Ao59asFBj5Bxw9vbQJyXSgsUg9M32yLwFCvjeE5PH25VgVjRXOWSTe+okS+Sp
LXDOkjjC5lBw+aD82AMppAqOtvsp0mR/nTEaFaeaNpYfJUAKNvgtrslIpnLIzWFI
FKHpRUfw3rjDZBA/pqQNhmrM30KY0muNq14KfL0CgYAh2PBtHyY09Or7uLkPr8kG
zsgVAle6vjE4r3s5cNO5hkqQs2kkfCklHZWFbDZ26r5hwmFHlbgF9X/K+JTPrZVh
9f2PcI2LK9M1y/YkgTx+qSc0ROLtMrfKz6XOX6WSBwl2CY2XYJh6gRwvWG88mjJ+
WcIZW/EN2+olnpMjA71EXA==
-----END PRIVATE KEY-----";

    const TEST_RSA_JWK_N: &str = "voAhnbPZoyk16UJ5MBXNX08cXYR3u2AQVCX_ryzDEtKUy-PUzk29MSf32f0AdYjdCqaTva8Xc8Vg77DeBzNVGiDxKZgY2Pp3r4e02vZHSkIF5aWXfOzrc-ZHsJqhOmf1hRE9LjAo6Zwe48ZyeH9MaKF0BbV5yU8WW3ed0OglCgRTxO1oigIeRwrXriZ0IDnBHakY0XpXAcRCBHfCqA7ISLEs8qA-vABhlQZ0G2kaqGJ8h1C4xoB2qasiKqGu8z7_3RyH2M14UUSXG_pJcqnXu4XzQLW5icWsaTgMHQe7ki_u2FfVdQKsdDbYBpHn0pk_r1raFmEs3mDAT4xAvRZThQ";

    fn rs256_token(claims: &serde_json::Value) -> String {
        let header = jsonwebtoken::Header::new(jsonwebtoken::Algorithm::RS256);
        let key = jsonwebtoken::EncodingKey::from_rsa_pem(TEST_RSA_PRIVATE_KEY_PEM.as_bytes())
            .expect("test rsa pem is valid");
        jsonwebtoken::encode(&header, claims, &key).expect("test rs256 token encodes")
    }

    fn test_rsa_jwk() -> String {
        format!(r#"{{"kty":"RSA","kid":"test-key-1","n":"{TEST_RSA_JWK_N}","e":"AQAB"}}"#)
    }

    #[test]
    fn jwt_verify_jwk_accepts_valid_rs256_token() {
        let token = rs256_token(&serde_json::json!({
            "iss": "https://api.botframework.com",
            "aud": "11111111-2222-3333-4444-555555555555",
            "serviceUrl": "https://smba.trafficmanager.net/teams/",
            "exp": 4_102_444_800u64
        }));

        let claims = jwt_verify_jwk(
            &token,
            &test_rsa_jwk(),
            r#"{"algorithms":["RS256"],"iss":["https://api.botframework.com"],"aud":["11111111-2222-3333-4444-555555555555"]}"#,
        )
        .unwrap();
        let claims: serde_json::Value = serde_json::from_str(&claims).unwrap();

        assert_eq!(
            claims["serviceUrl"],
            "https://smba.trafficmanager.net/teams/"
        );
    }

    #[test]
    fn jwt_sign_pem_round_trips_through_jwk_verification() {
        let token = jwt_sign_pem(
            r#"{"iss":"sa@project.iam.gserviceaccount.com","sub":"admin@example.com","scope":"https://www.googleapis.com/auth/admin.directory.user.readonly","aud":"https://oauth2.googleapis.com/token","iat":1000000000,"exp":4102444800}"#,
            TEST_RSA_PRIVATE_KEY_PEM,
            r#"{"algorithm":"RS256","key_id":"sa-key-1"}"#,
        )
        .unwrap();

        // The kid travels in the protected header.
        let header = jsonwebtoken::decode_header(&token).expect("token header decodes");
        assert_eq!(header.alg, jsonwebtoken::Algorithm::RS256);
        assert_eq!(header.kid.as_deref(), Some("sa-key-1"));

        let claims = jwt_verify_jwk(
            &token,
            &test_rsa_jwk(),
            r#"{"algorithms":["RS256"],"iss":["sa@project.iam.gserviceaccount.com"],"aud":["https://oauth2.googleapis.com/token"]}"#,
        )
        .unwrap();
        let claims: serde_json::Value = serde_json::from_str(&claims).unwrap();

        assert_eq!(claims["sub"], "admin@example.com");
        assert_eq!(
            claims["scope"],
            "https://www.googleapis.com/auth/admin.directory.user.readonly"
        );
    }

    #[test]
    fn jwt_sign_pem_rejects_bad_keys_and_hmac_algorithms() {
        let claims = r#"{"aud":"https://oauth2.googleapis.com/token","exp":4102444800}"#;

        // HMAC algorithms are not accepted on the PEM path.
        assert!(
            jwt_sign_pem(claims, TEST_RSA_PRIVATE_KEY_PEM, r#"{"algorithm":"HS256"}"#).is_err()
        );

        // A non-PEM key is rejected before signing.
        assert!(jwt_sign_pem(claims, "not a pem key", r#"{"algorithm":"RS256"}"#).is_err());

        // The header defaults to RS256 when no algorithm is given.
        let token = jwt_sign_pem(claims, TEST_RSA_PRIVATE_KEY_PEM, r#"{}"#).unwrap();
        let header = jsonwebtoken::decode_header(&token).expect("token header decodes");
        assert_eq!(header.alg, jsonwebtoken::Algorithm::RS256);
    }

    #[test]
    fn jwt_verify_jwk_rejects_invalid_tokens_keys_and_algorithms() {
        let token = rs256_token(&serde_json::json!({
            "iss": "https://api.botframework.com",
            "aud": "11111111-2222-3333-4444-555555555555",
            "exp": 4_102_444_800u64
        }));
        let jwk = test_rsa_jwk();

        // Wrong audience.
        assert!(
            jwt_verify_jwk(
                &token,
                &jwk,
                r#"{"algorithms":["RS256"],"aud":["other-app"]}"#
            )
            .is_err()
        );

        // HMAC algorithms are not accepted on the JWK path.
        assert!(jwt_verify_jwk(&token, &jwk, r#"{"algorithms":["HS256"]}"#).is_err());

        // Tampered payload (JWT payloads start with base64url "eyJ").
        let parts: Vec<&str> = token.split('.').collect();
        let tampered = format!("{}.f{}.{}", parts[0], &parts[1][1..], parts[2]);
        assert!(jwt_verify_jwk(&tampered, &jwk, r#"{"algorithms":["RS256"]}"#).is_err());

        // Expired token.
        let expired = rs256_token(&serde_json::json!({
            "aud": "11111111-2222-3333-4444-555555555555",
            "exp": 946_684_800u64
        }));
        assert!(jwt_verify_jwk(&expired, &jwk, r#"{"algorithms":["RS256"]}"#).is_err());

        // Non-RSA keys are rejected.
        assert!(
            jwt_verify_jwk(
                &token,
                r#"{"kty":"EC","crv":"P-256","x":"x","y":"y"}"#,
                r#"{"algorithms":["RS256"]}"#
            )
            .is_err()
        );
    }
}
