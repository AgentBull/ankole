// The canonical "anything that survives JSON.stringify/parse" type, shared across the agent computer.
// Used as the contract for values that cross a serialization boundary — persisted DB columns, message
// `details`, redaction output (see security/redact.ts) — so those call sites are typed against a value
// that is guaranteed round-trippable rather than an open `unknown`.
export type JsonValue = string | number | boolean | null | { [key: string]: JsonValue } | JsonValue[]
// A JSON value constrained to be an object at the top level (the common case for a row or payload).
export type JsonObject = { [key: string]: JsonValue }
