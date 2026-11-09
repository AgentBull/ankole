import { Button, Field, FieldDescription, FieldLabel, Input, Switch, Textarea } from '@ankole/uikit'
import {
  useEffect,
  useLayoutEffect,
  useRef,
  useState,
  type ClipboardEvent,
  type FocusEvent,
  type FormEvent,
  type MutableRefObject
} from 'react'
import { useTranslation } from 'react-i18next'

import { EncryptedValueInput, isEncryptedValueMask } from '../common/encrypted-value-input'
import {
  ENV_VAR_NAME_FORMAT,
  ENV_VAR_NAME_PATTERN,
  formatImportOutcomeError,
  formatPodEnvVarError,
  inspectDotEnv,
  isReservedEnvVarName,
  resolveImportDraftCompletion,
  shouldApplyDecryptedDraftValue,
  type EnvVarEntry,
  type EnvVarImportOutcome,
  type EnvVarSaveInput,
  type ParsedDotEnvItem
} from './env-vars-dotenv'

export type EnvVarEditSession = {
  id: number
  item: EnvVarEntry
  initialValue: string
}

export type DotEnvSeedRequest = {
  id: number
  text: string
}

export type PrepareRowRevealFn = (targetName: string) => (plaintext: string) => void

function syncUserInvalidAria(element: HTMLInputElement | HTMLTextAreaElement) {
  let invalid = false
  try {
    invalid = element.matches(':user-invalid')
  } catch {
    invalid = !element.checkValidity()
  }
  element.setAttribute('aria-invalid', invalid ? 'true' : 'false')
}

export function EnvVarDotEnvImportForm({
  baseId,
  active,
  modeEpoch,
  seed,
  onImport,
  onSavedNames,
  onApplyOpenState,
  onError
}: {
  baseId: string
  active: boolean
  modeEpoch: number
  seed: DotEnvSeedRequest | null
  onImport: (entries: ParsedDotEnvItem[], secret: boolean) => Promise<EnvVarImportOutcome>
  onSavedNames: (names: string[]) => void
  onApplyOpenState: (nextOpen: boolean) => void
  onError: (message: string | null) => void
}) {
  const { t } = useTranslation()
  const [importText, setImportText] = useState('')
  const [importSecret, setImportSecret] = useState(true)
  const [importing, setImporting] = useState(false)

  const importEpochRef = useRef(0)
  const appliedSeedIdRef = useRef(0)
  const latestModeEpochRef = useRef(modeEpoch)
  const latestActiveRef = useRef(active)

  useLayoutEffect(() => {
    latestModeEpochRef.current = modeEpoch
    latestActiveRef.current = active
  }, [modeEpoch, active])

  useLayoutEffect(() => {
    if (!seed || seed.id === appliedSeedIdRef.current) return
    appliedSeedIdRef.current = seed.id
    importEpochRef.current += 1
    setImportText(seed.text)
  }, [seed])

  if (!active && !importing && importText.length === 0 && !seed) {
    return null
  }

  const importTextId = `${baseId}-import-text`
  const importSecretId = `${baseId}-import-secret`
  const preview = inspectDotEnv(importText)
  const hasBlankPreviewItem = preview.items.some(item => !/\S/.test(item.value))

  const handleImportSubmit = async (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault()
    if (importing) return
    onError(null)

    const { items: parsed, errors } = inspectDotEnv(importText)
    if (errors.length > 0) {
      const firstError = errors[0]!
      onError(
        firstError.reason === 'reserved_name'
          ? t('pod.env_vars.name_reserved')
          : t('pod.env_vars.import_syntax_error', { line: firstError.line })
      )
      return
    }
    if (parsed.length === 0) {
      onError(t('pod.env_vars.import_empty'))
      return
    }
    const blankEntry = parsed.find(item => !/\S/.test(item.value))
    if (blankEntry) {
      onError(`${blankEntry.name}: ${t('pod.env_vars.value_required')}`)
      return
    }

    const submitEpoch = importEpochRef.current
    const submitModeEpoch = latestModeEpochRef.current
    setImporting(true)
    try {
      const outcome = await onImport(parsed, importSecret)
      if (outcome.saved.length > 0) {
        onSavedNames(outcome.saved)
      }
      const currentEpoch = importEpochRef.current
      const currentModeEpoch = latestModeEpochRef.current
      setImportText(
        currentText =>
          resolveImportDraftCompletion({
            requestEpoch: submitEpoch,
            currentEpoch,
            requestModeEpoch: submitModeEpoch,
            currentModeEpoch,
            currentImportText: currentText,
            currentImportOpen: latestActiveRef.current,
            outcome
          }).importText
      )
      const nextOpen = resolveImportDraftCompletion({
        requestEpoch: submitEpoch,
        currentEpoch,
        requestModeEpoch: submitModeEpoch,
        currentModeEpoch,
        currentImportText: '',
        currentImportOpen: latestActiveRef.current,
        outcome
      }).importOpen
      onApplyOpenState(nextOpen)

      if (outcome.failures.length > 0) {
        onError(formatImportOutcomeError(t, outcome))
      }
    } catch (importError) {
      onError(formatPodEnvVarError(importError))
    } finally {
      setImporting(false)
    }
  }

  return (
    <form
      hidden={!active}
      aria-hidden={!active || undefined}
      className={active ? 'grid gap-3' : 'hidden'}
      noValidate
      onSubmit={event => void handleImportSubmit(event)}>
      <Field>
        <FieldLabel htmlFor={importTextId}>{t('pod.env_vars.import_label')}</FieldLabel>
        <FieldDescription>{t('pod.env_vars.import_hint')}</FieldDescription>
        <Textarea
          id={importTextId}
          name="dotenv"
          rows={4}
          required
          autoCapitalize="off"
          autoCorrect="off"
          spellCheck={false}
          placeholder={'API_KEY=sk-...\nAPI_BASE_URL=https://api.example.com'}
          className="font-mono text-xs"
          value={importText}
          onChange={event => {
            importEpochRef.current += 1
            setImportText(event.target.value)
            onError(null)
          }}
        />
      </Field>
      <Field
        orientation="horizontal"
        className="items-center justify-between rounded-md border border-border bg-muted/30 p-3">
        <div className="grid gap-0.5 pr-3">
          <FieldLabel htmlFor={importSecretId}>{t('pod.env_vars.secret_storage')}</FieldLabel>
          <FieldDescription>
            {importSecret ? t('pod.env_vars.secret_hint') : t('pod.env_vars.plaintext_value_hint')}
          </FieldDescription>
        </div>
        <Switch
          id={importSecretId}
          checked={importSecret}
          onCheckedChange={checked => setImportSecret(checked === true)}
        />
      </Field>
      <div className="flex flex-wrap items-center gap-2">
        <Button type="submit" size="sm" disabled={importing}>
          {preview.errors.length === 0 && !hasBlankPreviewItem && preview.items.length > 0
            ? t('pod.env_vars.import_submit_count', { count: preview.items.length })
            : t('pod.env_vars.import_submit')}
        </Button>
        <Button
          type="button"
          size="sm"
          variant="ghost"
          disabled={importing}
          onClick={() => {
            importEpochRef.current += 1
            setImportText('')
            onError(null)
            onApplyOpenState(false)
          }}>
          {t('common.cancel')}
        </Button>
      </div>
    </form>
  )
}

export function EnvVarSingleEntryForm({
  baseId,
  active,
  ownSource,
  editSession,
  editingItem,
  canRevealEditing,
  revealedPlaintext,
  revealing,
  prepareRowRevealRef,
  onReveal,
  onSave,
  onSavedName,
  onExitEdit,
  onMultilineDotEnvPaste,
  onError
}: {
  baseId: string
  active: boolean
  ownSource: 'applet' | 'tenant'
  editSession: EnvVarEditSession | null
  editingItem?: EnvVarEntry
  canRevealEditing: boolean
  revealedPlaintext?: string
  revealing: boolean
  prepareRowRevealRef: MutableRefObject<PrepareRowRevealFn | null>
  onReveal?: () => void
  onSave: (input: EnvVarSaveInput) => Promise<unknown>
  onSavedName: (name: string) => void
  onExitEdit: () => void
  onMultilineDotEnvPaste: (raw: string) => void
  onError: (message: string | null) => void
}) {
  const { t } = useTranslation()
  const nameInputRef = useRef<HTMLInputElement>(null)
  const valueInputRef = useRef<HTMLInputElement>(null)

  const [name, setName] = useState(() => editSession?.item.name ?? '')
  const [value, setValue] = useState(() => editSession?.initialValue ?? '')
  const [secret, setSecret] = useState(() => editSession?.item.secret ?? true)
  const [description, setDescription] = useState(() => editSession?.item.description ?? '')
  const [saving, setSaving] = useState(false)
  const [formResetCount, setFormResetCount] = useState(0)

  const draftEpochRef = useRef(0)
  const editingName = editSession?.item.name ?? null
  const editingNameRef = useRef<string | null>(editingName)

  useLayoutEffect(() => {
    editingNameRef.current = editingName
  }, [editingName])

  useLayoutEffect(() => {
    prepareRowRevealRef.current = (targetName: string) => {
      const requestEpoch = draftEpochRef.current
      const wasEditingTarget = editingNameRef.current === targetName
      return (plaintext: string) => {
        setValue(current =>
          shouldApplyDecryptedDraftValue({
            wasEditingTarget,
            requestEpoch,
            currentEpoch: draftEpochRef.current,
            currentEditingName: editingNameRef.current,
            targetName,
            currentValue: current
          })
            ? plaintext
            : current
        )
      }
    }
    return () => {
      prepareRowRevealRef.current = null
    }
  }, [prepareRowRevealRef])

  useEffect(() => {
    if (!editSession) return
    nameInputRef.current?.removeAttribute('aria-invalid')
    valueInputRef.current?.removeAttribute('aria-invalid')
    valueInputRef.current?.focus()
  }, [editSession])

  const ownStoredSecretExists = Boolean(
    editingItem && editingItem.source === ownSource && editingItem.secret && editingItem.present
  )
  useEffect(() => {
    if (!editingName || ownStoredSecretExists) return
    setValue(current => (isEncryptedValueMask(current) ? '' : current))
  }, [editingName, ownStoredSecretExists])

  const bumpDraftEpoch = (nextEditingName?: string | null) => {
    draftEpochRef.current += 1
    if (nextEditingName !== undefined) {
      editingNameRef.current = nextEditingName
    }
  }

  const resetForm = () => {
    bumpDraftEpoch(null)
    setName('')
    setValue('')
    setSecret(true)
    setDescription('')
    setFormResetCount(count => count + 1)
    onError(null)
    nameInputRef.current?.removeAttribute('aria-invalid')
    valueInputRef.current?.removeAttribute('aria-invalid')
    onExitEdit()
  }

  const handleNamePaste = (event: ClipboardEvent<HTMLInputElement>) => {
    if (editingName) return
    const text = event.clipboardData.getData('text')
    if (!text || !text.includes('=')) return
    const { items: parsed, errors } = inspectDotEnv(text)
    if (parsed.length === 0 && errors.length === 0) return
    if (parsed.length === 1 && errors.length === 0 && !text.includes('\n')) {
      event.preventDefault()
      bumpDraftEpoch()
      setName(parsed[0]!.name)
      setValue(parsed[0]!.value)
      onError(null)
      queueMicrotask(() => valueInputRef.current?.focus())
      return
    }
    if (text.includes('\n') || parsed.length > 1) {
      event.preventDefault()
      onMultilineDotEnvPaste(text)
      return
    }
    if (errors.length > 0) {
      event.preventDefault()
      const firstError = errors[0]!
      onError(
        firstError.reason === 'reserved_name'
          ? t('pod.env_vars.name_reserved')
          : firstError.reason === 'invalid_name'
            ? t('pod.env_vars.name_invalid')
            : t('pod.env_vars.import_syntax_error', { line: firstError.line })
      )
    }
  }

  const handleSubmit = async (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault()
    if (saving) return
    onError(null)
    const trimmedName = (editingName ?? name).trim()
    if (!ENV_VAR_NAME_FORMAT.test(trimmedName)) {
      nameInputRef.current?.setAttribute('aria-invalid', 'true')
      nameInputRef.current?.focus()
      onError(t('pod.env_vars.name_invalid'))
      return
    }
    if (isReservedEnvVarName(trimmedName)) {
      nameInputRef.current?.setAttribute('aria-invalid', 'true')
      nameInputRef.current?.focus()
      onError(t('pod.env_vars.name_reserved'))
      return
    }
    if (!isEncryptedValueMask(value) && !/\S/.test(value)) {
      valueInputRef.current?.setAttribute('aria-invalid', 'true')
      valueInputRef.current?.focus()
      onError(t('pod.env_vars.value_required'))
      return
    }
    if (!secret && isEncryptedValueMask(value)) {
      valueInputRef.current?.setAttribute('aria-invalid', 'true')
      valueInputRef.current?.focus()
      onError(t('pod.env_vars.reveal_or_replace_for_plaintext'))
      return
    }

    const submitEpoch = draftEpochRef.current
    setSaving(true)
    try {
      await onSave({
        name: trimmedName,
        ...(isEncryptedValueMask(value) ? {} : { value }),
        secret,
        description: description.trim() ? description.trim() : null
      })
      onSavedName(trimmedName)
      if (draftEpochRef.current === submitEpoch) {
        resetForm()
      }
    } catch (saveError) {
      onError(formatPodEnvVarError(saveError))
    } finally {
      setSaving(false)
    }
  }

  const nameId = `${baseId}-name`
  const valueId = `${baseId}-value`
  const valueHintId = `${baseId}-value-hint`
  const secretId = `${baseId}-secret`
  const secretHintId = `${baseId}-secret-hint`
  const descId = `${baseId}-description`

  return (
    <form
      hidden={!active}
      aria-hidden={!active || undefined}
      className={active ? 'grid gap-3' : 'hidden'}
      noValidate
      onSubmit={event => void handleSubmit(event)}>
      <div className="grid gap-3 sm:grid-cols-2">
        <Field>
          <FieldLabel htmlFor={nameId}>{t('pod.env_vars.name')}</FieldLabel>
          <Input
            ref={nameInputRef}
            id={nameId}
            name="name"
            required
            readOnly={Boolean(editingName)}
            pattern={ENV_VAR_NAME_PATTERN}
            autoCapitalize="off"
            autoComplete="off"
            autoCorrect="off"
            spellCheck={false}
            placeholder="EXAMPLE_API_KEY"
            className="font-mono text-xs user-invalid:border-destructive"
            value={editingName ?? name}
            onPaste={handleNamePaste}
            onBlur={(event: FocusEvent<HTMLInputElement>) => {
              if (!editingName) syncUserInvalidAria(event.currentTarget)
            }}
            onChange={event => {
              bumpDraftEpoch()
              setName(event.target.value)
              onError(null)
              if (event.currentTarget.hasAttribute('aria-invalid')) {
                syncUserInvalidAria(event.currentTarget)
              }
            }}
          />
        </Field>
        <Field>
          <FieldLabel htmlFor={valueId}>{t('pod.env_vars.value')}</FieldLabel>
          {secret || isEncryptedValueMask(value) ? (
            <EncryptedValueInput
              key={`${editingName ?? '__new__'}:${formResetCount}`}
              ref={valueInputRef}
              id={valueId}
              name="value"
              required
              placeholder={
                editingItem && editingItem.source !== ownSource && editingItem.present
                  ? t('pod.env_vars.override_placeholder')
                  : undefined
              }
              className="font-mono text-xs user-invalid:border-destructive"
              hideLabel={t('common.hide_secret')}
              revealLabel={t('common.reveal_secret')}
              revealed={editingName !== null && revealedPlaintext === value && !isEncryptedValueMask(value)}
              revealing={revealing}
              value={value}
              onBlur={(event: FocusEvent<HTMLInputElement>) => syncUserInvalidAria(event.currentTarget)}
              onChange={event => {
                bumpDraftEpoch()
                setValue(event.target.value)
                onError(null)
                if (event.currentTarget.hasAttribute('aria-invalid')) {
                  syncUserInvalidAria(event.currentTarget)
                }
              }}
              onReveal={canRevealEditing ? onReveal : undefined}
              aria-describedby={isEncryptedValueMask(value) ? valueHintId : undefined}
            />
          ) : (
            <Input
              ref={valueInputRef}
              id={valueId}
              name="value"
              required
              autoCapitalize="off"
              autoComplete="off"
              autoCorrect="off"
              spellCheck={false}
              placeholder={
                editingItem && editingItem.source !== ownSource && editingItem.present
                  ? t('pod.env_vars.override_placeholder')
                  : undefined
              }
              className="font-mono text-xs user-invalid:border-destructive"
              value={value}
              onBlur={(event: FocusEvent<HTMLInputElement>) => syncUserInvalidAria(event.currentTarget)}
              onChange={event => {
                bumpDraftEpoch()
                setValue(event.target.value)
                onError(null)
                if (event.currentTarget.hasAttribute('aria-invalid')) {
                  syncUserInvalidAria(event.currentTarget)
                }
              }}
            />
          )}
          {isEncryptedValueMask(value) ? (
            <FieldDescription id={valueHintId}>{t('pod.env_vars.secret_value_hint')}</FieldDescription>
          ) : null}
        </Field>
      </div>

      <Field
        orientation="horizontal"
        className="items-center justify-between rounded-md border border-border bg-muted/30 p-3">
        <div className="grid gap-0.5 pr-3">
          <FieldLabel htmlFor={secretId}>{t('pod.env_vars.secret_storage')}</FieldLabel>
          <FieldDescription id={secretHintId}>
            {secret ? t('pod.env_vars.secret_hint') : t('pod.env_vars.plaintext_value_hint')}
          </FieldDescription>
        </div>
        <Switch
          id={secretId}
          aria-describedby={secretHintId}
          checked={secret}
          onCheckedChange={checked => {
            bumpDraftEpoch()
            setSecret(checked === true)
            onError(null)
          }}
        />
      </Field>

      <Field>
        <FieldLabel htmlFor={descId}>{t('pod.env_vars.description_label')}</FieldLabel>
        <Input
          id={descId}
          name="description"
          placeholder={t('pod.env_vars.description_placeholder')}
          value={description}
          onChange={event => {
            bumpDraftEpoch()
            setDescription(event.target.value)
          }}
        />
      </Field>

      <div className="flex flex-wrap items-center gap-2">
        <Button type="submit" size="sm" disabled={saving}>
          {t('pod.env_vars.save_variable')}
        </Button>
        {editingName ? (
          <Button type="button" size="sm" variant="ghost" disabled={saving} onClick={resetForm}>
            {t('common.cancel')}
          </Button>
        ) : null}
      </div>
    </form>
  )
}
