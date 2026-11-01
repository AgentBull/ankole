import { canCreateChild } from './state/page-location'
import { BdiLabel } from '../common/bidi-file-name'
import { stripBidi } from '../common/bidi'
import { formatFileBytes } from '../common/file-format'
import { usePagesMetadata } from './use-page-metadata'
import {
  Badge,
  Button,
  ContextMenu,
  ContextMenuContent,
  ContextMenuTrigger,
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuRadioGroup,
  DropdownMenuRadioItem,
  DropdownMenuTrigger,
  Popover,
  PopoverContent,
  PopoverHeader,
  PopoverTitle,
  PopoverTrigger,
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
  cn,
  toast
} from '@ankole/uikit'
import {
  RiAddLine,
  RiArrowDownLine,
  RiArrowDownSLine,
  RiArrowGoBackLine,
  RiArrowRightSLine,
  RiArrowUpDownLine,
  RiArrowUpLine,
  RiArrowUpSLine,
  RiDraggable,
  RiEqualizerLine,
  RiEyeLine,
  RiEyeOffLine,
  RiLayoutGridLine,
  RiListUnordered,
  RiLoader4Line,
  RiLockLine,
  RiMoreFill,
  RiUpload2Line
} from '@remixicon/react'
import { useModel } from '@preact/signals-react'
import { useSignals } from '@preact/signals-react/runtime'
import { useInfiniteQuery, useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { Link } from '@tanstack/react-router'
import { useEffect, useRef, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { podLocation } from '../common/browser-context'
import { requestErrorMessage } from '../common/request-errors'
import {
  fileURL,
  pageAPI,
  pageQuery,
  pageSubpagesQuery,
  pagesQuery,
  type ChildrenViewPatch,
  type PageDetail,
  type SubpageItem
} from './content-api'
import { contentError } from './content-errors'
import { formatPageTimestamp, handlePodListKeyDown } from './content-list'
import { ContentError, typeLabels } from './content-primitives'
import { PageMenuItems, usePageActions, type PageActions } from './page-actions'
import { uploadFileSubpages, usePageCreation } from './page-create-menu'
import { PageIcon } from './page-icon'
import { MovePageDialog } from './page-move-dialog'
import { PageRenameField } from './page-navigation'
import { updatePageMetadata } from './state/navigation-cache'
import {
  PageSubpagesModel,
  fileExtensionBadge,
  sortSubpages,
  type SubpageField,
  type SubpageSort,
  type SubpageSortField,
  type SubpageViewMode
} from './state/page-subpages'

export function DocumentSubpages({
  detail,
  canEdit,
  hideTopDivider = false
}: {
  detail: PageDetail
  canEdit: boolean
  hideTopDivider?: boolean
}) {
  useSignals()
  const { t, i18n } = useTranslation()
  const client = useQueryClient()
  const { page } = detail
  const scope = page.private_owner_uid ? 'private' : 'space'
  const privateOwner = page.private_owner_uid ?? undefined

  const model = useModel(() => new PageSubpagesModel(page.children_view))
  useEffect(() => {
    model.syncFromServer(page.children_view)
  }, [model, page.children_view])

  const persistMutation = useMutation({
    scope: { id: `page-children-view:${page.id}` },
    mutationFn: (children_view: NonNullable<ChildrenViewPatch>) => pageAPI.update(page.id, { children_view }),
    onSuccess: ({ page: updated }) => {
      updatePageMetadata(client, { id: updated.id, children_view: updated.children_view })
    },
    onError: error => toast.error(requestErrorMessage(contentError(error)))
  })
  const persist = (patch: NonNullable<ChildrenViewPatch>) => persistMutation.mutate(patch)

  const collapsed = model.collapsed.value
  const view = model.view.value
  const fieldOrder = model.fieldOrder.value
  const visibleFields = model.visibleFields.value
  const sort = model.sort.value

  const hasPotentialChildren = detail.child_count > 0
  const showEmpty = page.type === 'folder'
  const canCreate = canCreateChild({ ...page, actions: detail.actions })
  const subpages = useInfiniteQuery({
    ...pageSubpagesQuery(scope, page.id),
    enabled: (hasPotentialChildren || showEmpty) && !collapsed
  })
  const { hasNextPage, isFetchingNextPage, isFetchNextPageError, fetchNextPage } = subpages
  useEffect(() => {
    if (!collapsed && sort !== null && hasNextPage && !isFetchingNextPage && !isFetchNextPageError) {
      void fetchNextPage()
    }
  }, [collapsed, sort, hasNextPage, isFetchingNextPage, isFetchNextPageError, fetchNextPage])

  const favorites = useQuery({
    ...pagesQuery('favorites'),
    enabled: (hasPotentialChildren || showEmpty) && !collapsed
  })
  const favoriteIDs = new Set(favorites.data?.pages.map(item => item.id) ?? [])
  const actions = usePageActions()
  const createChild = usePageCreation({ parentID: page.id, scope, privateOwner })

  const uploadInput = useRef<HTMLInputElement>(null)
  const [uploading, setUploading] = useState(false)
  const [draggedField, setDraggedField] = useState<SubpageField | null>(null)
  const [dragOverField, setDragOverField] = useState<SubpageField | null>(null)

  const rawPages = usePagesMetadata(subpages.data?.pages.flatMap(batch => batch.pages) ?? [])
  if (!hasPotentialChildren && !showEmpty) return null
  if (!showEmpty && !collapsed && subpages.isSuccess && !subpages.hasNextPage && rawPages.length === 0) return null

  const sortedPages = sortSubpages(rawPages, sort, t('pod.content.untitled'))

  const handleUploadFiles = async (files: File[]) => {
    if (!files.length || uploading) return
    setUploading(true)
    try {
      await uploadFileSubpages(client, page.id, files)
    } catch (error) {
      toast.error(requestErrorMessage(contentError(error)))
    } finally {
      setUploading(false)
    }
  }

  const fieldLabel = (field: SubpageField) => {
    switch (field) {
      case 'created_by':
        return t('pod.subpages.field_created_by')
      case 'updated_at':
        return t('pod.subpages.field_updated_at')
      case 'created_at':
        return t('pod.subpages.field_created_at')
    }
  }

  if (collapsed) {
    const countLabel = subpages.data
      ? subpages.hasNextPage
        ? `${rawPages.length}+`
        : `${rawPages.length}`
      : `${detail.child_count}`

    return (
      <section
        aria-label={t('pod.subpages.title')}
        data-pod-subpages
        data-collapsed=""
        className={cn(
          'opacity-55 transition-opacity focus-within:opacity-100 hover:opacity-100',
          hideTopDivider ? 'mt-1' : 'mt-5 border-t border-border/70 pt-2.5'
        )}>
        <button
          type="button"
          aria-expanded={false}
          onClick={() => model.toggleCollapsed(canEdit, persist)}
          className="inline-flex h-8 cursor-pointer items-center gap-1.5 rounded-control px-1.5 text-sm font-medium text-foreground transition-colors hover:bg-accent focus-visible:outline-2 focus-visible:outline-ring">
          <RiArrowRightSLine aria-hidden className="size-4 text-fg-secondary" />
          <span>{t('pod.subpages.title')}</span>
          <Badge
            variant="secondary"
            className="pointer-events-none ml-0.5 h-5 min-w-5 px-1.5 text-xs font-medium tabular-nums text-fg-secondary">
            {countLabel}
          </Badge>
        </button>
      </section>
    )
  }

  return (
    <section
      aria-label={t('pod.subpages.title')}
      data-pod-subpages
      onKeyDown={handlePodListKeyDown}
      className={hideTopDivider ? 'mt-1' : 'mt-5 border-t border-border pt-3.5'}>
      <div className="flex flex-wrap items-center justify-between gap-2 pb-2.5">
        <div className="flex flex-wrap items-center gap-1">
          <button
            type="button"
            aria-expanded={true}
            onClick={() => model.toggleCollapsed(canEdit, persist)}
            className="inline-flex h-8 cursor-pointer items-center gap-1.5 rounded-control px-1.5 text-sm font-medium text-foreground transition-colors hover:bg-accent focus-visible:outline-2 focus-visible:outline-ring">
            <RiArrowDownSLine aria-hidden className="size-4 text-fg-secondary" />
            <span>{t('pod.subpages.title')}</span>
          </button>

          <span aria-hidden className="mx-1 h-3.5 w-px bg-border" />

          <DropdownMenu>
            <DropdownMenuTrigger
              render={
                <Button variant="ghost" size="sm" aria-label={t('pod.subpages.switch_view')} className="gap-1.5 px-2" />
              }>
              {view === 'list' ? (
                <RiListUnordered aria-hidden className="size-4 text-fg-secondary" />
              ) : (
                <RiLayoutGridLine aria-hidden className="size-4 text-fg-secondary" />
              )}
              <span>{view === 'list' ? t('pod.subpages.view_list') : t('pod.subpages.view_grid')}</span>
              <RiArrowDownSLine aria-hidden className="size-3.5 text-fg-tertiary" />
            </DropdownMenuTrigger>
            <DropdownMenuContent align="start" className="w-36">
              <DropdownMenuRadioGroup
                value={view}
                onValueChange={next => model.setView(next as SubpageViewMode, canEdit, persist)}>
                <DropdownMenuRadioItem value="list">
                  <RiListUnordered aria-hidden />
                  {t('pod.subpages.view_list')}
                </DropdownMenuRadioItem>
                <DropdownMenuRadioItem value="grid">
                  <RiLayoutGridLine aria-hidden />
                  {t('pod.subpages.view_grid')}
                </DropdownMenuRadioItem>
              </DropdownMenuRadioGroup>
            </DropdownMenuContent>
          </DropdownMenu>

          {sort && view === 'list' && (
            <Button
              variant="ghost"
              size="sm"
              className="gap-1 px-2 text-xs text-fg-secondary"
              onClick={() => model.resetSort()}>
              <RiArrowGoBackLine aria-hidden className="size-3.5" />
              {t('pod.subpages.reset_order')}
            </Button>
          )}
        </div>

        <div className="flex flex-wrap items-center gap-1">
          <Popover>
            <PopoverTrigger
              render={
                <Button
                  variant="ghost"
                  size="sm"
                  disabled={view === 'grid'}
                  className="gap-1.5 px-2 text-fg-secondary"
                />
              }>
              <RiEqualizerLine aria-hidden className="size-4" />
              <span>{t('pod.subpages.display_settings')}</span>
            </PopoverTrigger>
            <PopoverContent align="end" className="w-64 gap-2 p-3">
              <PopoverHeader>
                <PopoverTitle className="text-xs font-medium text-fg-secondary">
                  {t('pod.subpages.display_fields')}
                </PopoverTitle>
              </PopoverHeader>
              <div className="flex flex-col gap-0.5">
                <div className="flex h-8 items-center justify-between rounded-control px-2 text-sm text-fg-secondary">
                  <span className="inline-flex items-center gap-2">
                    <RiLockLine
                      aria-label={t('pod.subpages.always_visible')}
                      className="size-3.5 shrink-0 text-fg-tertiary"
                    />
                    <span>{t('pod.subpages.field_name')}</span>
                  </span>
                  <RiEyeLine aria-hidden className="size-4 text-fg-disabled" />
                </div>

                {fieldOrder.map((field, index) => {
                  const label = fieldLabel(field)
                  const isVisible = visibleFields.includes(field)
                  return (
                    <div
                      key={field}
                      draggable
                      onDragStart={event => {
                        setDraggedField(field)
                        event.dataTransfer.effectAllowed = 'move'
                        event.dataTransfer.setData('text/plain', field)
                      }}
                      onDragOver={event => {
                        if (!draggedField || draggedField === field) return
                        event.preventDefault()
                        event.dataTransfer.dropEffect = 'move'
                        if (dragOverField !== field) setDragOverField(field)
                      }}
                      onDrop={event => {
                        event.preventDefault()
                        if (draggedField && draggedField !== field) {
                          model.moveField(draggedField, index, canEdit, persist)
                        }
                        setDraggedField(null)
                        setDragOverField(null)
                      }}
                      onDragEnd={() => {
                        setDraggedField(null)
                        setDragOverField(null)
                      }}
                      className={cn(
                        'group/field-row flex h-8 items-center justify-between rounded-control px-1.5 text-sm transition-colors hover:bg-accent/60',
                        dragOverField === field && 'bg-accent ring-1 ring-ring/40',
                        !isVisible && 'text-fg-secondary'
                      )}>
                      <span className="inline-flex min-w-0 items-center gap-1.5">
                        <RiDraggable aria-hidden className="size-3.5 shrink-0 cursor-grab text-fg-tertiary" />
                        <span className="truncate">{label}</span>
                      </span>
                      <span className="inline-flex shrink-0 items-center gap-0.5">
                        <Button
                          variant="ghost"
                          size="icon-sm"
                          disabled={index === 0}
                          aria-label={t('pod.subpages.move_field_up', { field: label })}
                          title={t('pod.subpages.move_field_up', { field: label })}
                          className="size-6 opacity-0 group-focus-within/field-row:opacity-100 group-hover/field-row:opacity-100 disabled:opacity-0"
                          onClick={() => model.stepField(field, -1, canEdit, persist)}>
                          <RiArrowUpSLine aria-hidden className="size-3.5" />
                        </Button>
                        <Button
                          variant="ghost"
                          size="icon-sm"
                          disabled={index === fieldOrder.length - 1}
                          aria-label={t('pod.subpages.move_field_down', { field: label })}
                          title={t('pod.subpages.move_field_down', { field: label })}
                          className="size-6 opacity-0 group-focus-within/field-row:opacity-100 group-hover/field-row:opacity-100 disabled:opacity-0"
                          onClick={() => model.stepField(field, 1, canEdit, persist)}>
                          <RiArrowDownSLine aria-hidden className="size-3.5" />
                        </Button>
                        <Button
                          variant="ghost"
                          size="icon-sm"
                          aria-pressed={isVisible}
                          aria-label={t(isVisible ? 'pod.subpages.hide_field' : 'pod.subpages.show_field', {
                            field: label
                          })}
                          title={t(isVisible ? 'pod.subpages.hide_field' : 'pod.subpages.show_field', {
                            field: label
                          })}
                          className="size-6"
                          onClick={() => model.toggleField(field, canEdit, persist)}>
                          {isVisible ? (
                            <RiEyeLine aria-hidden className="size-4 text-foreground" />
                          ) : (
                            <RiEyeOffLine aria-hidden className="size-4 text-fg-tertiary" />
                          )}
                        </Button>
                      </span>
                    </div>
                  )
                })}
              </div>
            </PopoverContent>
          </Popover>

          {canCreate && (
            <>
              <input
                ref={uploadInput}
                type="file"
                multiple
                aria-label={t('pod.subpages.upload')}
                className="hidden"
                onChange={event => {
                  const files = Array.from(event.target.files ?? [])
                  event.target.value = ''
                  if (files.length) void handleUploadFiles(files)
                }}
              />
              <Button
                variant="ghost"
                size="sm"
                disabled={uploading}
                className="gap-1.5 px-2 text-fg-secondary"
                onClick={() => uploadInput.current?.click()}>
                {uploading ? (
                  <RiLoader4Line aria-hidden className="size-4 animate-spin" />
                ) : (
                  <RiUpload2Line aria-hidden className="size-4" />
                )}
                <span>{uploading ? t('pod.subpages.uploading') : t('pod.subpages.upload')}</span>
              </Button>

              <DropdownMenu>
                <DropdownMenuTrigger
                  render={
                    <Button
                      variant="ghost"
                      size="sm"
                      disabled={createChild.isPending}
                      className="gap-1 px-2 text-fg-secondary"
                    />
                  }>
                  {createChild.isPending ? (
                    <RiLoader4Line aria-hidden className="size-4 animate-spin" />
                  ) : (
                    <RiAddLine aria-hidden className="size-4" />
                  )}
                  <span>{t('pod.subpages.new_subpage')}</span>
                </DropdownMenuTrigger>
                <DropdownMenuContent align="end" className="w-40">
                  <DropdownMenuItem onClick={() => void createChild.submit('folder')}>
                    <PageIcon page={{ type: 'folder' }} />
                    {typeLabels.folder}
                  </DropdownMenuItem>
                  <DropdownMenuItem onClick={() => void createChild.submit('doc')}>
                    <PageIcon page={{ type: 'doc' }} />
                    {typeLabels.doc}
                  </DropdownMenuItem>
                  <DropdownMenuItem onClick={() => void createChild.submit('base')}>
                    <PageIcon page={{ type: 'base' }} />
                    {typeLabels.base}
                  </DropdownMenuItem>
                </DropdownMenuContent>
              </DropdownMenu>
            </>
          )}
        </div>
      </div>

      <ContentError error={subpages.error} retry={() => void subpages.refetch()} />

      {subpages.isPending ? (
        <p role="status" className="py-4 text-xs text-fg-tertiary">
          {t('pod.content.loading')}
        </p>
      ) : sortedPages.length === 0 ? (
        <p className="py-4 text-sm text-fg-tertiary">{t('pod.content.no_pages_yet')}</p>
      ) : view === 'list' ? (
        <Table>
          <TableHeader>
            <TableRow className="hover:bg-transparent">
              <SortableTableHead
                label={t('pod.subpages.field_name')}
                field="title"
                sort={sort}
                onSort={field => model.cycleSort(field)}
                className="w-full min-w-[220px] pl-1.5"
              />
              {visibleFields.map(field =>
                field === 'created_by' ? (
                  <TableHead key={field} className="min-w-[112px]">
                    {fieldLabel(field)}
                  </TableHead>
                ) : (
                  <SortableTableHead
                    key={field}
                    label={fieldLabel(field)}
                    field={field}
                    sort={sort}
                    onSort={target => model.cycleSort(target)}
                    className="min-w-[116px]"
                  />
                )
              )}
              <TableHead className="w-9 px-1 text-right">
                <span className="sr-only">{t('common.more_actions')}</span>
              </TableHead>
            </TableRow>
          </TableHeader>
          <TableBody>
            {sortedPages.map(item => (
              <SubpageListRow
                key={item.id}
                item={item}
                siblings={sort ? [item] : rawPages}
                visibleFields={visibleFields}
                favorited={favoriteIDs.has(item.id)}
                locale={i18n.language}
                actions={actions}
              />
            ))}
          </TableBody>
        </Table>
      ) : (
        <div className="grid grid-cols-1 gap-3 pt-1 sm:grid-cols-2">
          {sortedPages.map(item => (
            <SubpageGridCard
              key={item.id}
              item={item}
              siblings={sort ? [item] : rawPages}
              favorited={favoriteIDs.has(item.id)}
              locale={i18n.language}
              actions={actions}
            />
          ))}
        </div>
      )}

      {subpages.hasNextPage && (
        <div className="mt-3">
          <Button
            variant="outline"
            size="sm"
            disabled={subpages.isFetchingNextPage}
            onClick={() => void subpages.fetchNextPage()}>
            {t('pod.content.load_more_pages')}
          </Button>
        </div>
      )}
    </section>
  )
}

function SortableTableHead({
  label,
  field,
  sort,
  onSort,
  className
}: {
  label: string
  field: SubpageSortField
  sort: SubpageSort
  onSort: (field: SubpageSortField) => void
  className?: string
}) {
  const active = sort?.field === field ? sort.direction : null
  return (
    <TableHead
      aria-sort={active === 'asc' ? 'ascending' : active === 'desc' ? 'descending' : 'none'}
      className={className}>
      <button
        type="button"
        onClick={() => onSort(field)}
        className="group/sort -mx-1.5 inline-flex cursor-pointer items-center gap-1 rounded-control px-1.5 py-0.5 text-xs font-medium text-muted-foreground transition-colors hover:bg-accent hover:text-foreground focus-visible:outline-2 focus-visible:outline-ring">
        <span>{label}</span>
        {active === 'asc' ? (
          <RiArrowUpLine aria-hidden className="size-3.5 text-foreground" />
        ) : active === 'desc' ? (
          <RiArrowDownLine aria-hidden className="size-3.5 text-foreground" />
        ) : (
          <RiArrowUpDownLine
            aria-hidden
            className="size-3.5 opacity-0 transition-opacity group-hover/sort:opacity-70 group-focus-visible/sort:opacity-70"
          />
        )}
      </button>
    </TableHead>
  )
}

function SubpageListRow({
  item,
  siblings,
  visibleFields,
  favorited,
  locale,
  actions
}: {
  item: SubpageItem
  siblings: SubpageItem[]
  visibleFields: readonly SubpageField[]
  favorited: boolean
  locale: string
  actions: PageActions
}) {
  const { t } = useTranslation()
  const client = useQueryClient()
  const [renaming, setRenaming] = useState(false)
  const [moving, setMoving] = useState(false)
  const keepFocusInRow = useRef(false)
  const menuFinalFocus = () => {
    const restore = !keepFocusInRow.current
    keepFocusInRow.current = false
    return restore
  }
  const label = item.title || t('pod.content.untitled')
  const prefetch = () => void client.prefetchQuery(pageQuery(item.id))

  const menu = (
    <PageMenuItems
      page={item}
      pages={siblings}
      favorited={favorited}
      actions={actions}
      onRename={() => {
        keepFocusInRow.current = true
        setRenaming(true)
      }}
      onMoveTo={() => setMoving(true)}
    />
  )

  return (
    <>
      <ContextMenu>
        <ContextMenuTrigger render={<TableRow className="group/subpage-row h-10" />}>
          <TableCell className="max-w-0 pl-1.5 whitespace-normal">
            {renaming ? (
              <div className="flex items-center gap-2">
                <PageIcon page={item} className="shrink-0" />
                <PageRenameField page={item} className="w-full max-w-sm" onDone={() => setRenaming(false)} />
              </div>
            ) : (
              <Link
                data-row-link
                data-pod-list-item
                to={podLocation(`/pages/${item.id}`).pathname}
                onPointerEnter={prefetch}
                onFocus={prefetch}
                className="inline-flex max-w-full items-center gap-2 rounded-control py-0.5 text-sm font-medium text-foreground outline-none focus-visible:outline-2 focus-visible:outline-ring">
                <PageIcon page={item} className="shrink-0" />
                <BdiLabel value={item.title} fallback={t('pod.content.untitled')} />
              </Link>
            )}
          </TableCell>

          {visibleFields.map(field => {
            if (field === 'created_by') {
              return (
                <TableCell key={field} className="max-w-[160px] truncate text-xs text-fg-secondary">
                  {item.creator_name || '—'}
                </TableCell>
              )
            }
            const timestamp = formatPageTimestamp(item[field], locale)
            return (
              <TableCell key={field} className="text-xs tabular-nums text-fg-tertiary">
                {timestamp || '—'}
              </TableCell>
            )
          })}

          <TableCell className="w-9 px-1 text-right">
            {!renaming && (
              <DropdownMenu>
                <DropdownMenuTrigger
                  render={
                    <Button
                      variant="ghost"
                      size="icon-sm"
                      aria-label={t('pod.sidebar.page_actions', { title: stripBidi(label) })}
                      title={t('common.more_actions')}
                      className="opacity-0 transition-opacity group-focus-within/subpage-row:opacity-100 group-hover/subpage-row:opacity-100 aria-expanded:opacity-100"
                    />
                  }>
                  <RiMoreFill aria-hidden className="size-4" />
                </DropdownMenuTrigger>
                <DropdownMenuContent align="end" className="w-56" finalFocus={menuFinalFocus}>
                  {menu}
                </DropdownMenuContent>
              </DropdownMenu>
            )}
          </TableCell>
        </ContextMenuTrigger>
        <ContextMenuContent finalFocus={menuFinalFocus}>{menu}</ContextMenuContent>
      </ContextMenu>
      {moving && <MovePageDialog page={item} close={() => setMoving(false)} />}
    </>
  )
}

function SubpageGridCard({
  item,
  siblings,
  favorited,
  locale,
  actions
}: {
  item: SubpageItem
  siblings: SubpageItem[]
  favorited: boolean
  locale: string
  actions: PageActions
}) {
  const { t } = useTranslation()
  const client = useQueryClient()
  const [renaming, setRenaming] = useState(false)
  const [moving, setMoving] = useState(false)
  const keepFocusInCard = useRef(false)
  const menuFinalFocus = () => {
    const restore = !keepFocusInCard.current
    keepFocusInCard.current = false
    return restore
  }
  const label = item.title || t('pod.content.untitled')
  const updatedLabel = formatPageTimestamp(item.updated_at, locale)
  const subtitle = [item.creator_name, updatedLabel].filter(Boolean).join(' · ') || typeLabels[item.type]
  const prefetch = () => void client.prefetchQuery(pageQuery(item.id))

  const menu = (
    <PageMenuItems
      page={item}
      pages={siblings}
      favorited={favorited}
      actions={actions}
      onRename={() => {
        keepFocusInCard.current = true
        setRenaming(true)
      }}
      onMoveTo={() => setMoving(true)}
    />
  )

  return (
    <>
      <ContextMenu>
        <ContextMenuTrigger
          render={
            <article className="group/subpage-card relative flex flex-col bg-card ring-1 ring-border transition-colors fine-hover:hover:bg-accent/35 fine-hover:hover:ring-fg-tertiary/40 has-aria-expanded:ring-fg-tertiary/40" />
          }>
          <SubpageCardPreview item={item} label={label} />

          <div className="flex items-center gap-2.5 px-3 py-2.5">
            <PageIcon page={item} className="shrink-0" />
            <div className="min-w-0 flex-1">
              {renaming ? (
                <PageRenameField page={item} className="w-full" onDone={() => setRenaming(false)} />
              ) : (
                <Link
                  data-pod-list-item
                  to={podLocation(`/pages/${item.id}`).pathname}
                  onPointerEnter={prefetch}
                  onFocus={prefetch}
                  className="block truncate text-sm font-medium text-foreground outline-none after:absolute after:inset-0 focus-visible:underline">
                  <BdiLabel value={item.title} fallback={t('pod.content.untitled')} />
                </Link>
              )}
              <p className="truncate text-xs leading-4 text-fg-tertiary">{subtitle}</p>
            </div>
            {!renaming && (
              <DropdownMenu>
                <DropdownMenuTrigger
                  render={
                    <Button
                      variant="ghost"
                      size="icon-sm"
                      aria-label={t('pod.sidebar.page_actions', { title: stripBidi(label) })}
                      title={t('common.more_actions')}
                      className="relative z-10 shrink-0 opacity-0 transition-opacity group-focus-within/subpage-card:opacity-100 group-hover/subpage-card:opacity-100 aria-expanded:opacity-100"
                    />
                  }>
                  <RiMoreFill aria-hidden className="size-4" />
                </DropdownMenuTrigger>
                <DropdownMenuContent align="end" className="w-56" finalFocus={menuFinalFocus}>
                  {menu}
                </DropdownMenuContent>
              </DropdownMenu>
            )}
          </div>
        </ContextMenuTrigger>
        <ContextMenuContent finalFocus={menuFinalFocus}>{menu}</ContextMenuContent>
      </ContextMenu>
      {moving && <MovePageDialog page={item} close={() => setMoving(false)} />}
    </>
  )
}

function SubpageCardPreview({ item, label }: { item: SubpageItem; label: string }) {
  const { t } = useTranslation()
  const [imageFailed, setImageFailed] = useState(false)

  if (item.type === 'file') {
    const file = item.file
    const isImage = Boolean(file?.content_type.startsWith('image/')) && !imageFailed
    if (isImage && file) {
      return (
        <div className="h-[132px] overflow-hidden border-b border-border/70 bg-muted/35">
          <img
            loading="lazy"
            src={fileURL(item.id, file.path, file.sha256)}
            alt=""
            onError={() => setImageFailed(true)}
            className="h-full w-full object-cover"
          />
        </div>
      )
    }
    const badge = fileExtensionBadge(file?.path ?? item.title, file?.content_type)
    const size = file ? formatFileBytes(file.size) : typeLabels.file
    return (
      <div className="flex h-[132px] items-center justify-center overflow-hidden border-b border-border/70 bg-muted/35 px-4">
        <div className="flex min-w-[96px] flex-col items-center gap-1 border border-border bg-background px-4 py-2.5 shadow-2xs">
          <span className="font-mono text-xs font-semibold tracking-wider text-foreground">{badge}</span>
          <span className="text-xs tabular-nums text-fg-tertiary">{size}</span>
        </div>
      </div>
    )
  }

  if (item.type === 'base') {
    return (
      <div className="h-[132px] overflow-hidden border-b border-border/70 bg-muted/35 px-4 pt-3">
        <div aria-hidden className="h-full border border-b-0 border-border/80 bg-background px-3 pt-2.5 shadow-2xs">
          <div className="grid grid-cols-3 gap-2 border-b border-border pb-1.5">
            <span className="h-2 w-12 bg-muted-foreground/25" />
            <span className="h-2 w-10 bg-muted-foreground/20" />
            <span className="h-2 w-8 bg-muted-foreground/20" />
          </div>
          {[0, 1, 2].map(row => (
            <div key={row} className="grid grid-cols-3 gap-2 border-b border-border/60 py-2">
              <span className="h-2 w-14 bg-muted" />
              <span className="h-2 w-9 bg-muted" />
              <span className="h-2 w-11 bg-muted" />
            </div>
          ))}
        </div>
      </div>
    )
  }

  if (item.type === 'applet') {
    return (
      <div className="h-[132px] overflow-hidden border-b border-border/70 bg-muted/35 px-4 pt-3">
        <div aria-hidden className="h-full border border-b-0 border-border/80 bg-background px-3 pt-2.5 shadow-2xs">
          <div className="flex items-center gap-1 border-b border-border/70 pb-2">
            <span className="size-1.5 rounded-full bg-muted-foreground/30" />
            <span className="size-1.5 rounded-full bg-muted-foreground/30" />
            <span className="ml-1 h-2 w-16 bg-muted-foreground/20" />
          </div>
          <div className="mt-2.5 grid grid-cols-2 gap-2">
            <div className="h-12 border border-border/70 bg-muted/40" />
            <div className="h-12 border border-border/70 bg-muted/40" />
          </div>
        </div>
      </div>
    )
  }

  const excerpt = item.excerpt?.trim()
  return (
    <div className="h-[132px] overflow-hidden border-b border-border/70 bg-muted/35 px-4 pt-3">
      <div aria-hidden className="h-full border border-b-0 border-border/80 bg-background px-3.5 pt-3 shadow-2xs">
        <p className="line-clamp-1 text-xs font-semibold text-foreground">{label}</p>
        {excerpt ? (
          <p className="mt-1.5 line-clamp-3 text-xs leading-4 text-fg-secondary">{excerpt}</p>
        ) : (
          <p className="mt-2 text-xs italic text-fg-tertiary">{t('pod.subpages.empty_document')}</p>
        )}
      </div>
    </div>
  )
}
