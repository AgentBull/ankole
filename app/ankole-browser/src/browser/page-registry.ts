import type { BrowserContext, Frame, Page } from 'playwright-core'
import { BrowserDataError } from '../errors'

type PageMetadata = {
  url: string
  title: string
}

export class PageRegistry {
  private selectedPage?: Page
  private selectedFrame?: Frame
  private readonly metadata = new Map<Page, PageMetadata>()

  constructor(
    readonly context: BrowserContext,
    private readonly onPageInstalled: (page: Page) => void
  ) {
    for (const page of context.pages()) this.install(page)
    context.on('page', page => {
      this.install(page)
      this.selectedPage = page
      this.selectedFrame = undefined
    })
  }

  pages(): Page[] {
    return [...this.metadata.keys()].filter(page => !page.isClosed())
  }

  async ensurePage(): Promise<Page> {
    const current = this.currentPageOrUndefined()
    if (current) return current
    const page = await this.context.newPage()
    this.install(page)
    this.selectedPage = page
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

  async newPage(): Promise<Page> {
    const page = await this.context.newPage()
    this.install(page)
    this.selectedPage = page
    this.selectedFrame = undefined
    return page
  }

  switchPage(index: number): Page {
    const page = this.pages()[index]
    if (!page) throw new BrowserDataError('invalid_command', `tab index ${index} does not exist`)
    this.selectedPage = page
    this.selectedFrame = undefined
    return page
  }

  async closePage(index: number): Promise<void> {
    const page = this.pages()[index]
    if (!page) throw new BrowserDataError('invalid_command', `tab index ${index} does not exist`)
    await page.close({ runBeforeUnload: false })
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
        active: page === this.currentPageOrUndefined(),
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
    if (!this.selectedPage || !pages.includes(this.selectedPage)) this.selectedPage = pages[0]
    return this.selectedPage
  }

  private install(page: Page): void {
    if (this.metadata.has(page) || page.isClosed()) return
    this.metadata.set(page, { url: page.url(), title: '' })
    page.on('framenavigated', frame => {
      if (frame === page.mainFrame()) {
        const metadata = this.metadata.get(page) ?? { url: '', title: '' }
        metadata.url = frame.url()
        this.metadata.set(page, metadata)
        if (this.selectedPage === page) this.selectedFrame = undefined
      }
    })
    page.on('close', () => {
      const index = [...this.metadata.keys()].indexOf(page)
      this.metadata.delete(page)
      if (this.selectedPage === page) {
        const pages = this.pages()
        this.selectedPage = pages[Math.min(index, pages.length - 1)]
        this.selectedFrame = undefined
      }
    })
    this.onPageInstalled(page)
  }
}
