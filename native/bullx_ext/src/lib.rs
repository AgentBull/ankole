use mimalloc::MiMalloc;

/// mimalloc is a compact general purpose allocator with excellent performance.
/// https://github.com/microsoft/mimalloc
#[global_allocator]
static GLOBAL: MiMalloc = MiMalloc;

mod crypto {
  pub mod aead;
  pub mod argon2;
  pub mod blake3;
  pub mod jwt;
}

mod encoding;
mod phone;
mod rule_engine;

rustler::init!("Elixir.BullX.Ext");
