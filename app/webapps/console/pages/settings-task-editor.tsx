import { Button, Input, Switch } from '@ankole/uikit'
import { useState } from 'react'
import { useTranslation } from 'react-i18next'
import type { AppConfigurationItem } from '../api/configuration-types'
import { LabeledField } from '../console-form'
import { SettingGroupField } from './setting-group-field'
import { SettingValueEditor } from './setting-value-editors'
import { requestErrorMessage } from '../../common/request-errors'

export function SettingsTaskEditor({
  group,
  items,
  drafts,
  onDraftChange,
  onRestore,
  saving,
  testMail
}: {
  group: string
  items: AppConfigurationItem[]
  drafts: Record<string, string>
  onDraftChange: (key: string, value: string) => void
  onRestore: (item: AppConfigurationItem) => void
  saving: boolean
  testMail: (settings: Record<string, unknown>, recipient: string) => Promise<unknown>
}) {
  const { t } = useTranslation()
  if (group === 'smtp') {
    const item = items[0]
    return item ? (
      <SettingGroupField
        item={item}
        label={t('console.settings.group_smtp')}
        description={item.description ?? ''}
        saving={saving}
        onRestore={onRestore}>
        <SmtpSettingsEditor
          item={item}
          value={drafts[item.key] ?? '{}'}
          onChange={value => onDraftChange(item.key, value)}
          testMail={testMail}
        />
      </SettingGroupField>
    ) : null
  }
  return (
    <div className="grid gap-7">
      {group === 'pod-access' ? (
        <p className="text-sm text-muted-foreground">{t('console.settings.guest_access_warning')}</p>
      ) : null}
      {items.map(item => (
        <SettingGroupField
          key={item.key}
          item={item}
          label={t(`console.settings.label_${item.key.split('.').at(-1)}`, { defaultValue: item.key })}
          description={item.description ?? ''}
          saving={saving}
          onRestore={onRestore}>
          <SettingValueEditor
            required={group !== 'turnstile' || drafts['saas.turnstile.enabled'] === 'true'}
            item={item}
            value={drafts[item.key] ?? ''}
            onChange={value => onDraftChange(item.key, value)}
          />
        </SettingGroupField>
      ))}
      {group === 'turnstile' ? (
        <p className="text-sm text-muted-foreground">{t('console.settings.turnstile_disable_hint')}</p>
      ) : null}
    </div>
  )
}

function SmtpSettingsEditor({
  item,
  value,
  onChange,
  testMail
}: {
  item: AppConfigurationItem
  value: string
  onChange: (value: string) => void
  testMail: (settings: Record<string, unknown>, recipient: string) => Promise<unknown>
}) {
  const { t } = useTranslation()
  const [recipient, setRecipient] = useState('')
  const [result, setResult] = useState<{ draft: string; recipient: string; message: string; pending?: boolean }>()
  let draft: Record<string, unknown> = {}
  try {
    draft = JSON.parse(value)
  } catch {
    /* Invalid input remains a form error. */
  }
  const set = (key: string, next: unknown) => onChange(JSON.stringify({ ...draft, [key]: next }))
  const runTest = async () => {
    const snapshot = value
    const to = recipient.trim()
    if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(recipient.trim())) {
      setResult({ draft: snapshot, recipient: to, message: t('console.settings.test_recipient_required') })
      return
    }
    setResult({ draft: snapshot, recipient: to, message: t('console.settings.mail_testing'), pending: true })
    try {
      await testMail(draft, recipient.trim())
      setResult({ draft: snapshot, recipient: to, message: t('console.settings.mail_accepted') })
    } catch (error) {
      setResult({ draft: snapshot, recipient: to, message: requestErrorMessage(error) })
    }
  }
  return (
    <section className="grid gap-5" data-setting-key={item.key}>
      {['server', 'port', 'from', 'username', 'password'].map(field => (
        <LabeledField
          key={field}
          label={t(`console.settings.smtp_${field}`)}
          required={field === 'server' || field === 'from'}>
          <Input
            data-setting-field={field}
            type={field === 'port' ? 'number' : field === 'password' ? 'password' : field === 'from' ? 'email' : 'text'}
            min={field === 'port' ? 1 : undefined}
            max={field === 'port' ? 65535 : undefined}
            required={field === 'server' || field === 'from'}
            value={String(draft[field] ?? (field === 'port' ? 587 : ''))}
            autoComplete="off"
            placeholder={
              field === 'password' && item.secret_present ? t('console.settings.keep_saved_password') : undefined
            }
            onChange={event => set(field, field === 'port' ? Number(event.target.value) : event.target.value)}
          />
        </LabeledField>
      ))}
      {Object.hasOwn(draft, 'password') && item.secret_present ? (
        <Button
          type="button"
          variant="ghost"
          className="w-fit"
          onClick={() => {
            const next = { ...draft }
            delete next.password
            onChange(JSON.stringify(next))
          }}>
          {t('console.settings.keep_saved_password')}
        </Button>
      ) : null}
      <label className="flex items-center gap-3">
        <Switch
          checked={draft.ssl === true}
          onCheckedChange={next => set('ssl', next)}
          aria-label={t('console.settings.smtp_implicit_tls')}
        />
        {t('console.settings.smtp_implicit_tls')}
      </label>
      <p className="text-xs text-muted-foreground">{t('console.settings.smtp_tls_hint')}</p>
      <details>
        <summary className="text-sm">{t('console.settings.advanced')}</summary>
        <LabeledField label={t('console.settings.smtp_cacertfile')}>
          <Input value={String(draft.cacertfile ?? '')} onChange={event => set('cacertfile', event.target.value)} />
        </LabeledField>
      </details>
      <div className="grid gap-3 border-t border-border pt-5">
        <LabeledField label={t('console.settings.test_recipient')}>
          <Input inputMode="email" value={recipient} onChange={event => setRecipient(event.target.value)} />
        </LabeledField>
        <Button
          type="button"
          variant="outline"
          className="w-fit"
          disabled={result?.pending}
          onClick={() => void runTest()}>
          {t('console.settings.test_draft_mail')}
        </Button>
        {result ? (
          <p role="status" className="text-sm">
            {result.draft === value && result.recipient === recipient.trim()
              ? result.message
              : t('console.settings.mail_draft_changed')}
          </p>
        ) : null}
        <p className="text-xs text-muted-foreground">{t('console.settings.mail_draft_hint')}</p>
      </div>
    </section>
  )
}
