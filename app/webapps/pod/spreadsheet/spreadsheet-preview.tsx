import { t } from 'i18next'
import { useSignals } from '@preact/signals-react/runtime'
import { useEffect, useRef, useState } from 'react'
import { readPrefix } from '../../common/browser-files'
import { createClientConfig } from '../../common/internal-api-client'
import { ContentError, ContentSkeleton } from '../content-primitives'
import {
  SpreadsheetModel,
  type SheetChannel,
  type SpreadsheetSession,
  type SpreadsheetSource
} from '../state/spreadsheet-collaboration'
import { SpreadsheetCanvas } from './spreadsheet-canvas'
import { createSpreadsheetEngine } from './spreadsheet-engine'
import { SpreadsheetFindDialog, type FindMode } from './spreadsheet-find-dialog'
import { SpreadsheetSheetTabs, WORKSPACE_ATTRIBUTE } from './spreadsheet-sheet-tabs'

const transport = createClientConfig({}).fetch!
const MAX_PREVIEW_BYTES = 25 * 1024 * 1024

function inertChannel(): SheetChannel {
  return {
    ready: Promise.resolve({}),
    push: async <T,>(_event: string, payload: object) => {
      const revision =
        typeof (payload as { revision?: unknown }).revision === 'number'
          ? (payload as { revision: number }).revision
          : 0
      return { revision, changes: [], reset_required: false } as T
    },
    on: () => () => {},
    presence: () => [],
    close: () => {}
  }
}

async function loadPreviewWorkbook(url: string, local: boolean, signal: AbortSignal): Promise<SpreadsheetSource> {
  const response = await (local ? fetch : transport)(url, { credentials: 'same-origin', signal })
  if (!response.ok || !response.body) {
    await response.body?.cancel()
    throw new Error(t('pod.content.could_not_read_the_spreadsheet_file'))
  }
  const result = await readPrefix(response, MAX_PREVIEW_BYTES, signal)
  if (result.truncated) return { kind: 'too_large' }
  const buffer = result.bytes.buffer.slice(
    result.bytes.byteOffset,
    result.bytes.byteOffset + result.bytes.byteLength
  ) as ArrayBuffer
  return {
    kind: 'loaded',
    revision: 0,
    ops: [],
    bytes: buffer,
    unsupported: false
  }
}

/**
 * Read-only `.xlsx` / `.xlsm` attachment preview backed by `ankole_spreadsheet_wasm` in a dedicated
 * Web Worker so chat attachment previews match collaborative Spreadsheet Pages byte-for-byte.
 */
export default function SpreadsheetWasmPreview({
  url,
  local = false,
  initialSheet
}: {
  url: string
  local?: boolean
  initialSheet?: string
}) {
  const [session, setSession] = useState<{ model: SpreadsheetSession; generation: number }>()
  const generation = useRef(0)

  useEffect(() => {
    const controller = new AbortController()
    const next = new SpreadsheetModel({
      canEdit: false,
      selfUID: () => undefined,
      connect: async () => inertChannel(),
      load: () => loadPreviewWorkbook(url, local, controller.signal),
      createEngine: createSpreadsheetEngine,
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
    return <ContentSkeleton variant="table" label={t('pod.spreadsheet.loading')} immediate />
  }

  return <SpreadsheetPreviewWorkspace key={session.generation} model={session.model} initialSheet={initialSheet} />
}

function SpreadsheetPreviewWorkspace({ model, initialSheet }: { model: SpreadsheetSession; initialSheet?: string }) {
  useSignals()
  const gridInput = useRef<HTMLTextAreaElement>(null)
  const [find, setFind] = useState<FindMode>()
  const status = model.status.value
  const sheets = model.sheets.value
  const appliedSheet = useRef<string | undefined>(undefined)

  useEffect(() => {
    if (!initialSheet || !sheets.length || appliedSheet.current === initialSheet) return
    appliedSheet.current = initialSheet
    const found =
      sheets.find(item => item.name === initialSheet) ??
      sheets.find(item => item.name.toLocaleLowerCase() === initialSheet.toLocaleLowerCase())
    if (found) model.goTo(found.sheet_id, { row: 0, col: 0 })
  }, [initialSheet, model, sheets])

  if (status === 'too_large') {
    return (
      <p className="rounded-control border border-dashed border-border px-6 py-10 text-center text-sm text-fg-secondary">
        {t('pod.office.too_large')}
      </p>
    )
  }
  if (status === 'error') return <ContentError error={model.error.value} retry={model.retry} />
  if (status === 'loading' && !sheets.length) {
    return <ContentSkeleton variant="table" label={t('pod.spreadsheet.loading')} immediate />
  }

  return (
    <div className="space-y-3">
      <div
        {...{ [WORKSPACE_ATTRIBUTE]: '' }}
        aria-busy={status === 'loading'}
        className="flex h-[min(68vh,720px)] min-h-[360px] flex-col overflow-hidden rounded-control border border-border bg-background">
        <SpreadsheetCanvas model={model} pageID="" inputRef={gridInput} onFind={setFind} />
        <SpreadsheetSheetTabs model={model} />
      </div>
      <SpreadsheetFindDialog
        open={find !== undefined}
        mode="find"
        model={model}
        onOpenChange={open => {
          if (!open) setFind(undefined)
        }}
      />
    </div>
  )
}
