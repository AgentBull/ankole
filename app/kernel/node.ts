export type WebURLRejection = 'metadata' | 'private' | 'invalid'

export type WebProxy = {
  readonly port: number
  close(): Promise<void>
}

type KernelBinding = {
  validateWebURL(url: string, schemes: string[], ssrfFilter: boolean): WebURLRejection | null
  validateIPAddresses(addresses: string[], ssrfFilter: boolean): WebURLRejection | null
  startWebProxy(ssrfFilter: boolean, port?: number): WebProxy
}

// Bun stages this static native import beside the bundled browser entry points.
const kernel = require('./target/napi-build/ankole_kernel.node') as KernelBinding

export const { validateWebURL, validateIPAddresses, startWebProxy } = kernel
