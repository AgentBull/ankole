import { usePageMetadata } from './use-page-metadata'
import { PageContent } from './page-content'
import { refreshDirectories } from './state/navigation-cache'
import { partition, uuidV4 } from '@agentbull/active-support'
import { t } from 'i18next'
import { I18nextProvider, useTranslation } from 'react-i18next'
import { editorLabels } from './state/editor-labels'
import { BlockEditor, type EditorHandle } from '@ankole/block-editor'
import { parseXml } from '@ankole/block-editor/document'
import {
  insertEmbed,
  insertMention,
  insertResource,
  EditorSelection,
  PageSession,
  PageCollaboration,
  remoteSelections,
  type Editor,
  type EditorHost,
  type EmbedAttributes,
  type PageChanges
} from '@ankole/block-editor/editor'
import {
  Button,
  Dialog,
  DialogContent,
  DialogFooter,
  DialogTitle,
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuTrigger,
  toast
} from '@ankole/uikit'
import {
  RiArrowDownSLine,
  RiAtLine,
  RiBarChartBoxLine,
  RiCheckLine,
  RiCloseLine,
  RiExternalLinkLine,
  RiWindowLine
} from '@remixicon/react'

import { useModel } from '@preact/signals-react'
import { DocumentPresence } from './document-presence'
import { DocumentPresenceModel, peerColor } from './state/document-presence'
import { useSignals } from '@preact/signals-react/runtime'
import { QueryClientProvider, useQuery, useQueryClient } from '@tanstack/react-query'
import { lazy, Suspense, useEffect, useEffectEvent, useMemo, useRef, useState, type SyntheticEvent } from 'react'
import { createPortal } from 'react-dom'
import { createRoot } from 'react-dom/client'
import { useNavigate } from '@tanstack/react-router'
import { ErrorBoundary, rootErrorOptions } from '../common/error-boundary'
import {
  EXTERNAL_TRANSLATION_GUARD_ATTRS,
  withExternalTranslationGuardClass
} from '../common/external-translation-guard'

import { requestErrorMessage } from '../common/request-errors'
import { contentKeys, fileURL, pageAPI, pageQuery, resolvePodLinkMetadata, type PageDetail } from './content-api'
import { contentError } from './content-errors'
import { ContentError, ContentLoading, ContentSkeleton, InlineLoading } from './content-primitives'
import { createMentionHostAdapters } from './document-mentions'

import { CreatePageSubmenu, uploadFileSubpages, usePageCreation } from './page-create-menu'
import { uploadPageFile } from './page-files'

import { DocumentDraftModel } from './state/document-draft'
import type { ReadonlySignal } from '@preact/signals-react'
import { DocumentRecovery, downloadDraft } from './document-recovery'

import { looksLikeChartEmbedView, parseEmbedView } from './state/view-config'
import { baseSchemaQuery, baseTablesQuery } from './base-api'
import type { BaseTable, BaseView } from '@ankole/applet-sdk/types'
import { ContentScope, useContent } from './content-context'
import { isRealtimeAccessDenied, RealtimeRequestError } from './realtime'

import { PageIcon } from './page-icon'

const BasePage = lazy(() => import('./base-page').then(module => ({ default: module.BasePage })))
const PagePicker = lazy(() => import('./page-picker').then(module => ({ default: module.PagePicker })))

export function DocumentPage({
  detail,
  model,
  title,
  presenceContainer,
  onEditor,
  resolvedCommentIDs,
  onComment,
  onRequestComment,
  onAskAgent
}: {
  detail: PageDetail
  model: InstanceType<typeof DocumentDraftModel>
  title: ReadonlySignal<string>
  presenceContainer: HTMLElement | null
  onEditor(handle: EditorHandle | null): void
  resolvedCommentIDs: readonly string[]
  onComment(ids: readonly string[]): void
  onRequestComment(selection: { from: number; to: number; quote: string }): void
  /** Present when this Page can hold a Page chat; the selection becomes a quote in it. */
  onAskAgent?(selection: { from: number; to: number; quote: string }): void
}) {
  useSignals()
  const { t, i18n } = useTranslation()
  const labels = useMemo(
    () => ({
      ...editorLabels(i18n.language),
      block: i18n.t('pod.editor.block', { defaultValue: 'Block' }),
      open_link: i18n.t('pod.editor.open_link', { defaultValue: 'Open link' })
    }),
    [i18n]
  )
  const [generation, setGeneration] = useState(0)
  const [initialXML, setInitialXML] = useState(detail.content?.content ?? '<page/>')
  const initialDocument = useMemo(() => parseXml(initialXML), [initialXML])
  const editor = useRef<Editor | null>(null)
  const session = useRef<PageSession | null>(null)
  const client = useQueryClient()
  const navigate = useNavigate()
  const content = useContent()
  const [assetError, setAssetError] = useState<unknown>()
  const awareness = useModel(DocumentPresenceModel)
  const [collaborationError, setCollaborationError] = useState<unknown>()
  const [revoked, setRevoked] = useState(false)
  const retryConnection = useRef<() => void>(() => {})
  const [fileDragOver, setFileDragOver] = useState(false)
  const [embedPickerOpen, setEmbedPickerOpen] = useState(false)
  const [chartPickerOpen, setChartPickerOpen] = useState(false)
  const insertAsChartRef = useRef(false)
  const openCreatedDocument = useRef<string | undefined>(undefined)
  const canEdit = detail.actions.includes('node_edit')
  const openComment = useEffectEvent((ids: readonly string[]) => onComment(ids))
  const requestComment = useEffectEvent((selection: { from: number; to: number; quote: string }) =>
    onRequestComment(selection)
  )
  const canComment = detail.actions.includes('node_comment')
  const askAgent = useEffectEvent((selection: { from: number; to: number; quote: string }) => onAskAgent?.(selection))
  const canAskAgent = !!onAskAgent
  const createChildPage = usePageCreation({
    parentID: detail.page.id,
    scope: detail.page.private_owner_uid ? 'private' : 'space',
    privateOwner: detail.page.private_owner_uid ?? undefined,
    onCreated: created => {
      const asChart = insertAsChartRef.current
      insertAsChartRef.current = false
      if (editor.current && !editor.current.state.readOnly) {
        if (created.type === 'doc') {
          openCreatedDocument.current = created.id
          insertMention(editor.current, { page: created.id })
        } else if (asChart && created.type === 'base') {
          insertEmbed(editor.current, { ref: created.id, view: JSON.stringify({ type: 'chart' }) })
        } else {
          insertEmbed(editor.current, { ref: created.id })
        }
      }
    }
  })
  const host = useMemo<EditorHost>(
    () => ({
      ...createMentionHostAdapters({
        client,
        currentPageID: detail.page.id,
        pageHref: content.pageHref,
        openPage: id => void navigate({ to: content.pageHref(id) }),
        i18n
      }),
      openComment: ids => openComment(ids),
      ...(canComment
        ? { requestComment: (selection: { from: number; to: number; quote: string }) => requestComment(selection) }
        : {}),
      ...(canAskAgent
        ? { askAgent: (selection: { from: number; to: number; quote: string }) => askAgent(selection) }
        : {}),
      mountEmbed: (attributes, container, update, remove, collapseToMention) => {
        const trashed = Boolean(detail.page.deleted_at)
        // The editor can hand a reused container to the next embed before this root unmounts.
        const mount = container.appendChild(document.createElement('div'))
        const root = createRoot(mount, rootErrorOptions)
        root.render(
          <I18nextProvider i18n={i18n}>
            <QueryClientProvider client={client}>
              <ContentScope value={content}>
                <ErrorBoundary
                  variant="inline"
                  resetKeys={[attributes.ref, attributes.table, attributes.view]}
                  actions={
                    canEdit && !trashed ? (
                      <Button type="button" size="xs" variant="ghost" onClick={remove}>
                        {i18n.t('pod.content.remove')}
                      </Button>
                    ) : undefined
                  }>
                  <PageEmbed
                    attributes={attributes}
                    canEdit={canEdit}
                    trashed={trashed}
                    model={model}
                    remove={remove}
                    collapseToMention={collapseToMention}
                    configure={(config, table) =>
                      update({ ...attributes, ...(table ? { table } : {}), view: JSON.stringify(config) })
                    }
                    bindSavedView={(viewID, table) =>
                      update({
                        ref: attributes.ref,
                        ...(table ? { table } : attributes.table ? { table: attributes.table } : {}),
                        ...(viewID ? { view: viewID } : {})
                      })
                    }
                    openPage={id => void navigate({ to: content.pageHref(id) })}
                  />
                </ErrorBoundary>
              </ContentScope>
            </QueryClientProvider>
          </I18nextProvider>
        )
        return () => {
          queueMicrotask(() => {
            root.unmount()
            mount.remove()
          })
        }
      },
      // The upload panel shows the rejection's message as it is.
      acceptFiles: files =>
        uploadFileSubpages(client, detail.page.id, files).catch(error => {
          throw new Error(requestErrorMessage(contentError(error)))
        }),
      uploadAsset: file => uploadDocumentAsset(detail.page.id, file),
      openPage: id => void navigate({ to: content.pageHref(id) }),
      resolveAsset: src =>
        src.startsWith('ankole:asset/') ? fileURL(detail.page.id, `assets/${src.slice('ankole:asset/'.length)}`) : src,
      resolveLinkMetadata: (url, signal) => resolvePodLinkMetadata(client, url, signal),
      deleteEmbeds: async ids => {
        try {
          await pageAPI.removeEmbeds(detail.page.id, ids)
          await Promise.all([
            refreshDirectories(client, [{ parent_id: detail.page.id }]),
            client.invalidateQueries({ queryKey: contentKeys.page(detail.page.id) })
          ])
          return true
        } catch (error) {
          toast.error(requestErrorMessage(contentError(error)))
          return false
        }
      },
      insertPageEmbed: () => {
        if (!canEdit || detail.page.deleted_at || model.conflict.value) return
        queueMicrotask(() => setEmbedPickerOpen(true))
      },
      insertChart: () => {
        if (!canEdit || detail.page.deleted_at || model.conflict.value) return
        queueMicrotask(() => setChartPickerOpen(true))
      }
    }),
    [client, navigate, detail.page.id, detail.page.deleted_at, content, canEdit, canComment, canAskAgent, model, i18n]
  )
  const reload = async () => {
    const xml = await model.reload(async () => {
      const latest = await pageAPI.read(detail.page.id)
      return { xml: latest.content?.content ?? '<page/>', revision: latest.page.revision }
    })
    if (xml === undefined) return
    setInitialXML(xml)
    setGeneration(value => value + 1)
  }
  const insertTransferredFiles = async (files: File[], coords?: { x: number; y: number }) => {
    const instance = editor.current
    if (!instance || instance.state.readOnly || !files.length) return
    if (coords) {
      const hit = instance.posAtCoords(coords)
      instance.dispatch({ selection: EditorSelection.near(instance.state, hit.pos, hit.side) })
      instance.focus()
    }
    // Images and videos belong to the document body; every other file becomes a File Page child.
    const [media, others] = partition(files, file => /^(image|video)\//.test(file.type))
    setAssetError(undefined)
    for (const file of media) {
      try {
        const uploaded = await uploadDocumentAsset(detail.page.id, file)
        if (editor.current && !editor.current.state.readOnly) {
          insertResource(editor.current, 'media', {
            ...uploaded,
            kind: file.type.startsWith('video/') ? 'video' : 'image'
          })
        }
      } catch (error) {
        setAssetError(error)
      }
    }
    if (others.length) await uploadFileSubpages(client, detail.page.id, others).catch(setAssetError)
  }
  // Overlays portal outside the section, and embeds and resource blocks own their own transfers.
  const ownsTransfer = (event: SyntheticEvent<HTMLElement>) => {
    const target = event.target instanceof Element ? event.target : (event.target as Node).parentElement
    return (
      canEdit &&
      !model.conflict.value &&
      !!target &&
      event.currentTarget.contains(target) &&
      !target.closest('.embed, .editor-resource')
    )
  }
  const isExternalFileDrag = (dataTransfer: DataTransfer | null) =>
    !!dataTransfer && !dataTransfer.types.includes('application/x-ankole-block') && dataTransfer.types.includes('Files')
  return (
    <section
      className={fileDragOver ? 'pod-document rounded-control ring-2 ring-ring/40' : 'pod-document'}
      onPasteCapture={event => {
        if (!ownsTransfer(event)) return
        const files = Array.from(event.clipboardData?.files ?? [])
        if (!files.length || event.clipboardData?.getData('text/plain').trim()) return
        event.preventDefault()
        event.stopPropagation()
        void insertTransferredFiles(files)
      }}
      onDragOverCapture={event => {
        if (!ownsTransfer(event) || !isExternalFileDrag(event.dataTransfer)) return
        event.preventDefault()
        event.dataTransfer.dropEffect = 'copy'
        if (!fileDragOver) setFileDragOver(true)
      }}
      onDragLeave={event => {
        if (!event.currentTarget.contains(event.relatedTarget as Node | null)) setFileDragOver(false)
      }}
      onDropCapture={event => {
        setFileDragOver(false)
        if (!ownsTransfer(event) || !isExternalFileDrag(event.dataTransfer)) return
        const files = Array.from(event.dataTransfer.files)
        if (!files.length) return
        event.preventDefault()
        event.stopPropagation()
        void insertTransferredFiles(files, { x: event.clientX, y: event.clientY })
      }}>
      {presenceContainer &&
        createPortal(
          <DocumentPresence
            model={awareness}
            pending={model.bodyPending.value || model.xml.value !== model.savedXML.value}
            error={Boolean(collaborationError || model.conflict.value)}
          />,
          presenceContainer
        )}
      {model.conflict.value && (
        <div className="rounded border border-warning p-4 text-sm" role="alert">
          <p>
            {isRealtimeAccessDenied(collaborationError)
              ? t('pod.content.you_can_no_longer_edit_this_page_your_draft_has_been_kept')
              : t('pod.content.the_document_has_changed_your_draft_has_been_kept_export')}
          </p>
          <div className="mt-3 flex gap-3">
            <Button variant="outline" size="sm" onClick={() => downloadDraft(model.xml.value, title.value)}>
              {t('pod.content.export_draft')}
            </Button>
            <Button variant="outline" size="sm" onClick={() => void reload().catch(setAssetError)}>
              {t('pod.content.reload_document')}
            </Button>
          </div>
        </div>
      )}
      <DocumentRecovery model={model} title={title.value} />
      <ContentError error={assetError} />
      <ContentError
        error={collaborationError}
        retry={model.conflict.value ? undefined : () => retryConnection.current()}
      />
      {revoked ? (
        <p role="alert">{t('pod.content.you_no_longer_have_access_to_this_page_your_unsaved')}</p>
      ) : (
        <div {...EXTERNAL_TRANSLATION_GUARD_ATTRS} className="notranslate contents">
          <BlockEditor
            key={generation}
            resolvedCommentIDs={resolvedCommentIDs}
            labels={labels}
            initial={initialDocument}
            host={host}
            readOnly={!detail.actions.includes('node_edit') || model.conflict.value}
            className={withExternalTranslationGuardClass(
              detail.child_count > 0 ? '[--editor-min-height:0px]' : 'min-h-[60vh]'
            )}
            toolbar={null}
            insertMenu={prepareInsertion => (
              <CreatePageSubmenu
                parentID={detail.page.id}
                label={t('pod.content.new_page')}
                types={['doc', 'base']}
                create={{
                  ...createChildPage,
                  submit: type => {
                    prepareInsertion()
                    return createChildPage.submit(type)
                  }
                }}
              />
            )}
            onError={setCollaborationError}
            onReady={(instance, editorHandle) => {
              editor.current = instance
              onEditor(editorHandle)
              const current = new PageSession(instance)
              session.current = current
              let disposed = false
              const decoratePeers = remoteSelections(instance)
              let presenceTimer: ReturnType<typeof setTimeout> | undefined
              let refreshPeers = () => {}
              let announceSelection = () => {}
              let handle: Awaited<ReturnType<typeof content.realtime.join>> | undefined
              let joined: Promise<Awaited<ReturnType<typeof content.realtime.join>>> | undefined
              const terminate = (error?: unknown) => {
                if (disposed) return
                collaboration.dispose()
                model.conflict.value = true
                setCollaborationError(error)
                handle?.close()
              }
              const revoke = (error: unknown) => {
                if (disposed) return
                terminate(error)
                setRevoked(true)
                void client.invalidateQueries({ queryKey: contentKeys.page(detail.page.id) })
              }
              const failed = (error: unknown) => {
                if (disposed) return
                if (isRealtimeAccessDenied(error)) revoke(error)
                else setCollaborationError(error)
              }
              const connect = () => {
                if (!joined) {
                  const attempt = content.realtime.join(`page:${detail.page.id}`).then(async connection => {
                    if (disposed) {
                      connection.close()
                      throw new Error(t('pod.content.the_page_connection_is_closed'))
                    }
                    handle = connection
                    const syncMembers = () => {
                      if (awareness.connection.value !== 'connected') return
                      awareness.sync(connection.presence())
                      refreshPeers()
                    }
                    connection.on('connection', ({ status }) => {
                      if (disposed) return
                      awareness.setConnection(status)
                      if (status !== 'connected') refreshPeers()
                      else {
                        syncMembers()
                        announceSelection()
                      }
                    })
                    connection.on('presence', syncMembers)
                    connection.on('changes', response => collaboration.receive(response))
                    const refreshComments = () => {
                      void client.invalidateQueries({ queryKey: contentKeys.comments(detail.page.id) })
                    }
                    connection.on('comments_changed', refreshComments)
                    connection.on('rejoined', response => {
                      awareness.self.value = response.presence_session
                      lastSelection = ''
                      syncMembers()
                      announceSelection()
                      refreshComments()
                      sync()
                    })
                    connection.on('access_revoked', () => {
                      revoke(new RealtimeRequestError({ reason: 'forbidden' }))
                    })
                    const response = (await connection.ready) as PageDetail & { presence_session: string }
                    awareness.self.value = response.presence_session
                    syncMembers()
                    announceSelection()
                    refreshComments()
                    if (response.page.revision !== collaboration.currentRevision()) sync()
                    return connection
                  })
                  joined = attempt
                  void attempt.catch(error => {
                    handle?.close()
                    handle = undefined
                    if (joined === attempt) joined = undefined
                    failed(error)
                  })
                }
                return joined
              }
              const sync = () => {
                if (disposed || model.conflict.value) return
                void connect()
                  .then(connection =>
                    connection.push<PageChanges>('sync', {
                      revision: collaboration.currentRevision()
                    })
                  )
                  .then(response => collaboration.receive(response))
                  .catch(failed)
              }
              retryConnection.current = sync
              const collaboration = new PageCollaboration(instance, model.revision.value, {
                clientID: uuidV4(),
                send: async request => {
                  try {
                    const connection = await connect()
                    return await connection.push<PageChanges>('changes', request)
                  } catch (error) {
                    if (error instanceof RealtimeRequestError) terminate(error)
                    throw error
                  }
                },
                changed: state => {
                  model.saved(state.xml, state.revision, state.pending)
                  setCollaborationError(state.error)
                  queueMicrotask(() => {
                    if (!disposed) {
                      refreshPeers()
                      announceSelection()
                    }
                  })
                  if (!state.pending && !state.error && openCreatedDocument.current) {
                    const id = openCreatedDocument.current
                    openCreatedDocument.current = undefined
                    void navigate({ to: content.pageHref(id) })
                  }
                },
                reset: draft => {
                  if (draft) model.keepRecoveryDraft(draft)
                  terminate()
                  void reload().catch(setCollaborationError)
                },
                sync
              })
              let rendered = ''
              refreshPeers = () => {
                const peers = awareness.peers.value.flatMap(peer => {
                  const selection = peer.selection && collaboration.selectionFromConfirmed(peer.selection)
                  return selection ? [{ id: peer.id, name: peer.name, color: peerColor(peer.uid), ...selection }] : []
                })
                const next = JSON.stringify(peers)
                if (next !== rendered) {
                  rendered = next
                  decoratePeers(peers)
                }
              }
              let lastSelection = ''
              announceSelection = () => {
                clearTimeout(presenceTimer)
                presenceTimer = setTimeout(() => {
                  if (disposed || !handle || awareness.connection.value !== 'connected') return
                  const selection =
                    instance.hasFocus && document.visibilityState === 'visible'
                      ? collaboration.selectionToConfirmed(instance.state.selection)
                      : null
                  const next = JSON.stringify(selection)
                  if (next === lastSelection) return
                  lastSelection = next
                  void handle
                    .push<{ stale?: boolean }>('presence', { selection })
                    .then(response => {
                      if (response?.stale) lastSelection = ''
                    })
                    .catch(error => {
                      lastSelection = ''
                      if (isRealtimeAccessDenied(error)) failed(error)
                    })
                }, 80)
              }
              const unlisten = editorHandle.subscribe(() => {
                refreshPeers()
                announceSelection()
              })
              const visibility = () => announceSelection()
              document.addEventListener('visibilitychange', visibility)
              void connect()
              const unwatch = content.realtime.watchVersion('pages', detail.page.id, version => {
                if (version === undefined) {
                  revoke(new RealtimeRequestError({ reason: 'forbidden' }))
                } else if (version !== collaboration.currentRevision()) sync()
              })
              return () => {
                disposed = true
                clearTimeout(presenceTimer)
                unlisten()
                document.removeEventListener('visibilitychange', visibility)
                model.cancelReload()
                unwatch()
                collaboration.dispose()
                handle?.close()
                current.dispose()
                if (session.current === current) {
                  session.current = null
                  editor.current = null
                  onEditor(null)
                }
              }
            }}
            onChange={() => {
              if (session.current) model.xml.value = session.current.readXml().xml
            }}
          />
        </div>
      )}
      {embedPickerOpen && (
        <Dialog open onOpenChange={next => !next && setEmbedPickerOpen(false)}>
          <DialogContent
            className="pod-dialog pod-picker-dialog"
            closeLabel={t('common.close')}
            finalFocus={() => {
              editor.current?.focus()
              return false
            }}>
            <DialogTitle>{t('pod.content.embed_existing_content')}</DialogTitle>
            <div className="pod-dialog-body grid gap-3">
              <ErrorBoundary variant="panel" resetKeys={[detail.page.id]}>
                <Suspense fallback={<InlineLoading />}>
                  <PagePicker
                    embeddable
                    label={t('pod.content.choose_a_page')}
                    onSelect={id => {
                      setEmbedPickerOpen(false)
                      if (editor.current && !editor.current.state.readOnly) {
                        insertEmbed(editor.current, { ref: id })
                        editor.current.focus()
                      }
                    }}
                  />
                </Suspense>
              </ErrorBoundary>
            </div>
          </DialogContent>
        </Dialog>
      )}
      {chartPickerOpen && (
        <ChartEmbedPickerDialog
          pageID={detail.page.id}
          creatingBase={createChildPage.isPending}
          onClose={() => setChartPickerOpen(false)}
          onFocusEditor={() => editor.current?.focus()}
          onCreateNewBase={() => {
            setChartPickerOpen(false)
            insertAsChartRef.current = true
            createChildPage.submit('base')
          }}
          onInsert={attrs => {
            setChartPickerOpen(false)
            if (editor.current && !editor.current.state.readOnly) {
              insertEmbed(editor.current, attrs)
              editor.current.focus()
            }
          }}
        />
      )}
    </section>
  )
}

function ChartEmbedPickerDialog({
  pageID,
  creatingBase,
  onClose,
  onFocusEditor,
  onCreateNewBase,
  onInsert
}: {
  pageID: string
  creatingBase: boolean
  onClose(): void
  onFocusEditor(): void
  onCreateNewBase(): void
  onInsert(attrs: EmbedAttributes): void
}) {
  const { t } = useTranslation()
  const client = useQueryClient()
  const [inspecting, setInspecting] = useState(false)
  const [choiceState, setChoiceState] = useState<{
    baseId: string
    tables: { table: BaseTable; chartViews: BaseView[] }[]
  } | null>(null)

  const handleBaseSelected = async (baseId: string) => {
    setInspecting(true)
    try {
      const { tables } = await client.fetchQuery(baseTablesQuery(baseId))
      const schemas = await Promise.all(
        tables.map(async table => {
          const schema = await client.fetchQuery(baseSchemaQuery(table.id))
          return {
            table,
            chartViews: schema.views.filter(v => v.type === 'chart')
          }
        })
      )
      const totalSavedCharts = schemas.reduce((sum, entry) => sum + entry.chartViews.length, 0)
      if (tables.length <= 1 && totalSavedCharts === 0) {
        onInsert({
          ref: baseId,
          ...(tables[0] ? { table: tables[0].id } : {}),
          view: JSON.stringify({ type: 'chart' })
        })
        return
      }
      setChoiceState({ baseId, tables: schemas })
    } catch {
      onInsert({ ref: baseId, view: JSON.stringify({ type: 'chart' }) })
    } finally {
      setInspecting(false)
    }
  }

  const savedCharts = choiceState?.tables.flatMap(entry => entry.chartViews.map(view => ({ table: entry.table, view })))

  return (
    <Dialog open onOpenChange={next => !next && onClose()}>
      <DialogContent
        className="pod-dialog pod-picker-dialog"
        closeLabel={t('common.close')}
        finalFocus={() => {
          onFocusEditor()
          return false
        }}>
        <DialogTitle>{t('pod.content.embed_base_chart', { defaultValue: 'Insert Base chart' })}</DialogTitle>
        <div className="pod-dialog-body grid gap-3">
          {choiceState ? (
            <div className="space-y-4 text-sm" data-slot="chart-picker-options">
              {savedCharts && savedCharts.length > 0 && (
                <div className="space-y-1.5">
                  <p className="text-xs font-medium text-fg-secondary">
                    {t('pod.content.link_existing_chart_view', { defaultValue: 'Link existing chart view' })}
                  </p>
                  <div className="grid gap-1">
                    {savedCharts.map(({ table, view }) => (
                      <Button
                        key={view.id}
                        variant="outline"
                        size="sm"
                        className="justify-between"
                        onClick={() =>
                          onInsert({
                            ref: choiceState.baseId,
                            table: table.id,
                            view: view.id
                          })
                        }>
                        <span className="inline-flex items-center gap-1.5 truncate">
                          <RiBarChartBoxLine aria-hidden="true" className="size-4 shrink-0" />
                          <span className="truncate">{view.name}</span>
                        </span>
                        {choiceState.tables.length > 1 && (
                          <span className="text-xs text-fg-tertiary">{table.name}</span>
                        )}
                      </Button>
                    ))}
                  </div>
                </div>
              )}

              <div className="space-y-1.5">
                <p className="text-xs font-medium text-fg-secondary">
                  {t('pod.content.new_inline_chart_for_table', { defaultValue: 'New chart in document' })}
                </p>
                <div className="grid gap-1">
                  {choiceState.tables.map(({ table }) => (
                    <Button
                      key={table.id}
                      variant="ghost"
                      size="sm"
                      className="justify-start border border-border/60"
                      onClick={() =>
                        onInsert({
                          ref: choiceState.baseId,
                          table: table.id,
                          view: JSON.stringify({ type: 'chart' })
                        })
                      }>
                      <RiBarChartBoxLine aria-hidden="true" className="size-4 shrink-0 text-fg-secondary" />
                      <span className="truncate">{table.name}</span>
                    </Button>
                  ))}
                </div>
              </div>
            </div>
          ) : (
            <ErrorBoundary variant="panel" resetKeys={[pageID]}>
              <Suspense fallback={<InlineLoading />}>
                <PagePicker
                  embeddable
                  disabled={inspecting}
                  canSelect={page => page.type === 'base'}
                  label={t('pod.content.choose_base_for_chart', { defaultValue: 'Choose a Base' })}
                  onSelect={id => {
                    void handleBaseSelected(id)
                  }}
                />
              </Suspense>
            </ErrorBoundary>
          )}
        </div>
        <DialogFooter>
          {choiceState ? (
            <Button variant="ghost" size="sm" onClick={() => setChoiceState(null)}>
              {t('pod.content.choose_another_base', { defaultValue: 'Choose another Base' })}
            </Button>
          ) : (
            <Button variant="outline" size="sm" disabled={creatingBase || inspecting} onClick={onCreateNewBase}>
              {t('pod.content.create_new_base_chart', { defaultValue: 'Create new Base & chart' })}
            </Button>
          )}
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}

export function PageEmbed({
  attributes,
  canEdit,
  trashed,
  model,
  remove,
  collapseToMention,
  configure,
  bindSavedView,
  openPage
}: {
  attributes: EmbedAttributes
  canEdit: boolean
  trashed: boolean
  model: InstanceType<typeof DocumentDraftModel>
  remove(): void
  collapseToMention?(): void
  configure(config: Record<string, unknown>, table?: string): void
  bindSavedView?(viewID: string, table?: string): void
  openPage(id: string): void
}) {
  useSignals()
  const { t } = useTranslation()
  const editable = canEdit && !model.conflict.value
  const query = useQuery({ ...pageQuery(attributes.ref ?? ''), enabled: !!attributes.ref })
  const page = usePageMetadata(query.data?.page)
  const containerRef = useRef<HTMLDivElement | null>(null)
  const view = parseEmbedView(attributes.view)
  const isChartIntent =
    (view.kind === 'inline' && view.config.type === 'chart') || looksLikeChartEmbedView(attributes.view)
  const [chartVisible, setChartVisible] = useState<boolean>(
    () => !isChartIntent || typeof IntersectionObserver === 'undefined'
  )

  useEffect(() => {
    if (chartVisible || !isChartIntent) {
      setChartVisible(true)
      return
    }
    const el = containerRef.current
    if (!el || typeof IntersectionObserver === 'undefined') {
      setChartVisible(true)
      return
    }
    const observer = new IntersectionObserver(
      entries => {
        if (entries.some(entry => entry.isIntersecting)) {
          setChartVisible(true)
          observer.disconnect()
        }
      },
      { rootMargin: '300px' }
    )
    observer.observe(el)
    return () => observer.disconnect()
  }, [chartVisible, isChartIntent])

  const cannotDisplay = (
    <div className="flex items-center justify-between gap-2 p-4 text-sm text-fg-tertiary">
      <span>{t('pod.content.cannot_display')}</span>
      {editable && !trashed && (
        <Button
          size="icon-xs"
          variant="ghost"
          aria-label={t('pod.content.remove')}
          title={t('pod.content.remove')}
          onClick={remove}>
          <RiCloseLine aria-hidden className="size-4" />
        </Button>
      )}
    </div>
  )
  if (!attributes.ref) {
    return cannotDisplay
  }
  if (query.error) {
    return cannotDisplay
  }
  if (!query.data || !page) {
    return <ContentLoading />
  }
  if (page.type === 'doc') {
    return cannotDisplay
  }
  const embedTrashed = trashed || Boolean(query.data.page.deleted_at)
  const embeddedDetail = embedTrashed ? { ...query.data, actions: ['node_view' as const] } : query.data
  const canConfigureEmbed = editable && !embedTrashed
  return (
    <div
      ref={containerRef}
      className="pod-inline-page group/inline-page my-4 min-w-0"
      data-page-type={page.type}
      data-chart-embed={isChartIntent || undefined}>
      <div className="mb-1.5 flex min-w-0 items-center justify-between gap-2">
        <Button
          variant="ghost"
          className="-ml-1 h-7.5 min-w-0 max-w-full justify-start px-1 py-0.5 text-base font-semibold"
          onClick={() => openPage(query.data!.page.id)}>
          <PageIcon page={page} />
          <span className="truncate">{page.title || t('pod.content.untitled')}</span>
          <RiExternalLinkLine aria-hidden className="shrink-0" />
        </Button>
        {canConfigureEmbed && collapseToMention && (
          <DropdownMenu modal={false}>
            <DropdownMenuTrigger
              render={
                <Button
                  variant="ghost"
                  size="xs"
                  className="shrink-0 gap-1 text-fg-secondary opacity-0 transition-opacity duration-120 group-focus-within/inline-page:opacity-100 group-hover/inline-page:opacity-100 data-popup-open:opacity-100 [@media(hover:none)]:opacity-100"
                  aria-label={t('pod.editor.resource_view')}
                />
              }>
              <RiWindowLine aria-hidden />
              <span>{t('pod.editor.mention_view_embed')}</span>
              <RiArrowDownSLine aria-hidden />
            </DropdownMenuTrigger>
            <DropdownMenuContent align="end" aria-label={t('pod.editor.resource_view')}>
              <DropdownMenuItem onClick={collapseToMention}>
                <RiAtLine aria-hidden />
                <span>{t('pod.editor.mention_view_inline')}</span>
              </DropdownMenuItem>
              <DropdownMenuItem data-active="true">
                <RiWindowLine aria-hidden />
                <span>{t('pod.editor.mention_view_embed')}</span>
                <RiCheckLine aria-hidden className="ml-auto text-foreground" />
              </DropdownMenuItem>
            </DropdownMenuContent>
          </DropdownMenu>
        )}
      </div>
      {page.type === 'base' ? (
        !chartVisible ? (
          <ContentSkeleton variant="block" className="h-[280px]" />
        ) : (
          <Suspense fallback={<ContentSkeleton variant="block" className="h-[280px]" immediate />}>
            {view.kind === 'invalid' ? (
              <div className="space-y-2 p-4" role="alert">
                <p>{t('pod.content.cannot_display')}</p>
                {canConfigureEmbed && (
                  <Button
                    variant="outline"
                    size="sm"
                    onClick={() => configure({ type: looksLikeChartEmbedView(attributes.view) ? 'chart' : 'grid' })}>
                    {t('pod.content.discard_view_changes')}
                  </Button>
                )}
              </div>
            ) : (
              <BasePage
                detail={embeddedDetail}
                tableID={attributes.table}
                viewID={view.kind === 'saved' ? view.id : undefined}
                inlineConfig={view.kind === 'inline' ? view.config : undefined}
                configureInline={canConfigureEmbed ? configure : undefined}
                bindSavedView={canConfigureEmbed ? bindSavedView : undefined}
                embedded
              />
            )}
          </Suspense>
        )
      ) : page.type === 'applet' && embedTrashed ? (
        <div className="p-4 text-sm text-muted-foreground" role="status">
          {t('pod.content.applet_inactive_in_trash')}
        </div>
      ) : (
        <PageContent detail={embeddedDetail} />
      )}
    </div>
  )
}

async function uploadDocumentAsset(pageID: string, file: File) {
  const uploaded = await uploadPageFile(pageID, file, 'asset')
  if (!uploaded.src) throw new Error(t('pod.editor.resource_upload_failed'))
  return { src: uploaded.src, title: file.name, mime: file.type, size: String(file.size) }
}
