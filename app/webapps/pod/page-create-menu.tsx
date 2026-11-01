import { t } from 'i18next'
import { useTranslation } from 'react-i18next'
import {
  Button,
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuSub,
  DropdownMenuSubContent,
  DropdownMenuSubTrigger,
  DropdownMenuTrigger,
  toast
} from '@ankole/uikit'
import { RiAddLine, RiFileAddLine, RiLoader4Line } from '@remixicon/react'
import { useRef } from 'react'
import { useInfiniteQuery, useMutation, useQueryClient, type QueryClient } from '@tanstack/react-query'
import { useNavigate } from '@tanstack/react-router'
import { podLocation } from '../common/browser-context'
import { requestErrorMessage } from '../common/request-errors'
import { directoryCapabilitiesQuery, pageAPI, type Page } from './content-api'
import { contentError } from './content-errors'
import { typeLabels } from './content-primitives'
import { PageIcon } from './page-icon'
import { pageCreated } from './state/navigation-cache'
import { chooseLocalFile, createFilePage } from './native-transfers'

export type CreatePageOptions = {
  parentID?: string
  scope?: 'space' | 'private'
  privateOwner?: string
  onCreated?: (page: Page) => void
}

type PageType = 'doc' | 'base' | 'folder' | 'file'

export type PageCreation = {
  isPending: boolean
  submit: (type: PageType) => Promise<void>
}

export function usePageCreation({ parentID, scope, privateOwner, onCreated }: CreatePageOptions = {}): PageCreation {
  const navigate = useNavigate()
  const client = useQueryClient()
  const latestOnCreated = useRef(onCreated)
  latestOnCreated.current = onCreated
  const mutation = useMutation({
    mutationFn: ({
      input,
      targetParentID,
      targetScope,
      targetOwner
    }: {
      input: 'doc' | 'base' | 'folder' | File
      targetParentID?: string
      targetScope?: 'space' | 'private'
      targetOwner?: string
    }) => {
      if (!targetParentID && targetScope === 'private' && !targetOwner) {
        throw new Error(t('pod.content.your_private_identity_is_not_available_yet_wait_for_the'))
      }
      const destination = targetParentID
        ? { parent_id: targetParentID }
        : targetScope === 'private'
          ? { private_owner_uid: targetOwner }
          : {}
      if (input instanceof File) return createFilePage(input, destination)
      return pageAPI.create({
        type: input,
        title: '',
        ...destination
      })
    }
  })
  const run = async (type: 'doc' | 'base' | 'folder' | 'file', override?: CreatePageOptions) => {
    const input = type === 'file' ? await chooseLocalFile() : type
    if (!input) return
    const callback = override?.onCreated ?? latestOnCreated.current
    try {
      const { page } = await mutation.mutateAsync({
        input,
        targetParentID: override?.parentID ?? parentID,
        targetScope: override?.scope ?? scope,
        targetOwner: override?.privateOwner ?? privateOwner
      })
      pageCreated(client, page)
      if (callback) callback(page)
      else void navigate({ to: podLocation(`/pages/${page.id}`).pathname })
    } catch (error) {
      toast.error(requestErrorMessage(contentError(error)))
    }
  }
  return {
    isPending: mutation.isPending,
    submit: type => run(type)
  }
}

/**
 * Creates one File Page per file under the parent, in order, and announces the result. A failure
 * stops at that file and rejects; the File Pages created before it stay in the tree.
 */
export async function uploadFileSubpages(client: QueryClient, parentID: string, files: readonly File[]) {
  let lastTitle = ''
  for (const file of files) {
    const { page } = await createFilePage(file, { parent_id: parentID })
    pageCreated(client, page)
    lastTitle = page.title || file.name
  }
  if (files.length === 1) toast.success(t('pod.subpages.uploaded_file', { title: lastTitle }))
  else if (files.length > 1) toast.success(t('pod.subpages.uploaded_files', { count: files.length }))
}

export function useSubpageCreation() {
  const navigate = useNavigate()
  const client = useQueryClient()
  const mutation = useMutation({
    mutationFn: ({ input, parentID }: { input: 'doc' | 'base' | 'folder' | File; parentID: string }) => {
      if (input instanceof File) return createFilePage(input, { parent_id: parentID })
      return pageAPI.create({ type: input, title: '', parent_id: parentID })
    }
  })
  const forParent = (parentID: string, onCreated?: (page: Page) => void): PageCreation => ({
    isPending: mutation.isPending,
    submit: async type => {
      const input = type === 'file' ? await chooseLocalFile() : type
      if (!input) return
      try {
        const { page } = await mutation.mutateAsync({ input, parentID })
        pageCreated(client, page)
        if (onCreated) onCreated(page)
        else void navigate({ to: podLocation(`/pages/${page.id}`).pathname })
      } catch (error) {
        toast.error(requestErrorMessage(contentError(error)))
      }
    }
  })
  return forParent
}

const pageTypes = ['doc', 'base', 'folder', 'file'] as const

function PageTypeItems({ create, types = pageTypes }: { create: PageCreation; types?: readonly PageType[] }) {
  useTranslation()
  return types.map(type => (
    <DropdownMenuItem key={type} disabled={create.isPending} onClick={() => void create.submit(type)}>
      <PageIcon page={{ type, icon: null }} />
      {typeLabels[type]}
    </DropdownMenuItem>
  ))
}

export function CreatePageButton({
  parentID,
  scope,
  privateOwner,
  compact = false,
  disabled = false,
  label: providedLabel,
  onCreated
}: CreatePageOptions & { compact?: boolean; disabled?: boolean; label?: string }) {
  const { t } = useTranslation()
  const label = providedLabel ?? t('pod.content.new_page')
  const needsCapabilities = !parentID && scope === undefined
  const destinations = useInfiniteQuery({ ...directoryCapabilitiesQuery(), enabled: needsCapabilities })
  const capabilities = destinations.data
  const effectiveScope = scope ?? (capabilities?.can_create_space ? 'space' : 'private')
  const owner = privateOwner ?? (scope === undefined ? capabilities?.principal_uid : undefined)
  const unavailable =
    needsCapabilities &&
    (!capabilities || destinations.isError || (!capabilities.can_create_space && !capabilities.can_create_private))
  const waitingForIdentity = !parentID && effectiveScope === 'private' && !owner
  const create = usePageCreation({ parentID, scope: effectiveScope, privateOwner: owner, onCreated })
  return (
    <DropdownMenu modal={false}>
      <DropdownMenuTrigger
        render={
          <Button
            variant={compact ? 'ghost' : 'outline'}
            size={compact ? 'icon-sm' : 'sm'}
            aria-label={label}
            title={label}
            aria-busy={create.isPending}
            disabled={disabled || unavailable || waitingForIdentity || create.isPending}
          />
        }>
        {create.isPending ? (
          <RiLoader4Line aria-hidden className="size-4 animate-spin" />
        ) : (
          <RiAddLine aria-hidden className="size-4" />
        )}
        {!compact && (create.isPending ? t('pod.content.creating') : label)}
      </DropdownMenuTrigger>
      <DropdownMenuContent align="start" className="w-56" aria-label={label}>
        <PageTypeItems create={create} />
      </DropdownMenuContent>
    </DropdownMenu>
  )
}

export function CreatePageSubmenu({
  label: providedLabel,
  create: provided,
  types,
  ...options
}: CreatePageOptions & { label?: string; create?: PageCreation; types?: readonly PageType[] }) {
  const { t } = useTranslation()
  const label = providedLabel ?? t('pod.sidebar.new_subpage')
  const fallback = usePageCreation(options)
  const create = provided ?? fallback
  return (
    <DropdownMenuSub>
      <DropdownMenuSubTrigger disabled={create.isPending}>
        <RiFileAddLine aria-hidden />
        {label}
      </DropdownMenuSubTrigger>
      <DropdownMenuSubContent className="w-56" aria-label={label}>
        <PageTypeItems create={create} types={types} />
      </DropdownMenuSubContent>
    </DropdownMenuSub>
  )
}
