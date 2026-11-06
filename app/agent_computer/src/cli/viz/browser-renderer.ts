import { existsSync, mkdirSync, mkdtempSync, readdirSync, renameSync, rmSync, statSync, writeFileSync } from 'node:fs'
import { mkdir, writeFile } from 'node:fs/promises'
import { createRequire } from 'node:module'
import { homedir, tmpdir } from 'node:os'
import { dirname, extname, join, resolve } from 'node:path'
import { pathToFileURL } from 'node:url'
import type { AnkoleVizBrowserHarness, HarnessChromeMode, HarnessJobOutcome, HarnessJobPayload } from './harness-entry'
import { buildVizHarnessBundle } from './build-harness'
import type { VizKind } from './validator'

interface MinimalLocator {
  screenshot(options: { type: 'png'; scale?: 'css' | 'device' }): Promise<Buffer>
}

interface MinimalPage {
  goto(url: string, options?: { waitUntil?: 'load' | 'domcontentloaded' | 'networkidle' }): Promise<unknown>
  setViewportSize(viewportSize: { width: number; height: number }): Promise<void>
  waitForFunction(pageFunction: () => unknown, arg?: unknown, options?: { timeout?: number }): Promise<unknown>
  evaluate<R, Arg>(pageFunction: (arg: Arg) => R | Promise<R>, arg: Arg): Promise<R>
  evaluate<R>(pageFunction: () => R | Promise<R>): Promise<R>
  locator(selector: string): MinimalLocator
}

interface MinimalBrowserContext {
  newPage(): Promise<MinimalPage>
  close(): Promise<void>
}

interface MinimalBrowser {
  newContext(options?: {
    viewport?: { width: number; height: number }
    deviceScaleFactor?: number
  }): Promise<MinimalBrowserContext>
  close(): Promise<void>
}

interface MinimalChromiumType {
  executablePath(): string
  launch(options: { executablePath: string; headless: boolean; args: string[] }): Promise<MinimalBrowser>
}

export interface VizRenderOutput {
  ok: true
  kind: VizKind
  path: string
  format: 'svg' | 'png'
  width: number
  height: number
  printSafe: boolean
  fallbackReason?: 'foreignObject' | 'canvas'
}

const DEFAULT_HARNESS_BUNDLE_PATH = '/opt/ankole-viz/dist/harness-entry.js'

let cachedBundlePromise: Promise<string> | null = null

export async function ensureHarnessBundlePath(): Promise<string> {
  const configured = process.env.ANKOLE_VIZ_HARNESS_JS?.trim() || DEFAULT_HARNESS_BUNDLE_PATH
  if (existsSync(configured)) {
    return configured
  }

  if (cachedBundlePromise) {
    return cachedBundlePromise
  }

  cachedBundlePromise = (async () => {
    const entrypoint = join(import.meta.dir, 'harness-entry.ts')
    const buildHelper = join(import.meta.dir, 'build-harness.ts')
    const cacheDir = join(tmpdir(), 'ankole-viz-harness-cache')
    mkdirSync(cacheDir, { recursive: true })
    const targetBundle = join(cacheDir, 'harness-entry.js')

    if (existsSync(targetBundle)) {
      try {
        const latestSrcMtime = Math.max(statSync(entrypoint).mtimeMs, statSync(buildHelper).mtimeMs)
        const bundleStat = statSync(targetBundle)
        if (bundleStat.size > 0 && bundleStat.mtimeMs >= latestSrcMtime) {
          return targetBundle
        }
      } catch {
        // Rebuild below if stat fails.
      }
    }

    const stagingDir = join(cacheDir, `build-${process.pid}-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`)
    mkdirSync(stagingDir, { recursive: true })
    try {
      const stagedFile = await buildVizHarnessBundle(stagingDir)
      renameSync(stagedFile, targetBundle)
      return targetBundle
    } finally {
      rmSync(stagingDir, { recursive: true, force: true })
    }
  })()

  try {
    return await cachedBundlePromise
  } catch (error) {
    cachedBundlePromise = null
    throw error
  }
}

function resolvePlaywrightChromium(): MinimalChromiumType {
  const baseRequire = createRequire(import.meta.url)
  const packageCandidates: string[] = []
  try {
    packageCandidates.push(baseRequire.resolve('@ankole/browser/package.json'))
  } catch {
    // Fallback to explicit locations below.
  }
  packageCandidates.push(
    '/opt/ankole-browser/package.json',
    resolve(import.meta.dir, '../../../../ankole-browser/package.json')
  )

  for (const pkgPath of packageCandidates) {
    if (!existsSync(pkgPath)) continue
    try {
      const pkgRequire = createRequire(pkgPath)
      const mod = pkgRequire('playwright-core') as { chromium?: MinimalChromiumType }
      if (mod?.chromium) {
        return mod.chromium
      }
    } catch {
      // Try next candidate.
    }
  }

  throw new Error('Unable to resolve playwright-core from @ankole/browser or /opt/ankole-browser.')
}

function scanPlaywrightCacheForChromium(): string | undefined {
  const cacheRoots = [
    process.env.PLAYWRIGHT_BROWSERS_PATH?.trim(),
    '/opt/ankole-browser/browsers',
    join(homedir(), 'Library', 'Caches', 'ms-playwright'),
    join(homedir(), '.cache', 'ms-playwright')
  ].filter((p): p is string => Boolean(p && existsSync(p)))

  const relativeExecutables = [
    'chrome-headless-shell-linux64/chrome-headless-shell',
    'chrome-headless-shell-mac-arm64/chrome-headless-shell',
    'chrome-headless-shell-mac-x64/chrome-headless-shell',
    'chrome-linux/chrome',
    'chrome-linux/headless_shell',
    'chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing',
    'chrome-mac/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing',
    'chrome-mac-arm64/Chromium.app/Contents/MacOS/Chromium',
    'chrome-mac/Chromium.app/Contents/MacOS/Chromium'
  ]

  for (const root of cacheRoots) {
    let entries: string[] = []
    try {
      entries = readdirSync(root)
        .filter(name => name.startsWith('chromium'))
        .sort()
        .reverse()
    } catch {
      continue
    }
    for (const dirName of entries) {
      for (const rel of relativeExecutables) {
        const candidate = join(root, dirName, rel)
        if (existsSync(candidate)) {
          return candidate
        }
      }
    }
  }

  return undefined
}

export function resolveChromiumExecutablePath(chromium: MinimalChromiumType): string {
  const envExecutable = process.env.ANKOLE_BROWSER_CHROMIUM_EXECUTABLE?.trim()
  const directCandidates = [
    envExecutable,
    '/opt/ankole-browser/browsers/chromium/chrome-headless-shell',
    '/usr/local/bin/chromium',
    '/usr/bin/chromium',
    '/usr/bin/chromium-browser'
  ]

  for (const candidate of directCandidates) {
    if (candidate && existsSync(candidate)) {
      return candidate
    }
  }

  try {
    const pwDefault = chromium.executablePath()
    if (pwDefault && existsSync(pwDefault)) {
      return pwDefault
    }
  } catch {
    // Fall through to cache scan.
  }

  const scanned = scanPlaywrightCacheForChromium()
  if (scanned) {
    return scanned
  }

  throw new Error(
    'Chromium executable not found. Set ANKOLE_BROWSER_CHROMIUM_EXECUTABLE or install Playwright Chromium.'
  )
}

function buildHarnessHtml(bundleFileUrl: string): string {
  return `<!doctype html>
<html lang="zh-CN" data-theme="light">
  <head>
    <meta charset="utf-8" />
    <style>
      @font-face {
        font-family: 'IBMPlexSansCN';
        src: local('IBM Plex Sans SC'), local('Noto Sans CJK SC'), local('PingFang SC'), local('Hiragino Sans GB');
      }
      @font-face {
        font-family: 'IBMPlexMonoCN';
        src: local('IBMPlexMonoSCHalf'), local('IBM Plex Mono'), local('SFMono-Regular'), local('Menlo');
      }
      html, body {
        margin: 0;
        padding: 0;
        background: transparent;
        font-family: 'IBMPlexSansCN', 'Noto Sans CJK SC', 'PingFang SC', sans-serif;
        -webkit-font-smoothing: antialiased;
        text-rendering: geometricPrecision;
      }
      #viz-root {
        display: inline-block;
        margin: 0;
        padding: 0;
      }
    </style>
  </head>
  <body>
    <div id="viz-root"></div>
    <script type="module" src="${bundleFileUrl}"></script>
  </body>
</html>
`
}

export function readPngDimensions(pngBuffer: Buffer): { width: number; height: number } {
  if (
    pngBuffer.length >= 24 &&
    pngBuffer[0] === 0x89 &&
    pngBuffer[1] === 0x50 &&
    pngBuffer[2] === 0x4e &&
    pngBuffer[3] === 0x47
  ) {
    return {
      width: pngBuffer.readUInt32BE(16),
      height: pngBuffer.readUInt32BE(20)
    }
  }
  throw new Error('Captured screenshot is not a valid PNG buffer.')
}

export function rewriteExtensionToPng(outputPath: string): string {
  if (extname(outputPath).toLowerCase() === '.svg') {
    return `${outputPath.slice(0, -4)}.png`
  }
  return outputPath
}

interface DprPageState {
  context: MinimalBrowserContext
  page: MinimalPage
  viewportWidth: number
  viewportHeight: number
}

export interface BrowserRenderRequest {
  payload: HarnessJobPayload
  outputPath: string
  dpr: number
}

/**
 * Manages a single headless Chromium instance and local `file://` harness page across one or
 * more visualization jobs (powering both single-chart renders and `ankole-viz batch`).
 */
export class VizBrowserSession {
  private browser: MinimalBrowser | null = null
  private tempHtmlDir: string | null = null
  private htmlFileUrl: string | null = null
  private readonly pagesByDpr = new Map<number, DprPageState>()

  private async ensureBrowserAndHtml(): Promise<{ browser: MinimalBrowser; htmlFileUrl: string }> {
    if (this.browser && this.htmlFileUrl) {
      return { browser: this.browser, htmlFileUrl: this.htmlFileUrl }
    }

    const bundlePath = await ensureHarnessBundlePath()
    const chromium = resolvePlaywrightChromium()
    const executablePath = resolveChromiumExecutablePath(chromium)

    const tempDir = mkdtempSync(join(tmpdir(), 'ankole-viz-stage-'))
    const htmlPath = join(tempDir, 'index.html')
    writeFileSync(htmlPath, buildHarnessHtml(pathToFileURL(bundlePath).href), 'utf8')

    try {
      const browser = await chromium.launch({
        executablePath,
        headless: true,
        args: [
          '--no-sandbox',
          '--disable-setuid-sandbox',
          '--disable-dev-shm-usage',
          '--font-render-hinting=none',
          '--allow-file-access-from-files'
        ]
      })
      this.tempHtmlDir = tempDir
      this.htmlFileUrl = pathToFileURL(htmlPath).href
      this.browser = browser
      return { browser, htmlFileUrl: this.htmlFileUrl }
    } catch (error) {
      rmSync(tempDir, { recursive: true, force: true })
      throw error
    }
  }

  private async getPageForDpr(dpr: number, minWidth: number, minHeight: number): Promise<MinimalPage> {
    const safeDpr = Number.isFinite(dpr) && dpr > 0 ? dpr : 2
    const existing = this.pagesByDpr.get(safeDpr)
    const desiredWidth = Math.max(1600, Math.ceil(minWidth) + 200)
    const desiredHeight = Math.max(1200, Math.ceil(minHeight) + 240)

    if (existing) {
      if (desiredWidth > existing.viewportWidth || desiredHeight > existing.viewportHeight) {
        const nextW = Math.max(existing.viewportWidth, desiredWidth)
        const nextH = Math.max(existing.viewportHeight, desiredHeight)
        await existing.page.setViewportSize({ width: nextW, height: nextH })
        existing.viewportWidth = nextW
        existing.viewportHeight = nextH
      }
      return existing.page
    }

    const { browser, htmlFileUrl } = await this.ensureBrowserAndHtml()
    const context = await browser.newContext({
      viewport: { width: desiredWidth, height: desiredHeight },
      deviceScaleFactor: safeDpr
    })
    const page = await context.newPage()
    await page.goto(htmlFileUrl, { waitUntil: 'load' })
    await page.waitForFunction(
      () => Boolean((window as unknown as { __ANKOLE_VIZ_HARNESS__?: AnkoleVizBrowserHarness }).__ANKOLE_VIZ_HARNESS__),
      undefined,
      { timeout: 15_000 }
    )
    await page.evaluate(() => document.fonts.ready.then(() => true))

    this.pagesByDpr.set(safeDpr, {
      context,
      page,
      viewportWidth: desiredWidth,
      viewportHeight: desiredHeight
    })
    return page
  }

  async renderJob(req: BrowserRenderRequest): Promise<VizRenderOutput> {
    const { payload, dpr } = req
    const estWidth = payload.width ?? 1000
    const estHeight = payload.height ?? 800
    const page = await this.getPageForDpr(dpr, estWidth, estHeight)

    const outcome: HarnessJobOutcome = await page.evaluate(
      (job: HarnessJobPayload) => window.__ANKOLE_VIZ_HARNESS__!.runJob(job),
      payload
    )

    if (!outcome.needsPngCapture && outcome.svg !== undefined) {
      await mkdir(dirname(req.outputPath), { recursive: true })
      await writeFile(req.outputPath, outcome.svg, 'utf8')
      return {
        ok: true,
        kind: payload.kind,
        path: req.outputPath,
        format: 'svg',
        width: outcome.svgWidth ?? estWidth,
        height: outcome.svgHeight ?? estHeight,
        printSafe: outcome.isPrintSafe
      }
    }

    const pngBuffer = await page.locator('#viz-stage').screenshot({
      type: 'png',
      scale: 'device'
    })
    const dims = readPngDimensions(pngBuffer)
    const finalPath = outcome.fallbackReason ? rewriteExtensionToPng(req.outputPath) : req.outputPath

    await mkdir(dirname(finalPath), { recursive: true })
    await writeFile(finalPath, pngBuffer)

    return {
      ok: true,
      kind: payload.kind,
      path: finalPath,
      format: 'png',
      width: dims.width,
      height: dims.height,
      printSafe: true,
      ...(outcome.fallbackReason ? { fallbackReason: outcome.fallbackReason } : {})
    }
  }

  async close(): Promise<void> {
    for (const state of this.pagesByDpr.values()) {
      try {
        await state.context.close()
      } catch {
        // Ignore teardown errors.
      }
    }
    this.pagesByDpr.clear()

    if (this.browser) {
      try {
        await this.browser.close()
      } catch {
        // Ignore teardown errors.
      }
      this.browser = null
    }

    if (this.tempHtmlDir) {
      rmSync(this.tempHtmlDir, { recursive: true, force: true })
      this.tempHtmlDir = null
    }
    this.htmlFileUrl = null
  }
}

export type { HarnessChromeMode }
