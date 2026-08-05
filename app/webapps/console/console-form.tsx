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
  RiLoaderLine,
  RiSave3Line
} from '@remixicon/react'
import {
  Children,
  cloneElement,
  isValidElement,
  useEffect,
  useId,
  useLayoutEffect,
  useRef,
  useState,
  type ComponentProps,
  type FormEvent,
  type ReactElement,
  type ReactNode
} from 'react'
import { useTranslation } from 'react-i18next'
import { Link } from 'react-router'
import { PageStack } from './console-page'
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
  contentWidth = 'form',
  description,
  error,
  onSubmit,
  secondary,
  supplementary,
  submitDisabled,
  submitDisabledReason,
  submitUnavailable,
  submitLabel,
  submitting,
  title
}: {
  backTo: string
  children: ReactNode
  contentWidth?: 'form' | 'wide'
  description?: string
  error?: unknown
  onSubmit: () => void
  secondary?: ReactNode
  supplementary?: ReactNode
  submitDisabled?: boolean
  submitDisabledReason?: string
  submitUnavailable?: boolean
  submitLabel?: string
  submitting?: boolean
  title: string
}) {
  const { t } = useTranslation()
  const disabledReasonID = useId()
  const formCompleteness = useFormCompleteness()
  const disabledForNoChanges = Boolean(submitDisabled && !formCompleteness.incomplete)
  const saveDisabled = Boolean(submitting || submitUnavailable || disabledForNoChanges)
  const disabledReason = disabledForNoChanges ? (submitDisabledReason ?? t('common.save_disabled')) : undefined

  const handleSubmit = (event: FormEvent) => {
    event.preventDefault()
    onSubmit()
  }

  return (
    <PageStack className={cn('mx-auto w-full', contentWidth === 'wide' ? 'max-w-6xl' : 'max-w-3xl')}>
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

      <form
        ref={formCompleteness.formRef}
        className="grid gap-6"
        noValidate
        onChange={formCompleteness.refresh}
        onInput={formCompleteness.refresh}
        onSubmit={handleSubmit}>
        <ErrorBlock error={error} />
        <div className="grid gap-5 border border-border bg-card p-5 md:p-6">{children}</div>
        <div className="sticky bottom-0 flex flex-wrap items-center gap-x-3 gap-y-2 border-t border-border bg-background/95 py-4 backdrop-blur">
          <SaveButton
            aria-describedby={disabledReason ? disabledReasonID : undefined}
            disabled={saveDisabled}
            incomplete={formCompleteness.incomplete && !submitting && !submitUnavailable}
            loading={submitting}
            size="sm"
            type="submit">
            {submitLabel ?? t('common.save')}
          </SaveButton>
          <Link to={backTo} className={cn(buttonVariants({ size: 'sm', variant: 'ghost' }))}>
            {t('common.cancel')}
          </Link>
          {disabledReason ? (
            <p id={disabledReasonID} className="basis-full text-xs leading-5 text-muted-foreground" aria-live="polite">
              {disabledReason}
            </p>
          ) : null}
        </div>
      </form>
      {supplementary}
    </PageStack>
  )
}

export function useFormCompleteness() {
  const formRef = useRef<HTMLFormElement>(null)
  const [incomplete, setIncomplete] = useState(false)
  const refresh = () => setIncomplete(Boolean(formRef.current?.querySelector(':invalid')))

  useLayoutEffect(refresh)

  return { formRef, incomplete, refresh }
}

export function SaveButton({
  children,
  className,
  disabled,
  loading = false,
  size,
  ...props
}: ComponentProps<typeof Button> & { loading?: boolean }) {
  const { t } = useTranslation()
  const showIcon = size !== 'xs'

  return (
    <Button
      className={cn(disabled && !loading && 'disabled:bg-muted disabled:text-muted-foreground', className)}
      disabled={loading || disabled}
      size={size}
      {...props}>
      {loading ? <RiLoaderLine className="animate-spin" data-icon="inline-start" /> : null}
      {!loading && showIcon ? <RiSave3Line data-icon="inline-start" /> : null}
      {children ?? t('common.save')}
    </Button>
  )
}

/** A visual and semantic group inside a long editor without adding a nested card. */
export function FormSection({
  children,
  description,
  title
}: {
  children: ReactNode
  description?: string
  title: string
}) {
  const titleID = useId()

  return (
    <section className="grid gap-4 border-t border-border pt-5 first:border-t-0 first:pt-0" aria-labelledby={titleID}>
      <div className="grid gap-1">
        <h3 id={titleID} className="text-sm font-semibold text-foreground">
          {title}
        </h3>
        {description ? <p className="text-xs leading-5 text-muted-foreground">{description}</p> : null}
      </div>
      {children}
    </section>
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
  // Adopting the first element child covers plain and composite controls,
  // including fields that render a sibling `datalist` or hint. The adopted
  // control owns the label, required state, description, and error relation.
  const childList = Children.toArray(children)
  const child = childList.find(
    node =>
      isValidElement<{ id?: string }>(node) &&
      !node.props.id &&
      (typeof node.type !== 'string' || ['input', 'select', 'textarea'].includes(node.type))
  ) as
    | ReactElement<{
        id?: string
        'aria-describedby'?: string
        'aria-invalid'?: boolean
        required?: boolean
      }>
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
              ? cloneElement(child, {
                  id: generatedID,
                  'aria-describedby': describedBy || undefined,
                  'aria-invalid': error ? true : child.props['aria-invalid'],
                  required: required || child.props.required
                })
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
  required,
  value
}: {
  description?: string
  error?: string
  label: string
  minRows?: number
  onChange: (value: string) => void
  required?: boolean
  value: string
}) {
  const { t } = useTranslation()
  const controlID = useId()
  const draft = inspectJSONDraft(value)
  const syntaxError = draft.kind === 'invalid' ? draft.error : undefined
  const formatted = draft.kind === 'valid' ? formatJSONDraft(value) : undefined

  return (
    <LabeledField
      htmlFor={controlID}
      label={label}
      description={description}
      error={error ?? syntaxError}
      required={required}>
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
          id={controlID}
          aria-invalid={error || syntaxError ? true : undefined}
          required={required}
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
