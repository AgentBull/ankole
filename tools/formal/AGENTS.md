# Formal Verification Agent Guidelines

This file applies to all files under `tools/formal/`. It supplements the root `AGENTS.md`.

## Workflow

1. Write broad candidate properties first. Use Lean 4 proof attempts or model counterexample search to traverse the input and state space and surface every failing case.
2. Check each surfaced case against real callers, Ash resource schemas, PostgreSQL column types and constraints, and runtime protocols.
3. Classify and handle each case:
   - **Bug**: The case is reachable in production or violates a domain invariant. Add a regression test in the owning suite, fix the production module, and prove the repaired contract.
   - **Expected incompleteness**: An upstream caller, schema, or database constraint excludes the case. Do not add defensive branches or synthetic tests to production code. Scope the formal law's `requires:` precondition to the real contract and record the boundary and its upstream owner in `EXPECTED_INCOMPLETENESS.md`.

## Target selection

Use Lynx (`Core Erlang -> Lean 4`) for small, self-contained pure functions in `app/control_plane/lib/`. Compile target modules directly from their owning source files through `Mix.Tasks.Compile.AnkoleTargets`; do not duplicate production logic in `tools/formal/`.

Use standalone Lean 4 state-machine models for stateful or concurrent protocols that depend on `Ash`, `Ecto`, OTP processes, or external I/O. Do not rewrite idiomatic stateful production modules solely to satisfy bytecode translation.

## Proof checks

Every committed law suite must pass uncached elaboration (`LYNX_CACHE=0 mix test`) and standalone kernel verification (`lake --dir deps/lynx/Lean check --from-export ...`) with zero `sorry` declarations and only Lean's standard axioms (`propext`, `Quot.sound`, `Classical.choice`).
