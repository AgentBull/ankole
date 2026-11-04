import { Button, Dialog, DialogContent, DialogTitle } from '@ankole/uikit'
import { useModel } from '@preact/signals-react'
import { useSignals } from '@preact/signals-react/runtime'
import { useMutation } from '@tanstack/react-query'
import { useTranslation } from 'react-i18next'
import { ConfigField } from '../common/config-fields'
import { ErrorBlock } from '../common/error-block'
import * as api from './api/generated/sdk.gen'
import { CredentialBindingModel, type ConnectorConnection, type ConnectorDefinition } from './state/connectors'

export function CredentialBindingDialog({
  connection,
  subject,
  definition,
  onClose,
  onBound
}: {
  connection: ConnectorConnection
  subject: 'human' | 'app'
  definition?: ConnectorDefinition
  onClose(): void
  onBound(): Promise<unknown>
}) {
  useSignals()
  const { t, i18n } = useTranslation()
  const model = useModel(CredentialBindingModel)
  const bind = useMutation({
    mutationFn: () => {
      const options = { body: { data: { connection: connection.slug, credentials: model.credentials.value } } }
      return subject === 'human'
        ? api.podConnectorAccountsConnectPersonal(options)
        : api.podConnectorAccountsConnectTeam(options)
    },
    onSuccess: onBound
  })
  const credentials = model.credentials.value
  const personal = subject === 'human'
  const fields = personal
    ? (definition?.personal_credential_fields ?? [])
    : [...(definition?.credential_fields ?? []), ...(definition?.public_fields ?? [])].filter(
        field => !Array.isArray(field.schemes) || field.schemes.includes(connection.auth_scheme ?? '')
      )
  return (
    <Dialog
      open
      onOpenChange={open => {
        if (!open) onClose()
      }}>
      <DialogContent closeLabel={t('common.close')} className="max-h-[85dvh] overflow-y-auto">
        <DialogTitle>
          {t(personal ? 'pod.connectors.bind_personal_token' : 'pod.connectors.bind_team_credentials')}
        </DialogTitle>
        <ErrorBlock error={bind.error} />
        <form
          method="post"
          className="grid gap-4"
          onSubmit={event => {
            event.preventDefault()
            bind.mutate()
          }}>
          <p className="text-sm text-muted-foreground">{connection.display_name}</p>
          {connection.plugin_id === 'figma' ? (
            <div className="grid gap-3 text-sm">
              <ol className="list-decimal space-y-2 pl-5">
                <li>
                  <a
                    href="https://www.figma.com/settings"
                    target="_blank"
                    rel="noreferrer"
                    className="underline underline-offset-4">
                    {t('pod.connectors.figma_step_settings')}
                  </a>
                </li>
                <li>{t('pod.connectors.figma_step_scopes')}</li>
                <li>{t('pod.connectors.figma_step_paste')}</li>
              </ol>
              <p className="text-muted-foreground">
                {t(personal ? 'pod.connectors.personal_description' : 'pod.connectors.team_description')}
              </p>
            </div>
          ) : ['stripe', 'sentry', 'zendesk'].includes(connection.plugin_id ?? '') ? (
            <p className="text-sm text-muted-foreground">{t(`pod.connectors.guide_${connection.plugin_id}`)}</p>
          ) : null}
          {fields.map(field => {
            const path = String(field.key)
            return (
              <ConfigField
                key={path}
                locale={i18n.language}
                field={{
                  path,
                  label: {
                    default: personal ? t('pod.connectors.personal_access_token') : String(field.label ?? path)
                  },
                  type: String(field.type ?? 'string'),
                  encrypted: field.secret === true,
                  required: field.required === true
                }}
                value={credentials[path] ?? field.default ?? ''}
                required={field.required === true}
                onChange={value => {
                  model.credentials.value = { ...model.credentials.value, [path]: value }
                }}
              />
            )
          })}
          <p className="text-sm text-muted-foreground">{t('pod.connectors.credentials_verify_hint')}</p>
          <Button type="submit" disabled={bind.isPending}>
            {t(bind.isPending ? 'pod.connectors.credentials_verifying' : 'pod.connectors.credentials_verify_connect')}
          </Button>
        </form>
      </DialogContent>
    </Dialog>
  )
}
