import {
  Button,
  CopyButton,
  Dialog,
  DialogContent,
  DialogFooter,
  DialogHeader,
  DialogTitle,
  Input,
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
  Textarea,
  toast
} from '@ankole/uikit'
import { useMemo, useRef, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { LabeledField } from '../console-form'
import { DeclarativeFields, DeclarativeSelect } from './fields'
import { withFieldDefaults, asRecord, formatIdentifierLabel, serializeDeclarativeFields } from './transport'
import type { DeclarativeBatchLinesConfig, DeclarativeOAuthPkceConfig, DeclarativeSurfaceDescriptor } from './types'

export type ParsedBatchItem = Readonly<Record<string, string>>

export function redactBatchLine(raw: string): string {
  const trimmed = raw.trim()
  const pipeIdx = trimmed.indexOf('|')
  const prefix = pipeIdx >= 0 ? trimmed.slice(0, pipeIdx + 1) : ''
  const target = (pipeIdx >= 0 ? trimmed.slice(pipeIdx + 1) : trimmed).trim()
  const sanitizedTarget = redactUrlCredentials(target).replace(/((?:^|\/\/))[^/\s:@]+:[^/\s@]+@/g, '$1***@')
  return prefix ? `${prefix}${sanitizedTarget}` : sanitizedTarget
}

export function parseBatchLine(
  line: string,
  defaultScheme: string,
  config: Pick<DeclarativeBatchLinesConfig, 'urlField' | 'nameField' | 'schemeField' | 'schemes'>
): ParsedBatchItem {
  const trimmed = line.trim()
  const [left, right] = trimmed.includes('|') ? trimmed.split('|', 2) : [undefined, trimmed]
  const rawTarget = (right ?? trimmed).trim()
  const url = rawTarget.includes('://') ? rawTarget : `${defaultScheme}://${rawTarget}`
  let parsed: URL
  try {
    parsed = new URL(url)
  } catch {
    throw new Error(`Invalid entry: ${redactBatchLine(trimmed)}`)
  }
  const scheme = parsed.protocol.replace(/:$/, '')
  if (!config.schemes.includes(scheme) || !parsed.hostname) {
    throw new Error(`Invalid entry: ${redactBatchLine(trimmed)}`)
  }
  return {
    [config.urlField]: parsed.href,
    [config.nameField]: left?.trim() || `${parsed.hostname}:${parsed.port || (scheme === 'https' ? 443 : 80)}`,
    [config.schemeField]: scheme
  }
}

function base64Url(bytes: Uint8Array): string {
  return btoa(String.fromCharCode(...bytes))
    .replace(/\+/g, '-')
    .replace(/\//g, '_')
    .replace(/=+$/, '')
}

async function createPkceChallenge(verifier: string): Promise<string> {
  if (typeof crypto === 'undefined' || !crypto.subtle) return verifier
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(verifier))
  return base64Url(new Uint8Array(digest))
}

function generateRandomToken(byteCount: number): string {
  if (typeof crypto === 'undefined') return 'local-token'
  const bytes = new Uint8Array(byteCount)
  crypto.getRandomValues(bytes)
  return base64Url(bytes)
}

interface PkceSession {
  readonly verifier: string
  readonly state: string
  readonly authorizeUrl: string
}

export function redactUrlCredentials(rawUrl: string): string {
  try {
    const parsed = new URL(rawUrl)
    if (!parsed.username && !parsed.password) return parsed.href
    return `${parsed.protocol}//***@${parsed.host}${parsed.pathname}${parsed.search}${parsed.hash}`
  } catch {
    return rawUrl.replace(/\/\/[^/@\s]+@/, '//***@')
  }
}

function sanitizeConfirmValue(value: unknown): string {
  if (typeof value === 'string') return /^https?:\/\/|^socks5?:\/\//i.test(value) ? redactUrlCredentials(value) : value
  return (
    JSON.stringify(value, (_key, nested) => (typeof nested === 'string' ? sanitizeConfirmValue(nested) : nested)) ?? ''
  )
}

export function DeclarativeWizardModal({
  surface,
  open,
  i18nPrefix = 'console',
  onClose,
  onComplete,
  onExecute
}: {
  surface: DeclarativeSurfaceDescriptor
  open: boolean
  i18nPrefix?: string
  onClose: () => void
  onComplete?: () => void
  onExecute: (
    targetSurface: DeclarativeSurfaceDescriptor,
    payload: Record<string, unknown>
  ) => Promise<readonly Record<string, unknown>[]>
}) {
  const { t } = useTranslation()
  const steps = surface.stepSchemas
  const secretFieldNames = new Set(
    [...surface.fields, ...steps.flatMap(item => item.fields)]
      .filter(field => field.type === 'secret')
      .map(field => field.name)
  )
  const [stepIndex, setStepIndex] = useState(0)
  const [draft, setDraft] = useState<Record<string, unknown>>(() =>
    withFieldDefaults([...surface.fields, ...steps.flatMap(item => item.fields)])
  )
  const formRef = useRef<HTMLFormElement>(null)
  const [defaultScheme, setDefaultScheme] = useState('http')
  const [pkce, setPkce] = useState<PkceSession | null>(null)
  const [previewItems, setPreviewItems] = useState<readonly ParsedBatchItem[]>([])
  const [pending, setPending] = useState(false)
  const [error, setError] = useState<string | null>(null)

  const step = steps[stepIndex]
  const isFinal = stepIndex >= steps.length - 1
  const oauthStep = steps.find(item => item.kind === 'oauth_pkce' && item.oauthConfig)?.oauthConfig
  const batchStep = steps.find(item => item.kind === 'batch_lines' && item.batchLinesConfig)?.batchLinesConfig

  const batchParseResult = useMemo(() => {
    if (!batchStep) return { items: [] as ParsedBatchItem[], error: null as string | null }
    const text = String(draft[batchStep.textField] ?? '')
    const items: ParsedBatchItem[] = []
    for (const rawLine of text.split(/\r?\n/)) {
      const trimmed = rawLine.trim()
      if (!trimmed) continue
      try {
        items.push(parseBatchLine(trimmed, defaultScheme, batchStep))
      } catch (err) {
        const message = err instanceof Error ? err.message : String(err)
        return {
          items,
          error: message.replace(/((?:^|\/\/|\|\s*|\s))[^/\s:@|]+:[^/\s@|]+@/g, '$1***@')
        }
      }
    }
    return { items, error: null as string | null }
  }, [batchStep, defaultScheme, draft])
  const batchPreview = batchParseResult.items

  const generateAuthorizeUrl = async (config: DeclarativeOAuthPkceConfig) => {
    const rawRedirect = String(draft[config.redirectUriField] ?? '').trim()
    if (!rawRedirect) throw new Error('Redirect URI is required before starting OAuth authorization')
    const redirectUri = new URL(rawRedirect)
    const verifier = generateRandomToken(32)
    const challenge = await createPkceChallenge(verifier)
    const state = generateRandomToken(16)
    const params = new URLSearchParams({
      response_type: 'code',
      client_id: config.clientId,
      redirect_uri: redirectUri.href,
      scope: config.scope,
      code_challenge: challenge,
      code_challenge_method: 'S256',
      state
    })
    setPkce({
      verifier,
      state,
      authorizeUrl: `${config.authorizeEndpoint}?${params}`
    })
  }

  const validatedOAuthPayload = () => {
    if (!oauthStep || !pkce) throw new Error('Start OAuth authorization before submitting its callback')
    const callbackUrl = new URL(String(draft[oauthStep.callbackField] ?? '').trim())
    const redirectUrl = new URL(String(draft[oauthStep.redirectUriField] ?? '').trim())
    const code = callbackUrl.searchParams.get('code')
    if (
      !code ||
      callbackUrl.origin !== redirectUrl.origin ||
      callbackUrl.pathname !== redirectUrl.pathname ||
      callbackUrl.searchParams.get('state') !== pkce.state
    ) {
      throw new Error('OAuth callback URL did not match the active authorization request')
    }
    return {
      ...draft,
      [oauthStep.callbackField]: code,
      [oauthStep.redirectUriField]: redirectUrl.href,
      [oauthStep.verifierField]: pkce.verifier
    }
  }

  const handleAdvance = async () => {
    if (pending || !step || !formRef.current?.reportValidity()) return
    setPending(true)
    setError(null)
    try {
      if (step.kind === 'batch_lines' && batchStep) {
        if (batchParseResult.error) {
          throw new Error(batchParseResult.error)
        }
        if (batchPreview.length === 0) {
          throw new Error(t(`${i18nPrefix}.ui.no_entries`, { defaultValue: 'Enter at least one entry' }))
        }
        setPreviewItems(batchPreview)
      }

      if (!isFinal) {
        if (step.kind === 'oauth_pkce' && oauthStep) validatedOAuthPayload()
        setStepIndex(prev => prev + 1)
        return
      }

      if (oauthStep) {
        await onExecute(surface, serializeDeclarativeFields(surface, validatedOAuthPayload()))
        onComplete?.()
        onClose()
        return
      }

      if (batchStep) {
        const items = previewItems.length > 0 ? previewItems : batchPreview
        const result = await onExecute(surface, { [batchStep.listField]: items })
        const errors = result[0]?.errors
        if (Array.isArray(errors) && errors.length > 0) {
          if (errors.length === items.length) {
            throw new Error(
              t(`${i18nPrefix}.ui.import_failed`, { count: errors.length, defaultValue: 'Import failed' })
            )
          }
          toast.error(
            t(`${i18nPrefix}.ui.import_partial`, {
              count: errors.length,
              defaultValue: `${errors.length} entries failed to import`
            })
          )
          onClose()
          return
        }
        onComplete?.()
        onClose()
        return
      }

      await onExecute(surface, serializeDeclarativeFields(surface, draft))
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
          onSubmit={event => {
            event.preventDefault()
            void handleAdvance()
          }}
          className="grid min-h-0 flex-1 gap-4 overflow-y-auto pr-1">
          {(() => {
            if (!step) return null
            if (step.kind === 'oauth_pkce' && step.oauthConfig) {
              return (
                <div className="grid gap-3">
                  <div className="flex flex-wrap items-center gap-2">
                    <Button
                      size="sm"
                      type="button"
                      variant="outline"
                      onClick={() => void generateAuthorizeUrl(step.oauthConfig!).catch(err => setError(String(err)))}>
                      {t(`${i18nPrefix}.ui.generate_auth_url`, { defaultValue: 'Generate authorization URL' })}
                    </Button>
                    {pkce ? (
                      <>
                        <CopyButton
                          copiedLabel={t('common.copied', { defaultValue: 'Copied' })}
                          label={t('common.copy', { defaultValue: 'Copy URL' })}
                          value={pkce.authorizeUrl}
                        />
                        <a
                          className="text-sm underline"
                          href={pkce.authorizeUrl}
                          rel="noopener noreferrer"
                          target="_blank">
                          {t(`${i18nPrefix}.ui.open_auth_page`, { defaultValue: 'Open authorization page' })}
                        </a>
                      </>
                    ) : null}
                  </div>
                  {pkce ? <Input aria-label="Authorization URL" readOnly value={pkce.authorizeUrl} /> : null}
                  <DeclarativeFields draft={draft} fields={step.fields} i18nPrefix={i18nPrefix} onChange={setDraft} />
                </div>
              )
            }
            if (step.kind === 'batch_lines' && step.batchLinesConfig) {
              return (
                <div className="grid gap-3">
                  <LabeledField label={t(`${i18nPrefix}.ui.default_scheme`, { defaultValue: 'Default scheme' })}>
                    <DeclarativeSelect
                      label={t(`${i18nPrefix}.ui.default_scheme`, { defaultValue: 'Default scheme' })}
                      options={step.batchLinesConfig.schemes.map(scheme => [scheme, scheme.toUpperCase()])}
                      value={defaultScheme}
                      onChange={setDefaultScheme}
                    />
                  </LabeledField>
                  <LabeledField
                    label={t(step.labelKey, { defaultValue: formatIdentifierLabel(step.id) })}
                    description={t(`${i18nPrefix}.ui.batch_lines_hint`, {
                      defaultValue: 'One entry per line (URL or name|URL).'
                    })}>
                    <Textarea
                      rows={6}
                      spellCheck={false}
                      value={String(draft[step.batchLinesConfig.textField] ?? '')}
                      onChange={event => setDraft({ ...draft, [step.batchLinesConfig!.textField]: event.target.value })}
                    />
                  </LabeledField>
                </div>
              )
            }
            if ((step.kind === 'preview_items' || step.kind === 'confirm') && batchStep) {
              return (
                <div className="overflow-x-auto border border-border-subtle">
                  <Table>
                    <TableHeader>
                      <TableRow>
                        <TableHead>Name</TableHead>
                        <TableHead>Protocol</TableHead>
                        <TableHead>Endpoint</TableHead>
                      </TableRow>
                    </TableHeader>
                    <TableBody>
                      {(previewItems.length > 0 ? previewItems : batchPreview).map((item, idx) => (
                        <TableRow key={`${item[batchStep.nameField]}-${idx}`}>
                          <TableCell>{item[batchStep.nameField]}</TableCell>
                          <TableCell>{item[batchStep.schemeField]}</TableCell>
                          <TableCell className="font-mono text-xs">
                            {redactUrlCredentials(item[batchStep.urlField]!)}
                          </TableCell>
                        </TableRow>
                      ))}
                    </TableBody>
                  </Table>
                </div>
              )
            }
            if (step.kind === 'confirm') {
              return (
                <dl className="grid gap-x-4 gap-y-2 border border-border-subtle p-3 text-sm sm:grid-cols-[10rem_1fr]">
                  {Object.entries(asRecord(draft))
                    .filter(([key]) => {
                      if (oauthStep && (key === oauthStep.callbackField || key === oauthStep.verifierField)) {
                        return false
                      }
                      return !secretFieldNames.has(key)
                    })
                    .map(([key, val]) => (
                      <div key={key} className="contents">
                        <dt className="text-fg-secondary">{formatIdentifierLabel(key)}</dt>
                        <dd className="break-all font-mono text-xs">{sanitizeConfirmValue(val)}</dd>
                      </div>
                    ))}
                </dl>
              )
            }
            return <DeclarativeFields draft={draft} fields={step.fields} i18nPrefix={i18nPrefix} onChange={setDraft} />
          })()}

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
              onClick={() => setStepIndex(prev => prev - 1)}>
              {t('common.back', { defaultValue: 'Back' })}
            </Button>
          ) : null}
          <Button disabled={pending} size="sm" type="button" variant="outline" onClick={onClose}>
            {t('common.cancel', { defaultValue: 'Cancel' })}
          </Button>
          <Button disabled={pending} size="sm" type="button" onClick={() => void handleAdvance()}>
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
  i18nPrefix = 'console',
  onComplete,
  onExecute
}: {
  surface: DeclarativeSurfaceDescriptor
  i18nPrefix?: string
  onComplete?: () => void
  onExecute: (
    targetSurface: DeclarativeSurfaceDescriptor,
    payload: Record<string, unknown>
  ) => Promise<readonly Record<string, unknown>[]>
}) {
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
          onClose={() => setOpen(false)}
          onComplete={onComplete}
          onExecute={onExecute}
        />
      ) : null}
    </>
  )
}
