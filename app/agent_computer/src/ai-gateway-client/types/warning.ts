import type { SharedWarning } from '@/ai-gateway-client/provider'

/**
 * Warning from the model provider for this call. The call will proceed, but e.g.
 * some settings might not be supported, which can lead to suboptimal results.
 */
export type Warning = SharedWarning
