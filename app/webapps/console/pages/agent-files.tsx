import { formatFileBytes } from '../../common/file-format'
import { BdiLabel } from '../../common/bidi-file-name'
import { sanitizeFileName, sanitizeRenameValue, stripBidi } from '../../common/bidi'
import { TableRow, useMutation, useQuery, Link, useSearchParams, useConsoleTenant } from '../tenant-context'
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
import { useDeferredValue, useRef, useState, type InputHTMLAttributes } from 'react'
import { useTranslation } from 'react-i18next'
import { linkTarget } from '../../common/router'
import { dataTenantID } from '../../common/browser-session'
import { podID } from '../../common/browser-context'
import { createDriveNode } from '../api/v2/generated/sdk.gen'
import {
  createDriveNodeMutation,
  deleteDriveNodeMutation,
  listDriveNodesOptions,
  moveDriveNodeMutation
} from '../api/v2/generated/@tanstack/react-query.gen'
import type { ListDriveNodesResponse } from '../api/v2/generated/types.gen'
import { downloadDriveFile, uploadDriveFile } from '../api/agent-files'
import { requestErrorMessage } from '../../common/request-errors'
import { ResourceListPage, ResourceSearch, ScopeBar } from '../console-list-page'
import { formatConsoleDate } from '../console-primitives'
import { effectiveResourceSearchQuery, matchesResourceSearch } from '../state/resource-search'

type DriveNode = ListDriveNodesResponse['nodes'][number]
type Ancestor = ListDriveNodesResponse['ancestors'][number]

export function AgentFilesPage() {
  const { t } = useTranslation()
  const tenantID = useConsoleTenant()?.id ?? dataTenantID() ?? podID() ?? ''
  const queryClient = useQueryClient()
  const [params, setParams] = useSearchParams()
  const parentID = params.get('node') ?? undefined
  const after = params.get('after') ?? undefined
  const [query, setQuery] = useState('')
  const deferredQuery = useDeferredValue(query)
  const search = effectiveResourceSearchQuery(query, deferredQuery)
  const [newFolder, setNewFolder] = useState<string>()
  const listing = useQuery(
    listDriveNodesOptions({
      path: { tenant_id: tenantID },
      query: {
        parent_id: parentID,
        owner_uid: params.get('owner') ?? undefined,
        relative_path: params.get('prefix') ?? undefined,
        after
      }
    })
  )
  const currentParentID = parentID ?? listing.data?.ancestors.at(-1)?.id
  const nodes = (listing.data?.nodes ?? []).filter(node =>
    matchesResourceSearch(search, node.name, node.kind, node.private_owner_uid, node.conversation_id)
  )
  const navigate = (id?: string) => {
    setQuery('')
    setParams(id ? { node: id } : {})
  }
  const failure = (error: unknown) => toast.error(requestErrorMessage(error))
  const move = useMutation({ ...moveDriveNodeMutation(), onError: failure })
  const remove = useMutation({ ...deleteDriveNodeMutation(), onError: failure })
  const create = useMutation({
    ...createDriveNodeMutation(),
    onSuccess: () => setNewFolder(undefined),
    onError: failure
  })
  const upload = useMutation({
    mutationFn: async ({ files }: { files: File[] }) => {
      if (!currentParentID) throw new Error(t('console.drive.choose_space'))
      const directories = new Map<string, string>([['', currentParentID]])
      const failures: { name: string; reason: string }[] = []
      for (const file of files) {
        const parts = (file.webkitRelativePath || file.name).split('/').map(segment => sanitizeFileName(segment))
        const name = parts.pop()!
        let directory = currentParentID
        let prefix = ''
        try {
          for (const part of parts) {
            prefix = prefix ? `${prefix}/${part}` : part
            const cached = directories.get(prefix)
            if (cached) {
              directory = cached
              continue
            }
            const created = await createDriveNode({
              path: { tenant_id: tenantID },
              body: { data: { parent_id: directory, name: part, kind: 'folder' } },
              throwOnError: true
            })
            directory = created.data.id
            directories.set(prefix, directory)
          }
          const result = await uploadDriveFile(tenantID, directory, name, file)
          if (result.error !== undefined) throw result.error
        } catch (error) {
          failures.push({ name: sanitizeFileName(file.name), reason: requestErrorMessage(error) })
        }
      }
      return { uploaded: files.length - failures.length, failures }
    },
    onSuccess: ({ uploaded, failures }) => {
      if (uploaded) toast.success(t('console.agent_files.uploaded', { count: uploaded }))
      const [first, ...more] = failures
      if (first) toast.error(t('console.agent_files.upload_failed', first))
      if (more.length) toast.error(t('console.agent_files.upload_failed_more', { count: more.length }))
    },
    onError: error => {
      failure(error)
      void queryClient.invalidateQueries()
    }
  })
  const pending = move.isPending || remove.isPending || create.isPending
  return (
    <ResourceListPage
      title={t('console.drive.title')}
      description={t('console.drive.description')}
      subNav={
        <ScopeBar>
          <Breadcrumbs ancestors={listing.data?.ancestors ?? []} onNavigate={navigate} />
          {currentParentID ? (
            <div className="ml-auto flex gap-2">
              <Button size="sm" variant="ghost" disabled={pending} onClick={() => setNewFolder('')}>
                {t('console.drive.new_folder')}
              </Button>
              <UploadMenu disabled={upload.isPending} onUpload={files => upload.mutate({ files })} />
            </div>
          ) : null}
        </ScopeBar>
      }
      toolbar={
        <ResourceSearch
          label={t('console.agent_files.search')}
          placeholder={t('console.drive.search_placeholder')}
          value={query}
          onChange={setQuery}
        />
      }
      columns={[
        t('console.agent_files.name'),
        t('console.drive.kind'),
        t('console.agent_files.size'),
        t('console.agent_files.modified')
      ]}
      isLoading={listing.isLoading}
      isEmpty={!nodes.length}
      count={nodes.length}
      emptyTitle={t('console.agent_files.empty_title')}
      emptyDescription={t('console.agent_files.empty_description')}
      emptyIcon={<RiFolder3Line aria-hidden />}
      isFiltered={Boolean(query.trim())}
      onClearFilters={() => setQuery('')}
      error={listing.error}
      footer={
        <div className="flex gap-2">
          {after ? (
            <Button variant="ghost" onClick={() => navigate(currentParentID)}>
              {t('console.drive.first_page')}
            </Button>
          ) : null}
          {listing.data?.next_after ? (
            <Button
              variant="ghost"
              onClick={() =>
                setParams({ ...(currentParentID ? { node: currentParentID } : {}), after: listing.data!.next_after! })
              }>
              {t('console.drive.next_page')}
            </Button>
          ) : null}
        </div>
      }>
      {nodes.map(node => (
        <NodeRow
          key={node.id}
          tenantID={tenantID}
          node={node}
          pending={pending}
          onNavigate={navigate}
          onMove={(attrs, done) =>
            move.mutate({ path: { tenant_id: tenantID, id: node.id }, body: { data: attrs } }, { onSuccess: done })
          }
          onDelete={done => remove.mutate({ path: { tenant_id: tenantID, id: node.id } }, { onSuccess: done })}
        />
      ))}
      <Dialog
        open={newFolder !== undefined}
        onOpenChange={open => {
          if (!open) setNewFolder(undefined)
        }}>
        <DialogContent closeLabel={t('common.close')}>
          <DialogHeader>
            <DialogTitle>{t('console.drive.new_folder')}</DialogTitle>
          </DialogHeader>
          <form
            className="grid gap-4"
            onSubmit={event => {
              event.preventDefault()
              if (currentParentID && newFolder?.trim()) {
                create.mutate({
                  path: { tenant_id: tenantID },
                  body: { data: { parent_id: currentParentID, name: newFolder.trim(), kind: 'folder' } }
                })
              }
            }}>
            <label className="grid gap-1">
              {t('console.agent_files.name')}
              <Input
                autoFocus
                required
                pattern="[^/]+"
                value={newFolder ?? ''}
                onChange={event => setNewFolder(event.target.value)}
              />
            </label>
            <DialogFooter>
              <Button type="submit" disabled={pending}>
                {t('common.save')}
              </Button>
            </DialogFooter>
          </form>
        </DialogContent>
      </Dialog>
    </ResourceListPage>
  )
}

function Breadcrumbs({ ancestors, onNavigate }: { ancestors: Ancestor[]; onNavigate: (id?: string) => void }) {
  const { t } = useTranslation()
  return (
    <nav
      aria-label={t('console.agent_files.breadcrumbs')}
      className="flex min-w-0 flex-wrap items-center gap-1 text-sm">
      <button type="button" className="link" onClick={() => onNavigate()}>
        {t('console.drive.all_spaces')}
      </button>
      {ancestors.map((node, index) => (
        <span key={node.id} className="flex min-w-0 items-center gap-1">
          <span aria-hidden>/</span>
          {index === ancestors.length - 1 ? (
            <span aria-current="page" className="min-w-0">
              <BdiLabel value={node.name} />
            </span>
          ) : (
            <button type="button" className="link min-w-0" onClick={() => onNavigate(node.id)}>
              <BdiLabel value={node.name} />
            </button>
          )}
        </span>
      ))}
    </nav>
  )
}

function NodeRow({
  tenantID,
  node,
  pending,
  onNavigate,
  onMove,
  onDelete
}: {
  tenantID: string
  node: DriveNode
  pending: boolean
  onNavigate: (id?: string) => void
  onMove: (attrs: { name?: string; parent_id?: string }, done: () => void) => void
  onDelete: (done: () => void) => void
}) {
  const { t } = useTranslation()
  const [rename, setRename] = useState<string>()
  const [moving, setMoving] = useState(false)
  const [deleting, setDeleting] = useState(false)
  const isFile = node.kind === 'file'
  const rootLabel = node.parent_id
    ? null
    : node.private_owner_uid
      ? t('console.drive.private', { id: node.private_owner_uid })
      : node.conversation_id
        ? t('console.drive.conversation', { id: node.conversation_id })
        : t('console.drive.public')
  const download = async () => {
    const result = await downloadDriveFile(tenantID, node.id)
    if (result.error !== undefined || !(result.data instanceof Blob)) {
      toast.error(requestErrorMessage(result.error ?? new Error(t('console.agent_files.download_failed'))))
      return
    }
    const url = URL.createObjectURL(result.data)
    const anchor = document.createElement('a')
    anchor.href = url
    anchor.download = sanitizeFileName(node.name)
    document.body.appendChild(anchor)
    anchor.click()
    anchor.remove()
    URL.revokeObjectURL(url)
  }
  return (
    <TableRow>
      <TableCell>
        <div className="flex min-w-0 items-center gap-2">
          {isFile ? (
            <RiFileLine className="size-4 shrink-0 text-muted-foreground" aria-hidden />
          ) : (
            <RiFolder3Line className="size-4 shrink-0 text-muted-foreground" aria-hidden />
          )}
          {rename !== undefined ? (
            <form
              className="flex gap-1"
              onSubmit={event => {
                event.preventDefault()
                if (rename.trim() && !pending) onMove({ name: rename.trim() }, () => setRename(undefined))
              }}>
              <Input
                variant="inline"
                autoFocus
                required
                pattern="[^/]+"
                aria-label={t('console.agent_files.name')}
                value={rename}
                disabled={pending}
                onChange={event => setRename(event.target.value)}
                onKeyDown={event => {
                  if (event.key === 'Escape') setRename(undefined)
                }}
              />
              <Button type="submit" size="icon-sm" variant="ghost" aria-label={t('common.save')} disabled={pending}>
                <RiCheckLine />
              </Button>
              <Button
                type="button"
                size="icon-sm"
                variant="ghost"
                aria-label={t('common.cancel')}
                onClick={() => setRename(undefined)}>
                <RiCloseLine />
              </Button>
            </form>
          ) : (
            <button
              type="button"
              data-row-link
              className="min-w-0 break-all text-left hover:underline"
              onClick={() => (isFile ? void download() : onNavigate(node.id))}>
              {rootLabel ?? <BdiLabel value={node.name} />}
            </button>
          )}
        </div>
      </TableCell>
      <TableCell>{t(`console.drive.kind_${node.kind}`)}</TableCell>
      <TableCell>{isFile ? formatFileBytes(node.size) : '–'}</TableCell>
      <TableCell>{formatConsoleDate(node.updated_at)}</TableCell>
      <TableCell className="text-right">
        {node.parent_id ? (
          <>
            <DropdownMenu>
              <DropdownMenuTrigger
                render={
                  <Button
                    type="button"
                    variant="ghost"
                    size="icon-sm"
                    disabled={pending}
                    aria-label={t('common.more_actions')}
                  />
                }>
                <RiMore2Fill />
              </DropdownMenuTrigger>
              <DropdownMenuContent align="end">
                {isFile ? (
                  <DropdownMenuItem onClick={() => void download()}>
                    <RiDownloadLine />
                    {t('console.agent_files.download')}
                  </DropdownMenuItem>
                ) : null}
                <DropdownMenuItem onClick={() => setRename(sanitizeRenameValue(node.name))}>
                  <RiPencilLine />
                  {t('console.agent_files.rename')}
                </DropdownMenuItem>
                <DropdownMenuItem onClick={() => setMoving(true)}>
                  <RiFolder3Line />
                  {t('console.agent_files.move')}
                </DropdownMenuItem>
                <DropdownMenuItem variant="destructive" onClick={() => setDeleting(true)}>
                  <RiDeleteBin6Line />
                  {t('common.delete')}
                </DropdownMenuItem>
              </DropdownMenuContent>
            </DropdownMenu>
            {moving ? (
              <MoveDialog
                tenantID={tenantID}
                node={node}
                pending={pending}
                onClose={() => setMoving(false)}
                onMove={id => onMove({ parent_id: id }, () => setMoving(false))}
              />
            ) : null}
            <Dialog open={deleting} onOpenChange={setDeleting}>
              <DialogContent closeLabel={t('common.close')}>
                <DialogHeader>
                  <DialogTitle>{t('console.drive.trash_title')}</DialogTitle>
                  <DialogDescription>
                    <bdi>{t('console.drive.trash_description', { name: stripBidi(node.name) })}</bdi>
                  </DialogDescription>
                </DialogHeader>
                <DialogFooter>
                  <DialogClose render={<Button variant="ghost" />}>{t('common.cancel')}</DialogClose>
                  <Button variant="destructive" disabled={pending} onClick={() => onDelete(() => setDeleting(false))}>
                    {t('common.delete')}
                  </Button>
                </DialogFooter>
              </DialogContent>
            </Dialog>
          </>
        ) : null}
      </TableCell>
    </TableRow>
  )
}

function MoveDialog({
  tenantID,
  node,
  pending,
  onClose,
  onMove
}: {
  tenantID: string
  node: DriveNode
  pending: boolean
  onClose: () => void
  onMove: (id: string) => void
}) {
  const { t } = useTranslation()
  const [parent, setParent] = useState<string>()
  const [after, setAfter] = useState<string>()
  const listing = useQuery(
    listDriveNodesOptions({ path: { tenant_id: tenantID }, query: { parent_id: parent, after } })
  )
  const navigate = (id?: string) => {
    setParent(id)
    setAfter(undefined)
  }
  return (
    <Dialog
      open
      onOpenChange={open => {
        if (!open) onClose()
      }}>
      <DialogContent closeLabel={t('common.close')}>
        <DialogHeader>
          <DialogTitle>{t('console.agent_files.move_title')}</DialogTitle>
        </DialogHeader>
        <Breadcrumbs ancestors={listing.data?.ancestors ?? []} onNavigate={navigate} />
        {listing.error ? <p role="alert">{requestErrorMessage(listing.error)}</p> : null}
        <div className="grid max-h-64 gap-1 overflow-y-auto" aria-busy={listing.isLoading}>
          {(listing.data?.nodes ?? [])
            .filter(child => child.kind !== 'file' && child.id !== node.id)
            .map(child => (
              <Button key={child.id} variant="ghost" className="justify-start" onClick={() => navigate(child.id)}>
                <RiFolder3Line />
                {child.private_owner_uid ?? child.conversation_id ?? <BdiLabel value={child.name} />}
              </Button>
            ))}
          {listing.data?.next_after ? (
            <Button variant="ghost" onClick={() => setAfter(listing.data!.next_after!)}>
              {t('console.drive.next_page')}
            </Button>
          ) : null}
        </div>
        <DialogFooter>
          <Button variant="ghost" onClick={onClose}>
            {t('common.cancel')}
          </Button>
          <Button
            disabled={!parent || parent === node.parent_id || pending || listing.isLoading || Boolean(listing.error)}
            onClick={() => {
              if (parent) onMove(parent)
            }}>
            {t('console.drive.move_here')}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}

const folderPicker = { webkitdirectory: '' } as InputHTMLAttributes<HTMLInputElement>
function UploadMenu({ disabled, onUpload }: { disabled: boolean; onUpload: (files: File[]) => void }) {
  const { t } = useTranslation()
  const filesInput = useRef<HTMLInputElement>(null)
  const folderInput = useRef<HTMLInputElement>(null)
  const choose = (input: HTMLInputElement) => {
    const files = Array.from(input.files ?? [])
    input.value = ''
    if (files.length) onUpload(files)
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
        <DropdownMenuTrigger render={<Button variant="outline" size="sm" disabled={disabled} aria-busy={disabled} />}>
          <RiUploadCloud2Line />
          {t(disabled ? 'console.agent_files.uploading' : 'console.agent_files.upload')}
        </DropdownMenuTrigger>
        <DropdownMenuContent align="end">
          <DropdownMenuItem onClick={() => filesInput.current?.click()}>
            {t('console.agent_files.upload_title')}
          </DropdownMenuItem>
          <DropdownMenuItem onClick={() => folderInput.current?.click()}>
            {t('console.agent_files.upload_folder')}
          </DropdownMenuItem>
        </DropdownMenuContent>
      </DropdownMenu>
    </>
  )
}

export function agentFilesPath(uid: string, prefix = ''): string {
  return `/drive?${new URLSearchParams({ owner: uid, ...(prefix ? { prefix } : {}) })}`
}

export function AgentFilesLink({ agentUID }: { agentUID: string }) {
  const { t } = useTranslation()
  return (
    <section className="grid gap-2">
      <h3 className="title-section">{t('console.drive.title')}</h3>
      <Link {...linkTarget(agentFilesPath(agentUID))} className="link text-sm">
        {t('console.agent_files.browse')}
      </Link>
    </section>
  )
}
