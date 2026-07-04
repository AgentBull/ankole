use uuid::Uuid;

/// Generates a standard hyphenated UUIDv4 string.
pub fn gen_uuid() -> String {
    Uuid::new_v4().to_string()
}

/// Generates a standard hyphenated UUIDv7 string for time-sortable identifiers.
pub fn gen_uuid_v7() -> String {
    Uuid::now_v7().to_string()
}
