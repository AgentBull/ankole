export type WebURLRejection = 'metadata' | 'private' | 'invalid'
export type WebURLFacts = {
  scheme: string
  host?: string
  hostClass?: 'metadata' | 'private' | 'public'
}

export type WebProxy = {
  readonly port: number
  close(): Promise<void>
}

type KernelBinding = {
  webURLFacts(url: string): WebURLFacts
  validateWebURL(url: string, schemes: string[], ssrfFilter: boolean): WebURLRejection | null
  validateIPAddresses(addresses: string[], ssrfFilter: boolean): WebURLRejection | null
  startWebProxy(ssrfFilter: boolean, port?: number): WebProxy
}

// Bun stages this static native import beside the bundled browser entry points.
const kernel = require('./target/napi-build/ankole_kernel.node') as KernelBinding

export const { webURLFacts, validateWebURL, validateIPAddresses, startWebProxy } = kernel
