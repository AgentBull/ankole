import { afterEach, describe, expect, it } from 'bun:test'
import type { OfficeSnapshotBase, OfficeSyncEngine } from './office-collaboration'
import {
  createOfficeFontCoordinator,
  resolveOfficeFontBlobs,
  selectPendingFontFamilies,
  type OfficeFontCoordinator,
  type OfficeFontManifestEntry
} from './office-fonts'

const MANIFEST_FONTS: OfficeFontManifestEntry[] = [
  { family: 'Carlito', aliases: ['Calibri'], file: 'Carlito-Regular.ttf' },
  { family: 'Carlito', aliases: ['Calibri'], file: 'Carlito-Bold.ttf' },
  { family: 'Carlito', aliases: ['Calibri'], file: 'Carlito-Italic.ttf' },
  { family: 'Carlito', aliases: ['Calibri'], file: 'Carlito-BoldItalic.ttf' },
  {
    family: 'JetBrains Mono',
    aliases: ['Consolas', 'Cascadia Mono', 'Cascadia Code'],
    file: 'JetBrainsMono-Regular.ttf'
  },
  {
    family: 'IBM Plex Sans SC',
    aliases: ['IBM Plex Sans', 'Noto Sans SC', 'Microsoft YaHei', '微软雅黑', 'PingFang SC'],
    file: 'IBMPlexSansSC-Regular.ttf'
  },
  {
    family: 'IBM Plex Sans SC',
    file: 'IBMPlexSansSC-Bold.ttf'
  },
  {
    family: '寒蝉锦书宋',
    aliases: ['ChillJinshuSong', '寒蟬錦書宋', 'Noto Serif SC', 'SimSun', '宋体', '华文宋体'],
    file: 'ChillJinshuSongRegular.ttf'
  },
  {
    family: '寒蝉锦书宋',
    file: 'ChillJinshuSongBold.ttf'
  },
  {
    family: 'LXGW WenKai GB',
    aliases: ['霞鹜文楷 GB', 'KaiTi', '楷体', 'STKaiti', '华文楷体', 'FangSong', '仿宋', 'STXingkai', '华文行楷'],
    file: 'LXGWWenKaiGB-Regular.ttf'
  },
  {
    family: 'IBMPlexMonoSCHalf',
    aliases: ['IBM Plex Mono SC'],
    file: 'IBMPlexMonoSCHalf-Regular.ttf'
  },
  {
    family: 'IBMPlexMonoSCHalf',
    file: 'IBMPlexMonoSCHalf-Bold.ttf'
  },
  {
    family: 'Noto Sans TC',
    aliases: ['Noto Sans CJK TC', 'Microsoft JhengHei', '微軟正黑體'],
    file: 'NotoSansTC-VF.ttf'
  },
  {
    family: 'Noto Serif TC',
    aliases: ['Noto Serif CJK TC', 'PMingLiU', '新細明體', 'DFKai-SB', '標楷體'],
    file: 'NotoSerifTC-VF.ttf'
  },
  {
    family: 'Noto Sans JP',
    aliases: ['Noto Sans CJK JP', 'Yu Gothic', '游ゴシック', 'Meiryo', 'メイリオ'],
    file: 'NotoSansJP-VF.ttf'
  },
  {
    family: 'Noto Serif JP',
    aliases: ['Noto Serif CJK JP', 'MS Mincho', '游明朝'],
    file: 'NotoSerifJP-VF.ttf'
  },
  {
    family: 'Noto Sans KR',
    aliases: ['Noto Sans CJK KR', 'Malgun Gothic', '맑은 고딕'],
    file: 'NotoSansKR-VF.ttf'
  },
  {
    family: 'Noto Serif KR',
    aliases: ['Noto Serif CJK KR', 'Batang', '바탕'],
    file: 'NotoSerifKR-VF.ttf'
  }
]

const originalFetch = globalThis.fetch

function installFakeFontServer(handler?: (url: string) => Response | undefined | Promise<Response | undefined>) {
  const requestedFiles: string[] = []
  globalThis.fetch = (async (input: RequestInfo | URL) => {
    const url = typeof input === 'string' ? input : input instanceof URL ? input.pathname : input.url
    const override = await handler?.(url)
    if (override) return override
    if (url === '/fonts/office/manifest.json') {
      return new Response(JSON.stringify({ fonts: MANIFEST_FONTS }), {
        status: 200,
        headers: { 'content-type': 'application/json' }
      })
    }
    const prefix = '/fonts/office/'
    if (url.startsWith(prefix)) {
      const file = url.slice(prefix.length)
      requestedFiles.push(file)
      return new Response(new TextEncoder().encode(`font:${file}`), { status: 200 })
    }
    return new Response('not found', { status: 404 })
  }) as unknown as typeof fetch

  return { requestedFiles }
}

type FakeSnapshot = OfficeSnapshotBase & {
  substitutedFonts: string[]
  missingGlyphFonts: string[]
}

function makeFakeModel(onAddFonts?: (blobs: Uint8Array[]) => FakeSnapshot) {
  const addedBatches: Uint8Array[][] = []
  const baseSnapshot: FakeSnapshot = {
    canUndo: false,
    canRedo: false,
    editing: false,
    composing: false,
    presenceSelection: null,
    substitutedFonts: [],
    missingGlyphFonts: []
  }
  const engine = {
    async addFonts(blobs: Uint8Array[]): Promise<FakeSnapshot> {
      addedBatches.push(blobs)
      return onAddFonts ? onAddFonts(blobs) : baseSnapshot
    }
  } as unknown as OfficeSyncEngine<FakeSnapshot> & {
    addFonts(blobs: Uint8Array[]): Promise<FakeSnapshot>
  }

  return {
    addedBatches,
    model: {
      async updateSelection(task: (eng: OfficeSyncEngine<FakeSnapshot>) => Promise<{ snapshot: FakeSnapshot }>) {
        const res = await task(engine)
        return res.snapshot
      }
    }
  }
}

afterEach(() => {
  globalThis.fetch = originalFetch
})

describe('resolveOfficeFontBlobs', () => {
  it('resolves Simplified Chinese Sans, Song, Kai/FangSong, Monospace, and regional TC/JP/KR families selectively', async () => {
    const kai = installFakeFontServer()
    const kaiResult = await resolveOfficeFontBlobs(['华文楷体', 'STKaiti', '仿宋'])
    expect(kai.requestedFiles).toEqual(['LXGWWenKaiGB-Regular.ttf'])
    expect(kaiResult.blobs).toHaveLength(1)
    expect(kaiResult.complete).toBe(true)

    const song = installFakeFontServer()
    const songResult = await resolveOfficeFontBlobs(['宋体', 'ChillJinshuSong'])
    expect(song.requestedFiles).toEqual(['ChillJinshuSongRegular.ttf', 'ChillJinshuSongBold.ttf'])
    expect(songResult.blobs).toHaveLength(2)
    expect(songResult.complete).toBe(true)

    const sans = installFakeFontServer()
    const sansResult = await resolveOfficeFontBlobs(['微软雅黑'])
    expect(sans.requestedFiles).toEqual(['IBMPlexSansSC-Regular.ttf', 'IBMPlexSansSC-Bold.ttf'])
    expect(sansResult.blobs).toHaveLength(2)
    expect(sansResult.complete).toBe(true)

    const mono = installFakeFontServer()
    await resolveOfficeFontBlobs(['IBMPlexMonoSCHalf'])
    expect(mono.requestedFiles).toEqual(['IBMPlexMonoSCHalf-Regular.ttf', 'IBMPlexMonoSCHalf-Bold.ttf'])

    const tc = installFakeFontServer()
    await resolveOfficeFontBlobs(['標楷體'])
    expect(tc.requestedFiles).toEqual(['NotoSerifTC-VF.ttf'])

    const jp = installFakeFontServer()
    await resolveOfficeFontBlobs(['游ゴシック'])
    expect(jp.requestedFiles).toEqual(['NotoSansJP-VF.ttf'])

    const kr = installFakeFontServer()
    await resolveOfficeFontBlobs(['맑은 고딕'])
    expect(kr.requestedFiles).toEqual(['NotoSansKR-VF.ttf'])
  })

  it('infers IBM Plex Sans SC or regional Noto Sans JP/KR by script for unmapped non-ASCII font names', async () => {
    const server = installFakeFontServer()
    await resolveOfficeFontBlobs(['カスタム書体', '한글전용체', '汉仪定制体'])
    expect(server.requestedFiles).toEqual([
      'IBMPlexSansSC-Regular.ttf',
      'IBMPlexSansSC-Bold.ttf',
      'NotoSansJP-VF.ttf',
      'NotoSansKR-VF.ttf'
    ])
  })

  it('does not treat Latin names containing "sc" such as Cascadia Code as Simplified Chinese', async () => {
    const server = installFakeFontServer()
    const { blobs, complete } = await resolveOfficeFontBlobs(['Cascadia Code'])
    expect(server.requestedFiles).toEqual(['JetBrainsMono-Regular.ttf'])
    expect(blobs).toHaveLength(1)
    expect(complete).toBe(true)
  })

  it('loads every weight file belonging to a matched multi-weight family alias', async () => {
    const server = installFakeFontServer()
    const { blobs, complete } = await resolveOfficeFontBlobs(['Calibri'])
    expect(server.requestedFiles).toEqual([
      'Carlito-Regular.ttf',
      'Carlito-Bold.ttf',
      'Carlito-Italic.ttf',
      'Carlito-BoldItalic.ttf'
    ])
    expect(blobs).toHaveLength(4)
    expect(complete).toBe(true)
  })

  it('evicts failed manifest and font blob fetches and marks them incomplete so retries succeed', async () => {
    let manifestFailuresRemaining = 1
    let blobFailuresRemaining = 1
    const server = installFakeFontServer(url => {
      if (url === '/fonts/office/manifest.json' && manifestFailuresRemaining > 0) {
        manifestFailuresRemaining--
        return new Response('unavailable', { status: 503 })
      }
      if (url === '/fonts/office/JetBrainsMono-Regular.ttf' && blobFailuresRemaining > 0) {
        blobFailuresRemaining--
        return new Response('bad gateway', { status: 502 })
      }
      return undefined
    })

    expect(await resolveOfficeFontBlobs(['Consolas'])).toEqual({ blobs: [], complete: false })
    expect(await resolveOfficeFontBlobs(['Consolas'])).toEqual({ blobs: [], complete: false })
    const third = await resolveOfficeFontBlobs(['Consolas'])
    expect(third.complete).toBe(true)
    expect(third.blobs).toHaveLength(1)
    expect(server.requestedFiles).toEqual(['JetBrainsMono-Regular.ttf'])
  })
})

describe('selectPendingFontFamilies & createOfficeFontCoordinator', () => {
  it('defers generic IBM Plex Sans SC on Pass 1 for 华文楷体 documents and avoids downloading it when Kai covers all glyphs', async () => {
    const server = installFakeFontServer()
    expect(
      selectPendingFontFamilies(
        { substitutedFamilies: ['华文楷体'], missingGlyphFamilies: ['IBM Plex Sans SC'] },
        new Set(),
        MANIFEST_FONTS
      )
    ).toEqual(['华文楷体'])

    expect(
      selectPendingFontFamilies(
        { substitutedFamilies: ['STXingkai'], missingGlyphFamilies: ['IBM Plex Sans SC'] },
        new Set(),
        MANIFEST_FONTS
      )
    ).toEqual(['stxingkai'])

    // Latin substitutions do NOT defer generic CJK glyph fallback.
    expect(
      selectPendingFontFamilies(
        { substitutedFamilies: ['Calibri'], missingGlyphFamilies: ['IBM Plex Sans SC'] },
        new Set(),
        MANIFEST_FONTS
      )
    ).toEqual(['calibri', 'ibm plex sans sc'])

    const holder: { current?: OfficeFontCoordinator } = {}
    const { addedBatches, model } = makeFakeModel(() => {
      // Simulate Worker snapshot after LXGW WenKai GB covers all Chinese glyphs: missingGlyphFonts becomes [].
      const next = {
        canUndo: false,
        canRedo: false,
        editing: false,
        composing: false,
        presenceSelection: null,
        substitutedFonts: ['华文楷体'],
        missingGlyphFonts: []
      }
      holder.current?.sync(
        { substitutedFamilies: next.substitutedFonts, missingGlyphFamilies: next.missingGlyphFonts },
        { documentLoaded: true }
      )
      return next
    })
    const coordinator = createOfficeFontCoordinator(model)
    holder.current = coordinator

    const initial = coordinator.peek(
      { substitutedFamilies: ['华文楷体'], missingGlyphFamilies: ['IBM Plex Sans SC'] },
      true
    )
    expect(initial.fontsReady).toBe(false)

    coordinator.sync(
      { substitutedFamilies: ['华文楷体'], missingGlyphFamilies: ['IBM Plex Sans SC'] },
      { documentLoaded: true }
    )
    await coordinator.waitForFonts()

    expect(server.requestedFiles).toEqual(['LXGWWenKaiGB-Regular.ttf'])
    expect(addedBatches).toHaveLength(1)
    expect(coordinator.getState()).toEqual({ epoch: 1, fontsReady: true, allSettled: true })
    coordinator.dispose()
  })

  it('escalates to Pass 2 for IBM Plex Sans SC when a rare glyph remains uncovered after Pass 1', async () => {
    const server = installFakeFontServer()
    let pass = 0
    const holder: { current?: OfficeFontCoordinator } = {}
    const { addedBatches, model } = makeFakeModel(() => {
      pass += 1
      const next: FakeSnapshot = {
        canUndo: false,
        canRedo: false,
        editing: false,
        composing: false,
        presenceSelection: null,
        substitutedFonts: ['华文楷体'],
        missingGlyphFonts: pass === 1 ? ['IBM Plex Sans SC'] : []
      }
      holder.current?.sync(
        { substitutedFamilies: next.substitutedFonts, missingGlyphFamilies: next.missingGlyphFonts },
        { documentLoaded: true }
      )
      return next
    })
    const coordinator = createOfficeFontCoordinator(model)
    holder.current = coordinator
    coordinator.sync(
      { substitutedFamilies: ['华文楷体'], missingGlyphFamilies: ['IBM Plex Sans SC'] },
      { documentLoaded: true }
    )

    await coordinator.waitForFonts()
    expect(server.requestedFiles).toEqual([
      'LXGWWenKaiGB-Regular.ttf',
      'IBMPlexSansSC-Regular.ttf',
      'IBMPlexSansSC-Bold.ttf'
    ])
    expect(addedBatches).toHaveLength(2)
    expect(coordinator.getState()).toEqual({ epoch: 2, fontsReady: true, allSettled: true })
    coordinator.dispose()
  })

  it('automatically retries transient HTTP 503 failures once and waits before resolving waitForFonts()', async () => {
    let manifestFailures = 1
    const server = installFakeFontServer(url => {
      if (url === '/fonts/office/manifest.json' && manifestFailures > 0) {
        manifestFailures -= 1
        return new Response('unavailable', { status: 503 })
      }
      return undefined
    })

    const { addedBatches, model } = makeFakeModel()
    const coordinator = createOfficeFontCoordinator(model, { retryDelayMs: 10 })
    coordinator.sync(
      { substitutedFamilies: ['华文楷体'], missingGlyphFamilies: [] },
      { documentLoaded: true, retryDelayMs: 10 }
    )
    expect(coordinator.getState().fontsReady).toBe(false)

    await coordinator.waitForFonts()
    expect(server.requestedFiles).toEqual(['LXGWWenKaiGB-Regular.ttf'])
    expect(addedBatches).toHaveLength(1)
    expect(coordinator.getState()).toEqual({ epoch: 1, fontsReady: true, allSettled: true })
    coordinator.dispose()
  })

  it('releases the initial skeleton gate on timeout while waitForFonts() still awaits in-flight downloads', async () => {
    let releaseFontFetch!: () => void
    const fontGate = new Promise<void>(resolve => {
      releaseFontFetch = resolve
    })
    installFakeFontServer(async url => {
      if (url === '/fonts/office/LXGWWenKaiGB-Regular.ttf') {
        await fontGate
      }
      return undefined
    })

    const { addedBatches, model } = makeFakeModel()
    const coordinator = createOfficeFontCoordinator(model, { initialGateTimeoutMs: 15 })
    coordinator.sync(
      { substitutedFamilies: ['华文楷体'], missingGlyphFamilies: [] },
      { documentLoaded: true, initialGateTimeoutMs: 15 }
    )
    expect(coordinator.getState().fontsReady).toBe(false)

    await new Promise(resolve => setTimeout(resolve, 25))
    expect(coordinator.getState().fontsReady).toBe(true)
    expect(coordinator.getState().allSettled).toBe(false)

    let exportResolved = false
    const exportWait = coordinator.waitForFonts().then(() => {
      exportResolved = true
    })
    await Promise.resolve()
    expect(exportResolved).toBe(false)

    releaseFontFetch()
    await exportWait
    expect(exportResolved).toBe(true)
    expect(addedBatches).toHaveLength(1)
    expect(coordinator.getState()).toEqual({ epoch: 1, fontsReady: true, allSettled: true })
    coordinator.dispose()
  })

  it('fetches Office font manifests and blobs from ankole-static-base with omitted credentials when CDN is configured', async () => {
    const originalDocument = Object.getOwnPropertyDescriptor(globalThis, 'document')
    Object.defineProperty(globalThis, 'document', {
      configurable: true,
      value: {
        querySelector: (selector: string) =>
          selector === 'meta[name="ankole-static-base"]' ? { content: '//cdn.example.com' } : null
      }
    })

    const observedRequests: Array<{ url: string; credentials: RequestCredentials | undefined }> = []
    globalThis.fetch = (async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = typeof input === 'string' ? input : input instanceof URL ? input.toString() : input.url
      observedRequests.push({ url, credentials: init?.credentials })
      if (url === '//cdn.example.com/fonts/office/manifest.json') {
        return new Response(JSON.stringify({ version: 2, fonts: MANIFEST_FONTS }), {
          status: 200,
          headers: { 'content-type': 'application/json' }
        })
      }
      if (url === '//cdn.example.com/fonts/office/LXGWWenKaiGB-Regular.ttf') {
        return new Response(new Uint8Array([1, 2, 3, 4]), { status: 200 })
      }
      return new Response('not found', { status: 404 })
    }) as typeof fetch

    try {
      const result = await resolveOfficeFontBlobs(['华文楷体'])
      expect(result.complete).toBe(true)
      expect(result.blobs).toHaveLength(1)
      expect(observedRequests).toEqual([
        {
          url: '//cdn.example.com/fonts/office/manifest.json',
          credentials: 'omit'
        },
        {
          url: '//cdn.example.com/fonts/office/LXGWWenKaiGB-Regular.ttf',
          credentials: 'omit'
        }
      ])
    } finally {
      if (originalDocument) Object.defineProperty(globalThis, 'document', originalDocument)
      else Reflect.deleteProperty(globalThis, 'document')
    }
  })

  it('defers IBM Plex Sans SC on cold start for ASCII manifest aliases like STXingkai just like 华文行楷', async () => {
    const server = installFakeFontServer()
    const holder: { current?: OfficeFontCoordinator } = {}
    const { addedBatches, model } = makeFakeModel(() => {
      const next: FakeSnapshot = {
        canUndo: false,
        canRedo: false,
        editing: false,
        composing: false,
        presenceSelection: null,
        substitutedFonts: ['STXingkai'],
        missingGlyphFonts: []
      }
      holder.current?.sync(
        { substitutedFamilies: next.substitutedFonts, missingGlyphFamilies: next.missingGlyphFonts },
        { documentLoaded: true }
      )
      return next
    })

    const coordinator = createOfficeFontCoordinator(model)
    holder.current = coordinator
    coordinator.sync(
      { substitutedFamilies: ['STXingkai'], missingGlyphFamilies: ['IBM Plex Sans SC'] },
      { documentLoaded: true }
    )
    await coordinator.waitForFonts()

    // Must download ONLY LXGWWenKaiGB-Regular.ttf and never request IBMPlexSansSC-*.ttf.
    expect(server.requestedFiles).toEqual(['LXGWWenKaiGB-Regular.ttf'])
    expect(addedBatches).toHaveLength(1)
    expect(coordinator.getState()).toEqual({ epoch: 1, fontsReady: true, allSettled: true })
    coordinator.dispose()
  })

  it('recovers cleanly across React StrictMode mount -> dispose -> remount replay without stranding fontsReady', async () => {
    const server = installFakeFontServer()
    const { addedBatches, model } = makeFakeModel()
    const coordinator = createOfficeFontCoordinator(model)

    let notifications = 0
    // Mount 1 (StrictMode initial effect pass)
    const unsub1 = coordinator.subscribe(() => {
      notifications += 1
    })
    coordinator.sync(
      { substitutedFamilies: ['STXingkai'], missingGlyphFamilies: [] },
      { documentLoaded: true, initialGateTimeoutMs: 50 }
    )

    // StrictMode immediate effect cleanup before async font load settles
    unsub1()
    coordinator.dispose()

    // StrictMode immediate effect remount with the same memoized coordinator instance
    const unsub2 = coordinator.subscribe(() => {
      notifications += 1
    })
    coordinator.sync(
      { substitutedFamilies: ['STXingkai'], missingGlyphFamilies: [] },
      { documentLoaded: true, initialGateTimeoutMs: 50 }
    )

    await coordinator.waitForFonts()
    expect(server.requestedFiles).toEqual(['LXGWWenKaiGB-Regular.ttf'])
    expect(addedBatches).toHaveLength(1)
    expect(notifications).toBeGreaterThan(0)
    expect(coordinator.getState()).toEqual({ epoch: 1, fontsReady: true, allSettled: true })
    expect(coordinator.peek({ substitutedFamilies: ['STXingkai'], missingGlyphFamilies: [] }, true)).toEqual({
      epoch: 1,
      fontsReady: true
    })

    unsub2()
    coordinator.dispose()
  })

  it('bootstraps base Latin fonts and gates fontsReady on blank documents when WASM starts with 0 embedded fonts', async () => {
    const server = installFakeFontServer()
    const { addedBatches, model } = makeFakeModel()
    const coordinator = createOfficeFontCoordinator(model)

    expect(coordinator.peek({ substitutedFamilies: [], missingGlyphFamilies: [] }, true)).toEqual({
      epoch: 0,
      fontsReady: false
    })

    const initial = coordinator.sync({ substitutedFamilies: [], missingGlyphFamilies: [] }, { documentLoaded: true })
    expect(initial.fontsReady).toBe(false)

    await coordinator.waitForFonts()
    expect(server.requestedFiles).toEqual([
      'Carlito-Regular.ttf',
      'Carlito-Bold.ttf',
      'Carlito-Italic.ttf',
      'Carlito-BoldItalic.ttf'
    ])
    expect(addedBatches).toHaveLength(1)
    expect(coordinator.getState()).toEqual({ epoch: 1, fontsReady: true, allSettled: true })
    coordinator.dispose()
  })

  it('falls back to base Latin and Monospace manifest faces for unmapped ASCII font names', async () => {
    const sansServer = installFakeFontServer()
    const sansResult = await resolveOfficeFontBlobs(['Avenir Next'])
    expect(sansResult.complete).toBe(true)
    expect(sansServer.requestedFiles).toEqual([
      'Carlito-Regular.ttf',
      'Carlito-Bold.ttf',
      'Carlito-Italic.ttf',
      'Carlito-BoldItalic.ttf'
    ])

    const monoServer = installFakeFontServer()
    const monoResult = await resolveOfficeFontBlobs(['Inconsolata Mono'])
    expect(monoResult.complete).toBe(true)
    expect(monoServer.requestedFiles).toEqual(['JetBrainsMono-Regular.ttf'])
  })
})
