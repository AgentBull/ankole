import { mkdir } from 'node:fs/promises'
import { dirname, isAbsolute, relative, resolve } from 'node:path'
import type { BrowserContext, Frame, Locator, Page } from 'playwright-core'
import type { BrowserCommandArgs, BrowserMaterial, BrowserPageCommand } from '../protocol'
import { BrowserDataError } from '../errors'
import { PhysicalBrowser } from './backend'
import { DialogGuard } from './dialog-guard'
import { installNavigationPolicy, validateNavigationURL } from './navigation-policy'
import { PageRegistry } from './page-registry'
import { SnapshotStore } from './snapshot'

type PointerActionCommand = Extract<
  BrowserPageCommand,
  {
    name:
      | 'click'
      | 'dblclick'
      | 'focus'
      | 'hover'
      | 'fill'
      | 'type'
      | 'press'
      | 'select'
      | 'check'
      | 'uncheck'
      | 'scroll'
      | 'scrollintoview'
      | 'drag'
      | 'upload'
  }
>

export class BrowserSession {
  readonly guard = new DialogGuard()
  readonly snapshots = new SnapshotStore()
  readonly registry: PageRegistry

  private constructor(
    readonly material: BrowserMaterial,
    readonly session: string,
    readonly physical: PhysicalBrowser
  ) {
    this.registry = new PageRegistry(physical.context, page => this.installPage(page))
  }

  static async create(material: BrowserMaterial, session: string): Promise<BrowserSession> {
    const physical = await PhysicalBrowser.connect(material, session)
    try {
      const browserSession = new BrowserSession(material, session, physical)
      await installNavigationPolicy(physical.context, material)
      await browserSession.guard.cleanupOrphans(physical.context)
      await browserSession.registry.ensurePage()
      await browserSession.registry.refreshMetadata()
      return browserSession
    } catch (error) {
      await physical.purge().catch(() => undefined)
      throw error
    }
  }

  warnings(): string[] {
    return this.guard.takeWarnings()
  }

  contexts(): BrowserContext[] {
    return this.physical.browser.contexts()
  }

  defaultContextOrdinal(): number {
    return this.contexts().indexOf(this.physical.context)
  }

  activePageOrdinal(): number {
    return this.registry.activePageIndex()
  }

  async bind(title: string): Promise<string> {
    return await this.physical.bind(title)
  }

  delegateDialogs(): void {
    this.guard.delegate()
  }

  async reconcileAfterLease(baseline: ReadonlySet<BrowserContext>): Promise<void> {
    for (const context of this.contexts()) {
      if (!baseline.has(context)) await context.close().catch(() => undefined)
    }
    if (!this.contexts().includes(this.physical.context)) {
      throw new BrowserDataError('session_lost', 'runner closed the persistent browser context')
    }
    await this.guard.resume(this.physical.context)
    this.snapshots.clear()
    await this.registry.ensurePage()
    await this.registry.refreshMetadata()
  }

  async close(): Promise<void> {
    await this.physical.close()
  }

  async purge(): Promise<void> {
    await this.physical.purge()
  }

  async execute(command: BrowserPageCommand, deadline = Date.now() + 30_000): Promise<unknown> {
    this.assertCommandAllowedDuringDialog(command)
    switch (command.name) {
      case 'open':
        return await this.open(command.args.url)
      case 'snapshot':
        this.guard.assertRendererAvailable('snapshot')
        return await this.snapshots.capture(this.registry.currentPage(), command.args)
      case 'screenshot':
        return await this.screenshot(command.args)
      case 'click':
      case 'dblclick':
      case 'focus':
      case 'hover':
      case 'fill':
      case 'type':
      case 'press':
      case 'select':
      case 'check':
      case 'uncheck':
      case 'scroll':
      case 'scrollintoview':
      case 'drag':
      case 'upload':
        return await this.action(command)
      case 'get':
        return await this.get(command.args)
      case 'is':
        return await this.is(command.args)
      case 'find':
        return await this.find(command.args)
      case 'wait':
        return await this.wait(command.args)
      case 'tab':
        return await this.tab(command.args)
      case 'frame':
        return await this.frame(command.args)
      case 'dialog':
        return await this.dialog(command.args)
      case 'eval':
        this.guard.assertRendererAvailable('eval')
        return await this.registry.currentFrame().evaluate(command.args.expression)
      case 'fetch':
        return await this.fetch(command.args.urls, deadline)
    }
    return unsupportedCommand(command)
  }

  status(): Record<string, unknown> {
    return {
      backend: this.physical.kind,
      connected: this.physical.isConnected(),
      session: this.session,
      tabs: this.registry.list(),
      dialog: this.guard.status()
    }
  }

  private async open(url?: string): Promise<Record<string, unknown>> {
    const page = await this.registry.ensurePage()
    if (url) {
      this.guard.assertRendererAvailable('open')
      const validated = await validateNavigationURL(url, this.material)
      this.snapshots.clear()
      await this.guard.runPotentialDialogAction(page, () =>
        page.goto(validated.href, { waitUntil: 'domcontentloaded' })
      )
    }
    await this.registry.refreshMetadata(page)
    return { url: page.url(), title: this.registry.cachedTitle() }
  }

  private async action(command: PointerActionCommand): Promise<Record<string, unknown>> {
    const page = this.registry.currentPage()
    this.guard.assertRendererAvailable(command.name)
    if (command.name === 'press') {
      await this.guard.runPotentialDialogAction(page, () => page.keyboard.press(command.args.key))
    } else if (command.name === 'scroll') {
      const direction = command.args.direction
      const pixels = command.args.pixels ?? 720
      const selector = command.args.selector
      const deltaX = direction === 'left' ? -pixels : direction === 'right' ? pixels : 0
      const deltaY = direction === 'up' ? -pixels : direction === 'down' ? pixels : 0
      if (selector) {
        const locator = await this.resolve(selector)
        await locator.evaluate(
          (element, delta) => element.scrollBy({ left: delta.x, top: delta.y, behavior: 'instant' }),
          { x: deltaX, y: deltaY }
        )
      } else await page.mouse.wheel(deltaX, deltaY)
    } else if (command.name === 'drag') {
      const source = await this.resolve(command.args.source)
      const target = await this.resolve(command.args.target)
      await this.guard.runPotentialDialogAction(page, () => source.dragTo(target))
    } else {
      const locator = await this.resolve(command.args.selector)
      await this.guard.runPotentialDialogAction(page, async () => {
        switch (command.name) {
          case 'click':
            await locator.click()
            break
          case 'dblclick':
            await locator.dblclick()
            break
          case 'focus':
            await locator.focus()
            break
          case 'hover':
            await locator.hover()
            break
          case 'fill':
            await locator.fill(command.args.text)
            break
          case 'type':
            await locator.pressSequentially(command.args.text)
            break
          case 'select':
            await locator.selectOption({ label: command.args.value }).catch(async () => {
              await locator.selectOption(command.args.value)
            })
            break
          case 'check':
            await locator.check()
            break
          case 'uncheck':
            await locator.uncheck()
            break
          case 'scrollintoview':
            await locator.scrollIntoViewIfNeeded()
            break
          case 'upload':
            await locator.setInputFiles(command.args.paths.map(path => this.workspacePath(path)))
            break
          default:
            unsupportedCommand(command)
        }
      })
    }
    await this.registry.refreshMetadata(page)
    return { url: page.url(), refs_may_be_stale: true }
  }

  private async get(args: BrowserCommandArgs<'get'>): Promise<unknown> {
    if (args.property === 'url') return this.registry.cachedURL()
    if (args.property === 'title') {
      if (!this.guard.hasPending()) await this.registry.refreshMetadata()
      return this.registry.cachedTitle()
    }
    this.guard.assertRendererAvailable(`get ${args.property}`)
    const locator = await this.resolve(args.selector)
    switch (args.property) {
      case 'text':
        return await locator.innerText()
      case 'html':
        return await locator.innerHTML()
      case 'value':
        return await locator.inputValue()
      case 'attr':
        return await locator.getAttribute(args.attribute)
      case 'count':
        return await locator.count()
      case 'box':
        return await locator.boundingBox()
    }
    return unsupportedCommand(args)
  }

  private async is(args: BrowserCommandArgs<'is'>): Promise<boolean> {
    this.guard.assertRendererAvailable('is')
    const locator = await this.resolve(args.selector)
    switch (args.predicate) {
      case 'visible':
        return await locator.isVisible()
      case 'enabled':
        return await locator.isEnabled()
      case 'checked':
        return await locator.isChecked()
    }
    return unsupportedCommand(args.predicate)
  }

  private async find(args: BrowserCommandArgs<'find'>): Promise<unknown> {
    this.guard.assertRendererAvailable('find')
    const frame = this.registry.currentFrame()
    let locator: Locator
    switch (args.kind) {
      case 'role':
        locator = frame.getByRole(args.value as Parameters<Frame['getByRole']>[0], {
          ...(args.name ? { name: args.name } : {}),
          exact: args.exact === true
        })
        break
      case 'text':
        locator = frame.getByText(args.value, { exact: args.exact === true })
        break
      case 'label':
        locator = frame.getByLabel(args.value, { exact: args.exact === true })
        break
      case 'placeholder':
        locator = frame.getByPlaceholder(args.value, { exact: args.exact === true })
        break
      case 'testid':
        locator = frame.getByTestId(args.value)
        break
      case 'first':
        locator = frame.locator(args.value).first()
        break
      case 'last':
        locator = frame.locator(args.value).last()
        break
      case 'nth':
        locator = frame.locator(args.selector).nth(args.index)
        break
      default:
        return unsupportedCommand(args)
    }
    const action = args.action
    if (!action) return { count: await locator.count() }
    if (action === 'text') return await locator.first().innerText()
    const page = this.registry.currentPage()
    await this.guard.runPotentialDialogAction(page, async () => {
      const target = locator.first()
      if (action === 'click') await target.click()
      else if (action === 'fill') await target.fill(args.text!)
      else if (action === 'type') await target.pressSequentially(args.text!)
      else if (action === 'hover') await target.hover()
      else if (action === 'focus') await target.focus()
      else if (action === 'check') await target.check()
      else if (action === 'uncheck') await target.uncheck()
      else unsupportedCommand(action)
    })
    return { action, refs_may_be_stale: true }
  }

  private async wait(args: BrowserCommandArgs<'wait'>): Promise<Record<string, unknown>> {
    this.guard.assertRendererAvailable('wait')
    const frame = this.registry.currentFrame()
    const ms = args.ms
    if (ms !== undefined) await new Promise(resolve => setTimeout(resolve, ms))
    else if (args.selector !== undefined) await frame.locator(args.selector).waitFor({ state: 'visible' })
    else if (args.text !== undefined) await frame.getByText(args.text).first().waitFor({ state: 'visible' })
    else if (args.url !== undefined) await this.registry.currentPage().waitForURL(args.url)
    else if (args.load !== undefined) await this.registry.currentPage().waitForLoadState(args.load)
    else if (args.expression !== undefined) await frame.waitForFunction(args.expression)
    else throw new BrowserDataError('invalid_command', 'wait requires a condition')
    return { satisfied: true }
  }

  private async tab(args: BrowserCommandArgs<'tab'>): Promise<unknown> {
    if (this.guard.hasPending() && args.action === 'new') this.guard.assertRendererAvailable('tab new')
    if (args.action === 'list') return this.registry.list()
    if (args.action === 'new') {
      this.snapshots.clear()
      const url = args.url ? (await validateNavigationURL(args.url, this.material)).href : undefined
      const page = await this.registry.newPage()
      if (url) {
        await this.guard.runPotentialDialogAction(page, () => page.goto(url, { waitUntil: 'domcontentloaded' }))
      }
    } else if (args.action === 'switch') this.registry.switchPage(args.index)
    else await this.registry.closePage(args.index)
    this.snapshots.clear()
    return this.registry.list()
  }

  private async frame(args: BrowserCommandArgs<'frame'>): Promise<Record<string, unknown>> {
    this.guard.assertRendererAvailable('frame')
    const frame = await this.registry.selectFrame(args.target)
    this.snapshots.clear()
    return { url: frame.url(), name: frame.name() }
  }

  private async dialog(args: BrowserCommandArgs<'dialog'>): Promise<Record<string, unknown>> {
    if (args.action === 'status') return this.guard.status()
    const result = await this.guard.handle(args.action, args.action === 'accept' ? args.text || undefined : undefined)
    if (result.handled === true) this.snapshots.clear()
    await this.registry.refreshMetadata()
    return result
  }

  private async screenshot(args: BrowserCommandArgs<'screenshot'>): Promise<Record<string, unknown>> {
    const page = this.registry.currentPage()
    const annotate = args.annotate === true
    this.guard.assertRendererAvailable('screenshot')
    const outputPath = this.artifactPath(args.path)
    await mkdir(dirname(outputPath), { recursive: true })
    if (annotate && this.snapshots.entries().length === 0) {
      await this.snapshots.capture(page, { interactive: true })
    }
    if (annotate) await this.installAnnotations(page)
    try {
      await page.screenshot({ path: outputPath, fullPage: args.full === true })
    } finally {
      if (annotate) await this.removeAnnotations(page)
    }
    return { path: this.modelArtifactPath(outputPath) }
  }

  private async fetch(urls: string[], deadline: number): Promise<Record<string, unknown>> {
    const results: Array<Record<string, unknown> | undefined> = Array.from({ length: urls.length })
    const workerCount = Math.min(2, urls.length)
    const waves = Math.ceil(urls.length / workerCount)
    const perURLBudget = Math.max(2_000, Math.min(15_000, Math.floor((deadline - Date.now() - 500) / waves)))
    let nextIndex = 0
    await this.guard.withAutomaticDialogs(async () => {
      const worker = async (): Promise<void> => {
        while (nextIndex < urls.length) {
          const index = nextIndex++
          const value = urls[index]!
          const page = await this.registry.newPage()
          const urlDeadline = Math.min(deadline - 250, Date.now() + perURLBudget)
          try {
            const url = await validateNavigationURL(value, this.material)
            const navigationTimeout = urlDeadline - Date.now() - RenderedFetchMinimumSettleMs
            if (navigationTimeout <= 0) throw new BrowserDataError('timeout', 'rendered fetch URL budget expired')
            await page.goto(url.href, {
              waitUntil: 'domcontentloaded',
              timeout: Math.min(30_000, navigationTimeout)
            })
            const text = await waitForReadableText(page, urlDeadline)
            const title = await page.title()
            results[index] = {
              url: page.url(),
              title,
              text: text.slice(0, 512 * 1024),
              metadata: { source: 'rendered_fallback' },
              warnings: []
            }
          } catch (error) {
            results[index] = {
              url: value,
              error: error instanceof Error ? error.message : String(error),
              metadata: { source: 'rendered_fallback' }
            }
          } finally {
            await page.close({ runBeforeUnload: false }).catch(() => undefined)
          }
        }
      }
      await Promise.all(Array.from({ length: workerCount }, () => worker()))
    })
    const completed = results.map(
      (result, index) =>
        result ?? {
          url: urls[index]!,
          error: 'rendered fetch did not complete before its request deadline',
          metadata: { source: 'rendered_fallback' }
        }
    )
    return {
      success: completed.every(result => typeof result.error !== 'string'),
      source: 'rendered_fallback',
      results: completed
    }
  }

  private async resolve(selector: string): Promise<Locator> {
    return await this.snapshots.resolve(this.registry.currentPage(), selector, this.registry.currentFrame())
  }

  private installPage(page: Page): void {
    this.guard.install(page)
    page.on('framenavigated', frame => {
      if (frame === page.mainFrame()) this.snapshots.clear()
    })
    page.on('close', () => this.snapshots.clear())
  }

  private assertCommandAllowedDuringDialog(command: BrowserPageCommand): void {
    if (!this.guard.hasPending()) return
    if (command.name === 'dialog') return
    if (command.name === 'get' && (command.args.property === 'url' || command.args.property === 'title')) return
    if (command.name === 'tab' && command.args.action !== 'new') return
    this.guard.assertRendererAvailable(command.name)
  }

  private artifactPath(value?: string): string {
    const path = value
      ? isAbsolute(value)
        ? resolve(value)
        : resolve(this.material.artifact_root, value.replace(/^browser\/?/, ''))
      : resolve(this.material.artifact_root, `screenshots/${new Date().toISOString().replace(/[:.]/g, '-')}.png`)
    assertInside(this.material.artifact_root, path)
    return path
  }

  private modelArtifactPath(path: string): string {
    return path
  }

  private workspacePath(value: string): string {
    const workspaceRoot = resolve(dirname(this.material.artifact_root))
    const path = isAbsolute(value) ? resolve(value) : resolve(workspaceRoot, value)
    assertInside(workspaceRoot, path)
    return path
  }

  private async installAnnotations(page: Page): Promise<void> {
    for (const target of this.snapshots.entries()) {
      const frame = page.frames()[target.frameIndex]
      if (!frame || frame.url() !== target.frameURL) continue
      const locator = await this.snapshots.resolve(page, `@${target.ref}`, frame)
      await locator.evaluate((element, ref) => {
        const rect = element.getBoundingClientRect()
        const label = document.createElement('div')
        label.dataset.ankoleBrowserAnnotation = 'true'
        label.textContent = ref.replace(/^e/, '')
        Object.assign(label.style, {
          position: 'fixed',
          left: `${Math.max(0, rect.left)}px`,
          top: `${Math.max(0, rect.top)}px`,
          zIndex: '2147483647',
          background: '#b31b5d',
          color: 'white',
          padding: '1px 4px',
          font: 'bold 12px sans-serif',
          pointerEvents: 'none'
        })
        document.body.appendChild(label)
      }, target.ref)
    }
  }

  private async removeAnnotations(page: Page): Promise<void> {
    for (const frame of page.frames()) {
      await frame
        .locator('[data-ankole-browser-annotation="true"]')
        .evaluateAll(elements => elements.forEach(element => element.remove()))
        .catch(() => undefined)
    }
  }
}

const RenderedFetchMinimumSettleMs = 1_000
const RenderedFetchStableWindowMs = 600
const RenderedFetchMaximumSettleMs = 3_000
const RenderedFetchSampleIntervalMs = 200

async function waitForReadableText(page: Page, deadline: number): Promise<string> {
  const startedAt = Date.now()
  const settleDeadline = Math.min(deadline, startedAt + RenderedFetchMaximumSettleMs)
  let previous: string | undefined
  let stableSince = startedAt

  while (true) {
    const now = Date.now()
    if (now >= deadline) throw new BrowserDataError('timeout', 'rendered fetch URL budget expired')
    const text = await page.locator('body').innerText({ timeout: Math.max(1, deadline - now) })
    const sampledAt = Date.now()
    if (text !== previous) {
      previous = text
      stableSince = sampledAt
    }
    if (
      sampledAt - startedAt >= RenderedFetchMinimumSettleMs &&
      sampledAt - stableSince >= RenderedFetchStableWindowMs
    ) {
      return text
    }
    if (sampledAt >= settleDeadline) return text
    await page.waitForTimeout(Math.min(RenderedFetchSampleIntervalMs, settleDeadline - sampledAt))
  }
}

function unsupportedCommand(command: never): never {
  const name =
    command !== null && typeof command === 'object' && 'name' in (command as Record<string, unknown>)
      ? String((command as Record<string, unknown>).name)
      : String(command)
  throw new BrowserDataError('invalid_command', `unsupported browser command: ${name}`)
}

function assertInside(root: string, path: string): void {
  const child = relative(resolve(root), resolve(path))
  if (child === '..' || child.startsWith(`..${process.platform === 'win32' ? '\\' : '/'}`) || isAbsolute(child)) {
    throw new BrowserDataError('invalid_command', 'artifact path must stay inside browser artifact root')
  }
}
