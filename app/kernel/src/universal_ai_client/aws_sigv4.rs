//! AWS Signature Version 4 for a prepared request.
//!
//! The signature covers the request's final body bytes, which the request
//! builder produces, so the kernel signs after it has built the body.

use std::time::{SystemTime, UNIX_EPOCH};

use hmac::{Hmac, KeyInit, Mac};
use serde::Deserialize;
use sha2::{Digest, Sha256};

use super::error::StreamError;
use super::spec::UpstreamSpec;

/// The credentials and the scope that sign one AWS request.
#[derive(Clone, Deserialize)]
pub(crate) struct AwsSigV4Spec {
    access_key_id: String,
    secret_access_key: String,
    #[serde(default)]
    session_token: Option<String>,
    region: String,
    service: String,
}

// The secret never reaches a log line.
impl std::fmt::Debug for AwsSigV4Spec {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("AwsSigV4Spec")
            .field("access_key_id", &self.access_key_id)
            .field("region", &self.region)
            .field("service", &self.service)
            .finish_non_exhaustive()
    }
}

/// The headers that the signature covers when the request carries them. AWS
/// requires `host` and every `x-amz-*` header, and `content-type` if present.
const SIGNED_HEADERS: [&str; 3] = ["content-type", "x-amz-security-token", "x-amz-target"];

/// Adds `x-amz-date`, the session token, and `authorization` to `upstream`.
pub(crate) fn sign(
    upstream: &mut UpstreamSpec,
    credentials: &AwsSigV4Spec,
    now: SystemTime,
) -> Result<(), StreamError> {
    let url = url::Url::parse(&upstream.url).map_err(|reason| {
        StreamError::new(
            "invalid_spec",
            "request_builder",
            format!("AWS request URL is invalid: {reason}"),
        )
    })?;
    let seconds = now
        .duration_since(UNIX_EPOCH)
        .map_or(0, |since| since.as_secs());
    let timestamp = amz_timestamp(seconds);
    let date = &timestamp[..8];

    upstream
        .headers
        .push(("x-amz-date".to_string(), timestamp.clone()));
    if let Some(token) = credentials
        .session_token
        .as_deref()
        .filter(|token| !token.is_empty())
    {
        upstream
            .headers
            .push(("x-amz-security-token".to_string(), token.to_string()));
    }

    let host = match url.port() {
        Some(port) => format!("{}:{port}", url.host_str().unwrap_or_default()),
        None => url.host_str().unwrap_or_default().to_string(),
    };
    let mut headers = vec![
        ("host".to_string(), host),
        ("x-amz-date".to_string(), timestamp.clone()),
    ];
    for (name, value) in &upstream.headers {
        let name = name.to_ascii_lowercase();
        if SIGNED_HEADERS.contains(&name.as_str()) {
            headers.push((name, value.split_whitespace().collect::<Vec<_>>().join(" ")));
        }
    }
    headers.sort();

    let signed_headers = headers
        .iter()
        .map(|(name, _value)| name.as_str())
        .collect::<Vec<_>>()
        .join(";");
    let canonical_headers: String = headers
        .iter()
        .map(|(name, value)| format!("{name}:{value}\n"))
        .collect();
    let payload_hash = hex::encode(Sha256::digest(upstream.body.as_deref().unwrap_or_default()));
    // shortcut: uses the URL's path as it is, which is right for a path of
    // unreserved characters such as `/v1/speech`; encode each segment twice
    // when a service path carries other characters.
    let canonical_request = format!(
        "{}\n{}\n{}\n{canonical_headers}\n{signed_headers}\n{payload_hash}",
        upstream.method,
        url.path(),
        canonical_query(&url)
    );

    let scope = format!(
        "{date}/{}/{}/aws4_request",
        credentials.region, credentials.service
    );
    let string_to_sign = format!(
        "AWS4-HMAC-SHA256\n{timestamp}\n{scope}\n{}",
        hex::encode(Sha256::digest(canonical_request))
    );
    let mut key = hmac(
        format!("AWS4{}", credentials.secret_access_key).as_bytes(),
        date,
    );
    for part in [
        credentials.region.as_str(),
        credentials.service.as_str(),
        "aws4_request",
    ] {
        key = hmac(&key, part);
    }
    let signature = hex::encode(hmac(&key, &string_to_sign));

    upstream.headers.push((
        "authorization".to_string(),
        format!(
            "AWS4-HMAC-SHA256 Credential={}/{scope}, SignedHeaders={signed_headers}, Signature={signature}",
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

// Parameters sorted by name, each name and value percent-encoded.
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

/// Formats seconds since the Unix epoch as `YYYYMMDDTHHMMSSZ`.
fn amz_timestamp(seconds: u64) -> String {
    let (days, rest) = (seconds / 86_400, seconds % 86_400);
    // Days since 1970-01-01 to a civil date, after Howard Hinnant's algorithm.
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

    // The values of the AWS Signature Version 4 test suite.
    fn suite_request(method: &str, headers: &[(&str, &str)], body: Option<&str>) -> String {
        let credentials = AwsSigV4Spec {
            access_key_id: "AKIDEXAMPLE".to_string(),
            secret_access_key: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY".to_string(),
            session_token: None,
            region: "us-east-1".to_string(),
            service: "service".to_string(),
        };
        let spec = serde_json::json!({
            "kind": "http_sse",
            "method": method,
            "url": "https://example.amazonaws.com/",
            "headers": headers,
            "body": body
        });
        let mut upstream: UpstreamSpec = serde_json::from_value(spec).unwrap();

        // 2015-08-30T12:36:00Z
        sign(
            &mut upstream,
            &credentials,
            UNIX_EPOCH + Duration::from_secs(1_440_938_160),
        )
        .unwrap();

        let header = |name: &str| {
            upstream
                .headers
                .iter()
                .find(|(header, _value)| header == name)
                .unwrap()
                .1
                .clone()
        };
        assert_eq!(header("x-amz-date"), "20150830T123600Z");
        header("authorization")
    }

    #[test]
    fn signs_a_request_without_a_body_as_the_aws_test_suite_does() {
        assert_eq!(
            suite_request("GET", &[], None),
            "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request, \
             SignedHeaders=host;x-amz-date, \
             Signature=5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31"
        );
        assert_eq!(
            suite_request("POST", &[], None),
            "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request, \
             SignedHeaders=host;x-amz-date, \
             Signature=5da7c1a2acd57cee7505fc6676e4e544621c30862966e37dddb68e92efbe5d6b"
        );
    }

    #[test]
    fn signs_the_content_type_and_the_body() {
        assert_eq!(
            suite_request(
                "POST",
                &[("Content-Type", "application/x-www-form-urlencoded")],
                Some("Param1=value1")
            ),
            "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request, \
             SignedHeaders=content-type;host;x-amz-date, \
             Signature=ff11897932ad3f4e8b18135d722051e5ac45fc38421b1da7b9d196a0fe09473a"
        );
    }

    #[test]
    fn formats_dates_across_leap_years() {
        assert_eq!(amz_timestamp(0), "19700101T000000Z");
        assert_eq!(amz_timestamp(951_782_400), "20000229T000000Z");
        assert_eq!(amz_timestamp(1_794_355_199), "20261110T235959Z");
    }
}
