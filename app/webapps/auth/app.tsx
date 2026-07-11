import { Card, CardContent, CardHeader } from '@ankole/uikit/components/card'
import { useMutation, useQuery } from '@tanstack/react-query'
import { useTranslation } from 'react-i18next'
import { internalAPIGet, internalAPIPost } from '../common/internal-api-client'
import { requestErrorMessage } from '../common/request-errors'

type LoginProvider = {
  adapterID: string
  pluginID: string
  providerID: string
}

/** Renders the admin sign-in SPA and starts OIDC for the chosen provider. */
export function AuthApp() {
  const { t } = useTranslation()
  const providers = useQuery({
    queryKey: ['identity-providers'],
    queryFn: () => internalAPIGet<{ providers: LoginProvider[] }>('/.internal-apis/identity-providers')
  })
  const mutation = useMutation({
    mutationFn: (providerID: string) => {
      const returnTo = new URLSearchParams(window.location.search).get('return_to') ?? '/console'
      // The server validates and stores the OIDC state. The SPA only passes the
      // desired return path so the callback can land back in the correct screen.
      return internalAPIPost<{ authorizationURL: string }>(
        `/.internal-apis/identity-providers/${encodeURIComponent(providerID)}/oidc/authorizations?return_to=${encodeURIComponent(returnTo)}`
      )
    },
    onSuccess: result => window.location.assign(result.authorizationURL)
  })

  return (
    <main className="ak-auth-page">
      <Card className="ak-auth-card">
        <CardHeader>
          <div>
            <p className="ak-eyebrow">Ankole</p>
            <h1>{t('auth.title')}</h1>
            <p>{t('auth.description')}</p>
          </div>
        </CardHeader>
        <CardContent>
          {providers.error || mutation.error ? (
            <div className="ak-error" role="alert">
              <strong>{t('common.error')}</strong>
              <span>{requestErrorMessage(providers.error ?? mutation.error)}</span>
            </div>
          ) : null}
          <div className="ak-login-list">
            {(providers.data?.providers ?? []).map(provider => (
              <button
                className="ak-login-provider"
                disabled={mutation.isPending}
                key={provider.providerID}
                type="button"
                onClick={() => mutation.mutate(provider.providerID)}>
                <span>
                  <strong>{provider.providerID}</strong>
                  <small>
                    {provider.adapterID} · {provider.pluginID}
                  </small>
                </span>
                <span>{t('auth.sign_in')}</span>
              </button>
            ))}
          </div>
          {!providers.isLoading && (providers.data?.providers ?? []).length === 0 ? (
            <p className="ak-muted">{t('auth.no_providers')}</p>
          ) : null}
          {providers.isLoading ? <p className="ak-muted">{t('common.loading')}</p> : null}
        </CardContent>
      </Card>
    </main>
  )
}
