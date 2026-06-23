# Ankole Kernel

Ankole Kernel is the shared Rust foundation used by both the Bun and Elixir
parts of Ankole.

It is not a Bun package with an Elixir adapter, and not an Elixir NIF project
with a Bun adapter. Rust owns the low-level semantics. Bun and Elixir are equal
host runtimes that load those semantics through separate binding layers.

## Purpose

The kernel exists to prevent the Bun side and the Elixir side from developing
separate meanings for the same native behavior. If a behavior must be trusted by
both runtimes, it belongs here as Rust first, with bindings second.

The categories are intentionally broad:

- cryptographic;
- identifier generation;
- rule evaluation;
- low-level Bun/Elixir communication protocol pieces.

These are not a checklist. The boundary is whether Ankole needs one native
semantics shared across runtimes.

## Boundary

The kernel owns shared mechanisms, not product ownership.

It may own the evaluator, codec, verifier, or protocol machinery. It does not own
the product lifecycle, storage model, UI, or business meaning that uses that
machinery.

## Architecture

`app/kernel` is the Rust crate root. `src/` is the Rust source tree.

The code is split conceptually into:

- Rust core: the actual behavior, independent of Bun, Node-API, Elixir, and
  Rustler types;
- Bun binding: napi-rs type/error translation for JavaScript callers;
- Elixir binding: Rustler type/error translation for BEAM callers.

Binding layers may use host-native naming and types, but they must not introduce
different behavior.

One-sided exports are allowed, but they should stay explicit in the binding layer
rather than changing the shared core contract by accident.
