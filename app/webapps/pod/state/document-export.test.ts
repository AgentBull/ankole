import { afterEach, beforeAll, beforeEach, describe, expect, test } from 'bun:test'
import { QueryClient } from '@tanstack/react-query'
import { strFromU8, unzipSync } from 'fflate'
import { podLocation } from '../../common/browser-context'
import { loadLocale } from '../../common/i18n'
import { client as podClient } from '../api/generated/client.gen'
import type { PageDetail } from '../content-api'
import { downloadDocument } from './document-export'

beforeAll(() => loadLocale('en-US'))

const docID = '00112233-4455-6677-8899-aabbccddeeff'
const mentionFileID = '11111111-2222-3333-4444-555555555555'
const linkFileID = '22222222-3333-4444-5555-666666666666'
const embedFileID = '33333333-4444-5555-6666-777777777777'

const previousWindow = Object.getOwnPropertyDescriptor(globalThis, 'window')
const previousDocument = Object.getOwnPropertyDescriptor(globalThis, 'document')
const previousFetch = globalThis.fetch
const previousCreateObjectURL = URL.createObjectURL
const previousRevokeObjectURL = URL.revokeObjectURL

let downloads: Array<{ filename: string; blob: Blob }>
let objectBlobs: Map<string, Blob>

function pageURL(id: string): string {
  return new URL(podLocation(`/pages/${id}`).pathname, 'https://ankole.test').href
}

function pageDetail(id: string, title: string, type: PageDetail['page']['type']): PageDetail {
  return {
    page: {
      id,
      title,
      icon: null,
      type,
      position: 'a0',
      inherit_permissions: true,
      revision: 1,
      children_view: {},
      created_at: '2026-10-30T10:00:00Z',
      updated_at: '2026-10-30T10:00:00Z',
      deleted_at: null,
      actions: ['node_view'],
      role: 'view'
    },
    ancestors: [],
    actions: ['node_view'],
    role: 'view',
    child_count: 0
  }
}

beforeEach(() => {
  downloads = []
  objectBlobs = new Map()
  podClient.setConfig({ baseUrl: 'https://ankole.test' })
  URL.createObjectURL = (object: Blob | MediaSource) => {
    const url = `blob:ankole/${objectBlobs.size + 1}`
    if (object instanceof Blob) objectBlobs.set(url, object)
    return url
  }
  URL.revokeObjectURL = () => {}

  const fakeDocument = {
    documentElement: { lang: 'en-US' },
    querySelector: (selector: string) =>
      selector.includes('csrf-token')
        ? { content: 'csrf-test' }
        : selector.includes('ankole-authentication')
          ? { content: 'auth-1' }
          : null,
    createElement: (tag: string) => {
      if (tag !== 'a') throw new Error(`Unexpected element: ${tag}`)
      const anchor = {
        href: '',
        download: '',
        click() {
          const blob = objectBlobs.get(anchor.href)
          if (blob) downloads.push({ filename: anchor.download, blob })
        }
      }
      return anchor
    }
  }
  Object.defineProperty(globalThis, 'document', { configurable: true, value: fakeDocument })
  Object.defineProperty(globalThis, 'window', {
    configurable: true,
    value: {
      location: new URL(pageURL(docID)),
      document: fakeDocument
    }
  })
})

afterEach(() => {
  if (previousWindow) Object.defineProperty(globalThis, 'window', previousWindow)
  else Reflect.deleteProperty(globalThis, 'window')
  if (previousDocument) Object.defineProperty(globalThis, 'document', previousDocument)
  else Reflect.deleteProperty(globalThis, 'document')
  globalThis.fetch = previousFetch
  URL.createObjectURL = previousCreateObjectURL
  URL.revokeObjectURL = previousRevokeObjectURL
})

describe('downloadDocument', () => {
  test('inline File Page mentions and links remain Web URLs without fetching or bundling their binaries', async () => {
    const requestedPaths: string[] = []
    globalThis.fetch = (async (input: RequestInfo | URL) => {
      const url = new URL(input instanceof Request ? input.url : String(input), 'https://ankole.test')
      requestedPaths.push(url.pathname)
      if (url.pathname === `/api/v2/pod/pages/${mentionFileID}`) {
        return Response.json(pageDetail(mentionFileID, 'Confidential Deck', 'file'))
      }
      if (url.pathname === `/api/v2/pod/pages/${linkFileID}`) {
        return Response.json(pageDetail(linkFileID, 'Signed Contract', 'file'))
      }
      throw new Error(`Unexpected fetch: ${url.href}`)
    }) as typeof fetch

    const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } })
    try {
      await downloadDocument(queryClient, {
        pageID: docID,
        title: 'Summary',
        xml: `<page><p>See <mention page="${mentionFileID}"/> and <a href="ankole:page/${linkFileID}">contract</a>.</p></page>`
      })

      expect(requestedPaths).toEqual([`/api/v2/pod/pages/${mentionFileID}`, `/api/v2/pod/pages/${linkFileID}`])
      expect(downloads).toHaveLength(1)
      expect(downloads[0]!.filename).toBe('Summary.md')
      expect(downloads[0]!.blob.type).toContain('text/markdown')
      const text = await downloads[0]!.blob.text()
      expect(text).toContain(`[Confidential Deck](${pageURL(mentionFileID)})`)
      expect(text).toContain(`[contract](${pageURL(linkFileID)})`)
    } finally {
      queryClient.clear()
    }
  })

  test('block-embedded File Pages stream into a ZIP archive while inline File Page mentions stay Web URLs', async () => {
    const pdfBytes = new TextEncoder().encode('%PDF-1.7 sample')
    globalThis.fetch = (async (input: RequestInfo | URL) => {
      const url = new URL(input instanceof Request ? input.url : String(input), 'https://ankole.test')
      if (url.pathname === `/api/v2/pod/pages/${embedFileID}`) {
        return Response.json(pageDetail(embedFileID, 'Budget PDF', 'file'))
      }
      if (url.pathname === `/api/v2/pod/pages/${mentionFileID}`) {
        return Response.json(pageDetail(mentionFileID, 'Appendix Sheet', 'file'))
      }
      if (url.pathname === `/api/v2/pod/pages/${embedFileID}/files`) {
        return Response.json({
          files: [{ path: 'report.pdf', sha256: 'abc123', size: pdfBytes.byteLength, mime_type: 'application/pdf' }]
        })
      }
      if (url.pathname === `/api/v2/pod/pages/${embedFileID}/files/content`) {
        return new Response(pdfBytes, { status: 200, headers: { 'content-type': 'application/pdf' } })
      }
      throw new Error(`Unexpected fetch: ${url.href}`)
    }) as typeof fetch

    const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } })
    try {
      await downloadDocument(queryClient, {
        pageID: docID,
        title: 'Quarterly Plan',
        xml: `<page><p>Context: <mention page="${mentionFileID}"/></p><embed ref="${embedFileID}"/></page>`
      })

      expect(downloads).toHaveLength(1)
      expect(downloads[0]!.filename).toBe('Quarterly-Plan.zip')
      const entries = unzipSync(new Uint8Array(await downloads[0]!.blob.arrayBuffer()))
      expect(Object.keys(entries).sort()).toEqual(['Quarterly-Plan.md', 'assets/1-report.pdf'])
      expect(entries['assets/1-report.pdf']).toEqual(pdfBytes)
      const markdown = strFromU8(entries['Quarterly-Plan.md']!)
      expect(markdown).toContain(`[Appendix Sheet](${pageURL(mentionFileID)})`)
      expect(markdown).toContain('[Budget PDF](assets/1-report.pdf)')
    } finally {
      queryClient.clear()
    }
  })

  test('missing or forbidden assets, embedded files, and custom emoji icons degrade to portable Markdown without failing', async () => {
    globalThis.fetch = (async (input: RequestInfo | URL) => {
      const url = new URL(input instanceof Request ? input.url : String(input), 'https://ankole.test')
      if (url.pathname === `/api/v2/pod/pages/${embedFileID}`) {
        return Response.json(pageDetail(embedFileID, 'Missing File', 'file'))
      }
      if (url.pathname === `/api/v2/pod/pages/${embedFileID}/files`) {
        return Response.json({ error: 'not found' }, { status: 404 })
      }
      if (url.pathname === `/api/v2/pod/pages/${docID}/files/content`) {
        return new Response('forbidden', { status: 403 })
      }
      if (url.pathname === '/api/v2/pod/metadata/files/content') {
        return new Response('not found', { status: 404 })
      }
      throw new Error(`Unexpected fetch: ${url.href}`)
    }) as typeof fetch

    const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } })
    try {
      await downloadDocument(queryClient, {
        pageID: docID,
        title: '.env',
        icon: 'metadata/custom-emoji/deleted.png',
        xml: `<page><p><img src="ankole:asset/hash/diagram.png" alt="Diagram"/></p><embed ref="${embedFileID}"/></page>`
      })

      expect(downloads).toHaveLength(1)
      expect(downloads[0]!.filename).toBe('env.md')
      const markdown = await downloads[0]!.blob.text()
      expect(markdown).not.toContain('metadata/custom-emoji/deleted.png')
      expect(markdown).not.toContain('authentication_ref')
      expect(markdown).toContain(
        `![Diagram](https://ankole.test/api/v2/pod/pages/${docID}/files/content?path=assets%2Fhash%2Fdiagram.png)`
      )
      expect(markdown).toContain(`[Missing File](${pageURL(embedFileID)})`)
    } finally {
      queryClient.clear()
    }
  })
})
