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
  Field,
  FieldDescription,
  FieldError,
  FieldLabel,
  Input,
  Skeleton,
  Sheet,
  SheetClose,
  SheetContent,
  SheetDescription,
  SheetHeader,
  SheetTitle,
  SheetTrigger,
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
  Textarea,
  Tooltip,
  TooltipContent,
  TooltipProvider,
  TooltipTrigger,
  Badge,
  cn
} from '@ankole/uikit'
import {
  RiArrowLeftLine,
  RiCheckboxCircleLine,
  RiCloseLine,
  RiDeleteBin6Line,
  RiErrorWarningLine,
  RiEyeLine,
  RiEyeOffLine,
  RiInformationLine,
  RiInboxLine,
  RiLoaderLine,
  RiLogoutBoxRLine,
  RiMenuLine,
  RiMore2Fill,
  RiPencilLine,
  RiRefreshLine,
  RiRobot2Line,
  RiSearchLine,
  RiSettings3Line,
  RiSparkling2Line,
  RiBroadcastLine,
  RiBrainLine,
  RiShieldKeyholeLine,
  RiServerLine,
  RiGitBranchLine,
  RiTerminalBoxLine,
  RiChat3Line
} from '@remixicon/react'
import { useMutation, useQueryClient } from '@tanstack/react-query'
import { useEffect, useState, type ComponentProps, type ComponentType, type FormEvent, type ReactNode } from 'react'
import { useTranslation } from 'react-i18next'
import { Link, NavLink, Outlet } from 'react-router'
import { ThemeToggle } from '../common/theme-toggle'
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
  { to: '/conversations', label: 'console.nav.conversations', icon: RiChat3Line },
  { to: '/brain', label: 'console.nav.brain', icon: RiBrainLine },
  { to: '/worker-envs', label: 'console.nav.worker_envs', icon: RiTerminalBoxLine },
  { to: '/settings', label: 'console.nav.settings', icon: RiSettings3Line }
]

/** Routed console frame: header, sidebar navigation, and the active page outlet. */
export function ConsoleLayout() {
  const { t } = useTranslation()
  const [navigationOpen, setNavigationOpen] = useState(false)
  const logout = useMutation({
    mutationFn: logoutConsoleSession,
    onSettled: () => window.location.assign('/sessions/new')
  })

  return (
    <TooltipProvider>
      <div className="min-h-screen bg-background text-foreground">
        <header className="sticky top-0 z-30 flex h-12 items-center justify-between border-b border-border bg-background px-3 text-foreground">
          <div className="flex min-w-0 items-center gap-3">
            <Sheet open={navigationOpen} onOpenChange={setNavigationOpen}>
              <SheetTrigger
                render={
                  <Button aria-label={t('console.aria.open_navigation')} size="icon-sm" type="button" variant="ghost" />
                }
                className="hover:bg-accent hover:text-accent-foreground lg:hidden">
                <RiMenuLine />
              </SheetTrigger>
              <SheetContent
                side="left"
                showCloseButton={false}
                className="w-[min(320px,88vw)] border-border bg-background p-0 text-foreground">
                <SheetHeader className="flex-row items-center justify-between border-b border-border p-3">
                  <div className="grid min-w-0 gap-0.5">
                    <SheetTitle className="truncate text-base text-foreground">{t('console.title')}</SheetTitle>
                    <SheetDescription className="truncate text-muted-foreground">
                      {t('console.control_plane')}
                    </SheetDescription>
                  </div>
                  <SheetClose
                    render={<Button aria-label={t('common.close')} size="icon-sm" type="button" variant="ghost" />}
                    className="hover:bg-accent hover:text-accent-foreground">
                    <RiCloseLine />
                  </SheetClose>
                </SheetHeader>
                <ConsoleNavigation onNavigate={() => setNavigationOpen(false)} />
              </SheetContent>
            </Sheet>
            <div className="grid size-8 place-items-center bg-primary text-primary-foreground">
              <RiSettings3Line className="size-4" aria-hidden />
            </div>
            <div className="min-w-0">
              <h1 className="truncate text-sm font-semibold tracking-normal text-foreground">{t('console.title')}</h1>
              <p className="hidden truncate text-xs text-muted-foreground sm:block">{t('console.control_plane')}</p>
            </div>
          </div>
          <div className="flex items-center gap-2">
            <ThemeToggle />
            <Tooltip>
              <TooltipTrigger
                render={
                  <Button
                    aria-label={t('console.aria.sign_out')}
                    disabled={logout.isPending}
                    size="icon-sm"
                    type="button"
                    variant="ghost"
                  />
                }
                className="hover:bg-accent hover:text-accent-foreground"
                onClick={() => logout.mutate()}>
                <RiLogoutBoxRLine />
              </TooltipTrigger>
              <TooltipContent>{t('console.aria.sign_out')}</TooltipContent>
            </Tooltip>
          </div>
        </header>

        <div className="grid min-h-[calc(100vh-3rem)] lg:grid-cols-[256px_minmax(0,1fr)]">
          <aside className="sticky top-12 hidden h-[calc(100vh-3rem)] flex-col border-r border-border bg-background lg:flex">
            <ConsoleNavigation />
          </aside>

          <main className="min-w-0 p-4 md:p-6 xl:p-8">
            <Outlet />
          </main>
        </div>
      </div>
    </TooltipProvider>
  )
}

function ConsoleNavigation({ onNavigate }: { onNavigate?: () => void }) {
  const { t } = useTranslation()
  const version = systemVersion()

  return (
    <div className="flex min-h-0 flex-1 flex-col">
      <nav
        className="grid min-h-0 flex-1 content-start gap-0.5 overflow-y-auto p-3"
        aria-label={t('console.aria.sections')}>
        {NAV_ITEMS.map(item => {
          const Icon = item.icon
          return (
            <NavLink
              key={item.to}
              to={item.to}
              onClick={onNavigate}
              className={({ isActive }) =>
                cn(
                  'flex min-h-10 items-center gap-3 border-l-4 px-3 py-2 text-left text-sm transition-colors focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary',
                  isActive
                    ? 'border-primary bg-accent text-accent-foreground'
                    : 'border-transparent text-muted-foreground hover:bg-accent hover:text-accent-foreground'
                )
              }>
              <Icon className="size-4 shrink-0" aria-hidden />
              <span className="truncate">{t(item.label)}</span>
            </NavLink>
          )
        })}
      </nav>
      <footer className="border-t border-border px-6 py-3 text-xs text-muted-foreground">
        <span className="block truncate" title={version}>
          Ankole {version}
        </span>
      </footer>
    </div>
  )
}

function systemVersion(): string {
  return document.querySelector<HTMLMetaElement>('meta[name="ankole-version"]')?.content.trim() || 'development'
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
  emptyAction,
  emptyDescription,
  emptyTitle,
  error,
  footer,
  isFiltered = false,
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
  emptyAction?: ReactNode
  emptyDescription?: string
  emptyTitle?: string
  error?: unknown
  footer?: ReactNode
  isFiltered?: boolean
  isEmpty: boolean
  isLoading: boolean
  title: string
  toolbar?: ReactNode
}) {
  const { t } = useTranslation()
  const queryClient = useQueryClient()
  const hasError = Boolean(error)

  return (
    <div className="grid min-w-0 gap-5">
      <PageHeader
        title={title}
        description={description}
        actions={
          <>
            <Tooltip>
              <TooltipTrigger
                render={
                  <Button aria-label={t('console.aria.refresh')} size="icon-sm" type="button" variant="outline" />
                }
                onClick={() => void queryClient.refetchQueries({ type: 'active' })}>
                <RiRefreshLine />
              </TooltipTrigger>
              <TooltipContent>{t('console.aria.refresh')}</TooltipContent>
            </Tooltip>
            {createTo ? (
              <Link to={createTo} className={cn(buttonVariants({ size: 'sm' }))}>
                {createLabel ?? t('common.new')}
              </Link>
            ) : null}
          </>
        }
      />

      {toolbar}
      <ErrorBlock error={error} />

      {!hasError && isEmpty && !isLoading ? (
        <Empty className="items-start border border-border bg-card text-left">
          <EmptyHeader className="items-start">
            <EmptyMedia variant="icon">
              <RiInboxLine />
            </EmptyMedia>
            <EmptyTitle>
              {isFiltered ? t('console.empty.no_results_title') : (emptyTitle ?? t('console.empty.title'))}
            </EmptyTitle>
            <EmptyDescription>
              {isFiltered ? t('console.empty.no_results_description') : emptyDescription}
            </EmptyDescription>
          </EmptyHeader>
          {emptyAction}
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

export function ResourceSearch({
  label,
  onChange,
  placeholder,
  value
}: {
  label: string
  onChange: (value: string) => void
  placeholder?: string
  value: string
}) {
  const { t } = useTranslation()

  return (
    <div className="flex min-h-14 min-w-0 items-center border border-border bg-card p-2">
      <div className="relative w-full max-w-xl">
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
          {onDelete && deleteConfirm ? (
            <DropdownMenuItem variant="destructive" disabled={deletePending} onClick={() => setConfirmOpen(true)}>
              <RiDeleteBin6Line />
              {deleteConfirm.confirmLabel}
            </DropdownMenuItem>
          ) : null}
        </DropdownMenuContent>
      </DropdownMenu>
      {onDelete && deleteConfirm ? (
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
      ) : null}
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
  supplementary,
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
  supplementary?: ReactNode
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
    <div className="mx-auto grid max-w-4xl gap-6">
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
      {supplementary}
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

  useEffect(() => {
    if (!revealed) return
    const remask = () => setRevealed(false)
    const timeout = window.setTimeout(remask, 30_000)
    window.addEventListener('blur', remask)
    return () => {
      window.clearTimeout(timeout)
      window.removeEventListener('blur', remask)
    }
  }, [revealed])

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
        className="absolute inset-y-0 right-0 grid w-10 place-items-center text-muted-foreground hover:text-foreground focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-inset focus-visible:ring-ring"
        title={revealed ? t('console.aria.hide_secret') : t('console.aria.reveal_secret')}
        type="button"
        onClick={() => setRevealed(current => !current)}>
        {revealed ? <RiEyeOffLine className="size-4" /> : <RiEyeLine className="size-4" />}
      </button>
    </div>
  )
}

/** Readable, selectable presentation for values that are immutable in this editor. */
export function ReadOnlyValue({ children, mono = false }: { children: ReactNode; mono?: boolean }) {
  return (
    <div
      className={cn(
        'min-h-10 border-b border-input bg-background px-4 py-2 text-sm leading-6 text-foreground',
        mono && 'font-mono text-xs'
      )}>
      {children === null || children === undefined || children === '' ? '—' : children}
    </div>
  )
}

/** Semantic status treatment. Brand color stays reserved for selection and primary actions. */
export function StatusIndicator({
  children,
  tone = 'neutral'
}: {
  children: ReactNode
  tone?: 'danger' | 'info' | 'neutral' | 'positive' | 'warning'
}) {
  const Icon =
    tone === 'positive'
      ? RiCheckboxCircleLine
      : tone === 'danger' || tone === 'warning'
        ? RiErrorWarningLine
        : RiInformationLine
  const variant =
    tone === 'positive'
      ? 'success'
      : tone === 'danger'
        ? 'destructive'
        : tone === 'warning'
          ? 'warning'
          : tone === 'info'
            ? 'info'
            : 'secondary'

  return (
    <Badge variant={variant}>
      <Icon aria-hidden />
      {children}
    </Badge>
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
        title={confirm.confirmLabel}
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
