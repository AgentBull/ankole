# Upstream Provenance (`anti-slop`)

- **Upstream repository**: `https://github.com/k-mistele/anti-slop` (forked from `https://github.com/dmmulroy/anti-slop`)
- **Upstream revision**: `b7c1619b4d51b4815e89ba3700a975a6ec54b8c3` (`2026-11-15`)
- **License**: MIT (`LICENSE`)
- **Installed path**: `tools/devkit/src/oxlint/anti-slop/`

## Architectural Selection & Local Customizations for Ankole

Ankole vendors only the deterministic, zero-network AST rules that match Ankole's multi-tenant TypeScript runtimes (`app/webapps`, `app/agent_computer`, `app/function_runtime`, `app/ankole-browser`, `libs/*`, `tools/devkit`):

### Enabled Rules (`error`)
- `anti-slop/no-chained-type-assertions` (production code; disabled in test overrides): rejects `as unknown as T` and `as any as T` double-cast type laundering.
- `anti-slop/no-widen-then-assert`: rejects widening known local `const` bindings to `unknown`/`any`/`object`/`Record<string, unknown>` and casting them back later.
- `anti-slop/no-disabled-type-assertion-rules`: rejects bare `oxlint-disable`/`eslint-disable` comments without rule names and inline suppression of protected anti-slop escape-hatch rules.
- `anti-slop/no-unknown-type-aliases`: rejects type aliases that disguise `unknown` behind a named contract.
- `anti-slop/no-reflect-apply`: rejects `Reflect.apply` (`any`-returning call escape hatch).
- `anti-slop/no-reflect-get` *(Ankole customization)*: rejects `Reflect.get` (`any`-returning property escape hatch), while allowing `Reflect.get` inside `Proxy` handler `get` traps (`new Proxy`, `Proxy.revocable`, `ProxyHandler<T>`) where receiver-preserving forwarding is required by WebIDL/ECMAScript invariants.
- `anti-slop/no-module-mocking` *(Ankole customization)*: extends Vitest/Jest detection to `bun:test`'s `mock.module` (which also mutates Bun's process-global module cache), with `allowSpecifierPatterns` supporting bundler-synthesized asset queries (`?worker`, `?url`, `?raw`, `?inline`).
- `anti-slop/no-reduce-accumulator-copy` (paired with native `oxc/no-accumulating-spread`): rejects quadratic `O(n^2)` accumulator copies in `.reduce`/`.reduceRight` and loops, mirroring Elixir's `Ankole.Credo.AppendInLoop`.
- `anti-slop/max-ternary-depth` (`maxDepth: 3`): allows 2-way, 3-way, and 4-state UI ternaries while rejecting deep nested ternary staircases (`depth >= 4`).
- `anti-slop/no-test-code-in-src` *(Ankole customization)*: prevents production `src/` modules from importing test directories/files or exporting `Fake*`/`Mock*`/`Stub*` test doubles, with `allowTestFiles` supporting `tools/devkit`'s co-located `src/**/*.test.ts` layout.
- `anti-slop/global-data`: rejects exported `let`/`var` bindings and exported containers mutated at module scope to prevent shared mutable state leaks across tenants or sessions.

### Intentionally Omitted Upstream Rules
- **Effect & paid LLM rules (`anti-slop-effect`, `@effect/tsgo`, `jev`, `diff-rules`)**: Ankole does not use `effect`, and CI static gates must stay deterministic, offline, and secret-free.
- **`require-readable-spacing`**: `oxfmt` (`.oxfmtrc.json`) is the single owner of code formatting in Ankole.
- **`no-shape-in-symbol-names`**: "Shape" is a first-class domain term in Agent Computer's perceptual output shaping and Office presentation shapes.
- **Effect-Schema boundary rules (`no-runtime-typeof`, `no-unsafe-dictionary-type`, `no-unknown-parameters`, `no-unknown-returns`, `no-known-value-widening`, `no-object-parameters`)**: plain TypeScript `typeof` narrowing, `unknown` boundary inputs, JSON-RPC `Record<string, unknown>` envelopes, `WeakMap<object, ...>`, and `@types/phoenix` `Channel.push(event, payload: object)` are idiomatic contracts in Ankole's non-Effect stack.
- **`no-conditional-spread`**: declarative `...(cond ? { key: value } : {})` spreads preserve exact property presence in JSON-RPC/JSON:API payloads and React props.
- **`no-array-filter-map`**: ES2025 iterator helpers (`.values().filter().map().toArray()`) require Safari 18.4+, which exceeds Ankole's Safari 18 browser floor (`app/webapps/AGENTS.md`).
- **`require-safety-comment-for-type-assertion`**: requiring `// SAFETY:` comments on every single cast encourages robotic comment noise; Ankole bans dangerous double casts and `Reflect` laundering directly instead.
- **Heuristic Fowler style warnings (`long-function`, `long-parameter-list`, `loops`, `message-chains`, `mutable-data`, `mysterious-name`, `repeated-switches`)**: noisy heuristics that flag ProseMirror document cursors, Worker lazy caches, and imperative loops; Ankole keeps `oxlint` at zero warnings.
