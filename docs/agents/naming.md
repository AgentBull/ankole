# Naming

Ankole-owned names preserve initialisms as semantic words instead of treating them as ordinary title-cased text.

## Initialisms

- PascalCase keeps the initialism uppercase: `RPCRequest`, `AIGatewayAPIKey`, `JSONValue`, `OpenAIResponses`.
- lower camelCase keeps a leading initialism lowercase and later initialisms uppercase: `rpcClient`, `apiKey`, `workerRPCRequest`, `providerID`, `baseURL`.
- snake_case and kebab-case keep lowercase word boundaries: `rpc_request`, `ai_gateway_transport`.
- Third-party symbols keep their upstream spelling only at the import or adapter boundary and receive a canonical local alias when practical.

The canonical initialisms are `AI`, `ALPN`, `API`, `AWS`, `CDP`, `CLI`, `DB`, `HTML`, `HTTP`, `HTTPS`, `ID`, `IM`, `IP`, `JSON`, `JWT`, `LLM`, `MCP`, `NAPI`, `NIF`, `OIDC`, `OTP`, `RPC`, `SDK`, `SQL`, `SSE`, `TCP`, `TLS`, `UID`, `URI`, `URL`, `UTF8`, `UUID`, `VFS`, `XML`, and `ZMQ`.

## Cardinality

Owned collection fields use plural domain nouns and owned single-item fields use singular domain nouns. Generic wrappers such as `data` and `results` do not express cardinality and must not be introduced on owned APIs.

Examples:

- `agents` and `agent`
- `identity_providers` and `identity_provider`
- `cron_schedules` and `cron_schedule`
- `delegations` and `delegation`

PostgreSQL tables that store entity sets use plural names. Ecto schema module names remain singular because one struct represents one row.

## Compatibility boundaries

The runtime API under `/api/v1/ai-gateway/*` preserves the OpenAI/OpenRouter wire contract, including Responses API HTTP and WebSocket fields and standard `data` or `results` envelopes.

Generated OpenAPI TypeScript is also left under the upstream generator's naming policy. Do not customize or post-process the generator solely to force Ankole acronym casing. Hand-written consumers may alias generated imports to canonical local names.

Run `bun run analyze:naming` from the repository root to check hand-written TypeScript, Elixir, Rust, and protobuf sources.

## Cleanup checklist

Before a naming cleanup changes code:

- Delete obsolete owned names instead of retaining aliases or dual-read compatibility branches.
- Merge duplicate spellings into one canonical term and reuse the existing domain owner rather than adding wrappers.
- Keep third-party and OpenAI-compatible spellings at explicit adapter boundaries.
- Verify the naming analyzer, package type checks, affected tests, OpenAI Responses wire tests, and database migrations.
- Treat supervision, persistence, message flow, generated OpenAPI output, and public wire contracts as explicit review risks. Naming-only work must not change OTP failure boundaries or customize the OpenAPI generator.
