import { validateWebURL, type WebURLRejection } from '@ankole/kernel'
import type { BrowserContext, Page, Route } from 'playwright-core'
import type { BrowserMaterial } from '../protocol'
import { BrowserDataError } from '../errors'

export const BlockedMediaResourceTypes: ReadonlySet<string> = new Set(['image', 'media', 'font'])

export async function validateNavigationURL(value: string, material: BrowserMaterial): Promise<URL> {
  let url: URL
  try {
    url = new URL(value.includes('://') ? value : `https://${value}`)
  } catch {
    throw new BrowserDataError('invalid_command', `invalid URL: ${value}`)
  }
  if (url.protocol === 'file:' && /^\/drive(?:\/|-recovery(?:\/|$)|$)/.test(decodeURIComponent(url.pathname))) {
    throw new BrowserDataError(
      'invalid_command',
      'Drive files belong to the execution view; use the file tools to read them'
    )
  }
  if (url.protocol === 'file:' && material.navigation.allow_file_urls) return url
  if (!['http:', 'https:'].includes(url.protocol)) {
    throw new BrowserDataError('invalid_command', `unsupported browser URL protocol: ${url.protocol}`)
  }
  // URL hosts keep their IPv6 brackets; classification works on the bare address.
  const host = url.hostname.startsWith('[') ? url.hostname.slice(1, -1) : url.hostname
  if (!host) throw new BrowserDataError('invalid_command', 'browser URL requires a hostname')
  // Remote browsers own their network policy and DNS environment.
  if (material.backend.kind === 'local_chromium') {
    rejectVerdict(validateWebURL(url.href, ['http', 'https'], material.navigation.ssrf_filter), host)
  }
  return url
}

export class NetworkPolicyController {
  private interactiveNoMedia = false
  private remoteMediaRouteInstalled = false
  private readonly renderedFetchPages = new WeakSet<Page>()

  private readonly localRouteHandler = async (route: Route): Promise<void> => {
    const request = route.request()
    const isNavigation = request.isNavigationRequest()
    if (!isNavigation) {
      const page = safeRequestPage(request)
      const blockMedia = this.interactiveNoMedia || (page !== undefined && this.renderedFetchPages.has(page))
      if (blockMedia && BlockedMediaResourceTypes.has(request.resourceType())) {
        await route.abort('blockedbyclient')
        return
      }
      if (!/^https?:/.test(request.url())) {
        await route.continue()
        return
      }
    }
    try {
      await validateNavigationURL(request.url(), this.material)
      await route.continue()
    } catch {
      await route.abort('blockedbyclient')
    }
  }

  private readonly remoteMediaRouteHandler = async (route: Route): Promise<void> => {
    const request = route.request()
    if (!request.isNavigationRequest() && BlockedMediaResourceTypes.has(request.resourceType())) {
      await route.abort('blockedbyclient')
      return
    }
    await route.continue()
  }

  constructor(
    private readonly context: BrowserContext,
    private readonly material: BrowserMaterial
  ) {}

  async install(): Promise<void> {
    // Remote CDP backends (including stateless Kitesurf Workers and hosted Chromium pools) enforce
    // their own egress policy; skipping global Fetch.enable avoids WAN round-trips per subresource.
    if (this.material.backend.kind === 'local_chromium') {
      await this.context.route('**/*', this.localRouteHandler)
    }
  }

  mode(): 'default' | 'no-media' {
    return this.interactiveNoMedia ? 'no-media' : 'default'
  }

  status(): { mode: 'default' | 'no-media'; blocked_resource_types: string[] } {
    return {
      mode: this.mode(),
      blocked_resource_types: this.interactiveNoMedia ? [...BlockedMediaResourceTypes] : []
    }
  }

  async setMode(next: 'default' | 'no-media'): Promise<{
    mode: 'default' | 'no-media'
    blocked_resource_types: string[]
  }> {
    const enableNoMedia = next === 'no-media'
    if (this.material.backend.kind !== 'local_chromium') {
      if (enableNoMedia && !this.remoteMediaRouteInstalled) {
        await this.context.route('**/*', this.remoteMediaRouteHandler)
        this.remoteMediaRouteInstalled = true
      } else if (!enableNoMedia && this.remoteMediaRouteInstalled) {
        await this.context.unroute('**/*', this.remoteMediaRouteHandler)
        this.remoteMediaRouteInstalled = false
      }
    }
    this.interactiveNoMedia = enableNoMedia
    return this.status()
  }

  async prepareRenderedFetchPage(page: Page): Promise<void> {
    if (this.material.backend.kind === 'local_chromium') {
      this.renderedFetchPages.add(page)
      return
    }
    if (typeof page.route === 'function') {
      // Best-effort on remote CDP backends: if a stateless engine omits Fetch.enable, fetch still proceeds.
      await page.route('**/*', this.remoteMediaRouteHandler).catch(() => undefined)
    }
  }
}

export async function installNavigationPolicy(
  context: BrowserContext,
  material: BrowserMaterial
): Promise<NetworkPolicyController> {
  const controller = new NetworkPolicyController(context, material)
  await controller.install()
  return controller
}

function safeRequestPage(request: ReturnType<Route['request']>): Page | undefined {
  try {
    return request.frame()?.page()
  } catch {
    return undefined
  }
}

function rejectVerdict(verdict: WebURLRejection | null, host: string): void {
  if (verdict) {
    throw new BrowserDataError('invalid_command', `blocked browser navigation to ${verdict} address: ${host}`)
  }
}
