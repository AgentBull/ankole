import { Button, Dialog, DialogContent, DialogFooter, DialogHeader, DialogTitle } from '@ankole/uikit'
import { useRef, useState } from 'react'
import { useTranslation } from 'react-i18next'
import {
  actionResponseEnvelope,
  formatIdentifierLabel,
  serializeDeclarativeFields,
  withFieldDefaults,
  type DeclarativeRecord
} from './transport'
import type {
  DeclarativeFieldDescriptor,
  DeclarativeStepSchema,
  DeclarativeSurfaceDescriptor,
  WizardStepTransition
} from './types'
import {
  canBlockAdvance,
  redactUrlCredentials,
  selectedRowIds,
  toggleTableSelectionRow,
  WizardBlockRenderer
} from './wizard-blocks'

export { canBlockAdvance, redactUrlCredentials, selectedRowIds, toggleTableSelectionRow, WizardBlockRenderer }

export interface WizardExecutionScope {
  readonly surfaceById: ReadonlyMap<string, DeclarativeSurfaceDescriptor>
  readonly visibleIds: ReadonlySet<string>
  readonly onExecute: (
    targetSurface: DeclarativeSurfaceDescriptor,
    payload: Record<string, unknown>
  ) => Promise<readonly DeclarativeRecord[]>
}

interface WizardTriggerProps extends WizardExecutionScope {
  readonly surface: DeclarativeSurfaceDescriptor
  readonly i18nPrefix?: string
  readonly onComplete?: () => void
}

function collectBlockFields(steps: readonly DeclarativeStepSchema[]): DeclarativeFieldDescriptor[] {
  const collected: DeclarativeFieldDescriptor[] = []
  for (const step of steps) {
    for (const block of step.blocks) {
      if (block.kind === 'fields') {
        collected.push(...block.fields)
      }
    }
  }
  return collected
}

export async function executeStepTransition(
  { surfaceById, visibleIds, onExecute }: WizardExecutionScope,
  transition: WizardStepTransition,
  state: Readonly<Record<string, unknown>>
): Promise<Record<string, unknown>> {
  const action = surfaceById.get(transition.actionSurfaceId)
  if (action?.kind !== 'action') {
    throw new Error(`Unknown wizard action: ${transition.actionSurfaceId}`)
  }
  if (!visibleIds.has(action.surface)) {
    throw new Error(`Unauthorized wizard action: ${action.id}`)
  }

  const inputDraft: Record<string, unknown> = {}
  for (const fieldName of transition.inputFields) {
    if (fieldName in state) {
      inputDraft[fieldName] = state[fieldName]
    }
  }

  const records = await onExecute(action, serializeDeclarativeFields(action, inputDraft))
  const envelope = actionResponseEnvelope(action)
  let responseObj: Readonly<Record<string, unknown>>
  if (envelope === 'flat') {
    responseObj = records.length === 1 && records[0] ? records[0] : { items: records }
  } else {
    responseObj = { items: records, ...(records.length === 1 ? records[0] : {}) }
  }

  const nextState: Record<string, unknown> = { ...state }
  for (const fieldName of transition.resetFields ?? []) {
    delete nextState[fieldName]
  }
  for (const [targetKey, sourceKey] of Object.entries(transition.outputMap)) {
    if (sourceKey === '$records') {
      nextState[targetKey] = records
    } else if (sourceKey in responseObj) {
      nextState[targetKey] = responseObj[sourceKey]
    }
  }
  return nextState
}

export function DeclarativeWizardModal({
  surface,
  surfaceById,
  visibleIds,
  open,
  i18nPrefix = 'console',
  onClose,
  onComplete,
  onExecute
}: WizardTriggerProps & { open: boolean; onClose: () => void }) {
  const { t } = useTranslation()
  const steps = surface.stepSchemas
  const allWizardFields = [...surface.fields, ...collectBlockFields(steps)]
  const [history, setHistory] = useState<readonly Record<string, unknown>[]>(() => [withFieldDefaults(allWizardFields)])
  const formRef = useRef<HTMLFormElement>(null)
  const [pending, setPending] = useState(false)
  const [error, setError] = useState<string | null>(null)

  const stepIndex = steps.length === 0 ? 0 : Math.min(history.length - 1, steps.length - 1)
  const currentStep = steps[stepIndex]
  const currentState = history[stepIndex] ?? {}
  const isFinal = stepIndex >= steps.length - 1
  const canAdvanceCurrentStep = currentStep
    ? currentStep.blocks.every(block => canBlockAdvance(block, currentState))
    : true

  const updateCurrentState = (updater: (previous: Record<string, unknown>) => Record<string, unknown>) => {
    setHistory(previous => {
      const current = previous[stepIndex] ?? {}
      const next = previous.slice()
      next[stepIndex] = updater(current)
      return next
    })
  }

  const handleAdvance = async () => {
    if (pending || !canAdvanceCurrentStep || !formRef.current?.reportValidity()) return
    setPending(true)
    setError(null)
    try {
      if (!isFinal) {
        const nextState = currentStep?.transition
          ? await executeStepTransition({ surfaceById, visibleIds, onExecute }, currentStep.transition, currentState)
          : { ...currentState }
        setHistory(previous => [...previous.slice(0, stepIndex + 1), nextState])
        return
      }
      await onExecute(surface, serializeDeclarativeFields(surface, currentState))
      onComplete?.()
      onClose()
    } catch (failure) {
      setError(failure instanceof Error ? failure.message : String(failure))
    } finally {
      setPending(false)
    }
  }

  return (
    <Dialog
      open={open}
      onOpenChange={next => {
        if (!next && !pending) onClose()
      }}>
      <DialogContent
        className="flex max-h-[85vh] flex-col gap-4 overflow-hidden sm:max-w-2xl"
        closeLabel={t('common.close', { defaultValue: 'Close' })}>
        <DialogHeader>
          <DialogTitle>{t(surface.titleKey, { defaultValue: formatIdentifierLabel(surface.id) })}</DialogTitle>
        </DialogHeader>

        {steps.length > 0 ? (
          <nav aria-label={t('common.progress', { defaultValue: 'Steps' })}>
            <ol className="flex flex-wrap gap-3 text-xs">
              {steps.map((item, idx) => (
                <li
                  key={item.id}
                  aria-current={idx === stepIndex ? 'step' : undefined}
                  className={idx === stepIndex ? 'font-semibold text-fg-primary' : 'text-fg-secondary'}>
                  {idx + 1}. {t(item.labelKey, { defaultValue: formatIdentifierLabel(item.id) })}
                </li>
              ))}
            </ol>
          </nav>
        ) : null}

        <form
          ref={formRef}
          inert={pending}
          onSubmit={event => {
            event.preventDefault()
            void handleAdvance()
          }}
          className="grid min-h-0 flex-1 gap-4 overflow-y-auto pr-1">
          {currentStep
            ? currentStep.blocks.map((block, blockIndex) => (
                <WizardBlockRenderer
                  key={`${currentStep.id}-${block.kind}-${blockIndex}`}
                  block={block}
                  disabled={pending}
                  i18nPrefix={i18nPrefix}
                  state={currentState}
                  surfaceFields={allWizardFields}
                  onStateChange={updateCurrentState}
                />
              ))
            : null}

          {error ? (
            <p className="text-sm text-destructive" role="alert">
              {error}
            </p>
          ) : null}
        </form>

        <DialogFooter>
          {stepIndex > 0 ? (
            <Button
              disabled={pending}
              size="sm"
              type="button"
              variant="outline"
              onClick={() => {
                setError(null)
                setHistory(previous => (previous.length > 1 ? previous.slice(0, -1) : previous))
              }}>
              {t('common.back', { defaultValue: 'Back' })}
            </Button>
          ) : null}
          <Button disabled={pending} size="sm" type="button" variant="outline" onClick={onClose}>
            {t('common.cancel', { defaultValue: 'Cancel' })}
          </Button>
          <Button
            disabled={pending || !canAdvanceCurrentStep}
            size="sm"
            type="button"
            onClick={() => void handleAdvance()}>
            {pending
              ? t(`${i18nPrefix}.ui.submitting`, { defaultValue: 'Submitting...' })
              : isFinal
                ? t(`${i18nPrefix}.ui.confirm`, { defaultValue: 'Confirm' })
                : t('common.next', { defaultValue: 'Next' })}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}

export function DeclarativeWizardTrigger({
  surface,
  surfaceById,
  visibleIds,
  i18nPrefix = 'console',
  onComplete,
  onExecute
}: WizardTriggerProps) {
  const { t } = useTranslation()
  const [open, setOpen] = useState(false)
  return (
    <>
      <Button size="sm" type="button" variant="outline" onClick={() => setOpen(true)}>
        {t(surface.titleKey, { defaultValue: formatIdentifierLabel(surface.id) })}
      </Button>
      {open ? (
        <DeclarativeWizardModal
          i18nPrefix={i18nPrefix}
          open={open}
          surface={surface}
          surfaceById={surfaceById}
          visibleIds={visibleIds}
          onClose={() => setOpen(false)}
          onComplete={onComplete}
          onExecute={onExecute}
        />
      ) : null}
    </>
  )
}
