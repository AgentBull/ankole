import { t } from 'i18next'
import { Alert, AlertAction, AlertDescription, AlertTitle, Button, toast } from '@ankole/uikit'
import { useSignals } from '@preact/signals-react/runtime'
import { RiCloseLine, RiErrorWarningLine } from '@remixicon/react'
import { useQueryClient } from '@tanstack/react-query'
import { useEffect, useRef, useState } from 'react'
import { createClientConfig, InternalAPIError } from '../../common/internal-api-client'
import { requestErrorCode, requestErrorMessage } from '../../common/request-errors'
import { podSpreadsheet } from '../api/generated/sdk.gen'
import { contentKeys, fileURL, type PageDetail } from '../content-api'
import { useContent } from '../content-context'
import { contentError } from '../content-errors'
import { ContentError } from '../content-primitives'
import {
  SpreadsheetModel,
  type SpreadsheetNotice,
  type SpreadsheetSession,
  type SpreadsheetSource
} from '../state/spreadsheet-collaboration'
import { describeOp, type SpreadsheetOp } from '../state/spreadsheet-grid'
import { SpreadsheetCanvas } from './spreadsheet-canvas'
import { createSpreadsheetEngine } from './spreadsheet-engine'
import { SpreadsheetSheetTabs } from './spreadsheet-sheet-tabs'
import { SpreadsheetToolbar } from './spreadsheet-toolbar'

const transport = createClientConfig({}).fetch!
/** Compaction can replace the file between the bootstrap and the pinned download; each retry bootstraps again. */
const BOOTSTRAP_ATTEMPTS = 3

function errorCode(error: unknown): string | undefined {
  return error instanceof InternalAPIError ? requestErrorCode(error.payload) : undefined
}

/** Loads the file by the digest that the bootstrap pairs with its uncompacted operations. */
async function loadSpreadsheet(pageID: string): Promise<SpreadsheetSource> {
  for (let attempt = 1; ; attempt++) {
    let bootstrap: Awaited<ReturnType<typeof podSpreadsheet>>
    try {
      bootstrap = await podSpreadsheet({ path: { id: pageID } })
    } catch (error) {
      if (errorCode(error) === 'file_too_large') return { kind: 'too_large' }
      throw error
    }
    try {
      const response = await transport(fileURL(pageID, bootstrap.file.path, bootstrap.file.sha256), {
        credentials: 'same-origin'
      })
      return {
        kind: 'loaded',
        revision: bootstrap.revision,
        ops: bootstrap.ops.map(entry => entry.op as SpreadsheetOp),
        bytes: await response.arrayBuffer(),
        unsupported: bootstrap.metadata?.has_unsupported_objects === true
      }
    } catch (error) {
      if (attempt < BOOTSTRAP_ATTEMPTS && errorCode(error) === 'manifest_changed') continue
      throw error
    }
  }
}

function announce(notice: SpreadsheetNotice) {
  switch (notice.kind) {
    case 'conflict': {
      const { target, input } = describeOp(notice.op)
      toast.error(
        t('pod.spreadsheet.edit_conflict', {
          target,
          reason: t(`pod.spreadsheet.conflicts.${notice.reason}`, { defaultValue: notice.reason })
        }),
        input ? { description: t('pod.spreadsheet.edit_input', { input }) } : undefined
      )
      return
    }
    case 'rejected':
      toast.error(t('pod.spreadsheet.edit_rejected', { target: describeOp(notice.op).target }), {
        description: notice.message
      })
      return
    case 'discarded':
      toast.warning(t('pod.spreadsheet.edits_discarded', { count: notice.count }))
      return
    case 'failed':
      toast.error(requestErrorMessage(contentError(notice.error)))
      return
    case 'revoked':
      return
  }
}

/**
 * The editor of a spreadsheet page. It bootstraps the workbook, keeps a worker with the kernel and
 * one collaboration session for the page channel, and falls back to the download card when the
 * file exceeds the tenant's editing limit.
 */
export default function SpreadsheetPage({ detail }: { detail: PageDetail }) {
  const { realtime } = useContent()
  const client = useQueryClient()
  const pageID = detail.page.id
  const canEdit = detail.actions.includes('node_edit')
  // Each session gets a new workspace, so caches of an earlier session's viewports never paint.
  const [session, setSession] = useState<{ model: SpreadsheetSession; generation: number }>()
  const generation = useRef(0)

  // The session owns a worker and a channel, so it lives exactly as long as this effect.
  useEffect(() => {
    const refresh = () => void client.invalidateQueries({ queryKey: contentKeys.page(pageID) })
    const next = new SpreadsheetModel({
      canEdit,
      selfUID: () => realtime.principal?.uid,
      connect: () => realtime.join(`page:${pageID}`),
      load: () => loadSpreadsheet(pageID),
      createEngine: createSpreadsheetEngine,
      notify: notice => {
        announce(notice)
        if (notice.kind === 'failed' || notice.kind === 'revoked') refresh()
      }
    })
    setSession({ model: next, generation: ++generation.current })
    void next.start()
    const unwatch = realtime.watchVersion('pages', pageID, version => {
      if (version === undefined) next.revoke()
      else if (version !== next.revision.peek()) next.sync()
    })
    return () => {
      unwatch()
      next[Symbol.dispose]()
    }
  }, [pageID, canEdit, realtime, client])

  return session ? (
    <SpreadsheetWorkspace key={session.generation} model={session.model} pageID={pageID} canEdit={canEdit} />
  ) : (
    <p role="status">{t('pod.spreadsheet.loading')}</p>
  )
}

function SpreadsheetWorkspace({
  model,
  pageID,
  canEdit
}: {
  model: SpreadsheetSession
  pageID: string
  canEdit: boolean
}) {
  useSignals()
  const gridInput = useRef<HTMLTextAreaElement>(null)
  const [warningDismissed, setWarningDismissed] = useState(false)
  const status = model.status.value
  if (status === 'too_large') {
    return (
      <p className="rounded-control border border-dashed border-border px-6 py-10 text-center text-sm text-fg-secondary">
        {t('pod.spreadsheet.too_large')}
      </p>
    )
  }
  if (model.revoked.value) {
    return <ContentError error={new Error(t('pod.content.you_no_longer_have_access_to_this_file'))} />
  }
  if (status === 'error') return <ContentError error={model.error.value} retry={model.retry} />
  if (status === 'loading' && !model.sheets.value.length) {
    return <p role="status">{t('pod.spreadsheet.loading')}</p>
  }
  return (
    <div className="space-y-3">
      {model.unsupported.value && canEdit && !warningDismissed && (
        <Alert variant="warning">
          <RiErrorWarningLine aria-hidden />
          <AlertTitle>{t('pod.spreadsheet.unsupported_title')}</AlertTitle>
          <AlertDescription>{t('pod.spreadsheet.unsupported_description')}</AlertDescription>
          <AlertAction>
            <Button
              size="icon-xs"
              variant="ghost"
              aria-label={t('common.close')}
              onClick={() => setWarningDismissed(true)}>
              <RiCloseLine />
            </Button>
          </AlertAction>
        </Alert>
      )}
      <div
        aria-busy={status === 'loading'}
        className="flex h-[min(78vh,880px)] min-h-[420px] flex-col overflow-hidden rounded-control border border-border bg-background">
        <SpreadsheetToolbar model={model} pageID={pageID} canEdit={canEdit} gridInput={gridInput} />
        <SpreadsheetCanvas model={model} inputRef={gridInput} />
        <SpreadsheetSheetTabs model={model} />
      </div>
    </div>
  )
}
