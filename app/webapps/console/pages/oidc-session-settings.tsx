import { Badge, Button, Checkbox, Input, Textarea, toast } from '@ankole/uikit'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useTranslation } from 'react-i18next'
import {
  ankoleWebIdentityProviderControllerIndexOptions,
  ankoleWebOidcClientControllerLogoutDeliveriesOptions,
  ankoleWebOidcClientControllerRetryLogoutMutation
} from '../api/generated/@tanstack/react-query.gen'
import { ErrorBlock } from '../../common/error-block'
import { requestErrorMessage } from '../../common/request-errors'
import { LabeledField } from '../console-form'
import type { ClientDraft } from '../state/oidc-client-editor-model'

export function OIDCSessionSettings({
  draft,
  setDraft
}: {
  draft: ClientDraft
  setDraft: (draft: ClientDraft) => void
}) {
  const { t } = useTranslation()
  const providers = useQuery(ankoleWebIdentityProviderControllerIndexOptions())
  return (
    <section className="grid gap-5 border-b border-border pb-6">
      <h3 className="text-base font-semibold">{t('console.access_sessions.title')}</h3>
      <p className="text-sm text-muted-foreground">{t('console.access_sessions.providers_hint')}</p>
      <ErrorBlock error={providers.error} />
      <div className="grid gap-3">
        {(providers.data?.identity_providers ?? []).map(provider => (
          <label key={provider.provider_id} className="flex items-center gap-3 text-sm">
            <Checkbox
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
          .filter(id => !providers.data?.identity_providers.some(p => p.provider_id === id))
          .map(id => (
            <label key={id} className="flex items-center gap-3 text-sm">
              <Checkbox
                checked
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
          disabled={draft.type !== 'confidential'}
          checked={draft.allowInsecureLocalLogout}
          onCheckedChange={checked => setDraft({ ...draft, allowInsecureLocalLogout: checked === true })}
        />
        {t('console.access_sessions.local_http')}
      </label>
    </section>
  )
}

export function OIDCLogoutDeliveries({ clientID }: { clientID: string }) {
  const { t } = useTranslation()
  const queryClient = useQueryClient()
  const deliveries = useQuery({
    ...ankoleWebOidcClientControllerLogoutDeliveriesOptions({ path: { id: clientID } }),
    refetchInterval: 15000
  })
  const retry = useMutation({
    ...ankoleWebOidcClientControllerRetryLogoutMutation(),
    onSuccess: () => {
      void queryClient.invalidateQueries()
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
      {deliveries.data?.deliveries.length === 0 ? (
        <p className="text-sm text-muted-foreground">{t('console.access_sessions.no_deliveries')}</p>
      ) : null}
      {deliveries.data?.deliveries.map(item => (
        <div key={item.id} className="flex flex-wrap items-center justify-between gap-3 border border-border p-4">
          <div className="grid gap-1 text-sm">
            <span>
              {item.principal_uid} · {item.status} ·{' '}
              {t('console.access_sessions.attempts', { count: item.attempt_count })}
            </span>
            <code className="text-xs break-all text-muted-foreground">{item.session_id}</code>
            {item.last_error ? <span role="status">{item.last_error}</span> : null}
            <span className="text-xs text-muted-foreground">
              {item.delivered_at ?? item.next_attempt_at ?? item.deadline}
            </span>
          </div>
          {item.status !== 'delivered' ? (
            <Button
              type="button"
              variant="outline"
              size="sm"
              disabled={retry.isPending}
              onClick={() => retry.mutate({ path: { id: clientID, delivery_id: item.id } })}>
              {t('common.retry')}
            </Button>
          ) : null}
        </div>
      ))}
    </section>
  )
}
