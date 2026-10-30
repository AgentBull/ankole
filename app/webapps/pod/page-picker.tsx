import { usePagesMetadata } from './use-page-metadata'
import { Command, CommandEmpty, CommandGroup, CommandInput, CommandItem, CommandList } from '@ankole/uikit'
import { RiFolderLine, RiLockLine } from '@remixicon/react'
import { useState } from 'react'
import { useDebouncedValue } from '../common/use-debounced-value'
import { useTranslation } from 'react-i18next'
import { useQuery } from '@tanstack/react-query'
import { pageSearchQuery, type Page, type PageSearchOptions } from './content-api'
import { ContentError } from './content-primitives'
import { PageIcon } from './page-icon'
import { pageAncestors } from './state/page-location'

type Location = { id: string; title: string; private?: boolean }

/** One searchable list for choosing a saved Page or its destination. */
export function PagePicker({
  excludeSubtreeOf,
  requiredAction,
  embeddable,
  roots = [],
  selected,
  onSelect,
  label,
  disabled = false,
  autoFocus = true
}: {
  excludeSubtreeOf?: Page['id']
  requiredAction?: PageSearchOptions['required_action']
  embeddable?: boolean
  roots?: Location[]
  selected?: string
  onSelect(id: string, page?: Page): void
  label: string
  disabled?: boolean
  autoFocus?: boolean
}) {
  const { t } = useTranslation()
  const [query, setQuery] = useState('')
  const settledQuery = useDebouncedValue(query, 180)
  const remote = useQuery(
    pageSearchQuery(settledQuery, {
      exclude_subtree_of: excludeSubtreeOf,
      required_action: requiredAction,
      ...(embeddable ? { embeddable: true } : {})
    })
  )
  const searching = query !== settledQuery || remote.isFetching
  const pages = usePagesMetadata(query === settledQuery ? (remote.data?.pages ?? []) : [])
  const ancestors = usePagesMetadata(remote.data?.ancestors ?? [])
  const visibleRoots = roots.filter(root => root.title.toLocaleLowerCase().includes(query.trim().toLocaleLowerCase()))
  const byID = new Map([...pages, ...ancestors].map(page => [page.id, page]))
  const parentTitle = (page: Page) => {
    const ancestors = pageAncestors(page, byID).map(parent => parent.title || t('pod.content.untitled'))
    const scope = page.private_owner_uid ? t('pod.content.private') : t('pod.content.space')
    return ancestors.length > 0 ? `${scope} / ${ancestors.join(' / ')}` : scope
  }
  return (
    <Command className="pod-page-picker" label={label} loop shouldFilter={false}>
      <CommandInput
        aria-label={label}
        placeholder={t('pod.content.search')}
        value={query}
        onValueChange={setQuery}
        disabled={disabled}
        autoFocus={autoFocus}
      />
      <CommandList label={label}>
        <CommandEmpty>{searching ? t('pod.content.loading') : t('pod.content.no_matches')}</CommandEmpty>
        {visibleRoots.length > 0 && (
          <CommandGroup>
            {visibleRoots.map(root => {
              const Icon = root.private ? RiLockLine : RiFolderLine
              return (
                <CommandItem
                  key={root.id}
                  value={root.id}
                  keywords={[root.title]}
                  data-checked={root.id === selected}
                  disabled={disabled}
                  onSelect={() => onSelect(root.id)}>
                  <Icon aria-hidden className="text-fg-tertiary" />
                  <span>{root.title}</span>
                </CommandItem>
              )
            })}
          </CommandGroup>
        )}
        <CommandGroup>
          {pages.map(page => {
            const title = page.title || t('pod.content.untitled')
            const parent = parentTitle(page)
            return (
              <CommandItem
                key={page.id}
                value={page.id}
                keywords={[title, parent]}
                data-checked={page.id === selected}
                disabled={disabled}
                onSelect={() => onSelect(page.id, page)}>
                <PageIcon page={page} />
                <span className="min-w-0 flex-1">
                  <span className="block truncate">{title}</span>
                  {parent && <span className="block truncate text-xs text-fg-tertiary">{parent}</span>}
                </span>
              </CommandItem>
            )
          })}
        </CommandGroup>
      </CommandList>
      <ContentError error={remote.error} retry={() => void remote.refetch()} />
    </Command>
  )
}
