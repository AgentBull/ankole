import { formatFileBytes } from '../../common/file-format'
import { TableRow, useMutation, useQuery, Link, useSearchParams } from '../tenant-context'
import {
  Button,
  Dialog,
  DialogClose,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuTrigger,
  Input,
  TableCell,
  toast
} from '@ankole/uikit'
import {
  RiDeleteBin6Line,
  RiCheckLine,
  RiCloseLine,
  RiDownloadLine,
  RiFileLine,
  RiFolder3Line,
  RiMore2Fill,
  RiPencilLine,
  RiUploadCloud2Line
} from '@remixicon/react'
import { useQueryClient } from '@tanstack/react-query'
import { useDeferredValue, useEffect, useRef, useState, type InputHTMLAttributes } from 'react'
import { useTranslation } from 'react-i18next'
import { useParams } from '@tanstack/react-router'
import { linkTarget } from '../../common/router'
import {
  deleteAgentFilesMutation,
  listAgentFilesOptions,
  moveAgentFilesMutation
} from '../api/v2/generated/@tanstack/react-query.gen'
import { downloadAgentFile, uploadAgentFile } from '../api/agent-files'
import type { AgentFileEntry } from '../api/runtime-types'
import { agentOptions } from '../api/agents'
import { requestErrorMessage } from '../../common/request-errors'
import { ResourceListPage, ResourceSearch, ScopeBar } from '../console-list-page'
import { BackLink } from '../console-page'
import { formatConsoleDate } from '../console-primitives'
import { effectiveResourceSearchQuery, matchesResourceSearch } from '../state/resource-search'

/**
 * The Agent's drive: every file that stays after a conversation. It lives in
 * the control plane, so it is browsable while the Agent has no running Worker.
 */
export function AgentFilesPage() {
  const { t } = useTranslation()
  const params = useParams({ strict: false })
  const agentUID = params.uid ?? ''
  const queryClient = useQueryClient()
  const [searchParams, setSearchParams] = useSearchParams()
  const path = searchParams.get('path') ?? ''
  const [query, setQuery] = useState('')
  const deferredQuery = useDeferredValue(query)
  const searchQuery = effectiveResourceSearchQuery(query, deferredQuery)

  const agent = useQuery(agentOptions(agentUID))
  const listing = useQuery(listAgentFilesOptions({ path: { agent_uid: agentUID }, query: path ? { path } : {} }))

  const folders = (listing.data?.file_listing.folders ?? []).filter(folder =>
    matchesResourceSearch(searchQuery, folder.name, folder.path)
  )
  const files = (listing.data?.file_listing.files ?? []).filter(file =>
    matchesResourceSearch(
      searchQuery,
      basename(file.path),
      file.path,
      file.content_type,
      file.source,
      file.conversation_id,
      file.message_id
    )
  )

  // The files of one upload go one after another and report once: how many
  // arrived, and the first rejected file with its reason.
  const upload = useMutation({
    mutationFn: async (items: UploadItem[]) => {
      const failures: { name: string; reason: string }[] = []
      for (const item of items) {
        const result = await uploadAgentFile(agentUID, item.drivePath, item.file)
        if (result.error !== undefined) {
          failures.push({ name: item.drivePath, reason: requestErrorMessage(result.error) })
        }
      }
      return { uploaded: items.length - failures.length, failures }
    },
    onSuccess: ({ uploaded, failures }) => {
      if (uploaded > 0) toast.success(t('console.agent_files.uploaded', { count: uploaded }))
      const [first, ...more] = failures
      if (first) toast.error(t('console.agent_files.upload_failed', first))
      if (more.length > 0) toast.error(t('console.agent_files.upload_failed_more', { count: more.length }))
    },
    onError: error => {
      toast.error(requestErrorMessage(error))
      void queryClient.invalidateQueries()
    }
  })

  const move = useMutation({
    ...moveAgentFilesMutation(),
    onSuccess: (_data, { body }) => {
      const renamed = parentPath(body.data.from_path) === parentPath(body.data.to_path)
      toast.success(t(renamed ? 'console.agent_files.renamed' : 'console.agent_files.moved'))
    },
    onError: error => toast.error(requestErrorMessage(error))
  })

  const remove = useMutation({
    ...deleteAgentFilesMutation(),
    onSuccess: () => {
      toast.success(t('console.agent_files.deleted'))
    },
    onError: error => toast.error(requestErrorMessage(error))
  })

  const enterPath = (next: string) => {
    setQuery('')
    setSearchParams(next ? { path: next } : {})
  }

  const agentName = agent.data?.display_name || agentUID
  const pending = move.isPending || remove.isPending

  // Navigation lives in `subNav` so it stays visible over an empty folder: the
  // breadcrumbs and the upload action are how the operator leaves it.
  const subNav = (
    <ScopeBar>
      <BackLink to={`/agents/${encodeURIComponent(agentUID)}`} />
      <Breadcrumbs agentName={agentName} path={path} onNavigate={enterPath} />
      <div className="ml-auto">
        <UploadMenu currentPath={path} disabled={upload.isPending} onUpload={items => upload.mutate(items)} />
      </div>
    </ScopeBar>
  )

  return (
    <ResourceListPage
      title={t('console.agent_files.title', { name: agentName })}
      description={t('console.agent_files.description')}
      subNav={subNav}
      toolbar={
        <ResourceSearch
          label={t('console.agent_files.search')}
          placeholder={t('console.agent_files.search_placeholder')}
          value={query}
          onChange={setQuery}
        />
      }
      columns={[
        t('console.agent_files.name'),
        t('console.agent_files.source'),
        t('console.agent_files.size'),
        t('console.agent_files.modified')
      ]}
      isLoading={listing.isLoading}
      isEmpty={folders.length === 0 && files.length === 0}
      count={folders.length + files.length}
      emptyTitle={t('console.agent_files.empty_title')}
      emptyIcon={<RiFolder3Line aria-hidden />}
      emptyDescription={t('console.agent_files.empty_description')}
      isFiltered={Boolean(query.trim())}
      onClearFilters={() => setQuery('')}
      footer={
        listing.data?.file_listing.truncated ? (
          <p role="status" className="text-sm text-muted-foreground">
            {t('console.agent_files.truncated')}
          </p>
        ) : null
      }
      error={agent.error ?? listing.error}>
      {folders.map(folder => (
        <PathRow
          key={folder.path}
          path={folder.path}
          pending={pending}
          onNavigate={enterPath}
          onMove={(to, onSuccess) =>
            move.mutate(
              { path: { agent_uid: agentUID }, body: { data: { from_path: folder.path, to_path: to } } },
              { onSuccess }
            )
          }
          onDelete={onSuccess =>
            remove.mutate({ path: { agent_uid: agentUID }, query: { path: folder.path } }, { onSuccess })
          }
        />
      ))}
      {files.map(file => (
        <PathRow
          key={file.path}
          agentUID={agentUID}
          file={file}
          path={file.path}
          pending={pending}
          onNavigate={enterPath}
          onMove={(to, onSuccess) =>
            move.mutate(
              { path: { agent_uid: agentUID }, body: { data: { from_path: file.path, to_path: to } } },
              { onSuccess }
            )
          }
          onDelete={onSuccess =>
            remove.mutate({ path: { agent_uid: agentUID }, query: { path: file.path } }, { onSuccess })
          }
        />
      ))}
    </ResourceListPage>
  )
}

function Breadcrumbs({
  agentName,
  path,
  onNavigate
}: {
  agentName: string
  path: string
  onNavigate: (path: string) => void
}) {
  const { t } = useTranslation()
  const segments = path.split('/').filter(Boolean)

  return (
    <nav aria-label={t('console.agent_files.breadcrumbs')} className="flex flex-wrap items-center gap-1 text-sm">
      {segments.length === 0 ? (
        <span className="text-foreground">{agentName}</span>
      ) : (
        <button type="button" className="text-muted-foreground hover:text-foreground" onClick={() => onNavigate('')}>
          {agentName}
        </button>
      )}
      {segments.map((segment, index) => {
        const prefix = segments.slice(0, index + 1).join('/')
        const isLast = index === segments.length - 1
        return (
          <span key={prefix} className="flex items-center gap-1">
            <span className="text-muted-foreground">/</span>
            {isLast ? (
              <span className="text-foreground">{segment}</span>
            ) : (
              <button
                type="button"
                className="text-muted-foreground hover:text-foreground"
                onClick={() => onNavigate(prefix)}>
                {segment}
              </button>
            )}
          </span>
        )
      })}
    </nav>
  )
}

/** One folder (without `file`) or one file of the listing. */
function PathRow({
  agentUID,
  file,
  path,
  pending,
  onNavigate,
  onMove,
  onDelete
}: {
  agentUID?: string
  file?: AgentFileEntry
  path: string
  pending: boolean
  onNavigate: (path: string) => void
  onMove: (to: string, onSuccess: () => void) => void
  onDelete: (onSuccess: () => void) => void
}) {
  const { t } = useTranslation()
  const name = basename(path)
  const isFolder = file === undefined
  const [moveOpen, setMoveOpen] = useState(false)
  const [deleteOpen, setDeleteOpen] = useState(false)
  const [rename, setRename] = useState<string>()

  const handleDownload = async () => {
    if (!agentUID) return
    // The response carries the file's own content type; without `parseAs` the
    // client would return text and JSON files as a string or an object.
    const result = await downloadAgentFile(agentUID, path)
    if (result.error !== undefined || !(result.data instanceof Blob)) {
      toast.error(requestErrorMessage(result.error ?? new Error(t('console.agent_files.download_failed'))))
      return
    }
    const url = URL.createObjectURL(result.data)
    const anchor = document.createElement('a')
    anchor.href = url
    anchor.download = name
    document.body.appendChild(anchor)
    anchor.click()
    anchor.remove()
    URL.revokeObjectURL(url)
  }

  return (
    <TableRow>
      <TableCell>
        <div className="flex items-center gap-2">
          {isFolder ? (
            <RiFolder3Line className="size-4 text-muted-foreground" aria-hidden />
          ) : (
            <RiFileLine className="size-4 text-muted-foreground" aria-hidden />
          )}
          {rename !== undefined ? (
            <form
              className="flex items-center gap-1"
              onSubmit={event => {
                event.preventDefault()
                if (pending || !rename.trim() || rename.includes('/')) return
                if (rename.trim() === name) setRename(undefined)
                else onMove(joinPath(parentPath(path), rename.trim()), () => setRename(undefined))
              }}>
              <Input
                autoFocus
                required
                pattern="[^/]+"
                aria-label={t('console.agent_files.name')}
                value={rename}
                disabled={pending}
                onFocus={event => event.currentTarget.select()}
                onChange={event => setRename(event.target.value)}
                onKeyDown={event => {
                  if (event.key === 'Escape') {
                    event.preventDefault()
                    setRename(undefined)
                  }
                }}
              />
              <Button type="submit" size="icon-sm" variant="ghost" disabled={pending} aria-label={t('common.save')}>
                <RiCheckLine />
              </Button>
              <Button
                type="button"
                size="icon-sm"
                variant="ghost"
                disabled={pending}
                aria-label={t('common.cancel')}
                onClick={() => setRename(undefined)}>
                <RiCloseLine />
              </Button>
            </form>
          ) : isFolder ? (
            <button
              type="button"
              data-row-link
              className="text-left"
              aria-label={t('console.agent_files.open_folder', { name })}
              onClick={() => onNavigate(path)}>
              {name}
            </button>
          ) : (
            <button
              type="button"
              data-row-link
              className="text-left hover:underline"
              onClick={() => void handleDownload()}>
              {name}
            </button>
          )}
        </div>
      </TableCell>
      <TableCell className="text-xs text-muted-foreground">
        {file ? (
          <div className="space-y-1">
            <div>{t(`console.agent_files.source_${file.source}`)}</div>
            {file.conversation_id ? (
              <div>{t('console.agent_files.source_channel', { id: file.conversation_id })}</div>
            ) : null}
            {file.message_id ? <div>{t('console.agent_files.source_entry', { id: file.message_id })}</div> : null}
          </div>
        ) : (
          t('console.agent_files.folder')
        )}
      </TableCell>
      <TableCell className="text-xs text-muted-foreground">{file ? formatFileBytes(file.size) || '–' : '–'}</TableCell>
      <TableCell className="text-xs text-muted-foreground">{file ? formatConsoleDate(file.updated_at) : '–'}</TableCell>
      <TableCell className="text-right">
        <DropdownMenu>
          <DropdownMenuTrigger
            render={
              <Button
                aria-label={t('common.more_actions')}
                title={t('common.more_actions')}
                disabled={pending}
                size="icon-sm"
                type="button"
                variant="ghost"
              />
            }>
            <RiMore2Fill />
          </DropdownMenuTrigger>
          <DropdownMenuContent align="end" className="w-48">
            {file ? (
              <DropdownMenuItem onClick={() => void handleDownload()}>
                <RiDownloadLine />
                {t('console.agent_files.download')}
              </DropdownMenuItem>
            ) : null}
            <DropdownMenuItem onClick={() => setRename(name)}>
              <RiPencilLine />
              {t('console.agent_files.rename')}
            </DropdownMenuItem>
            <DropdownMenuItem onClick={() => setMoveOpen(true)}>
              <RiFolder3Line />
              {t('console.agent_files.move')}
            </DropdownMenuItem>
            <DropdownMenuItem variant="destructive" onClick={() => setDeleteOpen(true)}>
              <RiDeleteBin6Line />
              {t('common.delete')}
            </DropdownMenuItem>
          </DropdownMenuContent>
        </DropdownMenu>
        <MoveDialog
          open={moveOpen}
          onOpenChange={setMoveOpen}
          path={path}
          disabled={pending}
          onConfirm={onMove}
          t={t}
        />
        <Dialog open={deleteOpen} onOpenChange={setDeleteOpen}>
          <DialogContent closeLabel={t('common.close')}>
            <DialogHeader>
              <DialogTitle>
                {isFolder ? t('console.agent_files.delete_folder_title') : t('console.agent_files.delete_title')}
              </DialogTitle>
              <DialogDescription>
                {isFolder
                  ? t('console.agent_files.delete_folder_description', { path })
                  : t('console.agent_files.delete_description', { path })}
              </DialogDescription>
            </DialogHeader>
            <DialogFooter>
              <DialogClose render={<Button size="sm" variant="ghost" />}>{t('common.cancel')}</DialogClose>
              <Button
                disabled={pending}
                size="sm"
                type="button"
                variant="destructive"
                onClick={() => onDelete(() => setDeleteOpen(false))}>
                {t('common.delete')}
              </Button>
            </DialogFooter>
          </DialogContent>
        </Dialog>
      </TableCell>
    </TableRow>
  )
}

/** Console route of one folder in an Agent's drive; an empty path is the drive root. */
export function agentFilesPath(agentUID: string, path = ''): string {
  const base = `/agents/${encodeURIComponent(agentUID)}/files`
  return path ? `${base}?${new URLSearchParams({ path })}` : base
}

/** Link from the Agent editor to this page. */
export function AgentFilesLink({ agentUID }: { agentUID: string }) {
  const { t } = useTranslation()
  return (
    <section className="grid gap-4">
      <div className="grid gap-1">
        <h3 className="title-section">{t('console.agent_files.section_title')}</h3>
        <p className="text-sm leading-6 text-muted-foreground">{t('console.agent_files.section_description')}</p>
      </div>
      <div>
        <Link {...linkTarget(agentFilesPath(agentUID))} className="link text-sm">
          {t('console.agent_files.browse')}
        </Link>
      </div>
    </section>
  )
}

// A folder picker sets each file's `webkitRelativePath`, which starts with the
// chosen folder's name, so the upload keeps the folder's inner structure.
const folderPicker = { webkitdirectory: '' } as InputHTMLAttributes<HTMLInputElement>

function uploadName(file: File): string {
  return file.webkitRelativePath || file.name
}

type UploadItem = { file: File; drivePath: string }

function UploadMenu({
  currentPath,
  disabled,
  onUpload
}: {
  currentPath: string
  disabled: boolean
  onUpload: (items: UploadItem[]) => void
}) {
  const { t } = useTranslation()
  const filesInput = useRef<HTMLInputElement>(null)
  const folderInput = useRef<HTMLInputElement>(null)

  const choose = (input: HTMLInputElement) => {
    const files = Array.from(input.files ?? [])
    input.value = ''
    if (files.length > 0) onUpload(files.map(file => ({ file, drivePath: joinPath(currentPath, uploadName(file)) })))
  }

  return (
    <>
      <input ref={filesInput} type="file" hidden multiple onChange={event => choose(event.currentTarget)} />
      <input
        ref={folderInput}
        type="file"
        hidden
        multiple
        {...folderPicker}
        onChange={event => choose(event.currentTarget)}
      />
      <DropdownMenu>
        <DropdownMenuTrigger
          render={<Button disabled={disabled} size="sm" type="button" variant="outline" aria-busy={disabled} />}>
          <RiUploadCloud2Line className="size-4" data-icon="inline-start" />
          {t(disabled ? 'console.agent_files.uploading' : 'console.agent_files.upload')}
        </DropdownMenuTrigger>
        <DropdownMenuContent align="end">
          <DropdownMenuItem onClick={() => filesInput.current?.click()}>
            <RiFileLine />
            {t('console.agent_files.upload_title')}
          </DropdownMenuItem>
          <DropdownMenuItem onClick={() => folderInput.current?.click()}>
            <RiFolder3Line />
            {t('console.agent_files.upload_folder')}
          </DropdownMenuItem>
        </DropdownMenuContent>
      </DropdownMenu>
    </>
  )
}

function MoveDialog({
  open,
  onOpenChange,
  path,
  disabled,
  onConfirm,
  t
}: {
  open: boolean
  onOpenChange: (open: boolean) => void
  path: string
  disabled: boolean
  onConfirm: (toPath: string, onSuccess: () => void) => void
  t: (key: string) => string
}) {
  const [value, setValue] = useState(parentPath(path))
  const normalizedValue = joinPath(value, basename(path))
  const unchanged = normalizedValue === path

  useEffect(() => {
    if (open) setValue(parentPath(path))
  }, [open, path])

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent closeLabel={t('common.close')}>
        <DialogHeader>
          <DialogTitle>{t('console.agent_files.move_title')}</DialogTitle>
        </DialogHeader>
        <form
          className="contents"
          onSubmit={event => {
            event.preventDefault()
            if (disabled || unchanged) return
            onConfirm(normalizedValue, () => onOpenChange(false))
          }}>
          <label className="grid gap-1 text-sm">
            <span className="text-muted-foreground">{t('console.agent_files.destination_folder')}</span>
            <Input placeholder="/" value={value} disabled={disabled} onChange={event => setValue(event.target.value)} />
          </label>
          <DialogFooter>
            <DialogClose render={<Button size="sm" type="button" variant="ghost" />}>{t('common.cancel')}</DialogClose>
            <Button aria-busy={disabled} disabled={disabled || unchanged} size="sm" type="submit">
              {t('console.agent_files.move')}
            </Button>
          </DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  )
}

function parentPath(path: string): string {
  return path.includes('/') ? path.slice(0, path.lastIndexOf('/')) : ''
}

function basename(path: string): string {
  const segments = path.split('/').filter(Boolean)
  return segments[segments.length - 1] ?? path
}

function joinPath(...segments: string[]): string {
  return segments
    .flatMap(segment => segment.split('/'))
    .map(segment => segment.trim())
    .filter(segment => segment.length > 0)
    .join('/')
}
