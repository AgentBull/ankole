import { useMutation, useQuery } from '../tenant-context'
import { Badge, Button, Checkbox, Input, Textarea, toast } from '@ankole/uikit'

import { useTranslation } from 'react-i18next'
import {
  listOidcLoginSourcesOptions,
  listOidcLogoutDeliveriesOptions,
  listPrincipalsOptions,
  retryOidcLogoutDeliveryMutation
} from '../api/v2/generated/@tanstack/react-query.gen'
import { fromDocument } from '../api/json-api'
import { ErrorBlock } from '../../common/error-block'
import { requestErrorMessage } from '../../common/request-errors'
import { LabeledField } from '../console-form'
import { formatConsoleDate } from '../console-primitives'
import type { ClientDraft } from '../state/oidc-client-editor-model'
import { principalLabel } from '../state/principal-label'

export function OIDCSessionSettings({
  disabled,
  draft,
  setDraft
}: {
  disabled: boolean
  draft: ClientDraft
  setDraft: (draft: ClientDraft) => void
}) {
  const { t } = useTranslation()
  const providers = useQuery(listOidcLoginSourcesOptions())
  return (
    <section className="grid gap-5 border-b border-border pb-6">
      <h3 className="text-base font-semibold">{t('console.access_sessions.title')}</h3>
      <p className="text-sm text-muted-foreground">{t('console.access_sessions.providers_hint')}</p>
      <ErrorBlock error={providers.error} />
      <div className="grid gap-3">
        {(providers.data?.sources ?? []).map(provider => (
          <label key={provider.provider_id} className="flex items-center gap-3 text-sm">
            <Checkbox
              disabled={disabled}
              checked={draft.allowedIdentityProviderIDs.includes(provider.provider_id)}
              onCheckedChange={checked =>
                setDraft({
                  ...draft,
                  allowedIdentityProviderIDs: checked
                    ? [...draft.allowedIdentityProviderIDs, provider.provider_id]
                    : draft.allowedIdentityProviderIDs.filter(id => id !== provider.provider_id)
                })
              }
            />
            <span>{provider.provider_id}</span>
            <Badge variant="outline">
              {t(provider.enabled ? 'console.status.enabled' : 'console.status.disabled')}
            </Badge>
          </label>
        ))}
        {draft.allowedIdentityProviderIDs
          .filter(id => !providers.data?.sources.some(p => p.provider_id === id))
          .map(id => (
            <label key={id} className="flex items-center gap-3 text-sm">
              <Checkbox
                checked
                disabled={disabled}
                onCheckedChange={() =>
                  setDraft({
                    ...draft,
                    allowedIdentityProviderIDs: draft.allowedIdentityProviderIDs.filter(value => value !== id)
                  })
                }
              />
              {id}
            </label>
          ))}
      </div>
      <LabeledField
        label={t('console.access_sessions.backchannel_uri')}
        description={t('console.access_sessions.backchannel_hint')}>
        <Input
          type="url"
          value={draft.backchannelLogoutURI}
          onChange={e => setDraft({ ...draft, backchannelLogoutURI: e.target.value })}
          placeholder="https://"
        />
      </LabeledField>
      <label className="flex items-center gap-3 text-sm">
        <Checkbox
          disabled={disabled}
          checked={draft.backchannelLogoutSessionRequired}
          onCheckedChange={checked => setDraft({ ...draft, backchannelLogoutSessionRequired: checked === true })}
        />
        {t('console.access_sessions.require_sid')}
      </label>
      <LabeledField
        label={t('console.access_sessions.post_logout_uris')}
        description={t('console.access_sessions.post_logout_hint')}>
        <Textarea
          rows={3}
          value={draft.postLogoutRedirectURIs}
          onChange={e => setDraft({ ...draft, postLogoutRedirectURIs: e.target.value })}
        />
      </LabeledField>
      <label className="flex items-center gap-3 text-sm">
        <Checkbox
          disabled={disabled || draft.type !== 'confidential'}
          checked={draft.allowInsecureLocalLogout}
          onCheckedChange={checked => setDraft({ ...draft, allowInsecureLocalLogout: checked === true })}
        />
        {t('console.access_sessions.local_http')}
      </label>
    </section>
  )
}

type LogoutDeliveryItem = {
  id: string
  session_id: string
  principal_uid: string
  status: 'pending' | 'delivering' | 'failed' | 'delivered'
  attempt_count: number
  next_attempt_at: string | null
  delivered_at: string | null
  deadline: string
  last_error: string | null
}

export function OIDCLogoutDeliveries({ clientID }: { clientID: string }) {
  const { t } = useTranslation()
  const deliveries = useQuery({
    ...listOidcLogoutDeliveriesOptions({ path: { client_id: clientID } }),
    select: document => fromDocument(document) as LogoutDeliveryItem[],
    refetchInterval: 15000
  })
  const principals = useQuery({
    ...listPrincipalsOptions({ query: { include_disabled: true } }),
    select: document => fromDocument(document),
    enabled: Boolean(deliveries.data && deliveries.data.length > 0)
  })
  const principalByUID = new Map((principals.data ?? []).map(principal => [principal.id, principal]))
  const retry = useMutation({
    ...retryOidcLogoutDeliveryMutation(),
    onSuccess: () => {
      toast.success(t('console.access_sessions.retry_started'))
    },
    onError: error => toast.error(requestErrorMessage(error))
  })
  return (
    <section className="grid gap-4 border-t border-border pt-6">
      <h3 className="text-base font-semibold">{t('console.access_sessions.deliveries')}</h3>
      <p className="text-sm text-muted-foreground">{t('console.access_sessions.delivery_hint')}</p>
      <ErrorBlock error={deliveries.error} />
      {deliveries.isLoading ? <p role="status">{t('common.loading')}</p> : null}
      {deliveries.data?.length === 0 ? (
        <p className="text-sm text-muted-foreground">{t('console.access_sessions.no_deliveries')}</p>
      ) : null}
      {deliveries.data?.map(item => {
        const principal = item.principal_uid ? principalByUID.get(item.principal_uid) : undefined
        const actorDisplay = principal ? principalLabel(principal) : (item.principal_uid ?? '—')
        const statusDisplay = t(`console.access_sessions.status_${item.status}`, { defaultValue: item.status })
        const timestamp = item.delivered_at ?? item.next_attempt_at ?? item.deadline
        return (
          <div key={item.id} className="flex flex-wrap items-center justify-between gap-3 border border-border p-4">
            <div className="grid gap-1 text-sm">
              <span>
                <span title={item.principal_uid ?? undefined}>{actorDisplay}</span> · {statusDisplay} ·{' '}
                {t('console.access_sessions.attempts', { count: item.attempt_count })}
              </span>
              <code className="text-xs break-all text-muted-foreground">{item.session_id}</code>
              {item.last_error ? <span role="status">{item.last_error}</span> : null}
              <span className="text-xs text-muted-foreground">{formatConsoleDate(timestamp)}</span>
            </div>
            {item.status !== 'delivered' ? (
              <Button
                type="button"
                variant="outline"
                size="sm"
                disabled={retry.isPending}
                onClick={() => retry.mutate({ path: { client_id: clientID, id: item.id } })}>
                {t('common.retry')}
              </Button>
            ) : null}
          </div>
        )
      })}
    </section>
  )
}
