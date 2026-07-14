import {
  Button,
  buttonVariants,
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
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
  TableCell,
  TableRow,
  cn,
  toast
} from '@ankole/uikit'
import {
  RiUploadCloud2Line,
  RiDeleteBin6Line,
  RiFolder3Line,
  RiFileLine,
  RiLinksLine,
  RiDownloadLine,
  RiMore2Fill,
  RiPencilLine
} from '@remixicon/react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useDeferredValue, useEffect, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { Link, useParams, useSearchParams } from 'react-router'
import {
  ankoleWebAgentComputerWorkerControllerIndexOptions,
  ankoleWebWorkerFileControllerDeleteMutation,
  ankoleWebWorkerFileControllerIndexOptions,
  ankoleWebWorkerFileControllerMoveMutation,
  ankoleWebWorkerFileControllerUploadMutation
} from '../api/generated/@tanstack/react-query.gen'
import { ankoleWebWorkerFileControllerDownload } from '../api/generated/sdk.gen'
import type { AgentComputerWorkerItem, WorkerFileEntry } from '../api/generated/types.gen'
import { requestErrorMessage } from '../../common/request-errors'
import { ResourceListPage, ResourceSearch, StatusIndicator } from '../console-shell'
import { matchesResourceSearch } from '../state/resource-search'

const ROOTS = ['workspace_sessions', 'user_files', 'agent_installed_skills'] as const
type FileRoot = (typeof ROOTS)[number]

export function WorkersListPage() {
  const { t } = useTranslation()
  const workers = useQuery(ankoleWebAgentComputerWorkerControllerIndexOptions())
  const [query, setQuery] = useState('')
  const deferredQuery = useDeferredValue(query)
  const rows = (workers.data?.workers ?? []).filter(worker =>
    matchesResourceSearch(deferredQuery, worker.worker_id, worker.status, worker.version)
  )

  return (
    <ResourceListPage
      title={t('console.workers.title')}
      description={t('console.workers.description')}
      columns={[
        t('console.workers.worker_id'),
        t('console.workers.status'),
        t('console.workers.version'),
        t('console.workers.slots'),
        t('console.workers.active_turns'),
        t('console.workers.last_heartbeat')
      ]}
      isLoading={workers.isLoading}
      isEmpty={rows.length === 0}
      emptyTitle={t('console.workers.empty_title')}
      emptyDescription={t('console.workers.empty_description')}
      error={workers.error}
      isFiltered={Boolean(query.trim())}
      toolbar={
        <ResourceSearch
          label={t('console.workers.search')}
          placeholder={t('console.workers.search_placeholder')}
          value={query}
          onChange={setQuery}
        />
      }>
      {rows.map(worker => (
        <TableRow key={worker.worker_id}>
          <TableCell className="font-mono text-xs">
            <Link
              to={`${encodeURIComponent(worker.worker_id)}/files`}
              className="text-primary hover:underline focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring/40">
              {worker.worker_id}
            </Link>
          </TableCell>
          <TableCell>
            <StatusIndicator tone={statusTone(worker.status)}>{t(`console.status.${worker.status}`)}</StatusIndicator>
          </TableCell>
          <TableCell className="text-xs text-muted-foreground">{worker.version}</TableCell>
          <TableCell>{formatSlots(worker)}</TableCell>
          <TableCell>{formatActiveTurns(worker)}</TableCell>
          <TableCell className="text-xs text-muted-foreground">{formatHeartbeat(worker)}</TableCell>
          <TableCell className="text-right">
            <Link
              to={`${encodeURIComponent(worker.worker_id)}/files`}
              className={cn(buttonVariants({ size: 'xs', variant: 'ghost' }))}>
              {t('console.workers.browse_files')}
            </Link>
          </TableCell>
        </TableRow>
      ))}
    </ResourceListPage>
  )
}

function statusTone(status: AgentComputerWorkerItem['status']): 'danger' | 'info' | 'positive' | 'warning' {
  if (status === 'ready') return 'positive'
  if (status === 'draining') return 'info'
  if (status === 'stale') return 'warning'
  return 'danger'
}

function formatSlots(worker: AgentComputerWorkerItem): string {
  const available = integerField(worker.capacity, 'available_turn_slots')
  const max = integerField(worker.capacity, 'max_turns')
  if (available === undefined && max === undefined) return '–'
  if (max !== undefined) return `${available ?? 0} / ${max}`
  return String(available ?? 0)
}

function formatActiveTurns(worker: AgentComputerWorkerItem): string {
  const value = integerField(worker.load, 'active_turns')
  return value === undefined ? '–' : String(value)
}

function formatHeartbeat(worker: AgentComputerWorkerItem): string {
  if (!worker.last_worker_heartbeat_at) return '–'
  try {
    return new Date(worker.last_worker_heartbeat_at).toLocaleString()
  } catch {
    return '–'
  }
}

function integerField(map: { [key: string]: unknown } | undefined, key: string): number | undefined {
  if (!map) return undefined
  const value = map[key]
  return typeof value === 'number' ? value : undefined
}

// --- Worker files page ---

export function WorkerFilesPage() {
  const { t } = useTranslation()
  const params = useParams()
  const workerID = params.workerID ?? ''
  const queryClient = useQueryClient()
  const [searchParams, setSearchParams] = useSearchParams()

  const root = rootOrDefault(searchParams.get('root'))
  const path = searchParams.get('path') ?? ''
  const [query, setQuery] = useState('')
  const deferredQuery = useDeferredValue(query)

  const files = useQuery(
    ankoleWebWorkerFileControllerIndexOptions({
      path: { worker_id: workerID },
      query: { root, path }
    })
  )

  const allEntries = files.data?.file_listing.entries ?? []
  const entries = allEntries.filter(entry =>
    matchesResourceSearch(deferredQuery, entry.relative_path, entry.kind, basename(entry.relative_path))
  )
  const truncated = files.data?.file_listing.truncated === true

  const refresh = () => void queryClient.invalidateQueries()

  const upload = useMutation({
    ...ankoleWebWorkerFileControllerUploadMutation(),
    onSuccess: () => {
      toast.success(t('console.worker_files.uploaded'))
      refresh()
    },
    onError: error => toast.error(requestErrorMessage(error))
  })

  const move = useMutation({
    ...ankoleWebWorkerFileControllerMoveMutation(),
    onSuccess: () => {
      toast.success(t('console.worker_files.renamed'))
      refresh()
    },
    onError: error => toast.error(requestErrorMessage(error))
  })

  const remove = useMutation({
    ...ankoleWebWorkerFileControllerDeleteMutation(),
    onSuccess: () => {
      toast.success(t('console.worker_files.deleted'))
      refresh()
    },
    onError: error => toast.error(requestErrorMessage(error))
  })

  const setRoot = (next: FileRoot) => {
    setQuery('')
    setSearchParams({ root: next, path: '' })
  }
  const enterPath = (next: string) => {
    setQuery('')
    setSearchParams({ root, path: next })
  }

  const toolbar = (
    <div className="grid gap-3">
      <div className="flex flex-wrap items-center gap-2">
        <Link to="/workers" className="text-sm text-muted-foreground hover:text-foreground">
          {t('common.back')}
        </Link>
        <div className="ml-auto flex items-center gap-2">
          <UploadDialog
            root={root}
            currentPath={path}
            disabled={upload.isPending}
            onUpload={(body, workerPath) =>
              upload.mutate({
                path: { worker_id: workerID },
                body: { root: body.root, path: workerPath, file: body.file }
              })
            }
          />
        </div>
      </div>
      <Breadcrumbs root={root} path={path} onNavigate={enterPath} onRootChange={setRoot} t={t} />
      <ResourceSearch
        label={t('console.worker_files.search')}
        placeholder={t('console.worker_files.search_placeholder')}
        value={query}
        onChange={setQuery}
      />
      {truncated ? <p className="text-xs text-muted-foreground">{t('console.worker_files.truncated')}</p> : null}
    </div>
  )

  return (
    <ResourceListPage
      title={workerID}
      description={t('console.worker_files.description')}
      toolbar={toolbar}
      columns={[
        t('console.worker_files.name'),
        t('console.worker_files.kind'),
        t('console.worker_files.size'),
        t('console.worker_files.modified')
      ]}
      isLoading={files.isLoading}
      isEmpty={entries.length === 0}
      emptyTitle={t('console.worker_files.empty_title')}
      emptyDescription={t('console.worker_files.empty_description')}
      emptyAction={
        query ? (
          <Button type="button" size="sm" variant="outline" onClick={() => setQuery('')}>
            {t('console.empty.clear_search')}
          </Button>
        ) : undefined
      }
      isFiltered={Boolean(query.trim())}
      error={files.error}>
      {entries.map(entry => (
        <FileRow
          key={entry.relative_path}
          workerID={workerID}
          root={root}
          entry={entry}
          pending={move.isPending || remove.isPending}
          onNavigate={enterPath}
          onRename={(from, to) =>
            move.mutate({
              path: { worker_id: workerID },
              body: { root, from_path: from, to_path: to, overwrite: false }
            })
          }
          onDelete={() =>
            remove.mutate({
              path: { worker_id: workerID },
              query: { root, path: entry.relative_path, recursive: entry.kind !== 'file' }
            })
          }
        />
      ))}
    </ResourceListPage>
  )
}

function rootOrDefault(value: string | null): FileRoot {
  return ROOTS.includes(value as FileRoot) ? (value as FileRoot) : 'workspace_sessions'
}

function Breadcrumbs({
  root,
  path,
  onNavigate,
  onRootChange,
  t
}: {
  root: FileRoot
  path: string
  onNavigate: (path: string) => void
  onRootChange: (root: FileRoot) => void
  t: (key: string) => string
}) {
  const segments = path ? path.split('/').filter(Boolean) : []

  return (
    <nav aria-label={t('console.worker_files.breadcrumbs')} className="flex flex-wrap items-center gap-1 text-sm">
      <RootSelect root={root} onRootChange={onRootChange} t={t} />
      {segments.length === 0 ? null : (
        <>
          <span className="text-muted-foreground">/</span>
          {segments.map((segment, index) => {
            const prefix = segments.slice(0, index + 1).join('/')
            const isLast = index === segments.length - 1
            return (
              <span key={prefix} className="flex items-center gap-1">
                {isLast ? (
                  <span className="text-foreground">{segment}</span>
                ) : (
                  <button
                    type="button"
                    className="text-muted-foreground outline-none hover:text-foreground focus-visible:ring-2 focus-visible:ring-ring/40"
                    onClick={() => onNavigate(prefix)}>
                    {segment}
                  </button>
                )}
                {!isLast ? <span className="text-muted-foreground">/</span> : null}
              </span>
            )
          })}
        </>
      )}
    </nav>
  )
}

function RootSelect({
  root,
  onRootChange,
  t
}: {
  root: FileRoot
  onRootChange: (root: FileRoot) => void
  t: (key: string) => string
}) {
  return (
    <div className="flex items-center gap-2">
      <Select value={root} onValueChange={value => onRootChange(value as FileRoot)}>
        <SelectTrigger className="h-8 w-52 text-xs" aria-label={t('console.worker_files.root')}>
          <RiFolder3Line className="size-4" aria-hidden />
          <SelectValue />
        </SelectTrigger>
        <SelectContent>
          {ROOTS.map(value => (
            <SelectItem key={value} value={value}>
              {rootLabel(value, t)}
            </SelectItem>
          ))}
        </SelectContent>
      </Select>
    </div>
  )
}

function rootLabel(root: FileRoot, t: (key: string) => string): string {
  switch (root) {
    case 'workspace_sessions':
      return t('console.worker_files.root_workspace_sessions')
    case 'user_files':
      return t('console.worker_files.root_user_files')
    case 'agent_installed_skills':
      return t('console.worker_files.root_agent_installed_skills')
  }
}

function FileRow({
  workerID,
  root,
  entry,
  pending,
  onNavigate,
  onRename,
  onDelete
}: {
  workerID: string
  root: FileRoot
  entry: WorkerFileEntry
  pending: boolean
  onNavigate: (path: string) => void
  onRename: (from: string, to: string) => void
  onDelete: () => void
}) {
  const { t } = useTranslation()
  const name = basename(entry.relative_path)
  const isDir = entry.kind === 'directory'
  const [renameOpen, setRenameOpen] = useState(false)
  const [deleteOpen, setDeleteOpen] = useState(false)

  const handleDownload = async () => {
    const result = await ankoleWebWorkerFileControllerDownload({
      path: { worker_id: workerID },
      query: { root, path: entry.relative_path }
    })
    if (result.error !== undefined || !(result.data instanceof Blob)) {
      toast.error(requestErrorMessage(result.error ?? new Error('download failed')))
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
          {entry.kind === 'file' ? (
            <RiFileLine className="size-4 text-muted-foreground" aria-hidden />
          ) : entry.kind === 'directory' ? (
            <RiFolder3Line className="size-4 text-muted-foreground" aria-hidden />
          ) : (
            <RiLinksLine className="size-4 text-muted-foreground" aria-hidden />
          )}
          {isDir ? (
            <button
              type="button"
              className="text-left outline-none hover:text-primary focus-visible:ring-2 focus-visible:ring-ring/40"
              aria-label={t('console.worker_files.open_directory', { name })}
              onClick={() => onNavigate(entry.relative_path)}>
              {name}
            </button>
          ) : (
            <span>{name}</span>
          )}
        </div>
      </TableCell>
      <TableCell className="text-xs text-muted-foreground">{entry.kind}</TableCell>
      <TableCell className="text-xs text-muted-foreground">
        {entry.kind === 'file' ? formatBytes(entry.size) : '–'}
      </TableCell>
      <TableCell className="text-xs text-muted-foreground">{formatModified(entry.modified_unix_ms)}</TableCell>
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
            {entry.kind === 'file' ? (
              <DropdownMenuItem onClick={() => void handleDownload()}>
                <RiDownloadLine />
                {t('console.worker_files.download')}
              </DropdownMenuItem>
            ) : null}
            <DropdownMenuItem onClick={() => setRenameOpen(true)}>
              <RiPencilLine />
              {t('console.worker_files.rename')}
            </DropdownMenuItem>
            <DropdownMenuItem variant="destructive" onClick={() => setDeleteOpen(true)}>
              <RiDeleteBin6Line />
              {t('common.delete')}
            </DropdownMenuItem>
          </DropdownMenuContent>
        </DropdownMenu>
        <RenameDialog
          open={renameOpen}
          onOpenChange={setRenameOpen}
          entry={entry}
          disabled={pending}
          onConfirm={newName => onRename(entry.relative_path, joinPath(dirname(entry.relative_path), newName))}
          t={t}
        />
        <Dialog open={deleteOpen} onOpenChange={setDeleteOpen}>
          <DialogContent>
            <DialogHeader>
              <DialogTitle>{t('console.worker_files.delete_title')}</DialogTitle>
              <DialogDescription>
                {isDir
                  ? t('console.worker_files.delete_directory_description')
                  : t('console.worker_files.delete_description', { path: entry.relative_path })}
              </DialogDescription>
            </DialogHeader>
            <DialogFooter>
              <DialogClose render={<Button size="sm" variant="ghost" />}>{t('common.cancel')}</DialogClose>
              <Button
                disabled={pending}
                size="sm"
                type="button"
                variant="destructive"
                onClick={() => {
                  setDeleteOpen(false)
                  onDelete()
                }}>
                {t('common.delete')}
              </Button>
            </DialogFooter>
          </DialogContent>
        </Dialog>
      </TableCell>
    </TableRow>
  )
}

function UploadDialog({
  root,
  currentPath,
  disabled,
  onUpload
}: {
  root: FileRoot
  currentPath: string
  disabled: boolean
  onUpload: (body: { root: FileRoot; file: File }, workerPath: string) => void
}) {
  const { t } = useTranslation()
  const [open, setOpen] = useState(false)
  const [files, setFiles] = useState<File[]>([])
  const [subdir, setSubdir] = useState('')

  const reset = () => {
    setFiles([])
    setSubdir('')
  }

  const submit = () => {
    for (const file of files) {
      onUpload({ root, file }, joinPath(currentPath, subdir.trim(), file.name))
    }
    reset()
    setOpen(false)
  }

  return (
    <Dialog open={open} onOpenChange={setOpen}>
      <Button disabled={disabled} size="sm" type="button" variant="outline" onClick={() => setOpen(true)}>
        <RiUploadCloud2Line className="size-4" data-icon="inline-start" />
        {t('console.worker_files.upload')}
      </Button>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>{t('console.worker_files.upload_title')}</DialogTitle>
          <DialogDescription>{t('console.worker_files.upload_hint')}</DialogDescription>
        </DialogHeader>
        <div className="grid gap-4">
          <input
            type="file"
            multiple
            onChange={event => setFiles(event.target.files ? Array.from(event.target.files) : [])}
          />
          <label className="grid gap-1 text-sm">
            <span className="text-muted-foreground">{t('console.worker_files.upload_subdirectory')}</span>
            <Input placeholder="docs/" value={subdir} onChange={event => setSubdir(event.target.value)} />
          </label>
          {files.length > 0 ? (
            <ul className="grid gap-1 text-xs text-muted-foreground">
              {files.map(file => (
                <li key={file.name}>{joinPath(currentPath, subdir.trim(), file.name)}</li>
              ))}
            </ul>
          ) : null}
        </div>
        <DialogFooter>
          <DialogClose render={<Button size="sm" variant="ghost" />}>{t('common.cancel')}</DialogClose>
          <Button disabled={disabled || files.length === 0} size="sm" type="button" onClick={submit}>
            {t('console.worker_files.upload')}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}

function RenameDialog({
  open,
  onOpenChange,
  entry,
  disabled,
  onConfirm,
  t
}: {
  open: boolean
  onOpenChange: (open: boolean) => void
  entry: WorkerFileEntry
  disabled: boolean
  onConfirm: (newName: string) => void
  t: (key: string) => string
}) {
  const [value, setValue] = useState('')

  useEffect(() => {
    if (open) setValue(basename(entry.relative_path))
  }, [entry.relative_path, open])

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>{t('console.worker_files.rename_title')}</DialogTitle>
        </DialogHeader>
        <label className="grid gap-1 text-sm">
          <span className="text-muted-foreground">{t('console.worker_files.new_name')}</span>
          <Input value={value} onChange={event => setValue(event.target.value)} />
        </label>
        <DialogFooter>
          <DialogClose render={<Button size="sm" variant="ghost" />}>{t('common.cancel')}</DialogClose>
          <Button
            disabled={disabled || value.trim() === ''}
            size="sm"
            type="button"
            onClick={() => {
              onConfirm(value.trim())
              onOpenChange(false)
            }}>
            {t('console.worker_files.rename')}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}

function basename(path: string): string {
  const segments = path.split('/').filter(Boolean)
  return segments[segments.length - 1] ?? path
}

function dirname(path: string): string {
  const segments = path.split('/').filter(Boolean)
  segments.pop()
  return segments.join('/')
}

function joinPath(...segments: string[]): string {
  return segments
    .flatMap(segment => segment.split('/'))
    .map(segment => segment.trim())
    .filter(segment => segment.length > 0)
    .join('/')
}

function formatBytes(bytes: number): string {
  if (!Number.isFinite(bytes) || bytes < 0) return '–'
  if (bytes < 1024) return `${bytes} B`
  const units = ['KB', 'MB', 'GB', 'TB']
  let value = bytes / 1024
  let unit = 0
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024
    unit += 1
  }
  return `${value.toFixed(value < 10 ? 1 : 0)} ${units[unit]}`
}

function formatModified(unixMs: number): string {
  if (!Number.isFinite(unixMs)) return '–'
  try {
    return new Date(unixMs).toLocaleString()
  } catch {
    return '–'
  }
}
