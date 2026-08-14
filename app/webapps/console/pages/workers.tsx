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
  RiPencilLine,
  RiServerLine
} from '@remixicon/react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useDeferredValue, useEffect, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { Link, useParams, useSearchParams } from 'react-router'
import {
  ankoleWebAgentControllerIndexOptions,
  ankoleWebAgentComputerWorkerControllerIndexOptions,
  ankoleWebWorkerFileControllerDeleteMutation,
  ankoleWebWorkerFileControllerIndexOptions,
  ankoleWebWorkerFileControllerMoveMutation,
  ankoleWebWorkerFileControllerUploadMutation
} from '../api/generated/@tanstack/react-query.gen'
import { ankoleWebWorkerFileControllerDownload } from '../api/generated/sdk.gen'
import type { AgentComputerWorkerItem, WorkerFileEntry } from '../api/generated/types.gen'
import { requestErrorMessage } from '../../common/request-errors'
import { StatusIndicator } from '../console-form'
import { ResourceListPage, ResourceSearch, RowViewAction, ScopeBar } from '../console-list-page'
import { BackLink } from '../console-page'
import { formatConsoleDate } from '../console-primitives'
import { effectiveResourceSearchQuery, matchesResourceSearch } from '../state/resource-search'
import {
  agentUIDFromWorkerFilePath,
  workerFileRootPath,
  WORKER_FILE_ROOTS,
  type WorkerFileRoot
} from '../state/worker-file-path'

export function WorkersListPage() {
  const { t, i18n } = useTranslation()
  const workers = useQuery({
    ...ankoleWebAgentComputerWorkerControllerIndexOptions(),
    refetchInterval: query => ((query.state.data?.workers.length ?? 0) === 0 ? 2_000 : 10_000)
  })
  const [query, setQuery] = useState('')
  const deferredQuery = useDeferredValue(query)
  const searchQuery = effectiveResourceSearchQuery(query, deferredQuery)
  const rows = (workers.data?.workers ?? []).filter(worker =>
    matchesResourceSearch(searchQuery, worker.worker_id, worker.status, worker.version)
  )

  return (
    <ResourceListPage
      title={t('console.workers.title')}
      description={t('console.workers.description')}
      columns={[
        t('console.workers.worker_id'),
        t('console.workers.status'),
        t('console.workers.version'),
        t('console.workers.load'),
        t('console.workers.last_heartbeat')
      ]}
      isLoading={workers.isLoading}
      isEmpty={rows.length === 0}
      count={rows.length}
      emptyTitle={t('console.workers.empty_title')}
      emptyIcon={<RiServerLine aria-hidden />}
      emptyDescription={t('console.workers.empty_description')}
      emptyAction={<WorkerStartGuide documentationLocale={i18n.resolvedLanguage} />}
      error={workers.error}
      isFiltered={Boolean(query.trim())}
      onClearFilters={() => setQuery('')}
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
              className="text-foreground hover:text-link hover:underline">
              {worker.worker_id}
            </Link>
          </TableCell>
          <TableCell>
            <StatusIndicator tone={statusTone(worker.status)}>{t(`console.status.${worker.status}`)}</StatusIndicator>
          </TableCell>
          <TableCell className="text-xs text-muted-foreground">{worker.version}</TableCell>
          <TableCell>{formatLoad(worker)}</TableCell>
          <TableCell className="text-xs text-muted-foreground">
            {formatConsoleDate(worker.last_worker_heartbeat_at)}
          </TableCell>
          <RowViewAction
            label={t('console.workers.browse_files_for', { name: worker.worker_id })}
            to={`${encodeURIComponent(worker.worker_id)}/files`}
          />
        </TableRow>
      ))}
    </ResourceListPage>
  )
}

function WorkerStartGuide({ documentationLocale }: { documentationLocale?: string }) {
  const { t } = useTranslation()
  const locale =
    documentationLocale === 'zh-Hans-CN' || documentationLocale === 'ja-JP' || documentationLocale === 'ko-KR'
      ? documentationLocale
      : 'en-US'

  return (
    <div className="grid w-full max-w-xl gap-3">
      <a
        className={cn(buttonVariants({ size: 'sm' }), 'w-fit')}
        href={`https://ankole.agentbull.com/${locale}/docs/quickstart/#deployment`}
        rel="noreferrer"
        target="_blank">
        {t('console.workers.deployment_guide')}
      </a>
      <p className="text-pretty text-xs text-muted-foreground">{t('console.workers.deployment_options')}</p>
      <p className="text-pretty text-xs text-muted-foreground">{t('console.workers.ready_hint')}</p>
    </div>
  )
}

function statusTone(status: AgentComputerWorkerItem['status']): 'danger' | 'info' | 'positive' | 'warning' {
  if (status === 'ready') return 'positive'
  if (status === 'draining') return 'info'
  if (status === 'stale') return 'warning'
  return 'danger'
}

/**
 * Active turns over total turn slots, in the used-over-total order capacity
 * columns are read in. A worker that reports only capacity derives its active
 * count from the free slots.
 */
function formatLoad(worker: AgentComputerWorkerItem): string {
  const max = integerField(worker.capacity, 'max_turns')
  const available = integerField(worker.capacity, 'available_turn_slots')
  const active =
    integerField(worker.load, 'active_turns') ??
    (max !== undefined && available !== undefined ? Math.max(max - available, 0) : undefined)
  if (active === undefined) return '–'
  return max === undefined ? String(active) : `${active} / ${max}`
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
  const requestedPath = searchParams.get('path') ?? ''
  const agents = useQuery(ankoleWebAgentControllerIndexOptions())
  const pathAgentUID = agentUIDFromWorkerFilePath(root, requestedPath)
  const agentUID = pathAgentUID ?? agents.data?.agents[0]?.uid ?? ''
  const path = pathAgentUID ? requestedPath : agentUID ? workerFileRootPath(root, agentUID) : ''
  const [query, setQuery] = useState('')
  const deferredQuery = useDeferredValue(query)
  const searchQuery = effectiveResourceSearchQuery(query, deferredQuery)

  const files = useQuery({
    ...ankoleWebWorkerFileControllerIndexOptions({
      path: { worker_id: workerID },
      query: { root, path }
    }),
    enabled: Boolean(path)
  })

  useEffect(() => {
    if (!path || path === requestedPath) return
    setSearchParams({ root, path }, { replace: true })
  }, [path, requestedPath, root, setSearchParams])

  const allEntries = files.data?.file_listing.entries ?? []
  const entries = allEntries.filter(entry =>
    matchesResourceSearch(searchQuery, entry.relative_path, entry.kind, basename(entry.relative_path))
  )
  const truncated = files.data?.file_listing.truncated === true
  // Without an Agent no per-agent directory exists, so "this directory is
  // empty" would misreport the missing prerequisite. A path that names its own
  // Agent is a real directory and keeps the plain empty state even when the
  // Agent list is empty.
  const agentsEmpty = agents.isSuccess && agents.data.agents.length === 0 && !pathAgentUID

  const refresh = () => void queryClient.invalidateQueries()

  // One toast per file, each naming the file it belongs to: a rejected upload
  // has to say which file the Worker refused and why, and a per-file handler
  // says it without a batching layer that has to track outcomes of its own.
  const upload = useMutation({
    ...ankoleWebWorkerFileControllerUploadMutation(),
    onSuccess: (_data, variables) => {
      toast.success(t('console.worker_files.uploaded', { name: basename(variables.body.path) }))
      refresh()
    },
    onError: (error, variables) =>
      toast.error(
        t('console.worker_files.upload_failed', {
          name: basename(variables.body.path),
          reason: requestErrorMessage(error)
        })
      )
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

  const setRoot = (next: WorkerFileRoot) => {
    setQuery('')
    setSearchParams({ root: next, path: agentUID ? workerFileRootPath(next, agentUID) : '' })
  }
  const setAgent = (next: string) => {
    setQuery('')
    setSearchParams({ root, path: workerFileRootPath(root, next) })
  }
  const enterPath = (next: string) => {
    setQuery('')
    setSearchParams({ root, path: next })
  }

  // Navigation lives in `subNav` so it stays visible over an empty directory:
  // the breadcrumbs and the upload action are how the operator leaves it.
  const subNav = (
    <ScopeBar>
      <BackLink to="/workers" />
      <Breadcrumbs
        root={root}
        path={path}
        agents={agents.data?.agents ?? []}
        agentUID={agentUID}
        onNavigate={enterPath}
        onAgentChange={setAgent}
        onRootChange={setRoot}
        t={t}
      />
      <div className="ml-auto">
        <UploadDialog
          currentPath={path}
          disabled={!path || upload.isPending}
          onUpload={body =>
            upload.mutate({ path: { worker_id: workerID }, body: { root, path: body.workerPath, file: body.file } })
          }
        />
      </div>
    </ScopeBar>
  )

  const toolbar = (
    <div className="grid gap-3">
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
      subNav={subNav}
      toolbar={toolbar}
      columns={[
        t('console.worker_files.name'),
        t('console.worker_files.kind'),
        t('console.worker_files.size'),
        t('console.worker_files.modified')
      ]}
      isLoading={agents.isLoading || files.isLoading}
      isEmpty={entries.length === 0}
      count={entries.length}
      emptyTitle={agentsEmpty ? t('console.agents.empty_title') : t('console.worker_files.empty_title')}
      emptyIcon={<RiFolder3Line aria-hidden />}
      emptyDescription={
        agentsEmpty ? t('console.agents.empty_description') : t('console.worker_files.empty_description')
      }
      emptyAction={
        agentsEmpty ? (
          <Link to="/agents/new" className={cn(buttonVariants({ size: 'sm' }))}>
            {t('console.agents.new')}
          </Link>
        ) : undefined
      }
      isFiltered={Boolean(query.trim())}
      onClearFilters={() => setQuery('')}
      error={agents.error ?? files.error}>
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

function rootOrDefault(value: string | null): WorkerFileRoot {
  return WORKER_FILE_ROOTS.includes(value as WorkerFileRoot) ? (value as WorkerFileRoot) : 'agent_sessions'
}

function Breadcrumbs({
  root,
  path,
  agents,
  agentUID,
  onNavigate,
  onAgentChange,
  onRootChange,
  t
}: {
  root: WorkerFileRoot
  path: string
  agents: Array<{ uid: string; display_name?: string | null }>
  agentUID: string
  onNavigate: (path: string) => void
  onAgentChange: (agentUID: string) => void
  onRootChange: (root: WorkerFileRoot) => void
  t: (key: string) => string
}) {
  const rootPath = agentUID ? workerFileRootPath(root, agentUID) : ''
  const segments = path.slice(rootPath.length).split('/').filter(Boolean)

  return (
    <nav aria-label={t('console.worker_files.breadcrumbs')} className="flex flex-wrap items-center gap-1 text-sm">
      <AgentSelect agents={agents} value={agentUID} onValueChange={onAgentChange} t={t} />
      <span className="text-muted-foreground">/</span>
      <RootSelect root={root} onRootChange={onRootChange} t={t} />
      {segments.length === 0 ? null : (
        <>
          <span className="text-muted-foreground">/</span>
          {segments.map((segment, index) => {
            const prefix = [rootPath, ...segments.slice(0, index + 1)].join('/')
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

function AgentSelect({
  agents,
  value,
  onValueChange,
  t
}: {
  agents: Array<{ uid: string; display_name?: string | null }>
  value: string
  onValueChange: (agentUID: string) => void
  t: (key: string) => string
}) {
  return (
    <Select
      value={value}
      onValueChange={next => {
        if (next) onValueChange(next)
      }}>
      <SelectTrigger size="sm" className="w-52 text-xs" aria-label={t('console.worker_files.agent')}>
        <SelectValue placeholder={t('console.worker_files.select_agent')} />
      </SelectTrigger>
      <SelectContent emptyLabel={t('common.select_no_agents')}>
        {agents.map(agent => (
          <SelectItem key={agent.uid} value={agent.uid}>
            {agent.display_name || agent.uid}
          </SelectItem>
        ))}
      </SelectContent>
    </Select>
  )
}

function RootSelect({
  root,
  onRootChange,
  t
}: {
  root: WorkerFileRoot
  onRootChange: (root: WorkerFileRoot) => void
  t: (key: string) => string
}) {
  return (
    <div className="flex items-center gap-2">
      <Select value={root} onValueChange={value => onRootChange(value as WorkerFileRoot)}>
        <SelectTrigger size="sm" className="w-52 text-xs" aria-label={t('console.worker_files.root')}>
          <RiFolder3Line className="size-4" aria-hidden />
          <SelectValue />
        </SelectTrigger>
        <SelectContent>
          {WORKER_FILE_ROOTS.map(value => (
            <SelectItem key={value} value={value}>
              {rootLabel(value, t)}
            </SelectItem>
          ))}
        </SelectContent>
      </Select>
    </div>
  )
}

function rootLabel(root: WorkerFileRoot, t: (key: string) => string): string {
  switch (root) {
    case 'agent_sessions':
      return t('console.worker_files.root_agent_sessions')
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
  root: WorkerFileRoot
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
              className="text-left outline-none hover:text-link focus-visible:ring-2 focus-visible:ring-ring/40"
              aria-label={t('console.worker_files.open_directory', { name })}
              onClick={() => onNavigate(entry.relative_path)}>
              {name}
            </button>
          ) : (
            <span>{name}</span>
          )}
        </div>
      </TableCell>
      <TableCell className="text-xs text-muted-foreground">{t(`console.worker_files.kind_${entry.kind}`)}</TableCell>
      <TableCell className="text-xs text-muted-foreground">
        {entry.kind === 'file' ? formatBytes(entry.size) : '–'}
      </TableCell>
      <TableCell className="text-xs text-muted-foreground">
        {formatConsoleDate(isoFromUnixMs(entry.modified_unix_ms))}
      </TableCell>
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
          <DialogContent closeLabel={t('common.close')}>
            <DialogHeader>
              <DialogTitle>
                {isDir ? t('console.worker_files.delete_directory_title') : t('console.worker_files.delete_title')}
              </DialogTitle>
              <DialogDescription>
                {isDir
                  ? t('console.worker_files.delete_directory_description', { path: entry.relative_path })
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
  currentPath,
  disabled,
  onUpload
}: {
  currentPath: string
  disabled: boolean
  onUpload: (body: { file: File; workerPath: string }) => void
}) {
  const { t } = useTranslation()
  const [open, setOpen] = useState(false)
  const [files, setFiles] = useState<File[]>([])
  const [subdir, setSubdir] = useState('')

  const reset = () => {
    setFiles([])
    setSubdir('')
  }

  // Each file reports its own outcome through its own toast, so the dialog
  // hands them over and closes rather than tracking a batch result.
  const submit = () => {
    if (disabled || files.length === 0) return
    for (const file of files) onUpload({ file, workerPath: joinPath(currentPath, subdir.trim(), file.name) })
    reset()
    setOpen(false)
  }

  return (
    <Dialog open={open} onOpenChange={setOpen}>
      <Button disabled={disabled} size="sm" type="button" variant="outline" onClick={() => setOpen(true)}>
        <RiUploadCloud2Line className="size-4" data-icon="inline-start" />
        {t('console.worker_files.upload')}
      </Button>
      <DialogContent closeLabel={t('common.close')}>
        <DialogHeader>
          <DialogTitle>{t('console.worker_files.upload_title')}</DialogTitle>
          <DialogDescription>{t('console.worker_files.upload_hint')}</DialogDescription>
        </DialogHeader>
        <form
          className="contents"
          onSubmit={event => {
            event.preventDefault()
            submit()
          }}>
          <div className="grid gap-4">
            <Input
              aria-label={t('console.worker_files.upload')}
              type="file"
              multiple
              required
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
            <DialogClose render={<Button size="sm" type="button" variant="ghost" />}>{t('common.cancel')}</DialogClose>
            <Button
              aria-busy={disabled}
              disabled={disabled}
              incomplete={files.length === 0 && !disabled}
              size="sm"
              type="submit">
              {t('console.worker_files.upload')}
            </Button>
          </DialogFooter>
        </form>
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
  const originalName = basename(entry.relative_path)
  const [value, setValue] = useState(originalName)
  const normalizedValue = value.trim()
  const incomplete = normalizedValue === ''
  const unchanged = normalizedValue === originalName

  useEffect(() => {
    if (open) setValue(originalName)
  }, [open, originalName])

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent closeLabel={t('common.close')}>
        <DialogHeader>
          <DialogTitle>{t('console.worker_files.rename_title')}</DialogTitle>
        </DialogHeader>
        <form
          className="contents"
          onSubmit={event => {
            event.preventDefault()
            if (disabled || incomplete || unchanged) return
            onConfirm(normalizedValue)
            onOpenChange(false)
          }}>
          <label className="grid gap-1 text-sm">
            <span className="text-muted-foreground">{t('console.worker_files.new_name')}</span>
            <Input required value={value} onChange={event => setValue(event.target.value)} />
          </label>
          <DialogFooter>
            <DialogClose render={<Button size="sm" type="button" variant="ghost" />}>{t('common.cancel')}</DialogClose>
            <Button
              aria-busy={disabled}
              disabled={disabled || (unchanged && !incomplete)}
              incomplete={incomplete && !disabled}
              size="sm"
              type="submit">
              {t('console.worker_files.rename')}
            </Button>
          </DialogFooter>
        </form>
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

/** `toISOString` throws on an invalid epoch; a malformed row must not crash the table. */
function isoFromUnixMs(unixMs: number): string | null {
  const date = new Date(unixMs)
  return Number.isNaN(date.getTime()) ? null : date.toISOString()
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
