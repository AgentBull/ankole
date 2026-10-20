import { validateWebURL, type WebURLRejection } from '@ankole/kernel'
import type { BrowserContext } from 'playwright-core'
import type { BrowserMaterial } from '../protocol'
import { BrowserDataError } from '../errors'

export async function validateNavigationURL(value: string, material: BrowserMaterial): Promise<URL> {
  let url: URL
  try {
    url = new URL(value.includes('://') ? value : `https://${value}`)
  } catch {
    throw new BrowserDataError('invalid_command', `invalid URL: ${value}`)
  }
  if (url.protocol === 'file:' && material.navigation.allow_file_urls) return url
  if (!['http:', 'https:'].includes(url.protocol)) {
    throw new BrowserDataError('invalid_command', `unsupported browser URL protocol: ${url.protocol}`)
  }
  // URL hosts keep their IPv6 brackets; classification works on the bare address.
  const host = url.hostname.startsWith('[') ? url.hostname.slice(1, -1) : url.hostname
  if (!host) throw new BrowserDataError('invalid_command', 'browser URL requires a hostname')
  // Remote Chromium owns its network policy and DNS environment.
  if (material.backend.kind === 'local_chromium') {
    rejectVerdict(validateWebURL(url.href, ['http', 'https'], material.navigation.ssrf_filter), host)
  }
  return url
}

export async function installNavigationPolicy(context: BrowserContext, material: BrowserMaterial): Promise<void> {
  await context.route('**/*', async route => {
    const request = route.request()
    if (!request.isNavigationRequest() && !/^https?:/.test(request.url())) {
      await route.continue()
      return
    }
    try {
      await validateNavigationURL(request.url(), material)
      await route.continue()
    } catch {
      await route.abort('blockedbyclient')
    }
  })
}

function rejectVerdict(verdict: WebURLRejection | null, host: string): void {
  if (verdict) {
    throw new BrowserDataError('invalid_command', `blocked browser navigation to ${verdict} address: ${host}`)
  }
}
