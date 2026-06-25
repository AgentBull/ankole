// @ts-nocheck
import type { SharedV4ProviderOptions } from '@/llm/provider'

/**
 * Additional provider-specific options.
 *
 * They are passed through to the provider from the AI SDK and enable
 * provider-specific functionality that can be fully encapsulated in the provider.
 */
export type ProviderOptions = SharedV4ProviderOptions
