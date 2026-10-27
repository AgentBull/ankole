import { t } from 'i18next'
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
import { useInfiniteQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { useNavigate } from '@tanstack/react-router'
import { podLocation } from '../common/browser-context'
import { requestErrorMessage } from '../common/request-errors'
import { contentKeys, pageAPI, pageChildrenQuery, type Page } from './content-api'
import { contentError } from './content-errors'
import { typeLabels } from './content-primitives'
import { PageIcon } from './page-icon'
import { chooseLocalFile, createFilePage } from './native-transfers'

export type CreatePageOptions = {
  parentID?: string
  scope?: 'space' | 'private'
  privateOwner?: string
  onCreated?: (page: Page) => void
}

export type PageCreation = {
  isPending: boolean
  submit: (type: 'doc' | 'base' | 'file') => Promise<void>
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
      input: 'doc' | 'base' | File
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
  const run = async (type: 'doc' | 'base' | 'file', override?: CreatePageOptions) => {
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
      await client.invalidateQueries({ queryKey: contentKeys.all })
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

export function useSubpageCreation() {
  const navigate = useNavigate()
  const client = useQueryClient()
  const mutation = useMutation({
    mutationFn: ({ input, parentID }: { input: 'doc' | 'base' | File; parentID: string }) => {
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
        await client.invalidateQueries({ queryKey: contentKeys.all })
        if (onCreated) onCreated(page)
        else void navigate({ to: podLocation(`/pages/${page.id}`).pathname })
      } catch (error) {
        toast.error(requestErrorMessage(contentError(error)))
      }
    }
  })
  return forParent
}

function PageTypeItems({ create }: { create: PageCreation }) {
  return (['doc', 'base', 'file'] as const).map(type => (
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
  label = t('pod.content.new_page'),
  onCreated
}: CreatePageOptions & { compact?: boolean; label?: string }) {
  const destinations = useInfiniteQuery({ ...pageChildrenQuery('space'), enabled: !parentID && scope === undefined })
  const capabilities = destinations.data?.pages[0]
  const effectiveScope = scope ?? (capabilities?.can_create_space ? 'space' : 'private')
  const owner = privateOwner ?? (scope === undefined ? capabilities?.principal_uid : undefined)
  const unavailable =
    !parentID &&
    scope === undefined &&
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
            disabled={unavailable || waitingForIdentity || create.isPending}
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
  label = t('pod.sidebar.new_subpage'),
  create: provided,
  ...options
}: CreatePageOptions & { label?: string; create?: PageCreation }) {
  const fallback = usePageCreation(options)
  const create = provided ?? fallback
  return (
    <DropdownMenuSub>
      <DropdownMenuSubTrigger disabled={create.isPending}>
        <RiFileAddLine aria-hidden />
        {label}
      </DropdownMenuSubTrigger>
      <DropdownMenuSubContent className="w-56" aria-label={label}>
        <PageTypeItems create={create} />
      </DropdownMenuSubContent>
    </DropdownMenuSub>
  )
}
