//! Volcengine OpenAPI Signature Version 4 (`HMAC-SHA256`) for a prepared request.
//!
//! Volcengine Visual Intelligence (`visual.volcengineapi.com`) signs the final
//! wire body bytes with `X-Date`, `X-Content-Sha256`, optional
//! `X-Security-Token`, and an `HMAC-SHA256` key chain derived directly from
//! `secret_access_key` (`date -> region -> service -> "request"`).

use std::time::{SystemTime, UNIX_EPOCH};

use hmac::{Hmac, KeyInit, Mac};
use serde::Deserialize;
use sha2::{Digest, Sha256};

use super::error::StreamError;
use super::spec::UpstreamSpec;

/// Credentials and scope that sign one Volcengine OpenAPI request.
#[derive(Clone, Deserialize)]
pub(crate) struct VolcengineSigV4Spec {
    access_key_id: String,
    secret_access_key: String,
    #[serde(default)]
    session_token: Option<String>,
    region: String,
    service: String,
}

// Secrets never appear in formatted debug output.
impl std::fmt::Debug for VolcengineSigV4Spec {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("VolcengineSigV4Spec")
            .field("access_key_id", &self.access_key_id)
            .field("region", &self.region)
            .field("service", &self.service)
            .finish_non_exhaustive()
    }
}

const SIGNED_HEADERS: [&str; 4] = [
    "content-type",
    "x-content-sha256",
    "x-date",
    "x-security-token",
];

/// Adds `x-date`, `x-content-sha256`, optional `x-security-token`, and
/// `authorization` to `upstream`.
pub(crate) fn sign(
    upstream: &mut UpstreamSpec,
    credentials: &VolcengineSigV4Spec,
    now: SystemTime,
) -> Result<(), StreamError> {
    let url = url::Url::parse(&upstream.url).map_err(|reason| {
        StreamError::new(
            "invalid_spec",
            "request_builder",
            format!("Volcengine request URL is invalid: {reason}"),
        )
    })?;
    let seconds = now
        .duration_since(UNIX_EPOCH)
        .map_or(0, |since| since.as_secs());
    let timestamp = utc_timestamp(seconds);
    let date = &timestamp[..8];
    let payload_hash = hex::encode(Sha256::digest(upstream.payload_bytes()));

    upstream
        .headers
        .push(("x-date".to_string(), timestamp.clone()));
    upstream
        .headers
        .push(("x-content-sha256".to_string(), payload_hash.clone()));
    if let Some(token) = credentials
        .session_token
        .as_deref()
        .filter(|token| !token.is_empty())
    {
        upstream
            .headers
            .push(("x-security-token".to_string(), token.to_string()));
    }

    let host = match url.port() {
        Some(port) => format!("{}:{port}", url.host_str().unwrap_or_default()),
        None => url.host_str().unwrap_or_default().to_string(),
    };
    let mut headers = vec![("host".to_string(), host)];
    for (name, value) in &upstream.headers {
        let name = name.to_ascii_lowercase();
        if SIGNED_HEADERS.contains(&name.as_str()) {
            headers.push((name, value.split_whitespace().collect::<Vec<_>>().join(" ")));
        }
    }
    headers.sort();
    headers.dedup_by(|left, right| left.0 == right.0);

    let signed_headers = headers
        .iter()
        .map(|(name, _value)| name.as_str())
        .collect::<Vec<_>>()
        .join(";");
    let canonical_headers: String = headers
        .iter()
        .map(|(name, value)| format!("{name}:{value}\n"))
        .collect();
    let canonical_uri = if url.path().is_empty() {
        "/"
    } else {
        url.path()
    };
    let canonical_request = format!(
        "{}\n{}\n{}\n{canonical_headers}\n{signed_headers}\n{payload_hash}",
        upstream.method.to_ascii_uppercase(),
        canonical_uri,
        canonical_query(&url)
    );

    let scope = format!(
        "{date}/{}/{}/request",
        credentials.region, credentials.service
    );
    let string_to_sign = format!(
        "HMAC-SHA256\n{timestamp}\n{scope}\n{}",
        hex::encode(Sha256::digest(canonical_request))
    );

    let mut key = hmac(credentials.secret_access_key.as_bytes(), date);
    for part in [
        credentials.region.as_str(),
        credentials.service.as_str(),
        "request",
    ] {
        key = hmac(&key, part);
    }
    let signature = hex::encode(hmac(&key, &string_to_sign));

    upstream.headers.push((
        "authorization".to_string(),
        format!(
            "HMAC-SHA256 Credential={}/{scope}, SignedHeaders={signed_headers}, Signature={signature}",
            credentials.access_key_id
        ),
    ));
    Ok(())
}

fn hmac(key: &[u8], message: &str) -> Vec<u8> {
    let mut mac = Hmac::<Sha256>::new_from_slice(key).expect("HMAC accepts a key of any length");
    mac.update(message.as_bytes());
    mac.finalize().into_bytes().to_vec()
}

fn canonical_query(url: &url::Url) -> String {
    let mut pairs: Vec<(String, String)> = url
        .query_pairs()
        .map(|(name, value)| (percent_encode(&name), percent_encode(&value)))
        .collect();
    pairs.sort();
    pairs
        .iter()
        .map(|(name, value)| format!("{name}={value}"))
        .collect::<Vec<_>>()
        .join("&")
}

fn percent_encode(text: &str) -> String {
    text.bytes()
        .map(|byte| match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                (byte as char).to_string()
            }
            _ => format!("%{byte:02X}"),
        })
        .collect()
}

fn utc_timestamp(seconds: u64) -> String {
    let (days, rest) = (seconds / 86_400, seconds % 86_400);
    let shifted = days as i64 + 719_468;
    let era = shifted.div_euclid(146_097);
    let day_of_era = shifted.rem_euclid(146_097);
    let year_of_era =
        (day_of_era - day_of_era / 1_460 + day_of_era / 36_524 - day_of_era / 146_096) / 365;
    let day_of_year = day_of_era - (365 * year_of_era + year_of_era / 4 - year_of_era / 100);
    let month_index = (5 * day_of_year + 2) / 153;
    let day = day_of_year - (153 * month_index + 2) / 5 + 1;
    let month = if month_index < 10 {
        month_index + 3
    } else {
        month_index - 9
    };
    let year = year_of_era + era * 400 + i64::from(month <= 2);

    format!(
        "{year:04}{month:02}{day:02}T{:02}{:02}{:02}Z",
        rest / 3_600,
        rest % 3_600 / 60,
        rest % 60
    )
}

#[cfg(test)]
mod tests {
    use std::time::Duration;

    use super::*;

    #[test]
    fn signs_volcengine_visual_form_request_with_payload_bytes() {
        let credentials = VolcengineSigV4Spec {
            access_key_id: "AKLTMjYx".to_string(),
            secret_access_key: "sk-volc-secret".to_string(),
            session_token: Some("sts-token".to_string()),
            region: "cn-north-1".to_string(),
            service: "cv".to_string(),
        };
        let spec = serde_json::json!({
            "kind": "http_sse",
            "method": "POST",
            "url": "https://visual.volcengineapi.com/?Version=2020-08-26&Action=OCRNormal",
            "headers": [["content-type", "application/x-www-form-urlencoded"]]
        });
        let mut upstream: UpstreamSpec = serde_json::from_value(spec).unwrap();
        upstream.body_bytes = Some(b"image_base64=aVZCT1J3MA%3D%3D".to_vec());

        sign(
            &mut upstream,
            &credentials,
            UNIX_EPOCH + Duration::from_secs(1_700_000_000),
        )
        .unwrap();

        let header = |name: &str| {
            upstream
                .headers
                .iter()
                .find(|(header, _)| header.eq_ignore_ascii_case(name))
                .map(|(_, value)| value.as_str())
                .unwrap()
        };

        assert_eq!(header("x-date"), "20231114T221320Z");
        assert_eq!(
            header("x-content-sha256"),
            "32ea6dba31d71a72e8702d77ebc1c58a2b07f01986f0eca4a3c45be0fdf0d3b2"
        );
        assert_eq!(header("x-security-token"), "sts-token");
        assert_eq!(
            header("authorization"),
            "HMAC-SHA256 Credential=AKLTMjYx/20231114/cn-north-1/cv/request, SignedHeaders=content-type;host;x-content-sha256;x-date;x-security-token, Signature=362c622be5b3d90137f20d9edadb713fe2aa219dca8098086e3f34de087864c8"
        );
        assert!(!format!("{credentials:?}").contains("sk-volc-secret"));
    }
}
