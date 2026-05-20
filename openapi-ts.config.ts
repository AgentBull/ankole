import { defineConfig } from "@hey-api/openapi-ts"

// Generates the typed client + TanStack Query options for the internal console
// API. Input is the OpenAPI document dumped from open_api_spex
// (`bun run openapi:spec`). Regenerate with `bun run gen:api`.
export default defineConfig({
  input: "priv/openapi/internal-api.json",
  output: "webui/src/apps/web-console/api/client",
  plugins: ["@hey-api/client-fetch", "@tanstack/react-query"],
})
