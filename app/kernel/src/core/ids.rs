use uuid::Uuid;

const BASE36_DIGITS: &[u8; 36] = b"0123456789abcdefghijklmnopqrstuvwxyz";

/// Generates a random UUIDv4 and returns it as lowercase Base36 text.
///
/// This gives a compact, URL-friendly identifier when callers do not need
/// timestamp ordering or the standard hyphenated UUID shape.
pub fn gen_base36_uuid() -> String {
    encode_base36(Uuid::new_v4().as_u128())
}

/// Generates a random UUIDv4 and returns its raw bytes in Base58 form.
pub fn gen_short_uuid() -> String {
    shorten_uuid(Uuid::new_v4())
}

/// Generates a standard hyphenated UUIDv4 string.
pub fn gen_uuid() -> String {
    Uuid::new_v4().to_string()
}

/// Generates a standard hyphenated UUIDv7 string for time-sortable identifiers.
pub fn gen_uuid_v7() -> String {
    Uuid::now_v7().to_string()
}

/// Encodes a `u128` as Base36 without allocating intermediate big integers.
///
/// A UUID fits in at most 26 Base36 digits, so a fixed stack buffer is enough.
/// Writing from the end avoids reversing a temporary vector after division.
fn encode_base36(mut value: u128) -> String {
    if value == 0 {
        return "0".to_owned();
    }

    let mut buffer = [0_u8; 26];
    let mut cursor = buffer.len();

    while value > 0 {
        cursor -= 1;
        buffer[cursor] = BASE36_DIGITS[(value % 36) as usize];
        value /= 36;
    }

    std::str::from_utf8(&buffer[cursor..])
        .expect("base36 digit table is valid ASCII")
        .to_owned()
}

/// Encodes UUID bytes as Base58 for the short UUID helper.
fn shorten_uuid(uuid: Uuid) -> String {
    bs58::encode(uuid.as_bytes()).into_string()
}
