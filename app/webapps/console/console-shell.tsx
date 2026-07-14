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
  Empty,
  EmptyDescription,
  EmptyHeader,
  EmptyMedia,
  EmptyTitle,
  Field,
  FieldDescription,
  FieldError,
  FieldLabel,
  Input,
  Skeleton,
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
  Textarea,
  cn
} from '@ankole/uikit'
import {
  RiArrowLeftLine,
  RiDeleteBin6Line,
  RiEyeLine,
  RiEyeOffLine,
  RiInboxLine,
  RiLoaderLine,
  RiLogoutBoxRLine,
  RiRefreshLine,
  RiRobot2Line,
  RiSettings3Line,
  RiSparkling2Line,
  RiBroadcastLine,
  RiBrainLine,
  RiShieldKeyholeLine,
  RiServerLine,
  RiGitBranchLine,
  RiTerminalBoxLine
} from '@remixicon/react'
import { useMutation, useQueryClient } from '@tanstack/react-query'
import { useState, type ComponentProps, type ComponentType, type FormEvent, type ReactNode } from 'react'
import { useTranslation } from 'react-i18next'
import { Link, NavLink, Outlet } from 'react-router'
import { logoutConsoleSession } from './api/tokens'
import { ErrorBlock } from './console-primitives'

/**
 * Shared shell for the console: the routed layout, list-page and editor-page
 * frames, and the small form building blocks (labeled field, JSON field,
 * destructive confirm) every resource screen reuses.
 *
 * Each resource owns its queries, mutations, and form body; these frames own the
 * consistent chrome — navigation, headers, empty/loading/error surfaces, and the
 * primary/secondary action layout — so the workspaces stop re-deriving it.
 */

type NavItem = {
  to: string
  label: string
  icon: ComponentType<{ className?: string }>
}

const NAV_ITEMS: NavItem[] = [
  { to: '/agents', label: 'console.nav.agents', icon: RiRobot2Line },
  { to: '/providers', label: 'console.nav.providers', icon: RiSparkling2Line },
  { to: '/identity', label: 'console.nav.identity', icon: RiShieldKeyholeLine },
  { to: '/signals', label: 'console.nav.signals', icon: RiBroadcastLine },
  { to: '/workers', label: 'console.nav.workers', icon: RiServerLine },
  { to: '/delegations', label: 'console.nav.delegations', icon: RiGitBranchLine },
  { to: '/brain', label: 'console.nav.brain', icon: RiBrainLine },
  { to: '/worker-envs', label: 'console.nav.worker_envs', icon: RiTerminalBoxLine },
  { to: '/settings', label: 'console.nav.settings', icon: RiSettings3Line }
]

/** Routed console frame: header, sidebar navigation, and the active page outlet. */
export function ConsoleLayout() {
  const { t } = useTranslation()
  const queryClient = useQueryClient()
  const logout = useMutation({
    mutationFn: logoutConsoleSession,
    onSettled: () => window.location.assign('/sessions/new')
  })

  return (
    <div className="min-h-screen bg-background text-foreground">
      <header className="sticky top-0 z-30 flex h-14 items-center justify-between border-b border-border bg-background/95 px-4 backdrop-blur">
        <div className="flex min-w-0 items-center gap-3">
          <div className="grid size-9 place-items-center border border-border bg-muted">
            <RiSettings3Line className="size-4" aria-hidden />
          </div>
          <div className="min-w-0">
            <h1 className="truncate text-base font-semibold tracking-normal">{t('console.title')}</h1>
            <p className="truncate text-xs text-muted-foreground">{t('console.control_plane')}</p>
          </div>
        </div>
        <div className="flex items-center gap-2">
          <Button
            aria-label={t('console.aria.refresh')}
            size="icon-sm"
            type="button"
            variant="outline"
            onClick={() => void queryClient.invalidateQueries()}>
            <RiRefreshLine />
          </Button>
          <Button
            aria-label={t('console.aria.sign_out')}
            disabled={logout.isPending}
            size="icon-sm"
            type="button"
            variant="ghost"
            onClick={() => logout.mutate()}>
            <RiLogoutBoxRLine />
          </Button>
        </div>
      </header>

      <div className="grid min-h-[calc(100vh-3.5rem)] grid-cols-1 lg:grid-cols-[248px_minmax(0,1fr)]">
        <aside className="border-b border-border bg-muted/35 p-3 lg:border-r lg:border-b-0">
          <nav className="grid gap-1" aria-label={t('console.aria.sections')}>
            {NAV_ITEMS.map(item => {
              const Icon = item.icon
              return (
                <NavLink
                  key={item.to}
                  to={item.to}
                  className={({ isActive }) =>
                    cn(
                      'flex h-10 items-center gap-3 border px-3 text-left text-sm transition-colors',
                      isActive
                        ? 'border-primary bg-primary text-primary-foreground'
                        : 'border-transparent text-muted-foreground hover:border-border hover:bg-background hover:text-foreground'
                    )
                  }>
                  <Icon className="size-4" aria-hidden />
                  <span className="truncate">{t(item.label)}</span>
                </NavLink>
              )
            })}
          </nav>
        </aside>

        <main className="min-w-0 p-4 md:p-6 lg:p-8">
          <Outlet />
        </main>
      </div>
    </div>
  )
}

/**
 * List-page frame: title, optional create action, and a data table with
 * consistent loading, empty, and error surfaces. Rows are supplied by the caller
 * so each resource keeps ownership of its columns and cells.
 */
export function ResourceListPage({
  children,
  columns,
  createLabel,
  createTo,
  description,
  emptyDescription,
  emptyTitle,
  error,
  footer,
  isEmpty,
  isLoading,
  title,
  toolbar
}: {
  children: ReactNode
  columns: string[]
  createLabel?: string
  createTo?: string
  description?: string
  emptyDescription?: string
  emptyTitle?: string
  error?: unknown
  footer?: ReactNode
  isEmpty: boolean
  isLoading: boolean
  title: string
  toolbar?: ReactNode
}) {
  const { t } = useTranslation()

  return (
    <div className="grid gap-6">
      <div className="flex flex-wrap items-end justify-between gap-3">
        <div className="grid gap-1">
          <h2 className="text-2xl font-semibold tracking-normal">{title}</h2>
          {description ? <p className="max-w-2xl text-sm leading-6 text-muted-foreground">{description}</p> : null}
        </div>
        {createTo ? (
          <Link to={createTo} className={cn(buttonVariants({ size: 'sm' }))}>
            {createLabel ?? t('common.new')}
          </Link>
        ) : null}
      </div>

      {toolbar}
      <ErrorBlock error={error} />

      {isEmpty && !isLoading ? (
        <Empty className="border border-border bg-card">
          <EmptyHeader>
            <EmptyMedia variant="icon">
              <RiInboxLine />
            </EmptyMedia>
            <EmptyTitle>{emptyTitle ?? t('console.empty.title')}</EmptyTitle>
            {emptyDescription ? <EmptyDescription>{emptyDescription}</EmptyDescription> : null}
          </EmptyHeader>
          {createTo ? (
            <Link to={createTo} className={cn(buttonVariants({ size: 'sm' }))}>
              {createLabel ?? t('common.new')}
            </Link>
          ) : null}
        </Empty>
      ) : (
        <div className="overflow-hidden border border-border bg-card">
          <Table>
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
      )}
      {footer}
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
  return (
    <TableCell className="text-right">
      <div className="flex items-center justify-end gap-1">
        <Link
          to={editTo}
          onClick={event => event.stopPropagation()}
          className={cn(buttonVariants({ size: 'xs', variant: 'ghost' }))}>
          {editLabel}
        </Link>
        {onDelete && deleteConfirm ? (
          <ConfirmDeleteButton confirm={deleteConfirm} pending={deletePending} onConfirm={onDelete} />
        ) : null}
      </div>
    </TableCell>
  )
}

/**
 * Editor-page frame: back link, header, error surface, the form body, and a
 * sticky footer with the primary submit plus a cancel link back to the list.
 * Destructive and out-of-band actions (delete, sync) slot into `secondary`.
 */
export function ResourceEditorPage({
  backTo,
  children,
  description,
  error,
  onSubmit,
  secondary,
  submitLabel,
  submitting,
  title
}: {
  backTo: string
  children: ReactNode
  description?: string
  error?: unknown
  onSubmit: () => void
  secondary?: ReactNode
  submitLabel?: string
  submitting?: boolean
  title: string
}) {
  const { t } = useTranslation()

  const handleSubmit = (event: FormEvent) => {
    event.preventDefault()
    onSubmit()
  }

  return (
    <div className="mx-auto grid max-w-3xl gap-6">
      <div className="grid gap-3">
        <Link
          to={backTo}
          className="inline-flex w-fit items-center gap-1.5 text-sm text-muted-foreground hover:text-foreground">
          <RiArrowLeftLine className="size-4" aria-hidden />
          {t('common.back')}
        </Link>
        <div className="flex flex-wrap items-start justify-between gap-3">
          <div className="grid gap-1">
            <h2 className="text-2xl font-semibold tracking-normal">{title}</h2>
            {description ? <p className="max-w-2xl text-sm leading-6 text-muted-foreground">{description}</p> : null}
          </div>
          {secondary}
        </div>
      </div>

      <form className="grid gap-6" onSubmit={handleSubmit}>
        <ErrorBlock error={error} />
        <div className="grid gap-5 border border-border bg-card p-5 md:p-6">{children}</div>
        <div className="sticky bottom-0 flex flex-wrap items-center gap-3 border-t border-border bg-background/95 py-4 backdrop-blur">
          <Button disabled={submitting} size="sm" type="submit">
            {submitting ? <RiLoaderLine className="animate-spin" data-icon="inline-start" /> : null}
            {submitLabel ?? t('common.save')}
          </Button>
          <Link to={backTo} className={cn(buttonVariants({ size: 'sm', variant: 'ghost' }))}>
            {t('common.cancel')}
          </Link>
        </div>
      </form>
    </div>
  )
}

/** Labeled form field with optional helper text and inline validation error. */
export function LabeledField({
  children,
  description,
  error,
  htmlFor,
  label,
  required
}: {
  children: ReactNode
  description?: string
  error?: string
  htmlFor?: string
  label: string
  required?: boolean
}) {
  return (
    <Field data-invalid={error ? true : undefined}>
      <FieldLabel htmlFor={htmlFor}>
        {label}
        {required ? <span className="text-destructive"> *</span> : null}
      </FieldLabel>
      {children}
      {description ? <FieldDescription>{description}</FieldDescription> : null}
      {error ? <FieldError>{error}</FieldError> : null}
    </Field>
  )
}

/** Password input with a reveal toggle, for entering credentials by hand. */
export function SecretInput({ className, ...props }: ComponentProps<typeof Input>) {
  const { t } = useTranslation()
  const [revealed, setRevealed] = useState(false)

  return (
    <div className="relative">
      <Input
        {...props}
        autoComplete="off"
        className={cn('pr-10', className)}
        spellCheck={false}
        type={revealed ? 'text' : 'password'}
      />
      <button
        aria-label={revealed ? t('console.aria.hide_secret') : t('console.aria.reveal_secret')}
        className="absolute inset-y-0 right-0 grid w-10 place-items-center text-muted-foreground hover:text-foreground"
        tabIndex={-1}
        type="button"
        onClick={() => setRevealed(current => !current)}>
        {revealed ? <RiEyeOffLine className="size-4" /> : <RiEyeLine className="size-4" />}
      </button>
    </div>
  )
}

/** Labeled multiline JSON editor used for genuinely freeform object payloads. */
export function JSONField({
  description,
  error,
  label,
  minRows = 8,
  onChange,
  value
}: {
  description?: string
  error?: string
  label: string
  minRows?: number
  onChange: (value: string) => void
  value: string
}) {
  return (
    <LabeledField label={label} description={description} error={error}>
      <Textarea
        aria-invalid={error ? true : undefined}
        className="font-mono text-xs"
        spellCheck={false}
        style={{ minHeight: `${minRows * 1.5}rem` }}
        value={value}
        onChange={event => onChange(event.target.value)}
      />
    </LabeledField>
  )
}

/** Icon button that opens a confirmation dialog before running a destructive action. */
export function ConfirmDeleteButton({
  confirm,
  onConfirm,
  pending
}: {
  confirm: { title: string; description?: string; confirmLabel: string }
  onConfirm: () => void
  pending?: boolean
}) {
  const { t } = useTranslation()
  const [open, setOpen] = useState(false)

  return (
    <Dialog open={open} onOpenChange={setOpen}>
      <Button
        aria-label={confirm.confirmLabel}
        disabled={pending}
        size="icon-xs"
        type="button"
        variant="ghost"
        onClick={event => {
          event.stopPropagation()
          setOpen(true)
        }}>
        <RiDeleteBin6Line />
      </Button>
      <DialogContent onClick={event => event.stopPropagation()}>
        <DialogHeader>
          <DialogTitle>{confirm.title}</DialogTitle>
          {confirm.description ? <DialogDescription>{confirm.description}</DialogDescription> : null}
        </DialogHeader>
        <DialogFooter>
          <DialogClose className={cn(buttonVariants({ size: 'sm', variant: 'ghost' }))}>
            {t('common.cancel')}
          </DialogClose>
          <Button
            disabled={pending}
            size="sm"
            type="button"
            variant="destructive"
            onClick={() => {
              setOpen(false)
              onConfirm()
            }}>
            {confirm.confirmLabel}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}
