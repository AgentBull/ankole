// @ts-nocheck
import type { FetchFunction, Resolvable } from '@/llm/provider-utils'

export interface GoogleVertexConfig {
  provider: string
  baseURL: string
  headers?: Resolvable<Record<string, string | undefined>>
  fetch?: FetchFunction
}
