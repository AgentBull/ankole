# Formal Verification Agent Guidelines

These guidelines apply to all files under `tools/formal/` and supplement the root `AGENTS.md`.

## Workflow

1. **Start with broad candidate properties.** Use Lean 4 proof attempts or bounded model counterexample search to explore the full input and state space and surface every failing case.
2. **Audit each counterexample against production reality.** Check real callers, Ash resource schemas, PostgreSQL column types and constraints, and wire protocols to see whether the failing state can actually arise.
3. **Classify and resolve each case:**
   - **Bug**: The case is reachable in production or violates a domain invariant. Add a regression test in the owning test suite, fix the production module, and prove the repaired contract.
   - **Expected incompleteness**: An upstream caller, schema, or database constraint already rules the case out. Do not add defensive dead branches or synthetic tests to production code; instead, narrow the formal law's `requires:` precondition to match the real contract, and document the boundary and its upstream owner in `EXPECTED_INCOMPLETENESS.md`.

## Target selection

Use Lynx (`Core Erlang -> Lean 4`) for small, self-contained pure functions in `app/control_plane/lib/`. Compile target modules directly from their owning production source files via `Mix.Tasks.Compile.AnkoleTargets` rather than copying logic into `tools/formal/`.

Use standalone Lean 4 state-machine models for stateful or concurrent protocols that depend on `Ash`, `Ecto`, OTP processes, or external I/O. Never contort idiomatic stateful Elixir modules just to force them through bytecode translation.

## Proof checks

Every committed law suite must pass both uncached elaboration (`LYNX_CACHE=0 mix test`) and standalone Lean kernel verification (`lake --dir deps/lynx/Lean check --from-export ...`) with zero `sorry` placeholders and only Lean's standard axioms (`propext`, `Quot.sound`, `Classical.choice`).
