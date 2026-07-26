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
  Empty,
  EmptyDescription,
  EmptyHeader,
  EmptyMedia,
  EmptyTitle,
  Input,
  Skeleton,
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
  Tooltip,
  TooltipContent,
  TooltipTrigger,
  cn
} from '@ankole/uikit'
import {
  RiCloseLine,
  RiDeleteBin6Line,
  RiInboxLine,
  RiMore2Fill,
  RiPencilLine,
  RiRefreshLine,
  RiSearchLine
} from '@remixicon/react'
import { useQueryClient } from '@tanstack/react-query'
import { useState, type ReactNode } from 'react'
import { useTranslation } from 'react-i18next'
import { Link, NavLink } from 'react-router'
import { ErrorBlock } from './console-primitives'

/**
 * List-page frame: title, optional create action, and a data table with
 * consistent loading, empty, and error surfaces. Rows are supplied by the caller
 * so each resource keeps ownership of its columns and cells.
 */
export function ResourceListPage({
  children,
  columns,
  count,
  createLabel,
  createTo,
  description,
  emptyAction,
  emptyDescription,
  emptyTitle,
  error,
  footer,
  isFiltered = false,
  isEmpty,
  isLoading,
  refreshable = true,
  subNav,
  title,
  toolbar
}: {
  children: ReactNode
  columns: string[]
  /** Rows currently rendered. Shown next to the toolbar so a filter reports its effect. */
  count?: number
  createLabel?: string
  createTo?: string
  description?: string
  emptyAction?: ReactNode
  emptyDescription?: string
  emptyTitle?: string
  error?: unknown
  footer?: ReactNode
  isFiltered?: boolean
  isEmpty: boolean
  isLoading: boolean
  /**
   * Refresh refetches every active query, so a route that stacks two of these
   * frames would otherwise show the same button twice doing the same thing.
   */
  refreshable?: boolean
  /** Sibling views of the same nav area, for sections the side nav lists once. */
  subNav?: ReactNode
  title: string
  toolbar?: ReactNode
}) {
  const { t } = useTranslation()
  const queryClient = useQueryClient()
  const hasError = Boolean(error)
  // A search box over a list that has nothing in it is a dead control: it can
  // only ever return the same empty state. It stays while a filter is active,
  // because that is the one case where the operator needs it to get back out.
  const showToolbar = Boolean(toolbar) && (isFiltered || !isEmpty || isLoading)

  return (
    <div className="grid min-w-0 gap-5">
      <PageHeader
        title={title}
        description={description}
        actions={
          <>
            {refreshable ? <RefreshButton /> : null}
            {createTo ? (
              <Link to={createTo} className={cn(buttonVariants({ size: 'sm' }))}>
                {createLabel ?? t('common.new')}
              </Link>
            ) : null}
          </>
        }
      />

      {subNav}
      {showToolbar ? toolbar : null}
      {showToolbar && count !== undefined && !isLoading ? <ResultCount count={count} /> : null}
      <ErrorBlock error={error} />

      {!hasError && isEmpty && !isLoading ? (
        <Empty className="items-start border border-border bg-card text-left">
          <EmptyHeader className="max-w-xl items-start">
            <EmptyMedia variant="icon">
              <RiInboxLine />
            </EmptyMedia>
            <EmptyTitle>
              {isFiltered ? t('console.empty.no_results_title') : (emptyTitle ?? t('console.empty.title'))}
            </EmptyTitle>
            <EmptyDescription className="text-balance">
              {isFiltered ? t('console.empty.no_results_description') : emptyDescription}
            </EmptyDescription>
          </EmptyHeader>
          {/* An empty list is where the create action is most needed, and the page
              header button is the furthest control from where the eye already is.
              A filtered list falls back to nothing: offering "create" to someone
              whose search missed answers a question they did not ask. */}
          {emptyAction ??
            (isFiltered || !createTo ? null : (
              <Link to={createTo} className={cn(buttonVariants({ size: 'sm' }))}>
                {createLabel ?? t('common.new')}
              </Link>
            ))}
        </Empty>
      ) : !hasError ? (
        <div className="overflow-x-auto border border-border bg-card">
          <Table className="min-w-[720px]" aria-busy={isLoading}>
            <TableHeader>
              <TableRow>
                {columns.map(column => (
                  <TableHead key={column}>{column}</TableHead>
                ))}
                <TableHead className="w-0 text-right">
                  <span className="sr-only">{t('console.actions')}</span>
                </TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {isLoading ? (
                <TableRow>
                  <TableCell colSpan={columns.length + 1}>
                    <div className="grid gap-2">
                      <Skeleton className="h-6 w-full" />
                      <Skeleton className="h-6 w-4/5" />
                      <Skeleton className="h-6 w-2/3" />
                    </div>
                  </TableCell>
                </TableRow>
              ) : (
                children
              )}
            </TableBody>
          </Table>
        </div>
      ) : null}
      {footer}
    </div>
  )
}

/**
 * Tab strip over sibling routes of one nav area.
 *
 * The side nav lists an area once, so a second page under it has no entry and
 * becomes unreachable — which is how the principal list sat orphaned behind a
 * URL nothing linked to.
 */
export function SubNav({ items }: { items: { to: string; label: string }[] }) {
  return (
    <nav className="-mt-1 flex min-w-0 flex-wrap gap-1 border-b border-border">
      {items.map(item => (
        <NavLink
          key={item.to}
          to={item.to}
          className={({ isActive }) =>
            cn(
              '-mb-px border-b-2 px-4 py-2 text-sm transition-colors focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary',
              isActive
                ? 'border-primary font-medium text-foreground'
                : 'border-transparent text-muted-foreground hover:border-border hover:text-foreground'
            )
          }>
          {item.label}
        </NavLink>
      ))}
    </nav>
  )
}

/**
 * Refetches every active query on the page and says so while it runs.
 *
 * Refresh used to fire and report nothing: on a fast local request the table
 * blinked, and on a slow one the page looked inert, so the operator clicked
 * again. The icon now spins and the control is disabled until the refetch
 * settles, which is the inline-loading treatment Carbon asks for on the element
 * that started the work.
 */
export function RefreshButton() {
  const { t } = useTranslation()
  const queryClient = useQueryClient()
  const [refreshing, setRefreshing] = useState(false)

  const refresh = () => {
    setRefreshing(true)
    void queryClient.refetchQueries({ type: 'active' }).finally(() => setRefreshing(false))
  }

  return (
    <Tooltip>
      <TooltipTrigger
        render={
          <Button
            aria-label={t('console.aria.refresh')}
            disabled={refreshing}
            size="icon-sm"
            type="button"
            variant="outline"
          />
        }
        onClick={refresh}>
        <RiRefreshLine className={cn(refreshing && 'animate-spin')} />
      </TooltipTrigger>
      <TooltipContent>{t('console.aria.refresh')}</TooltipContent>
    </Tooltip>
  )
}

/**
 * Pager for the cursor-based list endpoints.
 *
 * The server issues an opaque `next_cursor` and no total, so this reports the
 * page it counted and the rows it holds rather than inventing "page 3 of 12".
 * "Previous" is not optional: a next-only control walks the operator forward
 * into a list they cannot walk back out of.
 */
export function CursorPagination({
  hasPrevious,
  nextCursor,
  onNext,
  onPrevious,
  page,
  resultCount
}: {
  hasPrevious: boolean
  nextCursor?: string | null
  onNext: (cursor: string) => void
  onPrevious: () => void
  page: number
  resultCount: number
}) {
  const { t } = useTranslation()

  return (
    <div className="flex flex-wrap items-center justify-between gap-3">
      <span aria-live="polite" className="text-xs text-muted-foreground">
        {t('console.pagination.page_results', { page, count: resultCount })}
      </span>
      <div className="flex items-center gap-2">
        <Button type="button" size="sm" variant="outline" disabled={!hasPrevious} onClick={onPrevious}>
          {t('console.pagination.previous_page')}
        </Button>
        <Button
          type="button"
          size="sm"
          variant="outline"
          disabled={!nextCursor}
          onClick={() => nextCursor && onNext(nextCursor)}>
          {t('console.pagination.next_page')}
        </Button>
      </div>
    </div>
  )
}

/** Live row count for a filtered list, so a search reports what it did. */
export function ResultCount({ count }: { count: number }) {
  const { t } = useTranslation()
  return (
    <p aria-live="polite" className="-mt-3 text-sm text-muted-foreground">
      {t('console.result_count', { count })}
    </p>
  )
}

/**
 * One list toolbar: search on the left, resource filters on the right.
 *
 * Every list used to build its own — a full-width card holding a `max-w-xl`
 * input, a bare bordered box, or two separate boxes with a gap between them —
 * so the same control sat at three different widths on three pages.
 */
export function ResourceSearch({
  filters,
  label,
  onChange,
  placeholder,
  value
}: {
  filters?: ReactNode
  label: string
  onChange: (value: string) => void
  placeholder?: string
  value: string
}) {
  const { t } = useTranslation()

  return (
    <div className="flex min-w-0 flex-wrap items-center gap-x-4 gap-y-2 border border-border bg-card p-2">
      <div className="relative min-w-0 flex-1 basis-72">
        <RiSearchLine
          className="pointer-events-none absolute top-1/2 left-3 size-4 -translate-y-1/2 text-muted-foreground"
          aria-hidden
        />
        <Input
          aria-label={label}
          className="pr-10 pl-10"
          placeholder={placeholder ?? label}
          type="search"
          value={value}
          onChange={event => onChange(event.target.value)}
        />
        {value ? (
          <button
            aria-label={t('console.empty.clear_search')}
            className="absolute inset-y-0 right-0 grid w-10 place-items-center text-muted-foreground hover:text-foreground focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-inset focus-visible:ring-ring"
            type="button"
            onClick={() => onChange('')}>
            <RiCloseLine />
          </button>
        ) : null}
      </div>
      {filters ? <div className="flex min-w-0 flex-wrap items-center gap-3">{filters}</div> : null}
    </div>
  )
}

export function PageHeader({
  actions,
  description,
  title
}: {
  actions?: ReactNode
  description?: string
  title: string
}) {
  return (
    <div className="flex min-w-0 flex-wrap items-end justify-between gap-4 border-b border-border pb-5">
      <div className="grid min-w-0 gap-1">
        <h2 className="text-2xl font-semibold tracking-normal text-foreground">{title}</h2>
        {description ? <p className="max-w-3xl text-sm leading-6 text-muted-foreground">{description}</p> : null}
      </div>
      {actions ? <div className="flex flex-wrap items-center gap-2">{actions}</div> : null}
    </div>
  )
}

/** Right-aligned row actions cell: an edit link plus a confirmed delete. */
export function RowActions({
  deleteConfirm,
  deletePending,
  editLabel,
  editTo,
  onDelete
}: {
  deleteConfirm?: { title: string; description?: string; confirmLabel: string }
  deletePending?: boolean
  editLabel: string
  editTo: string
  onDelete?: () => void
}) {
  const { t } = useTranslation()
  const [confirmOpen, setConfirmOpen] = useState(false)

  // A menu that holds one item charges two clicks for one action and hides it
  // behind a label that names no action. With nothing to choose between, the
  // edit link goes straight into the row.
  if (!onDelete || !deleteConfirm) {
    return (
      <TableCell className="w-12 text-right" onClick={event => event.stopPropagation()}>
        <Link
          aria-label={editLabel}
          title={editLabel}
          to={editTo}
          className={cn(buttonVariants({ size: 'icon-sm', variant: 'ghost' }))}>
          <RiPencilLine />
        </Link>
      </TableCell>
    )
  }

  return (
    <TableCell className="w-12 text-right" onClick={event => event.stopPropagation()}>
      <DropdownMenu>
        <DropdownMenuTrigger
          render={
            <Button
              aria-label={t('common.more_actions')}
              title={t('common.more_actions')}
              size="icon-sm"
              type="button"
              variant="ghost"
            />
          }>
          <RiMore2Fill />
        </DropdownMenuTrigger>
        <DropdownMenuContent align="end" className="w-48">
          <DropdownMenuItem render={<Link to={editTo} />}>
            <RiPencilLine />
            {editLabel}
          </DropdownMenuItem>
          <DropdownMenuItem variant="destructive" disabled={deletePending} onClick={() => setConfirmOpen(true)}>
            <RiDeleteBin6Line />
            {deleteConfirm.confirmLabel}
          </DropdownMenuItem>
        </DropdownMenuContent>
      </DropdownMenu>
      <Dialog open={confirmOpen} onOpenChange={setConfirmOpen}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>{deleteConfirm.title}</DialogTitle>
            {deleteConfirm.description ? <DialogDescription>{deleteConfirm.description}</DialogDescription> : null}
          </DialogHeader>
          <DialogFooter>
            <DialogClose className={cn(buttonVariants({ size: 'sm', variant: 'ghost' }))}>
              {t('common.cancel')}
            </DialogClose>
            <Button
              disabled={deletePending}
              size="sm"
              type="button"
              variant="destructive"
              onClick={() => {
                setConfirmOpen(false)
                onDelete()
              }}>
              {deleteConfirm.confirmLabel}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </TableCell>
  )
}
