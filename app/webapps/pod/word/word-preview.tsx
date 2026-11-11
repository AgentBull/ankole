import { t } from 'i18next'
import { useEffect, useMemo, useRef, useState } from 'react'
import { readPrefix } from '../../common/browser-files'
import { createClientConfig } from '../../common/internal-api-client'
import { ContentSkeleton } from '../content-primitives'
import { inertOfficeChannel, OfficeCollaborationModel, type OfficeSource } from '../office/office-collaboration'
import { createWordEngine, type WordSession, type WordSnapshot } from './word-engine'
import { WordDocumentSurface } from './word-page'

const transport = createClientConfig({}).fetch!
const MAX_PREVIEW_BYTES = 25 * 1024 * 1024

function previewTitleFromUrl(url: string): string {
  try {
    const parsed = new URL(url, 'https://ankole.local')
    const segment = parsed.pathname.split('/').filter(Boolean).at(-1)
    if (segment) {
      const decoded = decodeURIComponent(segment).trim()
      if (decoded) return decoded
    }
  } catch {
    // Fall back to default document name when URL is malformed.
  }
  return 'document.docx'
}

async function loadPreviewDocument(url: string, local: boolean, signal: AbortSignal): Promise<OfficeSource> {
  const response = await (local ? fetch : transport)(url, {
    credentials: 'same-origin',
    signal
  })
  if (!response.ok || !response.body) {
    await response.body?.cancel()
    throw new Error(t('pod.chat_attachments.preview_unavailable'))
  }
  const result = await readPrefix(response, MAX_PREVIEW_BYTES, signal)
  if (result.truncated) return { kind: 'too_large' }
  const buffer = result.bytes.buffer.slice(
    result.bytes.byteOffset,
    result.bytes.byteOffset + result.bytes.byteLength
  ) as ArrayBuffer
  return {
    kind: 'loaded',
    format: 'word',
    revision: 0,
    ops: [],
    bytes: buffer,
    metadata: null
  }
}

/**
 * Read-only `.docx` / `.docm` attachment preview backed by `ankole_word_wasm` in a dedicated
 * Web Worker so chat attachment previews match collaborative Word Pages byte-for-byte.
 */
export default function WordPreview({
  url,
  local = false,
  initialPage,
  initialFind
}: {
  url: string
  local?: boolean
  initialPage?: number
  initialFind?: string
}) {
  const [session, setSession] = useState<{ model: WordSession; generation: number }>()
  const generation = useRef(0)
  const title = useMemo(() => previewTitleFromUrl(url), [url])

  useEffect(() => {
    const controller = new AbortController()
    const next = new OfficeCollaborationModel<WordSnapshot>({
      canEdit: false,
      selfUID: () => undefined,
      connect: async () => inertOfficeChannel(),
      load: () => loadPreviewDocument(url, local, controller.signal),
      createEngine: createWordEngine,
      notify: () => {}
    })
    setSession({ model: next, generation: ++generation.current })
    void next.start()
    return () => {
      controller.abort()
      next[Symbol.dispose]()
    }
  }, [url, local])

  if (!session) {
    return <ContentSkeleton variant="page" label={t('pod.word.preview_loading')} immediate />
  }

  return (
    <WordDocumentSurface
      key={session.generation}
      model={session.model}
      title={title}
      canEdit={false}
      initialPage={initialPage}
      initialFind={initialFind}
      preview
    />
  )
}
