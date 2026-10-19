import { t } from 'i18next'
import { BlockEditor } from '@ankole/block-editor'
import {
  insertEmbed,
  insertImage,
  PageSession,
  PageCollaboration,
  type Editor,
  type EditorHost,
  type EmbedAttributes,
  type PageChanges
} from '@ankole/block-editor/editor'
import { parseXml } from '@ankole/block-editor/document'
import {
  Button,
  Dialog,
  DialogContent,
  DialogFooter,
  DialogTitle,
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
  SidebarTrigger,
  useSidebar,
  toast
} from '@ankole/uikit'
import {
  RiAddLine,
  RiFileTextLine,
  RiImageLine,
  RiLink,
  RiExternalLinkLine,
  RiArrowRightSLine,
  RiChat3Line,
  RiDeleteBinLine,
  RiFileCopyLine,
  RiFolderTransferLine,
  RiMoreFill,
  RiStarFill,
  RiStarLine
} from '@remixicon/react'
import { useModel } from '@preact/signals-react'
import { useSignals } from '@preact/signals-react/runtime'
import { QueryClientProvider, useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { lazy, Suspense, useEffect, useMemo, useRef, useState, type RefObject } from 'react'
import { createRoot } from 'react-dom/client'
import { Link, useBlocker, useNavigate, useParams, useSearchParams } from 'react-router'
import { podLocation, podRouteID } from '../common/browser-context'
import { requestErrorMessage } from '../common/request-errors'
import { contentKeys, fileURL, pageAPI, pageQuery, pagesQuery, type Page, type PageDetail } from './content-api'
import { contentError } from './content-errors'
import { ContentError } from './content-primitives'
import { CreatePageDialog } from './page-navigation'
import { FilePage, uploadPageFile } from './page-files'
import { useCopyPageLink, PageSharingButton } from './page-sharing'
import { PageDraftModel } from './state/page-draft'
import { moveDestinations } from './state/page-location'
import { parseEmbedView } from './state/view-config'
import { ContentScope, useContent } from './content-context'
import { isRealtimeAccessDenied, RealtimeRequestError } from './realtime'
import { LocalPageChatDrafts } from './chat-drafts'
import { PageChat } from './page-chat'
import { PageIcon } from './page-icon'
import './page-workspace.css'

const AppletPage = lazy(() => import('./applet-page').then(module => ({ default: module.AppletPage })))
const DatabasePage = lazy(() => import('./database-page').then(module => ({ default: module.DatabasePage })))
const PagePicker = lazy(() => import('./page-picker').then(module => ({ default: module.PagePicker })))

export function PageRoute() {
  const pageID = podRouteID(useParams().pageID) ?? ''
  const { state: sidebarState, isMobile } = useSidebar()
  const navigation =
    isMobile || sidebarState === 'collapsed' ? (
      <header className="flex h-11 shrink-0 items-center px-3">
        <SidebarTrigger label={t('pod.sidebar.expand')} />
      </header>
    ) : null
  const page = useQuery(pageQuery(pageID))
  const client = useQueryClient()
  useEffect(() => {
    if (page.data) {
      void pageAPI
        .state(pageID, { visited: true })
        .then(() => client.invalidateQueries({ queryKey: contentKeys.lists }))
        .catch(() => {})
    }
  }, [pageID, !!page.data, client])
  if (page.isPending) {
    return (
      <>
        {navigation}
        <p role="status" className="p-8">
          {t('pod.content.loading_page')}
        </p>
      </>
    )
  }
  if (page.error && !page.data) {
    return (
      <section className="flex h-full min-h-0 flex-col">
        {navigation}
        <div className="overflow-auto p-8">
          <ContentError
            error={page.error}
            retry={isRealtimeAccessDenied(page.error) ? undefined : () => void page.refetch()}
          />
          <LocalPageChatDrafts pageID={pageID} />
        </div>
      </section>
    )
  }
  return page.data ? (
    <PageWorkspace key={pageID} detail={page.data} loadError={page.error} reload={() => void page.refetch()} />
  ) : null
}

function PageWorkspace({ detail, loadError, reload }: { detail: PageDetail; loadError: unknown; reload(): void }) {
  useSignals()
  const { page, role } = detail
  const { state: sidebarState, isMobile } = useSidebar()
  const [moving, setMoving] = useState(false)
  const actionsTrigger = useRef<HTMLButtonElement>(null)
  const copyLink = useCopyPageLink(page.id)
  const client = useQueryClient()
  const navigate = useNavigate()
  const [search, setSearch] = useSearchParams()
  const selection = search.get('chat')
  const chat = selection === 'new' || selection === 'latest' ? selection : podRouteID(selection ?? undefined)
  const chatTrigger = useRef<HTMLButtonElement>(null)
  const hadChat = useRef(!!chat)
  useEffect(() => {
    if (hadChat.current && !chat && !isMobile) chatTrigger.current?.focus()
    hadChat.current = !!chat
  }, [chat, isMobile])
  const selectChat = (id: string | null, flushSync = false) => {
    const next = podLocation(`/pages/${page.id}`, { ...Object.fromEntries(search), chat: id })
    setSearch(next.search, { replace: true, preventScrollReset: true, flushSync })
  }
  const model = useModel(PageDraftModel)
  model.load(page.id, detail.content?.xml ?? '<page/>', page.revision, page.title)
  const dirty = model.hasUnsavedChanges.value
  const blocker = useBlocker(
    ({ currentLocation, nextLocation }) => dirty && currentLocation.pathname !== nextLocation.pathname
  )
  useEffect(() => {
    if (!dirty && blocker.state === 'blocked') blocker.proceed()
  }, [dirty, blocker])
  useEffect(() => {
    const leave = (event: BeforeUnloadEvent) => {
      if (model.hasUnsavedChanges.value) event.preventDefault()
    }
    window.addEventListener('beforeunload', leave)
    return () => window.removeEventListener('beforeunload', leave)
  }, [model])
  const accessDenied = isRealtimeAccessDenied(loadError)
  const edit = role !== 'view' && !accessDenied
  const favorites = useQuery(pagesQuery('favorites'))
  const favorited = favorites.data?.pages.some(favorite => favorite.id === page.id) ?? false
  const rename = useMutation({
    scope: { id: `page-title:${page.id}` },
    mutationFn: (title: string) => pageAPI.update(page.id, { title }),
    onSuccess: async ({ page }) => {
      model.titleSaved(page.title)
      await Promise.all([
        client.invalidateQueries({ queryKey: contentKeys.page(page.id) }),
        client.invalidateQueries({ queryKey: contentKeys.lists })
      ])
    }
  })
  const saveTitle = () => {
    if (loadError || role === 'view') return
    const title = model.title.value.trim()
    if (model.titleDirty.value && !(rename.isPending && rename.variables === title)) rename.mutate(title)
  }
  const finishTitle = async () => {
    if (loadError || role === 'view') {
      throw new Error(t('pod.content.could_not_confirm_your_editing_permission_reload_the_page_and'))
    }
    if (model.titleDirty.value) await rename.mutateAsync(model.title.value.trim())
  }
  const remove = useMutation({
    mutationFn: async () => {
      await finishTitle()
      if (model.xml.value !== model.savedXML.value) {
        throw new Error(t('pod.content.the_document_has_unsaved_changes_wait_for_it_to_save'))
      }
      return pageAPI.remove(page.id)
    },
    onSuccess: async () => {
      await client.invalidateQueries({ queryKey: contentKeys.all })
      navigate(podLocation('/content/trash'))
    }
  })
  const favorite = useMutation({
    mutationFn: () => pageAPI.state(page.id, { favorite: !favorited }),
    onSuccess: () => client.invalidateQueries({ queryKey: contentKeys.lists })
  })
  return (
    <section className="pod-page flex h-full min-h-0 flex-col overflow-hidden" data-page-type={page.type}>
      <header className="pod-page-header flex h-11 shrink-0 items-center gap-2 px-3">
        <SidebarTrigger
          className={sidebarState === 'expanded' ? 'md:hidden' : undefined}
          label={t('pod.sidebar.expand')}
        />
        <nav
          className="pod-page-breadcrumbs flex min-w-0 flex-1 items-center gap-1 text-sm"
          aria-label={t('pod.content.parent_page')}>
          {page.parent_id && (
            <>
              <ParentPageLink pageID={page.parent_id} />
              <RiArrowRightSLine aria-hidden className="size-4 shrink-0 text-fg-tertiary" />
            </>
          )}
          <span className="truncate px-1" title={model.title.value}>
            {model.title.value || t('pod.content.untitled')}
          </span>
        </nav>
        <div className="flex shrink-0 items-center gap-0.5">
          <Button
            size="icon-sm"
            variant="ghost"
            aria-label={favorited ? t('pod.content.favorited') : t('pod.content.add_to_favorites')}
            title={favorited ? t('pod.content.favorited') : t('pod.content.add_to_favorites')}
            aria-pressed={favorited}
            disabled={favorite.isPending || favorites.isPending || !!favorites.error}
            onClick={() => favorite.mutate()}>
            {favorited ? <RiStarFill aria-hidden className="size-4" /> : <RiStarLine aria-hidden className="size-4" />}
          </Button>
          {!accessDenied && (
            <Button
              size="icon-sm"
              variant="ghost"
              aria-label={t('pod.page_chat.title')}
              title={t('pod.page_chat.title')}
              aria-pressed={!!chat}
              aria-expanded={!!chat}
              ref={chatTrigger}
              onClick={() => selectChat(chat ? null : 'latest', true)}>
              <RiChat3Line aria-hidden className="size-4" />
            </Button>
          )}
          {role === 'manage' && !loadError && <PageSharingButton pageID={page.id} />}
          <DropdownMenu>
            <DropdownMenuTrigger
              render={
                <Button
                  size="icon-sm"
                  variant="ghost"
                  aria-label={t('common.more_actions')}
                  title={t('common.more_actions')}
                  ref={actionsTrigger}
                />
              }>
              <RiMoreFill aria-hidden className="size-4" />
            </DropdownMenuTrigger>
            <DropdownMenuContent align="end" className="w-52">
              <DropdownMenuItem onClick={() => void copyLink()}>
                <RiFileCopyLine aria-hidden />
                {t('pod.content.copy_link')}
              </DropdownMenuItem>
              {edit && !loadError && (
                <DropdownMenuItem disabled={remove.isPending} onClick={() => setMoving(true)}>
                  <RiFolderTransferLine aria-hidden />
                  {t('pod.content.move')}
                </DropdownMenuItem>
              )}
              {role === 'manage' && !loadError && (
                <>
                  <DropdownMenuSeparator />
                  <DropdownMenuItem variant="destructive" disabled={remove.isPending} onClick={() => remove.mutate()}>
                    <RiDeleteBinLine aria-hidden />
                    {t('pod.content.move_to_trash')}
                  </DropdownMenuItem>
                </>
              )}
            </DropdownMenuContent>
          </DropdownMenu>
        </div>
      </header>
      {moving && (
        <MovePageDialog
          page={page}
          beforeMove={finishTitle}
          close={() => setMoving(false)}
          returnFocus={actionsTrigger}
        />
      )}
      <div className="flex min-h-0 flex-1 overflow-hidden">
        <div className="pod-page-scroll min-w-0 flex-1 overflow-auto">
          <div className="pod-page-content">
            <div className="pod-page-heading">
              {edit ? (
                <form
                  className="min-w-0 flex-1"
                  onSubmit={event => {
                    event.preventDefault()
                    saveTitle()
                  }}>
                  <textarea
                    aria-label={t('pod.content.page_title')}
                    rows={1}
                    value={model.title.value}
                    disabled={remove.isPending || !!loadError}
                    placeholder={t('pod.content.untitled')}
                    onChange={event => (model.title.value = event.target.value.replace(/\n/g, ' '))}
                    onKeyDown={event => {
                      if (event.key === 'Enter' && !event.nativeEvent.isComposing) {
                        event.preventDefault()
                        event.currentTarget.blur()
                      }
                    }}
                    className="pod-page-title"
                    onBlur={saveTitle}
                  />
                  <button className="sr-only" type="submit">
                    {t('pod.content.save_title')}
                  </button>
                </form>
              ) : (
                <h1 className="pod-page-title">{page.title || t('pod.content.untitled')}</h1>
              )}
            </div>
            {!!loadError && (
              <p className="mb-3 text-sm">{t('pod.content.could_not_load_the_latest_page_state_your_unsaved_draft')}</p>
            )}
            <ContentError error={loadError} retry={accessDenied ? undefined : reload} />
            {accessDenied && <LocalPageChatDrafts pageID={page.id} />}
            {accessDenied && model.dirty.value && (
              <Button
                variant="outline"
                size="sm"
                onClick={() =>
                  downloadFile(
                    JSON.stringify({ title: model.title.value, xml: model.xml.value }, null, 2),
                    'page-draft.json',
                    'application/json'
                  )
                }>
                {t('pod.content.export_draft')}
              </Button>
            )}
            {edit && (
              <p
                role="status"
                className={rename.isPending || model.titleDirty.value ? 'pod-page-save-state' : 'sr-only'}>
                {rename.isPending
                  ? t('pod.content.saving_title')
                  : model.titleDirty.value
                    ? t('pod.content.title_not_saved')
                    : ''}
              </p>
            )}
            <ContentError error={rename.error} retry={model.titleDirty.value ? saveTitle : undefined} />
            <ContentError error={remove.error || favorite.error || favorites.error} />
            {detail.source_conversation && (
              <p className="pod-page-origin">
                {detail.source_conversation.deleted ? (
                  t('pod.content.source_conversation_deleted')
                ) : (
                  <Link className="link" to={podLocation(`/conversations/${detail.source_conversation.id}`)}>
                    {t('pod.content.source_conversation')}
                    {detail.source_conversation.title || t('pod.content.view_conversation')}
                  </Link>
                )}
              </p>
            )}
            {!accessDenied && (
              <PageContent detail={loadError ? { ...detail, role: 'view' } : detail} documentDraft={model} />
            )}
          </div>
        </div>
        {!accessDenied && (
          <PageChat
            mobile={isMobile}
            pageID={page.id}
            pageTitle={model.title.value}
            selection={chat ?? null}
            select={selectChat}
            returnFocus={chatTrigger}
          />
        )}
      </div>
      <Dialog open={blocker.state === 'blocked'} onOpenChange={open => !open && blocker.reset?.()}>
        <DialogContent className="pod-dialog" closeLabel={t('common.close')}>
          <DialogTitle>{t('pod.content.unsaved_changes')}</DialogTitle>
          <p className="text-sm">{t('pod.content.wait_for_saving_to_finish_or_retry_you_can_download')}</p>
          <DialogFooter>
            <Button variant="outline" onClick={() => blocker.reset?.()}>
              {t('pod.content.continue_editing')}
            </Button>
            <Button
              variant="outline"
              onClick={() => {
                downloadFile(
                  JSON.stringify(
                    { title: model.title.value, xml: model.xml.value, recoveryDrafts: model.recoveryDrafts.value },
                    null,
                    2
                  ),
                  'page-draft.json',
                  'application/json'
                )
                blocker.proceed?.()
              }}>
              {t('pod.content.download_draft_and_leave')}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </section>
  )
}

function ParentPageLink({ pageID }: { pageID: string }) {
  const parent = useQuery(pageQuery(pageID))
  return (
    <Link
      className="inline-flex max-w-40 items-center gap-1.5 rounded px-1 py-1 text-fg-secondary no-underline hover:bg-accent"
      to={podLocation(`/pages/${pageID}`)}>
      {parent.data && <PageIcon page={parent.data.page} />}
      <span className="truncate">{parent.data?.page.title || t('pod.content.untitled')}</span>
    </Link>
  )
}

function PageContent({
  detail,
  documentDraft
}: {
  detail: PageDetail
  documentDraft?: InstanceType<typeof PageDraftModel>
}) {
  switch (detail.page.type) {
    case 'doc':
      return documentDraft ? <DocumentPage key={detail.page.id} detail={detail} model={documentDraft} /> : null
    case 'file':
      return <FilePage detail={detail} />
    case 'database':
      return (
        <Suspense fallback={<p role="status">{t('pod.content.loading')}</p>}>
          <DatabasePage detail={detail} />
        </Suspense>
      )
    case 'applet':
      return (
        <Suspense fallback={<p role="status">{t('pod.content.loading')}</p>}>
          <AppletPage detail={detail} />
        </Suspense>
      )
  }
}

function DocumentPage({ detail, model }: { detail: PageDetail; model: InstanceType<typeof PageDraftModel> }) {
  useSignals()
  const [generation, setGeneration] = useState(0)
  const [initialXML, setInitialXML] = useState(detail.content?.xml ?? '<page/>')
  const initialDocument = useMemo(() => parseXml(initialXML), [initialXML])
  const editor = useRef<Editor | null>(null)
  const session = useRef<PageSession | null>(null)
  const client = useQueryClient()
  const navigate = useNavigate()
  const content = useContent()
  const [assetError, setAssetError] = useState<unknown>()
  const [collaborationError, setCollaborationError] = useState<unknown>()
  const [revoked, setRevoked] = useState(false)
  const retryConnection = useRef<() => void>(() => {})
  const [pending, setPending] = useState(false)
  const [inserting, setInserting] = useState<'create' | 'reference'>()
  const addTrigger = useRef<HTMLButtonElement>(null)
  const imageInput = useRef<HTMLInputElement>(null)
  const host = useMemo<EditorHost>(
    () => ({
      mountEmbed: (attributes, container, update) => {
        const root = createRoot(container)
        root.render(
          <QueryClientProvider client={client}>
            <ContentScope value={content}>
              <PageEmbed
                attributes={attributes}
                configure={(config, table) =>
                  update({ ...attributes, ...(table ? { table } : {}), view: JSON.stringify(config) })
                }
                openPage={id => navigate(podLocation(`/pages/${id}`))}
              />
            </ContentScope>
          </QueryClientProvider>
        )
        return () => {
          queueMicrotask(() => root.unmount())
        }
      },
      openPage: id => navigate(podLocation(`/pages/${id}`)),
      resolveAsset: src =>
        src.startsWith('ankole:asset/') ? fileURL(detail.page.id, `assets/${src.slice('ankole:asset/'.length)}`) : src,
      deleteEmbed: async id => {
        try {
          await pageAPI.removeEmbed(detail.page.id, id)
          await client.invalidateQueries({ queryKey: contentKeys.all })
          return true
        } catch (error) {
          toast.error(requestErrorMessage(contentError(error)))
          return false
        }
      }
    }),
    [client, navigate, detail.page.id, content]
  )
  const reload = async () => {
    const latest = await pageAPI.read(detail.page.id)
    model.reload(latest.content?.xml ?? '<page/>', latest.page.revision)
    setInitialXML(latest.content?.xml ?? '<page/>')
    setGeneration(value => value + 1)
  }
  const uploadImage = async (file: File) => {
    try {
      setAssetError(undefined)
      const uploaded = await uploadPageFile(detail.page.id, file, 'asset')
      if (!uploaded.src || !editor.current) {
        throw new Error(t('pod.content.the_image_upload_did_not_return_a_usable_address'))
      }
      if (!insertImage(editor.current, { src: uploaded.src, alt: file.name })) {
        throw new Error(t('pod.content.the_image_cannot_be_inserted_right_now_finish_your_input'))
      }
    } catch (error) {
      setAssetError(error)
    }
  }
  return (
    <section className="pod-document">
      {detail.role !== 'view' && (
        <div className="pod-document-tools">
          <DropdownMenu>
            <DropdownMenuTrigger
              render={<Button size="sm" variant="ghost" className="pod-document-add" ref={addTrigger} />}>
              <RiAddLine aria-hidden className="size-4" />
              {t('pod.content.add_content')}
            </DropdownMenuTrigger>
            <DropdownMenuContent align="start" className="w-56">
              <DropdownMenuItem onClick={() => setInserting('create')}>
                <RiFileTextLine aria-hidden /> {t('pod.content.new_page')}
              </DropdownMenuItem>
              <DropdownMenuItem onClick={() => setInserting('reference')}>
                <RiLink aria-hidden /> {t('pod.content.reference_an_existing_page')}
              </DropdownMenuItem>
              <DropdownMenuItem onClick={() => imageInput.current?.click()}>
                <RiImageLine aria-hidden /> {t('pod.content.upload_image')}
              </DropdownMenuItem>
            </DropdownMenuContent>
          </DropdownMenu>
          <span
            className={
              model.conflict.value || collaborationError || pending || model.xml.value !== model.savedXML.value
                ? 'pod-document-status'
                : 'pod-document-status pod-document-status-saved'
            }
            role="status">
            {model.conflict.value
              ? t('pod.content.unsaved_draft_kept')
              : collaborationError
                ? t('pod.content.document_sync_error')
                : pending || model.xml.value !== model.savedXML.value
                  ? t('pod.content.saving')
                  : t('pod.content.saved_automatically')}
          </span>
          <input
            ref={imageInput}
            aria-label={t('pod.content.upload_image')}
            className="hidden"
            type="file"
            accept="image/*"
            onChange={event => {
              const file = event.target.files?.[0]
              if (file) void uploadImage(file)
              event.target.value = ''
            }}
          />
        </div>
      )}
      {inserting === 'create' && (
        <CreatePageDialog
          parentID={detail.page.id}
          returnFocus={addTrigger}
          onClose={() => setInserting(undefined)}
          onCreated={page => {
            if (editor.current) insertEmbed(editor.current, { ref: page.id })
          }}
        />
      )}
      {inserting === 'reference' && (
        <ReferencePageDialog
          returnFocus={addTrigger}
          onClose={() => setInserting(undefined)}
          onSelect={page => {
            if (editor.current) insertEmbed(editor.current, { ref: page.id })
          }}
        />
      )}
      {model.conflict.value && (
        <div className="rounded border border-warning p-4 text-sm" role="alert">
          <p>{t('pod.content.the_document_has_changed_your_draft_has_been_kept_export')}</p>
          <div className="mt-3 flex gap-3">
            <Button variant="outline" size="sm" onClick={() => downloadDraft(model.xml.value)}>
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
              <Button size="sm" variant="outline" onClick={() => downloadDraft(draft)}>
                {t('pod.content.export_kept_draft')} {index + 1}
              </Button>
              <Button size="sm" variant="ghost" onClick={() => model.discardRecoveryDraft(draft)}>
                {t('common.discard')}
              </Button>
            </div>
          ))}
        </div>
      )}
      <ContentError
        error={assetError || collaborationError}
        retry={!revoked ? () => retryConnection.current() : undefined}
      />
      {revoked ? (
        <p role="alert">{t('pod.content.you_no_longer_have_access_to_this_page_your_unsaved')}</p>
      ) : (
        <BlockEditor
          key={generation}
          initial={initialDocument}
          host={host}
          readOnly={detail.role === 'view' || model.conflict.value}
          className="min-h-[60vh]"
          toolbar={null}
          onError={setCollaborationError}
          onReady={instance => {
            editor.current = instance
            const current = new PageSession(instance)
            session.current = current
            let disposed = false
            let handle: Awaited<ReturnType<typeof content.realtime.join>> | undefined
            let joined: Promise<Awaited<ReturnType<typeof content.realtime.join>>> | undefined
            const failed = (error: unknown) => {
              if (disposed) return
              setCollaborationError(error)
              if (isRealtimeAccessDenied(error)) {
                collaboration.dispose()
                model.conflict.value = true
                setRevoked(true)
                void client.invalidateQueries({ queryKey: contentKeys.page(detail.page.id) })
              }
            }
            const connect = () => {
              if (!joined) {
                const attempt = content.realtime.join(`page:${detail.page.id}`).then(async connection => {
                  if (disposed) {
                    connection.close()
                    throw new Error(t('pod.content.the_page_connection_is_closed'))
                  }
                  handle = connection
                  connection.on('changes', response => collaboration.receive(response))
                  connection.on('access_revoked', () => {
                    failed(new RealtimeRequestError({ reason: 'forbidden' }))
                    connection.close()
                  })
                  const response = (await connection.ready) as PageDetail
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
              clientID: crypto.randomUUID(),
              send: async request => {
                try {
                  const connection = await connect()
                  return await connection.push<PageChanges>('changes', request)
                } catch (error) {
                  if (error instanceof RealtimeRequestError) {
                    collaboration.dispose()
                    model.conflict.value = true
                    setCollaborationError(error)
                  }
                  throw error
                }
              },
              changed: state => {
                model.saved(state.xml, state.revision)
                setPending(state.pending)
                setCollaborationError(state.error)
              },
              reset: draft => {
                if (draft) model.keepRecoveryDraft(draft)
                model.conflict.value = true
                void reload().catch(setCollaborationError)
              },
              sync
            })
            void connect()
            const unwatch = content.realtime.watchVersion('pages', detail.page.id, version => {
              if (version === undefined) {
                collaboration.dispose()
                model.conflict.value = true
                setRevoked(true)
                setCollaborationError(new Error(t('pod.content.you_no_longer_have_access_to_this_page_your_unsaved_2')))
                handle?.close()
              } else if (version !== collaboration.currentRevision()) sync()
            })
            return () => {
              disposed = true
              unwatch()
              collaboration.dispose()
              handle?.close()
              current.dispose()
              if (session.current === current) {
                session.current = null
                editor.current = null
              }
            }
          }}
          onChange={() => {
            if (session.current) model.xml.value = session.current.readXml().xml
          }}
        />
      )}
    </section>
  )
}

function PageEmbed({
  attributes,
  configure,
  openPage
}: {
  attributes: EmbedAttributes
  configure(config: Record<string, unknown>, table?: string): void
  openPage(id: string): void
}) {
  const { pageHref } = useContent()
  const query = useQuery({ ...pageQuery(attributes.ref ?? ''), enabled: !!attributes.ref })
  if (!attributes.ref || query.error) {
    return <p className="p-4 text-sm text-fg-tertiary">{t('pod.content.cannot_display')}</p>
  }
  if (!query.data) {
    return (
      <p role="status" className="p-4 text-sm">
        {t('pod.content.loading')}
      </p>
    )
  }
  if (query.data.page.type === 'doc') {
    return (
      <a
        className="pod-page-reference link"
        href={pageHref(query.data.page.id)}
        onClick={event => {
          if (event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return
          event.preventDefault()
          openPage(query.data!.page.id)
        }}>
        <PageIcon page={query.data.page} className="size-5 shrink-0" />
        <span>{query.data.page.title || t('pod.content.untitled')}</span>
      </a>
    )
  }
  const view = parseEmbedView(attributes.view)
  return (
    <div className="pod-inline-page" data-page-type={query.data.page.type}>
      <Button variant="ghost" className="pod-inline-page-title" onClick={() => openPage(query.data!.page.id)}>
        <PageIcon page={query.data.page} />
        {query.data.page.title || t('pod.content.untitled')}
        <RiExternalLinkLine aria-hidden />
      </Button>
      {query.data.page.type === 'database' ? (
        <Suspense fallback={<p role="status">{t('pod.content.loading')}</p>}>
          {view.kind === 'invalid' ? (
            <div className="space-y-2 p-4" role="alert">
              <p>{t('pod.content.cannot_display')}</p>
              <Button variant="outline" size="sm" onClick={() => configure({ type: 'grid' })}>
                {t('pod.content.discard_view_changes')}
              </Button>
            </div>
          ) : (
            <DatabasePage
              detail={query.data}
              tableID={attributes.table}
              viewID={view.kind === 'saved' ? view.id : undefined}
              inlineConfig={view.kind === 'inline' ? view.config : undefined}
              configureInline={configure}
            />
          )}
        </Suspense>
      ) : (
        <PageContent detail={query.data} />
      )}
    </div>
  )
}

function ReferencePageDialog({
  onSelect,
  onClose,
  returnFocus
}: {
  onSelect(page: Page): void
  onClose(): void
  returnFocus: RefObject<HTMLElement | null>
}) {
  const pages = useQuery(pagesQuery('all'))
  return (
    <Dialog open onOpenChange={open => !open && onClose()}>
      <DialogContent className="pod-dialog pod-picker-dialog" closeLabel={t('common.close')} finalFocus={returnFocus}>
        <DialogTitle>{t('pod.content.reference_page')}</DialogTitle>
        {pages.isPending ? (
          <p role="status">{t('pod.content.loading')}</p>
        ) : (
          <Suspense fallback={<p role="status">{t('pod.content.loading')}</p>}>
            <PagePicker
              label={t('pod.content.choose_a_page')}
              pages={pages.data?.pages ?? []}
              disabled={pages.isPending}
              onSelect={id => {
                const page = pages.data?.pages.find(page => page.id === id)
                if (page) {
                  onSelect(page)
                  onClose()
                }
              }}
            />
          </Suspense>
        )}
        <ContentError error={pages.error} />
      </DialogContent>
    </Dialog>
  )
}

function MovePageDialog({
  page,
  beforeMove,
  close,
  returnFocus
}: {
  page: Page
  beforeMove(): Promise<void>
  close(): void
  returnFocus: RefObject<HTMLElement | null>
}) {
  const currentTarget = page.parent_id ?? (page.private_owner_uid ? 'private' : 'space')
  const [target, setTarget] = useState(currentTarget)
  const available = useQuery(pagesQuery('all'))
  const privatePages = useQuery(pagesQuery('private'))
  const client = useQueryClient()
  const waitingForIdentity = target === 'private' && !privatePages.data?.principal_uid
  const move = useMutation({
    mutationFn: async () => {
      if (waitingForIdentity) throw new Error(t('pod.content.your_private_identity_is_not_available_yet_wait_for_the'))
      if (!validTarget || target === currentTarget) throw new Error(t('pod.content.choose_an_available_destination'))
      await beforeMove()
      return pageAPI.move(page.id, {
        parent_id: target === 'space' || target === 'private' ? null : target,
        private_owner_uid: target === 'private' ? privatePages.data?.principal_uid : null
      })
    },
    onSuccess: async () => {
      await client.invalidateQueries({ queryKey: contentKeys.all })
      close()
    }
  })
  const pages = moveDestinations(available.data?.pages ?? [], page.id)
  const validTarget = target === 'private' || target === 'space' || pages.some(candidate => candidate.id === target)
  const targetTitle =
    target === 'space'
      ? t('pod.content.space')
      : target === 'private'
        ? 'Private'
        : pages.find(candidate => candidate.id === target)?.title || t('pod.content.untitled')
  return (
    <Dialog open onOpenChange={next => !next && !move.isPending && close()}>
      <DialogContent
        className="pod-dialog pod-picker-dialog"
        closeLabel={t('common.close')}
        finalFocus={returnFocus}
        showCloseButton={!move.isPending}>
        <DialogTitle>{t('pod.content.move_page')}</DialogTitle>
        <div className="pod-dialog-body grid gap-3">
          <Suspense fallback={<p role="status">{t('pod.content.loading_destinations')}</p>}>
            <PagePicker
              label={t('pod.content.destination')}
              pages={pages}
              roots={[
                { id: 'space', title: t('pod.content.space') },
                { id: 'private', title: 'Private', private: true }
              ]}
              selected={target}
              onSelect={setTarget}
              disabled={move.isPending}
            />
          </Suspense>
          <p className="pod-selected-destination text-sm" aria-live="polite">
            <span className="text-fg-tertiary">{t('pod.content.destination')}: </span>
            {targetTitle}
          </p>
          {target !== currentTarget && (
            <p className="text-xs text-fg-tertiary">
              {target === 'private'
                ? t('pod.content.after_moving_to_private_the_page_stops_inheriting_permissions_from')
                : t('pod.content.the_page_and_its_subpages_move_together_pages_with_inherited')}
            </p>
          )}
          {available.isPending && <p role="status">{t('pod.content.loading_destinations')}</p>}
          {waitingForIdentity && !privatePages.error && <p role="status">{t('pod.content.loading_private')}</p>}
          <ContentError
            error={move.error || available.error || (target === 'private' ? privatePages.error : undefined)}
            retry={() => {
              void available.refetch()
              if (target === 'private') void privatePages.refetch()
            }}
          />
        </div>
        <DialogFooter>
          <Button variant="ghost" disabled={move.isPending} onClick={close}>
            {t('pod.content.cancel')}
          </Button>
          <Button
            disabled={!validTarget || target === currentTarget || waitingForIdentity || move.isPending}
            variant="outline"
            onClick={() => move.mutate()}>
            {move.isPending ? t('pod.content.moving') : t('pod.content.move')}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}

function downloadDraft(xml: string) {
  downloadFile(xml, 'document-draft.xml', 'application/xml')
}

function downloadFile(content: string, filename: string, type: string) {
  const url = URL.createObjectURL(new Blob([content], { type }))
  const anchor = document.createElement('a')
  anchor.href = url
  anchor.download = filename
  anchor.click()
  setTimeout(() => URL.revokeObjectURL(url), 1000)
}
