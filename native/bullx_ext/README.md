# BullX Native Helpers

This directory contains the Rust NIF crate loaded by `BullX.Ext`.

The crate is part of BullX infrastructure, not a product subsystem. It should only contain small native helpers where Rust provides a clear boundary or performance benefit, such as hashing, encoding, UUID generation, encryption, JWT handling, and other low-level utilities.

## Boundaries

- Keep durable product facts in PostgreSQL, not inside native state.
- Keep NIF functions deterministic or explicitly side-effect bounded.
- Prefer one representative Elixir smoke test per exported NIF wrapper.
- Do not add product-specific business logic here without a design doc.
- Treat NIF failures as tagged return values whenever bad user input is expected.

## Build

The crate builds through Rustler as part of the normal Mix compilation flow.

```sh
mix compile
```

For Rust-only checks:

```sh
cargo check
cargo fmt --all --check
```
