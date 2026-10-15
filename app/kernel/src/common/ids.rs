use uuid::Uuid as UUID;

pub fn gen_uuid() -> String {
    UUID::new_v4().to_string()
}

pub fn gen_uuid_v7() -> String {
    UUID::now_v7().to_string()
}
