import {
  Alert,
  AlertDescription,
  Badge,
  Button,
  Collapsible,
  CollapsibleContent,
  CollapsibleTrigger,
  Skeleton,
  Spinner,
  Table,
  TableBody,
  TableCaption,
  TableCell,
  TableHead,
  TableHeader,
  TableRow
} from '@ankole/uikit'
import { RiArrowDownSLine, RiEyeLine, RiEyeOffLine, RiFileList3Line } from '@remixicon/react'
import { useEffect, useId, useRef, useState } from 'react'
import { useTranslation } from 'react-i18next'

import { ENCRYPTED_VALUE_MASK } from '../common/encrypted-value-input'
import { ContentError } from './content-primitives'
import {
  formatPodEnvVarError,
  type EnvVarEntry,
  type EnvVarImportOutcome,
  type EnvVarSaveInput,
  type EnvVarSource,
  type ParsedDotEnvItem
} from './env-vars-dotenv'
import {
  EnvVarDotEnvImportForm,
  EnvVarSingleEntryForm,
  type DotEnvSeedRequest,
  type EnvVarEditSession,
  type PrepareRowRevealFn
} from './env-vars-forms'

function EnvVarSourceBadge({ source, ownSource }: { source: EnvVarSource; ownSource: 'applet' | 'tenant' }) {
  const { t } = useTranslation()
  if (source === 'missing') {
    return <Badge variant="warning">{t('pod.env_vars.source_missing')}</Badge>
  }
  if (source === ownSource) {
    return (
      <Badge variant="info">
        {ownSource === 'applet' ? t('pod.env_vars.source_applet') : t('pod.env_vars.source_pod')}
      </Badge>
    )
  }
  return <Badge variant="secondary">{t(`pod.env_vars.source_${source}`)}</Badge>
}

function maskSummary(item: EnvVarEntry, unconfiguredLabel: string): string {
  if (!item.present) return unconfiguredLabel
  if (item.secret) return '••••••••••••'
  return item.value ?? ''
}

export function EnvVarsEditor({
  items,
  ownSource,
  isLoading,
  error,
  canDecrypt = false,
  onRetry,
  onSave,
  onImport,
  onDelete,
  onDecrypt
}: {
  items: EnvVarEntry[]
  ownSource: 'applet' | 'tenant'
  isLoading?: boolean
  error?: unknown
  canDecrypt?: boolean
  onRetry?: () => void
  onSave: (input: EnvVarSaveInput) => Promise<unknown>
  onImport: (entries: ParsedDotEnvItem[], secret: boolean) => Promise<EnvVarImportOutcome>
  onDelete: (name: string) => Promise<unknown>
  onDecrypt?: (name: string) => Promise<string>
}) {
  const { t } = useTranslation()
  const baseId = useId()
  const formCardRef = useRef<HTMLDivElement>(null)
  const prepareRowRevealRef = useRef<PrepareRowRevealFn | null>(null)
  const nextCounterRef = useRef(0)
  const revealGenerationRef = useRef(0)
  const mountedRef = useRef(true)

  const [editSession, setEditSession] = useState<EnvVarEditSession | null>(null)
  const [importOpen, setImportOpen] = useState(false)
  const [modeEpoch, setModeEpoch] = useState(0)
  const [dotEnvSeed, setDotEnvSeed] = useState<DotEnvSeedRequest | null>(null)
  const [formError, setFormError] = useState<string | null>(null)
  const [deletingName, setDeletingName] = useState<string | null>(null)
  const [revealingName, setRevealingName] = useState<string | null>(null)
  const [revealedValues, setRevealedValues] = useState<Record<string, string>>({})
  const revealTimers = useRef<Record<string, number>>({})

  const clearRevealed = () => {
    revealGenerationRef.current += 1
    for (const timer of Object.values(revealTimers.current)) window.clearTimeout(timer)
    revealTimers.current = {}
    setRevealingName(null)
    setRevealedValues(current => (Object.keys(current).length === 0 ? current : {}))
  }

  useEffect(() => {
    mountedRef.current = true
    const onWindowBlur = () => {
      revealGenerationRef.current += 1
      for (const timer of Object.values(revealTimers.current)) window.clearTimeout(timer)
      revealTimers.current = {}
      setRevealingName(null)
      setRevealedValues(current => (Object.keys(current).length === 0 ? current : {}))
    }
    window.addEventListener('blur', onWindowBlur)
    return () => {
      mountedRef.current = false
      revealGenerationRef.current += 1
      window.removeEventListener('blur', onWindowBlur)
      for (const timer of Object.values(revealTimers.current)) window.clearTimeout(timer)
      revealTimers.current = {}
    }
  }, [])

  useEffect(() => {
    if (!canDecrypt || !onDecrypt) {
      clearRevealed()
      return
    }
    setRevealedValues(current => {
      const keys = Object.keys(current)
      if (keys.length === 0) return current
      const validNames = new Set(
        items.filter(item => item.source === ownSource && item.secret && item.present).map(item => item.name)
      )
      let changed = false
      const next: Record<string, string> = {}
      for (const key of keys) {
        if (validNames.has(key)) {
          next[key] = current[key]!
        } else {
          changed = true
          window.clearTimeout(revealTimers.current[key])
          delete revealTimers.current[key]
        }
      }
      return changed ? next : current
    })
  }, [canDecrypt, onDecrypt, items, ownSource])

  const hideRevealed = (targetName: string) => {
    window.clearTimeout(revealTimers.current[targetName])
    delete revealTimers.current[targetName]
    setRevealedValues(current => {
      if (!(targetName in current)) return current
      const next = { ...current }
      delete next[targetName]
      return next
    })
  }

  const hideRevealedBatch = (names: string[]) => {
    for (const targetName of names) hideRevealed(targetName)
  }

  const handleReveal = async (targetName: string) => {
    if (!onDecrypt || !canDecrypt) return
    const generation = revealGenerationRef.current
    const applyToDraft = prepareRowRevealRef.current?.(targetName)
    setRevealingName(targetName)
    setFormError(null)
    try {
      const plaintext = await onDecrypt(targetName)
      if (!mountedRef.current || revealGenerationRef.current !== generation) return
      setRevealedValues(current => ({ ...current, [targetName]: plaintext }))
      window.clearTimeout(revealTimers.current[targetName])
      revealTimers.current[targetName] = window.setTimeout(() => hideRevealed(targetName), 30_000)
      applyToDraft?.(plaintext)
    } catch (revealError) {
      if (mountedRef.current && revealGenerationRef.current === generation) {
        setFormError(formatPodEnvVarError(revealError))
      }
    } finally {
      if (mountedRef.current) {
        setRevealingName(current => (current === targetName ? null : current))
      }
    }
  }

  const beginEdit = (item: EnvVarEntry) => {
    nextCounterRef.current += 1
    const ownStoredSecret = item.source === ownSource && item.secret && item.present
    const initialValue = item.secret
      ? (revealedValues[item.name] ?? (ownStoredSecret ? ENCRYPTED_VALUE_MASK : ''))
      : item.source === ownSource
        ? (item.value ?? '')
        : ''

    setImportOpen(false)
    setModeEpoch(epoch => epoch + 1)
    setEditSession({ id: nextCounterRef.current, item, initialValue })
    setFormError(null)
    queueMicrotask(() => {
      formCardRef.current?.scrollIntoView?.({ block: 'nearest' })
    })
  }

  const handleDelete = async (targetName: string) => {
    setDeletingName(targetName)
    setFormError(null)
    try {
      await onDelete(targetName)
      hideRevealed(targetName)
      setEditSession(current => (current?.item.name === targetName ? null : current))
    } catch (deleteError) {
      setFormError(formatPodEnvVarError(deleteError))
    } finally {
      setDeletingName(current => (current === targetName ? null : current))
    }
  }

  const editingName = editSession?.item.name ?? null
  const primaryItems = items.filter(
    item => item.source === ownSource || item.source === 'missing' || Boolean(item.required) || Boolean(item.declared)
  )
  const inheritedItems = items.filter(
    item => item.source !== ownSource && item.source !== 'missing' && !item.required && !item.declared
  )
  const editingItem = editingName ? items.find(item => item.name === editingName) : undefined
  const canRevealEditing = Boolean(
    canDecrypt &&
    onDecrypt &&
    editingItem &&
    editingItem.source === ownSource &&
    editingItem.secret &&
    editingItem.present
  )
  const showDotEnvImport = importOpen && !editingName

  const renderRows = (rows: EnvVarEntry[]) =>
    rows.map(item => {
      const isOwn = item.source === ownSource
      const canResetToInherited = Boolean(item.inherited_source) || Boolean(item.declared)
      const canRevealRow = Boolean(canDecrypt && onDecrypt && isOwn && item.secret && item.present)
      const isRowRevealed = canRevealRow && revealedValues[item.name] !== undefined
      const rowActionLabel = isOwn
        ? t('common.edit')
        : item.source === 'missing'
          ? t('pod.env_vars.configure')
          : t('pod.env_vars.override')
      const removeLabel = canResetToInherited ? t('pod.env_vars.reset_inherited') : t('common.delete')

      return (
        <TableRow key={item.name} data-state={editingName === item.name ? 'selected' : undefined}>
          <th
            scope="row"
            className="max-w-[260px] border-b border-border px-3 py-1.5 text-left align-top font-normal whitespace-normal text-foreground">
            <div className="grid gap-1">
              <div className="flex min-h-6 flex-wrap items-center gap-1.5">
                <span className="font-mono text-xs font-medium break-all">{item.name}</span>
                {item.required ? <Badge variant="outline">{t('pod.env_vars.required')}</Badge> : null}
                {item.secret ? <Badge variant="secondary">{t('pod.env_vars.secret')}</Badge> : null}
              </div>
              {item.description ? <p className="text-xs leading-4 text-muted-foreground">{item.description}</p> : null}
            </div>
          </th>
          <TableCell className="max-w-[240px] align-top font-mono text-xs whitespace-normal">
            <div className="flex min-h-6 items-center gap-1.5">
              <span className="line-clamp-2 break-all text-foreground">
                {(canRevealRow ? revealedValues[item.name] : undefined) ??
                  maskSummary(item, t('pod.env_vars.not_configured'))}
              </span>
              {canRevealRow ? (
                <button
                  type="button"
                  aria-pressed={isRowRevealed}
                  aria-label={
                    isRowRevealed
                      ? `${t('common.hide_secret')} ${item.name}`
                      : `${t('common.reveal_secret')} ${item.name}`
                  }
                  title={isRowRevealed ? t('common.hide_secret') : t('common.reveal_secret')}
                  disabled={revealingName === item.name}
                  className="grid size-6 shrink-0 place-items-center rounded-md text-muted-foreground hover:bg-muted hover:text-foreground disabled:cursor-wait disabled:opacity-60"
                  onClick={() => {
                    if (isRowRevealed) hideRevealed(item.name)
                    else void handleReveal(item.name)
                  }}>
                  {revealingName === item.name ? (
                    <Spinner className="size-3.5" />
                  ) : isRowRevealed ? (
                    <RiEyeOffLine aria-hidden className="size-3.5" />
                  ) : (
                    <RiEyeLine aria-hidden className="size-3.5" />
                  )}
                </button>
              ) : null}
            </div>
          </TableCell>
          <TableCell className="align-top">
            <div className="flex flex-wrap items-center gap-1.5">
              <EnvVarSourceBadge source={item.source} ownSource={ownSource} />
              {isOwn && item.inherited_source ? (
                <span className="text-xs text-muted-foreground">
                  {t(`pod.env_vars.overrides_${item.inherited_source}`)}
                </span>
              ) : null}
            </div>
          </TableCell>
          <TableCell className="align-top text-right">
            <div className="flex items-center justify-end gap-1">
              <Button
                type="button"
                size="xs"
                variant={item.source === 'missing' ? 'outline' : 'ghost'}
                aria-label={`${rowActionLabel} ${item.name}`}
                onClick={() => beginEdit(item)}>
                {rowActionLabel}
              </Button>
              {isOwn ? (
                <Button
                  type="button"
                  size="xs"
                  variant="ghost"
                  disabled={deletingName === item.name}
                  aria-label={`${removeLabel} ${item.name}`}
                  onClick={() => void handleDelete(item.name)}>
                  {removeLabel}
                </Button>
              ) : null}
            </div>
          </TableCell>
        </TableRow>
      )
    })

  return (
    <div className="grid gap-4">
      <ContentError error={error} retry={onRetry} />
      {formError ? (
        <Alert variant="destructive">
          <AlertDescription>{formError}</AlertDescription>
        </Alert>
      ) : null}

      {isLoading ? (
        <div className="grid gap-2 rounded-lg border border-border bg-card p-4">
          <Skeleton className="h-7 w-full" />
          <Skeleton className="h-7 w-4/5" />
        </div>
      ) : primaryItems.length > 0 ? (
        <Table
          containerLabel={t('pod.env_vars.table_label')}
          containerClassName="max-h-[min(420px,55vh)] overflow-auto rounded-lg border border-border bg-card">
          <TableCaption className="sr-only">{t('pod.env_vars.table_label')}</TableCaption>
          <TableHeader className="sticky top-0 z-10 bg-card">
            <TableRow>
              <TableHead scope="col">{t('pod.env_vars.name')}</TableHead>
              <TableHead scope="col">{t('pod.env_vars.value')}</TableHead>
              <TableHead scope="col">{t('pod.env_vars.source')}</TableHead>
              <TableHead scope="col" className="w-0 text-right">
                <span className="sr-only">{t('pod.env_vars.actions')}</span>
              </TableHead>
            </TableRow>
          </TableHeader>
          <TableBody>{renderRows(primaryItems)}</TableBody>
        </Table>
      ) : inheritedItems.length === 0 ? (
        <div className="rounded-lg border border-dashed border-border px-4 py-6 text-center text-sm text-muted-foreground">
          {t('pod.env_vars.empty')}
        </div>
      ) : null}

      {!isLoading && inheritedItems.length > 0 ? (
        <Collapsible defaultOpen={primaryItems.length === 0 && inheritedItems.length <= 6}>
          <CollapsibleTrigger
            render={
              <Button
                type="button"
                variant="ghost"
                size="sm"
                className="group w-full justify-between border border-border bg-muted/30 px-3"
              />
            }>
            <span className="text-xs font-medium text-muted-foreground">
              {t('pod.env_vars.inherited_section', { count: inheritedItems.length })}
            </span>
            <RiArrowDownSLine
              aria-hidden
              className="size-4 text-muted-foreground transition-transform group-data-[panel-open]:rotate-180"
            />
          </CollapsibleTrigger>
          <CollapsibleContent className="pt-2">
            <Table
              containerLabel={t('pod.env_vars.inherited_table_label')}
              containerClassName="max-h-[min(320px,45vh)] overflow-auto rounded-lg border border-border bg-card">
              <TableCaption className="sr-only">{t('pod.env_vars.inherited_table_label')}</TableCaption>
              <TableHeader className="sticky top-0 z-10 bg-card">
                <TableRow>
                  <TableHead scope="col">{t('pod.env_vars.name')}</TableHead>
                  <TableHead scope="col">{t('pod.env_vars.value')}</TableHead>
                  <TableHead scope="col">{t('pod.env_vars.source')}</TableHead>
                  <TableHead scope="col" className="w-0 text-right">
                    <span className="sr-only">{t('pod.env_vars.actions')}</span>
                  </TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>{renderRows(inheritedItems)}</TableBody>
            </Table>
          </CollapsibleContent>
        </Collapsible>
      ) : null}

      <div
        ref={formCardRef}
        className={
          editingName
            ? 'grid gap-3 rounded-lg border border-foreground/25 bg-card p-4 ring-1 ring-foreground/10'
            : 'grid gap-3 rounded-lg border border-border bg-card p-4'
        }>
        <div className="flex flex-wrap items-center justify-between gap-2">
          <h3 className="text-sm font-medium text-foreground">
            {editingName
              ? t('pod.env_vars.edit_heading', { name: editingName })
              : importOpen
                ? t('pod.env_vars.import_heading')
                : t('pod.env_vars.add_heading')}
          </h3>
          {!editingName ? (
            <Button
              type="button"
              variant="ghost"
              size="xs"
              onClick={() => {
                setModeEpoch(epoch => epoch + 1)
                setImportOpen(current => !current)
                setFormError(null)
              }}>
              <RiFileList3Line aria-hidden className="size-3.5" />
              {importOpen ? t('pod.env_vars.single_entry') : t('pod.env_vars.import_dotenv')}
            </Button>
          ) : null}
        </div>

        <EnvVarDotEnvImportForm
          baseId={baseId}
          active={showDotEnvImport}
          modeEpoch={modeEpoch}
          seed={dotEnvSeed}
          onImport={onImport}
          onSavedNames={hideRevealedBatch}
          onApplyOpenState={nextOpen => setImportOpen(nextOpen)}
          onError={setFormError}
        />

        <EnvVarSingleEntryForm
          key={editSession?.id ?? 0}
          baseId={baseId}
          active={!showDotEnvImport}
          ownSource={ownSource}
          editSession={editSession}
          editingItem={editingItem}
          canRevealEditing={canRevealEditing}
          revealedPlaintext={editingName ? revealedValues[editingName] : undefined}
          revealing={editingName !== null && revealingName === editingName}
          prepareRowRevealRef={prepareRowRevealRef}
          onReveal={editingName ? () => void handleReveal(editingName) : undefined}
          onSave={onSave}
          onSavedName={hideRevealed}
          onExitEdit={() => setEditSession(null)}
          onMultilineDotEnvPaste={raw => {
            nextCounterRef.current += 1
            setModeEpoch(epoch => epoch + 1)
            setImportOpen(true)
            setDotEnvSeed({ id: nextCounterRef.current, text: raw })
            setFormError(null)
          }}
          onError={setFormError}
        />
      </div>
    </div>
  )
}
