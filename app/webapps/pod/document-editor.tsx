import { usePageMetadata } from './use-page-metadata'
import { PageContent } from './page-content'
import { refreshDirectories } from './state/navigation-cache'
import { partition, uuidV4 } from '@agentbull/active-support'
import { t } from 'i18next'
import { I18nextProvider, useTranslation } from 'react-i18next'
import { editorLabels } from './state/editor-labels'
import { BlockEditor, type EditorHandle } from '@ankole/block-editor'
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
import { parseXml, printMarkdown } from '@ankole/block-editor/document'
import { Button, Dialog, DialogContent, DialogTitle, DropdownMenuItem, toast } from '@ankole/uikit'
import { RiCloseLine, RiExternalLinkLine, RiLayoutGridLine } from '@remixicon/react'

import { useModel } from '@preact/signals-react'
import { DocumentPresence } from './document-presence'
import { DocumentPresenceModel, peerColor } from './state/document-presence'
import { useSignals } from '@preact/signals-react/runtime'
import { QueryClientProvider, useQuery, useQueryClient } from '@tanstack/react-query'
import { lazy, Suspense, useEffectEvent, useMemo, useRef, useState, type SyntheticEvent } from 'react'
import { createPortal } from 'react-dom'
import { createRoot } from 'react-dom/client'
import { useNavigate } from '@tanstack/react-router'
import { podLocation } from '../common/browser-context'
import { ErrorBoundary, rootErrorOptions } from '../common/error-boundary'
import {
  EXTERNAL_TRANSLATION_GUARD_ATTRS,
  withExternalTranslationGuardClass
} from '../common/external-translation-guard'

import { requestErrorMessage } from '../common/request-errors'
import { contentKeys, fileURL, pageAPI, pageQuery, type PageDetail } from './content-api'
import { contentError } from './content-errors'
import { ContentError } from './content-primitives'
import { createMentionHostAdapters } from './document-mentions'

import { CreatePageSubmenu, uploadFileSubpages, usePageCreation } from './page-create-menu'
import { uploadPageFile } from './page-files'

import { PageDraftModel } from './state/page-draft'
import { documentFilename } from './state/document-tools'

import { parseEmbedView } from './state/view-config'
import { ContentScope, useContent } from './content-context'
import { isRealtimeAccessDenied, RealtimeRequestError } from './realtime'

import { PageIcon } from './page-icon'

const BasePage = lazy(() => import('./base-page').then(module => ({ default: module.BasePage })))
const PagePicker = lazy(() => import('./page-picker').then(module => ({ default: module.PagePicker })))

export function DocumentPage({
  detail,
  model,
  presenceContainer,
  onEditor,
  resolvedCommentIDs,
  onComment,
  onRequestComment,
  onAskAgent
}: {
  detail: PageDetail
  model: InstanceType<typeof PageDraftModel>
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
      if (editor.current && !editor.current.state.readOnly) {
        if (created.type === 'doc') {
          openCreatedDocument.current = created.id
          insertMention(editor.current, { page: created.id })
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
        openPage: id => void navigate({ to: podLocation(`/pages/${id}`).pathname }),
        i18n
      }),
      openComment: ids => openComment(ids),
      ...(canComment
        ? { requestComment: (selection: { from: number; to: number; quote: string }) => requestComment(selection) }
        : {}),
      ...(canAskAgent
        ? { askAgent: (selection: { from: number; to: number; quote: string }) => askAgent(selection) }
        : {}),
      mountEmbed: (attributes, container, update, remove) => {
        const trashed = Boolean(detail.page.deleted_at)
        const root = createRoot(container, rootErrorOptions)
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
                    configure={(config, table) =>
                      update({ ...attributes, ...(table ? { table } : {}), view: JSON.stringify(config) })
                    }
                    openPage={id => void navigate({ to: podLocation(`/pages/${id}`).pathname })}
                  />
                </ErrorBoundary>
              </ContentScope>
            </QueryClientProvider>
          </I18nextProvider>
        )
        return () => {
          queueMicrotask(() => root.unmount())
        }
      },
      // The upload panel shows the rejection's message as it is.
      acceptFiles: files =>
        uploadFileSubpages(client, detail.page.id, files).catch(error => {
          throw new Error(requestErrorMessage(contentError(error)))
        }),
      uploadAsset: file => uploadDocumentAsset(detail.page.id, file),
      openPage: id => void navigate({ to: podLocation(`/pages/${id}`).pathname }),
      resolveAsset: src =>
        src.startsWith('ankole:asset/') ? fileURL(detail.page.id, `assets/${src.slice('ankole:asset/'.length)}`) : src,
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
            <Button variant="outline" size="sm" onClick={() => downloadDraft(model.xml.value, model.title.value)}>
              {t('pod.content.export_draft')}
            </Button>
            <Button variant="outline" size="sm" onClick={() => void reload().catch(setAssetError)}>
              {t('pod.content.reload_document')}
            </Button>
          </div>
        </div>
      )}
      {model.recoveryDrafts.value.length > 0 && (
        <div role="alert" className="rounded border border-border p-4 text-sm">
          <p>{t('pod.content.another_write_replaced_the_document_so_the_current_content_was')}</p>
          {model.recoveryDrafts.value.map((draft, index) => (
            <div key={draft} className="mt-2 flex gap-2">
              <Button size="sm" variant="outline" onClick={() => downloadDraft(draft, model.title.value)}>
                {t('pod.content.export_kept_draft')} {index + 1}
              </Button>
              <Button size="sm" variant="ghost" onClick={() => model.discardRecoveryDraft(draft)}>
                {t('common.discard')}
              </Button>
            </div>
          ))}
        </div>
      )}
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
              <>
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
                <DropdownMenuItem
                  onClick={() => {
                    prepareInsertion()
                    queueMicrotask(() => setEmbedPickerOpen(true))
                  }}>
                  <RiLayoutGridLine aria-hidden />
                  {t('pod.content.embed_existing_content')}
                </DropdownMenuItem>
              </>
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
                    void navigate({ to: podLocation(`/pages/${id}`).pathname })
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
                <Suspense fallback={<p role="status">{t('pod.content.loading')}</p>}>
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
    </section>
  )
}

export function PageEmbed({
  attributes,
  canEdit,
  trashed,
  model,
  remove,
  configure,
  openPage
}: {
  attributes: EmbedAttributes
  canEdit: boolean
  trashed: boolean
  model: InstanceType<typeof PageDraftModel>
  remove(): void
  configure(config: Record<string, unknown>, table?: string): void
  openPage(id: string): void
}) {
  useSignals()
  const { t } = useTranslation()
  const editable = canEdit && !model.conflict.value
  const query = useQuery({ ...pageQuery(attributes.ref ?? ''), enabled: !!attributes.ref })
  const page = usePageMetadata(query.data?.page)
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
    return (
      <p role="status" className="p-4 text-sm">
        {t('pod.content.loading')}
      </p>
    )
  }
  if (page.type === 'doc') {
    return cannotDisplay
  }
  const view = parseEmbedView(attributes.view)
  const embedTrashed = trashed || Boolean(query.data.page.deleted_at)
  const embeddedDetail = embedTrashed ? { ...query.data, actions: ['node_view' as const] } : query.data
  return (
    <div className="pod-inline-page" data-page-type={page.type}>
      <Button variant="ghost" className="pod-inline-page-title" onClick={() => openPage(query.data!.page.id)}>
        <PageIcon page={page} />
        {page.title || t('pod.content.untitled')}
        <RiExternalLinkLine aria-hidden />
      </Button>
      {page.type === 'base' ? (
        <Suspense fallback={<p role="status">{t('pod.content.loading')}</p>}>
          {view.kind === 'invalid' ? (
            <div className="space-y-2 p-4" role="alert">
              <p>{t('pod.content.cannot_display')}</p>
              <Button variant="outline" size="sm" disabled={embedTrashed} onClick={() => configure({ type: 'grid' })}>
                {t('pod.content.discard_view_changes')}
              </Button>
            </div>
          ) : (
            <BasePage
              detail={embeddedDetail}
              tableID={attributes.table}
              viewID={view.kind === 'saved' ? view.id : undefined}
              inlineConfig={view.kind === 'inline' ? view.config : undefined}
              configureInline={configure}
            />
          )}
        </Suspense>
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

function xmlToMarkdown(xml: string): string {
  try {
    return printMarkdown(parseXml(xml)).trim()
  } catch {
    return xml.trim()
  }
}

export function downloadDraft(xml: string, title?: string, recoveryDrafts?: readonly string[]) {
  const parts: string[] = []
  const heading = title?.trim()
  if (heading) parts.push(`# ${heading}`)
  const body = xmlToMarkdown(xml)
  if (body) parts.push(body)
  recoveryDrafts?.forEach((draft, index) => {
    const kept = xmlToMarkdown(draft)
    if (kept) parts.push(`---\n\n## ${t('pod.content.export_kept_draft')} ${index + 1}\n\n${kept}`)
  })
  downloadFile(
    `${parts.join('\n\n')}\n`,
    documentFilename(heading ?? '', 'document-draft'),
    'text/markdown;charset=utf-8'
  )
}

function downloadFile(content: string, filename: string, type: string) {
  const url = URL.createObjectURL(new Blob([content], { type }))
  const anchor = document.createElement('a')
  anchor.href = url
  anchor.download = filename
  anchor.click()
  setTimeout(() => URL.revokeObjectURL(url), 1000)
}
