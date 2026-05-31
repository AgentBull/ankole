# BullX.Ext

`BullX.Ext` is the Elixir boundary for BullX's Rust NIF library. It contains
small native helpers used where correctness, interoperability, or performance
benefits from a Rust implementation.

The implementation lives in `lib/bullx/ext.ex` and `native/bullx_ext`.

## Current Surface

Current NIF-backed areas include:

- UUID helpers and UUIDv7 generation;
- generic hashing and Base58 hashing;
- key derivation and generated keys;
- AEAD encryption and decryption;
- Argon2 password/code hashing and verification;
- JWT signing, verification, and header decoding;
- E.164 phone normalization;
- Base58, Base64, and Z85 helpers;
- ASCII classification;
- AuthZ resource-pattern and CEL evaluation support;
- MailBox delivery-rule validation and matching.

Most functions return values or `{:error, reason}` tuples instead of raising for
bad caller input.

## UUIDv7

BullX application code generates UUID primary keys before insert. Ecto schemas
with UUID primary keys use:

```elixir
@primary_key {:id, BullX.Ecto.UUIDv7, autogenerate: true}
```

Callers that need an explicit id use `BullX.Ext.gen_uuid_v7/0`.

## Crypto

Config secrets, LLM API keys, bootstrap/login auth code hashes, and derived
application secrets rely on `BullX.Ext` crypto helpers.

Secret plaintext must not be logged. Persisted secrets are encrypted by the
owning Elixir subsystem before storage.

## JWT

`BullX.Ext.jwt_sign/3`, `jwt_verify/3`, and `jwt_decode_header/1` wrap the
native JWT implementation. They support HMAC, RSA, RSA-PSS, ECDSA, and EdDSA
algorithms through Elixir-friendly option maps. Verification returns claims on
success or a tagged error for malformed, expired, rejected, or unauthenticated
tokens.

## Rule Engines

AuthZ and MailBox share Rust-backed CEL infrastructure but keep separate
business boundaries:

- AuthZ evaluates permission grants over Principal, resource, action, and
  context.
- MailBox evaluates delivery rules over CloudEvents routing context.

The two rule surfaces must not be treated as interchangeable.

## Invariants

- NIF functions must remain deterministic for a given input unless the function
  explicitly generates randomness or time-ordered ids.
- Native code must not own durable state.
- Elixir callers own business validation and error semantics around NIF
  results.
- UUID generation belongs in application code, not PostgreSQL defaults.
