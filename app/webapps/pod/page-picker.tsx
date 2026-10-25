import { t } from 'i18next'
import { Command, CommandEmpty, CommandGroup, CommandInput, CommandItem, CommandList } from '@ankole/uikit'
import { RiFolderLine, RiLockLine } from '@remixicon/react'
import { useDeferredValue, useState } from 'react'
import { useQuery } from '@tanstack/react-query'
import { pageSearchQuery, type Page, type PageSearchOptions } from './content-api'
import { ContentError } from './content-primitives'
import { PageIcon } from './page-icon'

type Location = { id: string; title: string; private?: boolean }

/** One searchable list for choosing a saved Page or its destination. */
export function PagePicker({
  excludeSubtreeOf,
  requiredAction,
  roots = [],
  selected,
  onSelect,
  label,
  disabled = false
}: {
  excludeSubtreeOf?: Page['id']
  requiredAction?: PageSearchOptions['required_action']
  roots?: Location[]
  selected?: string
  onSelect(id: string, page?: Page): void
  label: string
  disabled?: boolean
}) {
  const [query, setQuery] = useState('')
  const deferredQuery = useDeferredValue(query)
  const remote = useQuery(
    pageSearchQuery(deferredQuery, { exclude_subtree_of: excludeSubtreeOf, required_action: requiredAction })
  )
  const searching = query !== deferredQuery || remote.isFetching
  const pages = query === deferredQuery ? (remote.data?.pages ?? []) : []
  const visibleRoots = roots.filter(root => root.title.toLocaleLowerCase().includes(query.trim().toLocaleLowerCase()))
  const byID = new Map(pages.map(page => [page.id, page]))
  const parentTitle = (page: Page) => {
    const visited = new Set([page.id])
    const titles: string[] = []
    let parent = page.parent_id ? byID.get(page.parent_id) : undefined
    while (parent && !visited.has(parent.id)) {
      visited.add(parent.id)
      titles.unshift(parent.title || t('pod.content.untitled'))
      parent = parent.parent_id ? byID.get(parent.parent_id) : undefined
    }
    return titles.join(' / ')
  }
  return (
    <Command className="pod-page-picker" label={label} loop shouldFilter={false}>
      <CommandInput
        aria-label={label}
        placeholder={t('pod.content.search')}
        value={query}
        onValueChange={setQuery}
        disabled={disabled}
        autoFocus
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
