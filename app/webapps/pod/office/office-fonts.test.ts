import { afterEach, describe, expect, it } from 'bun:test'
import { resolveOfficeFontBlobs, type OfficeFontManifestEntry } from './office-fonts'

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
    family: 'Noto Sans SC',
    aliases: ['Noto Sans CJK SC', 'Microsoft YaHei', '微软雅黑', 'PingFang SC'],
    file: 'NotoSansSC-VF.ttf'
  },
  {
    family: 'Noto Serif SC',
    aliases: ['Noto Serif CJK SC', 'SimSun', '宋体'],
    file: 'NotoSerifSC-VF.ttf'
  },
  {
    family: 'Noto Sans TC',
    aliases: ['Noto Sans CJK TC', 'Microsoft JhengHei', '微軟正黑體'],
    file: 'NotoSansTC-VF.ttf'
  },
  {
    family: 'Noto Serif TC',
    aliases: ['Noto Serif CJK TC', 'PMingLiU', '新細明體'],
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

function installFakeFontServer(handler?: (url: string) => Response | undefined) {
  const requestedFiles: string[] = []
  globalThis.fetch = (async (input: RequestInfo | URL) => {
    const url = typeof input === 'string' ? input : input instanceof URL ? input.pathname : input.url
    const override = handler?.(url)
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

afterEach(() => {
  globalThis.fetch = originalFetch
})

describe('resolveOfficeFontBlobs', () => {
  it('fetches only the matching regional CJK variable font instead of all eight CJK bundles', async () => {
    const sc = installFakeFontServer()
    const scResult = await resolveOfficeFontBlobs(['微软雅黑'])
    expect(sc.requestedFiles).toEqual(['NotoSansSC-VF.ttf'])
    expect(scResult.blobs).toHaveLength(1)
    expect(scResult.complete).toBe(true)

    const jp = installFakeFontServer()
    await resolveOfficeFontBlobs(['游ゴシック'])
    expect(jp.requestedFiles).toEqual(['NotoSansJP-VF.ttf'])

    const kr = installFakeFontServer()
    await resolveOfficeFontBlobs(['맑은 고딕'])
    expect(kr.requestedFiles).toEqual(['NotoSansKR-VF.ttf'])
  })

  it('infers regional Noto Sans CJK fallback by script for unmapped non-ASCII font names', async () => {
    const server = installFakeFontServer()
    await resolveOfficeFontBlobs(['カスタム書体', '한글전용체', '汉仪定制体'])
    expect(server.requestedFiles).toEqual(['NotoSansSC-VF.ttf', 'NotoSansJP-VF.ttf', 'NotoSansKR-VF.ttf'])
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

    // First attempt: manifest 503 is evicted and reported incomplete.
    expect(await resolveOfficeFontBlobs(['Consolas'])).toEqual({ blobs: [], complete: false })
    // Second attempt: manifest succeeds, blob 502 is evicted and reported incomplete.
    expect(await resolveOfficeFontBlobs(['Consolas'])).toEqual({ blobs: [], complete: false })
    // Third attempt: cached manifest + retried blob succeeds completely.
    const third = await resolveOfficeFontBlobs(['Consolas'])
    expect(third.complete).toBe(true)
    expect(third.blobs).toHaveLength(1)
    expect(server.requestedFiles).toEqual(['JetBrainsMono-Regular.ttf'])
  })
})
