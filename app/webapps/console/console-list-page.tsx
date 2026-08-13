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
  Switch,
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
  cn
} from '@ankole/uikit'
import {
  RiArrowRightLine,
  RiCloseLine,
  RiDeleteBin6Line,
  RiMore2Fill,
  RiPencilLine,
  RiSearchLine
} from '@remixicon/react'
import { useEffect, useRef, useState, type ReactNode } from 'react'
import { useTranslation } from 'react-i18next'
import { Link, NavLink } from 'react-router'
import { PageHeader, PageStack, RefreshButton } from './console-page'
import { ErrorBlock } from '../common/error-block'

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
  emptyIcon,
  emptyTitle,
  error,
  footer,
  isFiltered = false,
  isEmpty,
  isLoading,
  onClearFilters,
  refreshable = true,
  subNav,
  title,
  toolbar,
  toolbarCanRevealRows = false
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
  /** Decorative resource icon. Omit it when the page has no clear resource symbol. */
  emptyIcon?: ReactNode
  emptyTitle?: string
  error?: unknown
  footer?: ReactNode
  isFiltered?: boolean
  isEmpty: boolean
  isLoading: boolean
  onClearFilters?: () => void
  /**
   * Refresh refetches every active query, so a route that stacks two of these
   * frames would otherwise show the same button twice doing the same thing.
   */
  refreshable?: boolean
  /** Sibling views of the same nav area, for sections the side nav lists once. */
  subNav?: ReactNode
  title: string
  toolbar?: ReactNode
  /** Keep the toolbar available when one of its controls can broaden the server query. */
  toolbarCanRevealRows?: boolean
}) {
  const { t } = useTranslation()
  const toolbarRef = useRef<HTMLDivElement>(null)
  const restoreToolbarFocus = useRef(false)
  const hasError = Boolean(error)
  // Hide a toolbar that can only search an empty source. Keep it when a filter
  // is active or one of its controls can broaden the server query.
  const showToolbar = Boolean(toolbar) && (toolbarCanRevealRows || isFiltered || !isEmpty || isLoading)
  // A list has one primary create action. Empty lists place it beside the
  // explanation; populated lists keep it in the page header. Filtered empty
  // lists show only the action that clears the filter.
  const showHeaderCreate = Boolean(createTo) && !hasError && (!isEmpty || isLoading)

  useEffect(() => {
    if (isFiltered || !showToolbar || !restoreToolbarFocus.current) return

    const focusTarget = toolbarRef.current?.querySelector<HTMLElement>(
      'input[type="search"]:not([disabled]), input:not([disabled]), button:not([disabled]), [href], [tabindex]:not([tabindex="-1"])'
    )
    if (!focusTarget) return

    restoreToolbarFocus.current = false
    focusTarget.focus()
  }, [isFiltered, showToolbar])

  const clearFilters = () => {
    restoreToolbarFocus.current = true
    onClearFilters?.()
  }

  return (
    <PageStack>
      <PageHeader
        title={title}
        description={description}
        actions={
          <>
            {refreshable ? <RefreshButton /> : null}
            {showHeaderCreate && createTo ? (
              <Link to={createTo} className={cn(buttonVariants({ size: 'sm' }))}>
                {createLabel ?? t('common.new')}
              </Link>
            ) : null}
          </>
        }
      />

      {subNav}
      {showToolbar ? (
        <div ref={toolbarRef} className="contents">
          {toolbar}
        </div>
      ) : null}
      {showToolbar && count !== undefined && !isLoading ? <ResultCount count={count} /> : null}
      <ErrorBlock error={error} />

      {!hasError && isEmpty && !isLoading ? (
        <Empty className="items-start border border-border bg-card p-8 text-left md:p-10">
          <EmptyHeader className="max-w-xl items-start">
            {emptyIcon ? <EmptyMedia variant="icon">{emptyIcon}</EmptyMedia> : null}
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
          {isFiltered && onClearFilters ? (
            <Button size="sm" type="button" variant="outline" onClick={clearFilters}>
              {t('console.empty.clear_filters')}
            </Button>
          ) : (
            (emptyAction ??
            (!createTo ? null : (
              <Link to={createTo} className={cn(buttonVariants({ size: 'sm' }))}>
                {createLabel ?? t('common.new')}
              </Link>
            )))
          )}
        </Empty>
      ) : !hasError ? (
        <div className="grid gap-2">
          <p className="text-xs text-muted-foreground sm:hidden">{t('console.table.scroll_hint')}</p>
          <Table
            aria-busy={isLoading}
            className="min-w-[640px] [&_td:last-child]:sticky [&_td:last-child]:right-0 [&_td:last-child]:bg-card [&_td:last-child]:transition-colors [&_tbody_tr:hover_td:last-child]:bg-accent [&_tbody_tr:has([aria-expanded=true])_td:last-child]:bg-accent [&_tbody_tr[data-state=selected]_td:last-child]:bg-muted [&_th:last-child]:sticky [&_th:last-child]:right-0 [&_th:last-child]:z-10 [&_th:last-child]:bg-muted"
            containerClassName="border border-border bg-card"
            containerLabel={t('console.table.region_label', { title })}>
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
              {isLoading
                ? Array.from({ length: 4 }, (_, rowIndex) => (
                    <TableRow key={rowIndex}>
                      {columns.map((column, columnIndex) => (
                        <TableCell key={`${column}-${columnIndex}`}>
                          <Skeleton className={cn('h-4', columnIndex === 0 ? 'w-28' : 'w-20')} />
                        </TableCell>
                      ))}
                      <TableCell>
                        <Skeleton className="ml-auto size-9" />
                      </TableCell>
                    </TableRow>
                  ))
                : children}
            </TableBody>
          </Table>
        </div>
      ) : null}
      {footer}
    </PageStack>
  )
}

/**
 * Tab strip over sibling routes of one nav area.
 *
 * The side nav lists an area once, so a second page under it has no entry and
 * becomes unreachable — which is how the principal list sat orphaned behind a
 * URL nothing linked to.
 */
export function SubNav({
  ariaLabel,
  items
}: {
  ariaLabel: string
  /**
   * `end` marks a tab whose path prefixes its siblings, so it matches exactly.
   * `active` forces the highlight for a page whose path does not prefix its tab.
   */
  items: { to: string; label: string; end?: boolean; active?: boolean }[]
}) {
  return (
    <nav aria-label={ariaLabel} className="-mt-1 flex min-w-0 flex-wrap gap-1 border-b border-border">
      {items.map(item => (
        <NavLink
          key={item.to}
          end={item.end}
          to={item.to}
          className={({ isActive }) =>
            cn(
              '-mb-px border-b-2 px-4 py-2 text-sm transition-colors focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary',
              (item.active ?? isActive)
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
      <SearchField
        className="flex-1 basis-72"
        clearLabel={t('console.empty.clear_search')}
        label={label}
        onChange={onChange}
        placeholder={placeholder}
        value={value}
      />
      {filters ? <div className="flex min-w-0 flex-wrap items-center gap-3">{filters}</div> : null}
    </div>
  )
}

/** One searchable text field with a browser-independent visible hint. */
export function SearchField({
  'aria-describedby': ariaDescribedBy,
  className,
  clearLabel,
  id,
  label,
  onChange,
  placeholder,
  value
}: {
  'aria-describedby'?: string
  className?: string
  clearLabel?: string
  id?: string
  label: string
  onChange: (value: string) => void
  placeholder?: string
  value: string
}) {
  const { t } = useTranslation()

  return (
    <div className={cn('relative min-w-0', className)}>
      <RiSearchLine
        className="pointer-events-none absolute top-1/2 left-3 size-4 -translate-y-1/2 text-muted-foreground"
        aria-hidden
      />
      <Input
        aria-describedby={ariaDescribedBy}
        aria-label={label}
        className="pr-10 pl-10"
        id={id}
        type="search"
        value={value}
        onChange={event => onChange(event.target.value)}
      />
      {!value ? (
        <span
          aria-hidden
          className="pointer-events-none absolute inset-y-0 right-10 left-10 flex items-center truncate text-sm leading-5 text-muted-foreground">
          {placeholder ?? label}
        </span>
      ) : null}
      {value ? (
        <button
          aria-label={clearLabel ?? t('console.empty.clear_search')}
          className="absolute inset-y-0 right-0 grid w-10 place-items-center text-muted-foreground hover:text-foreground focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-inset focus-visible:ring-ring"
          type="button"
          onClick={() => onChange('')}>
          <RiCloseLine />
        </button>
      ) : null}
    </div>
  )
}

/**
 * Bordered row of scope or navigation controls for pages without a list
 * toolbar. It stays visible over an empty view because its controls are how
 * the operator brings rows back or leaves.
 */
export function ScopeBar({ children }: { children: ReactNode }) {
  return <div className="flex min-w-0 flex-wrap items-center gap-3 border border-border bg-card p-2">{children}</div>
}

/** Labeled on/off filter, such as widening a list to finished rows. */
export function FilterSwitch({
  checked,
  label,
  onChange
}: {
  checked: boolean
  label: string
  onChange: (checked: boolean) => void
}) {
  return (
    <label className="flex shrink-0 items-center gap-2 text-sm text-muted-foreground">
      <Switch checked={checked} onCheckedChange={onChange} />
      {label}
    </label>
  )
}

/** Truncated monospace cell for the agent that owns a row; the full UID stays in the title. */
export function AgentCell({ uid }: { uid: string }) {
  return (
    <TableCell>
      <span className="block max-w-40 truncate font-mono text-xs" title={uid}>
        {uid}
      </span>
    </TableCell>
  )
}

/** One compact trailing action for a row that opens a read-only view. */
export function RowViewAction(
  props: { label: string } & ({ onOpen: () => void; to?: never } | { onOpen?: never; to: string })
) {
  return (
    <TableCell className="w-12 text-right" onClick={event => event.stopPropagation()}>
      {props.to !== undefined ? (
        <Link
          aria-label={props.label}
          className={cn(buttonVariants({ size: 'icon-sm', variant: 'ghost' }))}
          title={props.label}
          to={props.to}>
          <RiArrowRightLine aria-hidden />
        </Link>
      ) : (
        <Button
          aria-label={props.label}
          size="icon-sm"
          title={props.label}
          type="button"
          variant="ghost"
          onClick={props.onOpen}>
          <RiArrowRightLine aria-hidden />
        </Button>
      )}
    </TableCell>
  )
}

/** Right-aligned edit link that becomes a menu when the row has another action. */
export type RowAction = { icon?: ReactNode; label: string; pending?: boolean; onAction: () => void }

export function RowActions({
  actions = [],
  deleteConfirm,
  deletePending,
  editLabel,
  editTo,
  onDelete
}: {
  actions?: RowAction[]
  /** `icon` names a non-delete confirmed action in the menu; the default is the trash icon. */
  deleteConfirm?: { title: string; description?: string; confirmLabel: string; icon?: ReactNode }
  deletePending?: boolean
  editLabel: string
  editTo: string
  onDelete?: () => void
}) {
  const { t } = useTranslation()
  const [confirmOpen, setConfirmOpen] = useState(false)
  const actionTriggerRef = useRef<HTMLButtonElement>(null)

  // A menu that holds one item charges two clicks for one action and hides it
  // behind a label that names no action. With nothing to choose between, the
  // edit link goes straight into the row.
  if (actions.length === 0 && (!onDelete || !deleteConfirm)) {
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
              ref={actionTriggerRef}
              aria-label={t('common.more_actions')}
              className="aria-expanded:bg-transparent hover:aria-expanded:bg-transparent"
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
          {actions.map(action => (
            <DropdownMenuItem key={action.label} disabled={action.pending} onClick={action.onAction}>
              {action.icon}
              {action.label}
            </DropdownMenuItem>
          ))}
          {onDelete && deleteConfirm ? (
            <DropdownMenuItem variant="destructive" disabled={deletePending} onClick={() => setConfirmOpen(true)}>
              {deleteConfirm.icon ?? <RiDeleteBin6Line />}
              {deleteConfirm.confirmLabel}
            </DropdownMenuItem>
          ) : null}
        </DropdownMenuContent>
      </DropdownMenu>
      {onDelete && deleteConfirm ? (
        <Dialog
          open={confirmOpen}
          onOpenChange={setConfirmOpen}
          onOpenChangeComplete={open => {
            if (!open) actionTriggerRef.current?.focus()
          }}>
          <DialogContent closeLabel={t('common.close')}>
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
      ) : null}
    </TableCell>
  )
}
