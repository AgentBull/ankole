// @ts-nocheck
import type { LanguageModelV4Middleware } from '@/llm/provider'

/**
 * Middleware for language models.
 * Accepts both V3 and V4 middleware types for backward compatibility.
 *
 * Uses LanguageModelV4Middleware as the base but relaxes specificationVersion
 * to accept any string (including 'v3') and makes it optional.
 */
export type LanguageModelMiddleware = Omit<LanguageModelV4Middleware, 'specificationVersion'> & {
  readonly specificationVersion?: string
}
