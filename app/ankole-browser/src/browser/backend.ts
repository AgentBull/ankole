import type { Browser, BrowserContext } from 'playwright-core'
import type { BrowserMaterial } from '../protocol'
import { connectLocalChromium, purgeDetachedLocalChromium, type LocalChromiumHandle } from './local-chromium'
import { connectRemoteChromium, purgeDetachedRemoteChromium, type RemoteChromiumHandle } from './remote-cdp'

export class PhysicalBrowser {
  readonly browser: Browser
  readonly context: BrowserContext
  readonly kind: BrowserMaterial['backend']['kind']
  readonly local?: LocalChromiumHandle
  readonly remote?: RemoteChromiumHandle
  private boundEndpoint?: string

  private constructor(input: {
    browser: Browser
    context: BrowserContext
    kind: BrowserMaterial['backend']['kind']
    local?: LocalChromiumHandle
    remote?: RemoteChromiumHandle
  }) {
    this.browser = input.browser
    this.context = input.context
    this.kind = input.kind
    this.local = input.local
    this.remote = input.remote
  }

  static async connect(material: BrowserMaterial, session: string): Promise<PhysicalBrowser> {
    if (material.backend.kind === 'local_chromium') {
      const local = await connectLocalChromium(material, session)
      try {
        return new PhysicalBrowser({
          browser: local.browser,
          context: requireDefaultContext(local.browser),
          kind: material.backend.kind,
          local
        })
      } catch (error) {
        await local.browser.close().catch(() => undefined)
        await local.stop().catch(() => undefined)
        throw error
      }
    }
    const remote = await connectRemoteChromium(material, session)
    try {
      return new PhysicalBrowser({
        browser: remote.browser,
        context: requireDefaultContext(remote.browser),
        kind: material.backend.kind,
        remote
      })
    } catch (error) {
      await remote.browser.close().catch(() => undefined)
      await remote.cleanup().catch(() => undefined)
      throw error
    }
  }

  static async purgeDetached(material: BrowserMaterial, session: string): Promise<void> {
    if (material.backend.kind === 'local_chromium') await purgeDetachedLocalChromium(material, session)
    else await purgeDetachedRemoteChromium(material, session)
  }

  isConnected(): boolean {
    return this.browser.isConnected()
  }

  async bind(title: string): Promise<string> {
    if (this.boundEndpoint) return this.boundEndpoint
    const result = await this.browser.bind(title, { host: '127.0.0.1', port: 0 })
    this.boundEndpoint = result.endpoint
    return result.endpoint
  }

  async unbind(): Promise<void> {
    if (!this.boundEndpoint) return
    this.boundEndpoint = undefined
    await settleWithin(this.browser.unbind(), 2_000)
  }

  async close(): Promise<void> {
    await this.unbind()
    // For a connectOverCDP browser Playwright maps close to closing this CDP
    // transport; the local process and provider lifecycle remain explicit below.
    await settleWithin(this.browser.close(), 2_000)
    await this.local?.stop()
  }

  async purge(): Promise<void> {
    await this.close()
    await this.remote?.cleanup()
  }
}

async function settleWithin(operation: Promise<unknown>, timeoutMs: number): Promise<void> {
  await new Promise<void>(resolve => {
    const timer = setTimeout(resolve, timeoutMs)
    operation.then(
      () => {
        clearTimeout(timer)
        resolve()
      },
      () => {
        clearTimeout(timer)
        resolve()
      }
    )
  })
}

function requireDefaultContext(browser: Browser): BrowserContext {
  const context = browser.contexts()[0]
  if (!context) throw new Error('browser backend exposed no persistent context')
  return context
}
