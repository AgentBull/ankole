// @ts-nocheck
import type { FetchFunction, Resolvable } from '@/llm/provider-utils'

export type GatewayConfig = {
  baseURL: string
  headers?: Resolvable<Record<string, string | undefined>>
  fetch?: FetchFunction
}
