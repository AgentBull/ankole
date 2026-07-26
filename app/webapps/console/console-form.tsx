import {
  Badge,
  Button,
  buttonVariants,
  Dialog,
  DialogClose,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
  Field,
  FieldDescription,
  FieldError,
  FieldLabel,
  Input,
  Textarea,
  cn
} from '@ankole/uikit'
import {
  RiArrowLeftLine,
  RiBracesLine,
  RiCheckboxCircleLine,
  RiDeleteBin6Line,
  RiErrorWarningLine,
  RiEyeLine,
  RiEyeOffLine,
  RiInformationLine,
  RiLoaderLine
} from '@remixicon/react'
import {
  Children,
  cloneElement,
  isValidElement,
  useEffect,
  useId,
  useState,
  type ComponentProps,
  type FormEvent,
  type ReactElement,
  type ReactNode
} from 'react'
import { useTranslation } from 'react-i18next'
import { Link } from 'react-router'
import { ErrorBlock } from './console-primitives'
import { formatJSONDraft, inspectJSONDraft } from './state/json-editor'

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
  const { t } = useTranslation()
  const generatedID = useId()
  const describedByID = `${generatedID}-description`
  const errorID = `${generatedID}-error`

  // The label rendered next to the control but was tied to nothing: no caller
  // passed `htmlFor`, and the plain `Input` children carried no `id`, so a
  // screen reader reached an unnamed text box on every form in the console.
  // Adopting the first element child covers every plain input and textarea,
  // including the fields that render a sibling `datalist` or hint next to the
  // control; composite controls that name their own trigger are left alone.
  const childList = Children.toArray(children)
  const child = childList.find(node => isValidElement<{ id?: string }>(node) && !node.props.id) as
    | ReactElement<{ id?: string; 'aria-describedby'?: string }>
    | undefined
  const adoptable = child !== undefined
  const controlID = htmlFor ?? (adoptable ? generatedID : undefined)
  const describedBy = [description ? describedByID : null, error ? errorID : null].filter(Boolean).join(' ')

  return (
    <Field data-invalid={error ? true : undefined}>
      {/* A bare asterisk is a convention the reader has to already know, and it
          reads as nothing at all to a screen reader. The console's forms are
          mostly optional fields, so the few required ones say the word. */}
      <FieldLabel htmlFor={controlID}>
        {label}
        {required ? <span className="ml-1 font-normal text-muted-foreground">{t('common.required')}</span> : null}
      </FieldLabel>
      {adoptable
        ? childList.map(node =>
            node === child
              ? cloneElement(child, { id: generatedID, 'aria-describedby': describedBy || undefined })
              : node
          )
        : children}
      {description ? <FieldDescription id={describedByID}>{description}</FieldDescription> : null}
      {error ? <FieldError id={errorID}>{error}</FieldError> : null}
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
  const { t } = useTranslation()
  const draft = inspectJSONDraft(value)
  const syntaxError = draft.kind === 'invalid' ? draft.error : undefined
  const formatted = draft.kind === 'valid' ? formatJSONDraft(value) : undefined

  return (
    <LabeledField label={label} description={description} error={error ?? syntaxError}>
      <div className="grid gap-2">
        <div className="flex min-h-7 items-center justify-end gap-2">
          {draft.kind === 'valid' ? <Badge variant="success">{t('console.settings.valid_json')}</Badge> : null}
          <Button
            disabled={formatted === undefined || formatted === value}
            size="xs"
            type="button"
            variant="outline"
            onClick={() => formatted !== undefined && onChange(formatted)}>
            <RiBracesLine data-icon="inline-start" />
            {t('console.settings.format_json')}
          </Button>
        </div>
        <Textarea
          aria-invalid={error || syntaxError ? true : undefined}
          className="max-h-[50dvh] overflow-auto font-mono text-xs [resize:vertical]"
          spellCheck={false}
          style={{ minHeight: `${minRows * 1.5}rem` }}
          value={value}
          onChange={event => onChange(event.target.value)}
        />
      </div>
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
