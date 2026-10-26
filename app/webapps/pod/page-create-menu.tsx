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
import { useInfiniteQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { useNavigate } from '@tanstack/react-router'
import { podLocation } from '../common/browser-context'
import { requestErrorMessage } from '../common/request-errors'
import { contentKeys, pageAPI, pageChildrenQuery, type Page, type PageType } from './content-api'
import { contentError } from './content-errors'
import { typeLabels } from './content-primitives'
import { PageIcon } from './page-icon'

type CreatePageOptions = {
  parentID?: string
  scope?: 'space' | 'private'
  privateOwner?: string
  onCreated?: (page: Page) => void
}

function usePageCreation({ parentID, scope, privateOwner, onCreated }: CreatePageOptions) {
  const navigate = useNavigate()
  const client = useQueryClient()
  return useMutation({
    mutationFn: (type: PageType) => {
      if (!parentID && scope === 'private' && !privateOwner) {
        throw new Error(t('pod.content.your_private_identity_is_not_available_yet_wait_for_the'))
      }
      return pageAPI.create({
        type,
        title: '',
        ...(parentID ? { parent_id: parentID } : scope === 'private' ? { private_owner_uid: privateOwner } : {})
      })
    },
    onSuccess: async ({ page }) => {
      await client.invalidateQueries({ queryKey: contentKeys.all })
      if (onCreated) onCreated(page)
      else void navigate({ to: podLocation(`/pages/${page.id}`).pathname })
    },
    onError: error => toast.error(requestErrorMessage(contentError(error)))
  })
}

function PageTypeItems({ create }: { create: ReturnType<typeof usePageCreation> }) {
  return (['doc', 'base', 'applet', 'file'] as const).map(type => (
    <DropdownMenuItem key={type} disabled={create.isPending} onClick={() => create.mutate(type)}>
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
  ...options
}: CreatePageOptions & { label?: string }) {
  const create = usePageCreation(options)
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
