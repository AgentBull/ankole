import type { BrowserContext, Frame, Page } from 'playwright-core'
import { BrowserDataError } from '../errors'

type PageMetadata = {
  url: string
  title: string
}

export class PageRegistry {
  private activeIndex = 0
  private selectedFrame?: Frame
  private readonly metadata = new WeakMap<Page, PageMetadata>()
  private readonly installed = new WeakSet<Page>()

  constructor(
    readonly context: BrowserContext,
    private readonly onPageInstalled: (page: Page) => void
  ) {
    for (const page of context.pages()) this.install(page)
    context.on('page', page => {
      this.install(page)
      this.activeIndex = Math.max(0, this.pages().indexOf(page))
    })
  }

  pages(): Page[] {
    return this.context.pages().filter(page => !page.isClosed())
  }

  async ensurePage(): Promise<Page> {
    const current = this.currentPageOrUndefined()
    if (current) return current
    const page = await this.context.newPage()
    this.install(page)
    this.activeIndex = this.pages().indexOf(page)
    return page
  }

  currentPage(): Page {
    const page = this.currentPageOrUndefined()
    if (!page) throw new BrowserDataError('no_page', 'browser session has no open page')
    return page
  }

  currentFrame(): Frame {
    const page = this.currentPage()
    if (this.selectedFrame && this.selectedFrame.page() === page && !this.selectedFrame.isDetached()) {
      return this.selectedFrame
    }
    this.selectedFrame = undefined
    return page.mainFrame()
  }

  activePageIndex(): number {
    const page = this.currentPage()
    return this.pages().indexOf(page)
  }

  defaultContextIndex(): number {
    return 0
  }

  async newPage(): Promise<Page> {
    const page = await this.context.newPage()
    this.install(page)
    this.activeIndex = this.pages().indexOf(page)
    this.selectedFrame = undefined
    return page
  }

  switchPage(index: number): Page {
    const page = this.pages()[index]
    if (!page) throw new BrowserDataError('invalid_command', `tab index ${index} does not exist`)
    this.activeIndex = index
    this.selectedFrame = undefined
    return page
  }

  async closePage(index: number): Promise<void> {
    const page = this.pages()[index]
    if (!page) throw new BrowserDataError('invalid_command', `tab index ${index} does not exist`)
    await page.close({ runBeforeUnload: false })
    this.activeIndex = Math.min(this.activeIndex, Math.max(0, this.pages().length - 1))
    this.selectedFrame = undefined
  }

  async selectFrame(target: string): Promise<Frame> {
    const page = this.currentPage()
    if (target === 'main') {
      this.selectedFrame = undefined
      return page.mainFrame()
    }
    const element = await page.locator(target).first().elementHandle()
    const frame = await element?.contentFrame()
    if (!frame) throw new BrowserDataError('invalid_command', `selector is not an attached frame: ${target}`)
    this.selectedFrame = frame
    return frame
  }

  list(): Array<{ index: number; active: boolean; url: string; title: string }> {
    return this.pages().map((page, index) => {
      const metadata = this.metadata.get(page)
      return {
        index,
        active: index === this.activeIndex,
        url: metadata?.url ?? page.url(),
        title: metadata?.title ?? ''
      }
    })
  }

  cachedURL(): string {
    const page = this.currentPage()
    return this.metadata.get(page)?.url ?? page.url()
  }

  cachedTitle(): string {
    return this.metadata.get(this.currentPage())?.title ?? ''
  }

  async refreshMetadata(page = this.currentPage()): Promise<void> {
    const existing = this.metadata.get(page) ?? { url: page.url(), title: '' }
    existing.url = page.url()
    try {
      existing.title = await page.title()
    } catch {
      // Native dialogs and closing pages can block/reject renderer reads. Keep cached title.
    }
    this.metadata.set(page, existing)
  }

  private currentPageOrUndefined(): Page | undefined {
    const pages = this.pages()
    if (pages.length === 0) return undefined
    if (this.activeIndex >= pages.length) this.activeIndex = pages.length - 1
    return pages[this.activeIndex]
  }

  private install(page: Page): void {
    if (this.installed.has(page)) return
    this.installed.add(page)
    this.metadata.set(page, { url: page.url(), title: '' })
    page.on('framenavigated', frame => {
      if (frame === page.mainFrame()) {
        const metadata = this.metadata.get(page) ?? { url: '', title: '' }
        metadata.url = frame.url()
        this.metadata.set(page, metadata)
        this.selectedFrame = undefined
      }
    })
    page.on('close', () => {
      this.selectedFrame = undefined
      this.activeIndex = Math.min(this.activeIndex, Math.max(0, this.pages().length - 1))
    })
    this.onPageInstalled(page)
  }
}
