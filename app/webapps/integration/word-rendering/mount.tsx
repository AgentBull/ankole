import { useEffect, useState } from 'react'
import { useSignals } from '@preact/signals-react/runtime'
import { createRoot } from 'react-dom/client'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { createRootRoute, createRouter, RouterProvider } from '@tanstack/react-router'
import { loadLocale } from '../../common/i18n'
import { inertOfficeChannel, OfficeCollaborationModel } from '../../pod/office/office-collaboration'
import type { WordSession, WordSnapshot } from '../../pod/word/word-engine'
import { WordDocumentSurface } from '../../pod/word/word-page'
import '@ankole/uikit/styles.css'

const snapshot: WordSnapshot = {
  canUndo: false,
  canRedo: false,
  editing: false,
  composing: false,
  presenceSelection: { story: 'body', block: null, anchor: { path: [], off: 0 }, focus: { path: [], off: 0 } },
  pages: Array.from({ length: 8 }, (_, index) => ({ index, width_pt: 400, height_pt: 600 })),
  caretState: {
    story: 'body',
    block: null,
    editing: false,
    anchor: { path: [], off: 0 },
    focus: { path: [], off: 0 },
    caret_rect: null,
    selection_rects: [],
    bold: false,
    italic: false,
    underline: false,
    strike: false,
    code: false,
    style: 'Normal',
    align: 'left',
    track_changes: false,
    can_undo: false,
    can_redo: false
  },
  missingPictures: [],
  substitutedFonts: [],
  missingGlyphFonts: []
}

function WordRenderingFixture() {
  useSignals()
  const [pending, setPending] = useState<Array<{ label: string; release(): void }>>([])
  const [requests, setRequests] = useState<string[]>([])
  const [mounted, setMounted] = useState(true)
  const createSession = (document: number) =>
    new OfficeCollaborationModel<WordSnapshot>({
      canEdit: false,
      selfUID: () => undefined,
      connect: async () => inertOfficeChannel(),
      load: async () => ({
        kind: 'loaded',
        format: 'word',
        revision: 0,
        ops: [],
        bytes: new ArrayBuffer(0),
        metadata: null
      }),
      createEngine: () => ({
        open: async () => snapshot,
        addFonts: async () => structuredClone(snapshot),
        renderPageRgba: async (page: number, scale: number) => {
          const label = `${document}:${page}:${scale.toFixed(4)}`
          setRequests(items => [...items, label])
          if (page === 1) {
            await new Promise<void>(resolve => {
              setPending(items => [...items, { label, release: resolve }])
            })
          }
          return { width: 1, height: 1, rgba: new Uint8Array([document * 40, Math.round(scale * 50), page, 255]) }
        },
        commitLocalStep: async () => ({ op: null, snapshot }),
        applyRemote: async () => ({
          snapshot,
          report: { dropped_pending: 0, draft_conflict: false, conflict_reason: null }
        }),
        undo: async () => ({ op: null, snapshot }),
        redo: async () => ({ op: null, snapshot }),
        dispose() {}
      }),
      notify: () => {}
    })
  const [sessions, setSessions] = useState<WordSession[]>([])
  const model = sessions.at(-1)
  useEffect(() => {
    setSessions([createSession(1)])
  }, [])
  useEffect(() => {
    void model?.start()
  }, [model])
  useEffect(
    () => () => {
      for (const session of sessions) session[Symbol.dispose]()
    },
    [sessions]
  )

  return (
    <>
      <button
        onClick={() => {
          const first = pending[0]
          if (first) {
            setPending(items => items.slice(1))
            first.release()
          }
        }}>
        Release next render
      </button>
      <button
        onClick={() => {
          if (model) model.version.value++
        }}>
        Change document version
      </button>
      <button onClick={() => setSessions(items => [...items, createSession(items.length + 1)])}>Change document</button>
      <button onClick={() => setMounted(value => !value)}>Toggle view</button>
      <output aria-label="Pending renders">{pending.map(item => item.label).join(',')}</output>
      <output aria-label="Render requests">{requests.join(',')}</output>
      {mounted && model && model.status.value === 'read_only' && (
        <WordDocumentSurface model={model} canEdit={false} preview />
      )}
    </>
  )
}

await loadLocale('en-US')
const client = new QueryClient()
const router = createRouter({ routeTree: createRootRoute({ component: WordRenderingFixture }) })
createRoot(document.getElementById('root')!).render(
  <QueryClientProvider client={client}>
    <RouterProvider router={router} />
  </QueryClientProvider>
)
