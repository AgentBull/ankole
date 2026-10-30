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
  Textarea,
  cn,
  type CronEditorLabels
} from '@ankole/uikit'
import type { TFunction } from 'i18next'
import {
  RiBracesLine,
  RiAlertLine,
  RiCheckboxCircleLine,
  RiCloseCircleLine,
  RiDeleteBin6Line,
  RiInformationLine,
  RiLoaderLine,
  RiQuestionLine,
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
import { useBlocker } from '@tanstack/react-router'
import { BackLink, DocumentTitle, PageStack } from './console-page'
import { ErrorBlock } from '../common/error-block'
import { formatJSONDraft, inspectJSONDraft } from './state/json-editor'

/**
 * Editor-page frame: back link, header, error surface, the form body, and a
 * sticky footer with the primary submit. The header back link owns navigation
 * away from the editor.
 * Destructive and out-of-band actions (delete, sync) slot into `secondary`.
 */
// Read-only mode drops the submit bar and disables every field, which makes
// the submit cluster meaningless. The union keeps that combination
// unrepresentable: a caller either provides the submit contract or declares
// the page read-only, never both.
type ResourceEditorModeProps =
  | {
      readOnly: true
      onSubmit?: never
      submitDisabled?: never
      submitDisabledReason?: never
      submitUnavailable?: never
      submitLabel?: never
      submitting?: never
    }
  | {
      readOnly?: false
      onSubmit: () => void
      submitDisabled?: boolean
      submitDisabledReason?: string
      submitUnavailable?: boolean
      submitLabel?: string
      submitting?: boolean
    }

export function ResourceEditorPage({
  backTo,
  children,
  contentWidth = 'form',
  description,
  dirty,
  error,
  onSubmit,
  readOnly = false,
  secondary,
  supplementary,
  supplementaryDirty = false,
  submitDisabled,
  submitDisabledReason,
  submitUnavailable,
  submitLabel,
  submitting,
  title,
  validationError
}: {
  backTo: string
  children: ReactNode
  contentWidth?: 'form' | 'wide'
  description?: string
  /**
   * Unsaved-draft flag. When provided, leaving the editor page with a dirty
   * draft asks for confirmation (in-app navigation and tab close), and the
   * footer shows an unsaved hint. The ordinary guard stands down while
   * submitting so an acknowledged save can navigate. Use supplementaryDirty
   * for drafts that remain editable during the request.
   */
  dirty?: boolean
  error?: unknown
  secondary?: ReactNode
  supplementary?: ReactNode
  /** Draft changes that must also block navigation during the main save. */
  supplementaryDirty?: boolean
  title: string
  /** A page-level draft problem. It renders without the request-failure title. */
  validationError?: string
} & ResourceEditorModeProps) {
  const { t } = useTranslation()
  const disabledReasonID = useId()
  const formCompleteness = useFormCompleteness()
  const disabledForNoChanges = Boolean(submitDisabled && !formCompleteness.incomplete)
  const saveDisabled = Boolean(submitting || submitUnavailable || disabledForNoChanges)
  const disabledReason = disabledForNoChanges ? (submitDisabledReason ?? t('common.save_disabled')) : undefined
  const errorBlockRef = useRef<HTMLDivElement>(null)

  // A server rejection lands while the operator sits at the sticky footer of a
  // long form; the error renders at the top, so bring it into the viewport.
  useEffect(() => {
    if (error || validationError) errorBlockRef.current?.scrollIntoView({ block: 'nearest', behavior: 'smooth' })
  }, [error, validationError])

  const handleSubmit = (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault()
    const form = event.currentTarget
    if (!form.reportValidity()) {
      // The capture handler below cancels every native validation bubble, so
      // the report cannot move focus on its own.
      focusFirstInvalidControl(form)
      return
    }
    onSubmit?.()
  }

  return (
    <PageStack className={cn('mx-auto w-full', contentWidth === 'wide' ? 'max-w-6xl' : 'max-w-3xl')}>
      <DocumentTitle title={title} />
      <div className="grid gap-3">
        <BackLink to={backTo} />
        <div className="flex flex-wrap items-start justify-between gap-3">
          <div className="grid gap-1">
            <h2 className="title-page">{title}</h2>
            {description ? <p className="max-w-2xl text-sm leading-6 text-muted-foreground">{description}</p> : null}
          </div>
          {secondary}
        </div>
      </div>

      {readOnly || (dirty === undefined && !supplementaryDirty) ? null : (
        <EditorNavigationGuard blocked={Boolean((dirty && !submitting) || supplementaryDirty)} />
      )}
      <form
        ref={formCompleteness.formRef}
        className="grid gap-6"
        noValidate
        onChange={formCompleteness.refresh}
        onInput={formCompleteness.refresh}
        // The browser bubble carries the browser locale, not the app locale.
        // Cancel it here once; LabeledField and ConfigField render the message
        // next to the control instead.
        onInvalidCapture={event => event.preventDefault()}
        onSubmit={handleSubmit}>
        {validationError || error ? (
          <div ref={errorBlockRef} className="grid gap-6">
            {validationError ? <ErrorBlock title={t('common.form_invalid')} error={validationError} /> : null}
            <ErrorBlock error={error} />
          </div>
        ) : null}
        <div className="grid gap-5 border border-border bg-card p-5 md:p-6">
          {readOnly ? (
            <fieldset className="contents" disabled>
              {children}
            </fieldset>
          ) : (
            children
          )}
        </div>
        {readOnly ? null : (
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
            {dirty && !submitting ? (
              <span className="text-xs text-muted-foreground">{t('common.unsaved_changes')}</span>
            ) : null}
            {disabledReason ? (
              <p
                id={disabledReasonID}
                className="basis-full text-xs leading-5 text-muted-foreground"
                aria-live="polite">
                {disabledReason}
              </p>
            ) : null}
          </div>
        )}
      </form>
      {supplementary}
    </PageStack>
  )
}

/**
 * Not-found frame for an editor whose resource does not exist: the editor's
 * back link plus the page-level error, at the editor frame's form width.
 */
export function EditorNotFound({ backTo, message }: { backTo: string; message: string }) {
  const { t } = useTranslation()
  return (
    <PageStack className="mx-auto w-full max-w-3xl">
      <BackLink to={backTo} />
      <ErrorBlock title={t('console.not_found.title')} error={new Error(message)} />
    </PageStack>
  )
}

/** Warns before tab close or reload while a draft is dirty. */
function useBeforeUnloadGuard(blocked: boolean) {
  useEffect(() => {
    if (!blocked) return
    const warn = (event: BeforeUnloadEvent) => event.preventDefault()
    window.addEventListener('beforeunload', warn)
    return () => window.removeEventListener('beforeunload', warn)
  }, [blocked])
}

/**
 * In-app navigation and tab-close guard for a dirty draft. Only a pathname
 * change counts as leaving: search-param writes such as an editor's own
 * `?agent=` scope stay free. It lives in its own component so callers without
 * a draft never reach `useBlocker`, which requires a data router.
 */
export function EditorNavigationGuard({ blocked }: { blocked: boolean }) {
  const blocker = useBlocker({
    shouldBlockFn: ({ current, next }) => blocked && current.pathname !== next.pathname,
    enableBeforeUnload: false,
    withResolver: true
  })
  useBeforeUnloadGuard(blocked)

  return (
    <DiscardConfirmDialog
      open={blocker.status === 'blocked'}
      onDiscard={() => blocker.proceed?.()}
      onKeep={() => blocker.reset?.()}
    />
  )
}

/**
 * Shows one confirmation dialog for each request to discard a draft.
 * Closing the dialog or pressing Escape keeps the draft.
 */
export function DiscardConfirmDialog({
  onDiscard,
  onKeep,
  open
}: {
  onDiscard: () => void
  onKeep: () => void
  open: boolean
}) {
  const { t } = useTranslation()

  return (
    <Dialog open={open} onOpenChange={nextOpen => !nextOpen && onKeep()}>
      <DialogContent closeLabel={t('common.close')}>
        <DialogHeader>
          <DialogTitle>{t('common.discard_title')}</DialogTitle>
          <DialogDescription>{t('common.discard_description')}</DialogDescription>
        </DialogHeader>
        <DialogFooter>
          <DialogClose render={<Button variant="outline" />}>{t('common.keep_editing')}</DialogClose>
          <Button variant="destructive" onClick={onDiscard}>
            {t('common.discard')}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}

/**
 * Controls close requests for a dialog that contains a draft. Use
 * `requestOpenChange` for user requests to close the dialog. The hook keeps
 * the dialog open while a request is pending. Call `onOpenChange` directly
 * after a successful save.
 */
export function useDialogDiscardGuard({
  dirty,
  onOpenChange,
  pending
}: {
  dirty: boolean
  onOpenChange: (open: boolean) => void
  pending: boolean
}) {
  const [confirmRequested, setConfirmRequested] = useState(false)

  return {
    confirming: dirty && confirmRequested,
    confirmDiscard: () => {
      setConfirmRequested(false)
      onOpenChange(false)
    },
    keepEditing: () => setConfirmRequested(false),
    requestOpenChange: (open: boolean) => {
      if (open) {
        setConfirmRequested(false)
        onOpenChange(true)
      } else if (pending) return
      else if (dirty) setConfirmRequested(true)
      else {
        setConfirmRequested(false)
        onOpenChange(false)
      }
    }
  }
}

export function useFormCompleteness() {
  const formRef = useRef<HTMLFormElement>(null)
  const [incomplete, setIncomplete] = useState(false)
  const refresh = () => setIncomplete(Boolean(formRef.current?.querySelector(':invalid')))

  useLayoutEffect(refresh)

  return { formRef, incomplete, refresh }
}

/**
 * Jumps to the first control that failed `reportValidity()`. Forms outside
 * `ResourceEditorPage` reuse this together with an `onInvalidCapture` that
 * cancels the browser bubble, so every console form intercepts the same way.
 */
export function focusFirstInvalidControl(form: HTMLFormElement) {
  const control = form.querySelector<HTMLElement>(':invalid:not(fieldset)')
  if (!control) return
  control.scrollIntoView({ block: 'center' })
  control.focus({ preventScroll: true })
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

export function LabeledField({
  children,
  description,
  error,
  htmlFor,
  invalidError,
  label,
  required
}: {
  children: ReactNode
  description?: string
  error?: string
  htmlFor?: string
  /** Replaces the generic invalid text when the control fails for a page-specific reason such as a pattern. */
  invalidError?: string
  label: string
  required?: boolean
}) {
  const { t } = useTranslation()
  const generatedID = useId()
  const describedByID = `${generatedID}-description`
  const errorID = `${generatedID}-error`
  const [nativeInvalid, setNativeInvalid] = useState<'missing' | 'invalid'>()
  const clearNativeInvalid = () => setNativeInvalid(undefined)
  const shownError =
    error ??
    (nativeInvalid === 'missing'
      ? t('common.field_required', { field: label })
      : nativeInvalid
        ? (invalidError ?? t('common.field_invalid', { field: label }))
        : undefined)

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
  const describedBy = [description ? describedByID : null, shownError ? errorID : null].filter(Boolean).join(' ')

  return (
    // The `invalid` event does not bubble, so only a capture listener sees a
    // descendant control fail `reportValidity()` — including the hidden input
    // a composite control such as Select renders for form participation. Blur
    // re-evaluates the control so a field the user leaves incomplete says so
    // at once, with a trim check because native `required` accepts blanks.
    // Any interaction clears the message until the next blur or submit.
    <Field
      data-invalid={shownError ? true : undefined}
      onChangeCapture={clearNativeInvalid}
      onClickCapture={clearNativeInvalid}
      onInputCapture={clearNativeInvalid}
      onKeyDownCapture={clearNativeInvalid}
      onBlurCapture={event => {
        const control = event.target
        if (!(control instanceof HTMLInputElement || control instanceof HTMLTextAreaElement)) return
        if (!control.willValidate) return
        if (control.validity.valueMissing || (control.required && !control.value.trim())) {
          setNativeInvalid('missing')
        } else if (!control.validity.valid) {
          setNativeInvalid('invalid')
        } else {
          setNativeInvalid(undefined)
        }
      }}
      onInvalidCapture={event => {
        const control = event.target as HTMLInputElement
        setNativeInvalid(control.validity?.valueMissing ? 'missing' : 'invalid')
      }}>
      {/* A bare asterisk is a convention the reader has to already know, and it
          reads as nothing at all to a screen reader. The console's forms are
          mostly optional fields, so the few required ones say the word. */}
      <FieldLabel htmlFor={controlID}>
        {label}
        {required ? (
          <>
            {' '}
            <span className="font-normal text-muted-foreground">{t('common.required')}</span>
          </>
        ) : null}
      </FieldLabel>
      {adoptable
        ? childList.map(node =>
            node === child
              ? cloneElement(child, {
                  id: generatedID,
                  'aria-describedby': describedBy || undefined,
                  'aria-invalid': shownError ? true : child.props['aria-invalid'],
                  required: required || child.props.required
                })
              : node
          )
        : children}
      {description ? <FieldDescription id={describedByID}>{description}</FieldDescription> : null}
      {shownError ? <FieldError id={errorID}>{shownError}</FieldError> : null}
    </Field>
  )
}

/** Readable, selectable presentation for values that are immutable in this editor. */
export function ReadOnlyValue({ children, mono = false }: { children: ReactNode; mono?: boolean }) {
  return (
    <div
      className={cn(
        'flex min-h-8 cursor-default items-center rounded-control border border-field-edge border-b-input bg-muted px-3 py-1.5 text-sm leading-5 text-muted-foreground',
        mono && 'font-mono text-xs leading-5'
      )}>
      {children === null || children === undefined || children === '' ? '—' : children}
    </div>
  )
}

export type StatusTone = 'danger' | 'info' | 'neutral' | 'positive' | 'waiting' | 'warning'

/**
 * Status colors follow the common convention: red is failure, amber is something that needs a person (a
 * warning, or a question that waits for an answer), green is success, blue is work in progress or
 * information, and gray is the rest. Each tone also has its own icon, because amber and red marks look
 * alike to people with red-green color blindness. Berry is never a status: next to red it reads as an error.
 */
const STATUS_TONES = {
  danger: { Icon: RiCloseCircleLine, variant: 'destructive' },
  warning: { Icon: RiAlertLine, variant: 'warning' },
  waiting: { Icon: RiQuestionLine, variant: 'warning' },
  positive: { Icon: RiCheckboxCircleLine, variant: 'success' },
  info: { Icon: RiInformationLine, variant: 'info' },
  neutral: { Icon: RiInformationLine, variant: 'secondary' }
} as const satisfies Record<StatusTone, unknown>

export function StatusIndicator({ children, tone = 'neutral' }: { children: ReactNode; tone?: StatusTone }) {
  const { Icon, variant } = STATUS_TONES[tone]

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
  const draft = inspectJSONDraft(value)
  const syntaxError = draft.kind === 'invalid' ? draft.error : undefined
  const formatted = draft.kind === 'valid' ? formatJSONDraft(value) : undefined

  // The Textarea stays a direct child so LabeledField adopts it: the label,
  // description, error, invalid state, and required relation all reach the
  // control. A wrapping div used to block adoption, so the field never
  // announced the syntax error.
  return (
    <LabeledField label={label} description={description} error={error ?? syntaxError} required={required}>
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
        className="max-h-[50dvh] overflow-auto font-mono text-xs [resize:vertical]"
        spellCheck={false}
        style={{ minHeight: `${minRows * 1.5}rem` }}
        value={value}
        onChange={event => onChange(event.target.value)}
      />
    </LabeledField>
  )
}

export function cronEditorLabels(t: TFunction): CronEditorLabels {
  return {
    mode: t('common.cron_mode'),
    modes: {
      every_minutes: t('common.cron_mode_every_minutes'),
      hourly: t('common.cron_mode_hourly'),
      daily: t('common.cron_mode_daily'),
      weekly: t('common.cron_mode_weekly'),
      monthly: t('common.cron_mode_monthly'),
      custom: t('common.cron_mode_custom')
    },
    interval: t('common.cron_interval'),
    minute: t('common.cron_minute'),
    time: t('common.cron_time'),
    weekday: t('common.cron_weekday'),
    weekdays: [
      t('common.cron_weekday_sun'),
      t('common.cron_weekday_mon'),
      t('common.cron_weekday_tue'),
      t('common.cron_weekday_wed'),
      t('common.cron_weekday_thu'),
      t('common.cron_weekday_fri'),
      t('common.cron_weekday_sat')
    ],
    dayOfMonth: t('common.cron_day_of_month'),
    expression: t('common.cron_expression')
  }
}

/** Button that opens a confirmation dialog before running a destructive action. */
export function ConfirmDeleteButton({
  confirm,
  icon,
  label,
  onConfirm,
  pending,
  size,
  variant
}: {
  confirm: { title: string; description?: string; confirmLabel: string }
  /** Icon for the compact form when the action is not a delete; the default is the trash icon. */
  icon?: ReactNode
  /** Text form for form and toolbar placements; the default is the compact icon form. */
  label?: string
  onConfirm: () => void
  pending?: boolean
  size?: ComponentProps<typeof Button>['size']
  variant?: ComponentProps<typeof Button>['variant']
}) {
  const { t } = useTranslation()
  const [open, setOpen] = useState(false)

  return (
    <Dialog open={open} onOpenChange={setOpen}>
      <Button
        aria-label={label ? undefined : confirm.confirmLabel}
        title={label ? undefined : confirm.confirmLabel}
        disabled={pending}
        size={size ?? (label ? 'xs' : 'icon-xs')}
        type="button"
        variant={variant ?? 'ghost'}
        onClick={event => {
          event.stopPropagation()
          setOpen(true)
        }}>
        {label ?? icon ?? <RiDeleteBin6Line />}
      </Button>
      <DialogContent closeLabel={t('common.close')} onClick={event => event.stopPropagation()}>
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
