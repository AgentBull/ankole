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
  toast,
  Spinner
} from '@ankole/uikit'
import {
  AddCircleRegular,
  AddRegular,
  DocumentAddRegular,
  DocumentPowerpointRegular,
  DocumentTableRegular,
  DocumentWordRegular
} from '@ankole/uikit/icons'
import { useRef } from 'react'
import { useMutation, useQueryClient, type QueryClient } from '@tanstack/react-query'
import { useNavigate } from '@tanstack/react-router'
import { podPagePath } from '../common/pod-url'
import { requestErrorMessage } from '../common/request-errors'
import { podOfficeCreate } from './api/generated/sdk.gen'
import { pageAPI, type Page } from './content-api'
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

type PageType = 'doc' | 'word' | 'spreadsheet' | 'presentation' | 'knowledge' | 'base' | 'file'
type Destination = { parent_id?: string; private_owner_uid?: string }

export type PageCreation = {
  isPending: boolean
  submit: (type: PageType) => Promise<void>
}

/** Creates a Page of a type that needs no local file; Office Pages start as blank packages. */
function createPage(input: Exclude<PageType, 'file'>, destination: Destination) {
  if (input === 'spreadsheet' || input === 'word' || input === 'presentation') {
    return podOfficeCreate({ body: { data: { format: input, ...destination } } })
  }
  return pageAPI.create({ type: input, title: '', ...destination })
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
      input: Exclude<PageType, 'file'> | File
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
      return createPage(input, destination)
    }
  })
  const run = async (type: PageType, override?: CreatePageOptions) => {
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
      else void navigate({ to: podPagePath(page.id, page.title) })
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
    mutationFn: ({ input, parentID }: { input: Exclude<PageType, 'file'> | File; parentID: string }) => {
      if (input instanceof File) return createFilePage(input, { parent_id: parentID })
      return createPage(input, { parent_id: parentID })
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
        else void navigate({ to: podPagePath(page.id, page.title) })
      } catch (error) {
        toast.error(requestErrorMessage(contentError(error)))
      }
    }
  })
  return forParent
}

const pageTypes = ['doc', 'word', 'spreadsheet', 'presentation', 'base', 'file'] as const

function PageTypeItems({ create, types = pageTypes }: { create: PageCreation; types?: readonly PageType[] }) {
  useTranslation()
  return types.map(type => (
    <DropdownMenuItem key={type} disabled={create.isPending} onClick={() => void create.submit(type)}>
      {type === 'word' ? (
        <DocumentWordRegular aria-hidden className="pod-page-icon" />
      ) : type === 'spreadsheet' ? (
        <DocumentTableRegular className="pod-page-icon" />
      ) : type === 'presentation' ? (
        <DocumentPowerpointRegular aria-hidden className="pod-page-icon" />
      ) : (
        <PageIcon page={{ type, icon: null }} />
      )}
      {type === 'word'
        ? t('pod.word.word_document')
        : type === 'spreadsheet'
          ? t('pod.spreadsheet.spreadsheet')
          : type === 'presentation'
            ? t('pod.presentation.presentation')
            : typeLabels[type]}
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
  types,
  onCreated
}: CreatePageOptions & {
  scope: 'space' | 'private'
  compact?: boolean
  disabled?: boolean
  label?: string
  types?: readonly PageType[]
}) {
  const { t } = useTranslation()
  const label = providedLabel ?? t('pod.content.new_page')
  const waitingForIdentity = !parentID && scope === 'private' && !privateOwner
  const create = usePageCreation({ parentID, scope, privateOwner, onCreated })
  return (
    <DropdownMenu modal={false}>
      <DropdownMenuTrigger
        render={
          <Button
            variant={compact ? 'ghost' : 'outline'}
            size={compact ? 'icon-xs' : 'sm'}
            aria-label={label}
            title={label}
            aria-busy={create.isPending}
            disabled={disabled || waitingForIdentity || create.isPending}
          />
        }>
        {/* The compact button is a sidebar action, which draws the circled plus of the Ankole icon set. */}
        {create.isPending ? (
          <Spinner aria-hidden className="size-4" />
        ) : compact ? (
          <AddCircleRegular className="size-4" />
        ) : (
          <AddRegular className="size-4" />
        )}
        {!compact && (create.isPending ? t('pod.content.creating') : label)}
      </DropdownMenuTrigger>
      <DropdownMenuContent align="start" className="w-56" aria-label={label}>
        <PageTypeItems create={create} types={types} />
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
        <DocumentAddRegular />
        {label}
      </DropdownMenuSubTrigger>
      <DropdownMenuSubContent className="w-56" aria-label={label}>
        <PageTypeItems create={create} types={types} />
      </DropdownMenuSubContent>
    </DropdownMenuSub>
  )
}
