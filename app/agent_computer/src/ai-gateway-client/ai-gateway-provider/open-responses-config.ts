import type { FetchFunction } from '@/ai-gateway-client/provider-utils'

export type OpenResponsesConfig = {
  provider: string
  url: (options: { modelId: string; path: string }) => string
  headers?: () => Record<string, string | undefined>
  fetch?: FetchFunction
  generateId?: () => string
  /**
   * This is soft-deprecated. Use provider references (e.g. `{ openai: 'file-abc123' }`)
   * in file part data instead. File ID prefixes used to identify file IDs
   * in Responses API. When undefined, all string file data is treated as
   * base64 content.
   *
   * TODO: remove in v8
   */
  fileIdPrefixes?: readonly string[]
}
