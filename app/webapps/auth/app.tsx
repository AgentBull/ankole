import { Card, CardContent, CardHeader } from '@ankole/uikit/components/card'
import { useMutation, useQuery } from '@tanstack/react-query'
import { useTranslation } from 'react-i18next'
import { apiErrorMessage, apiGet, apiPost } from '../common/api'

type LoginProvider = {
  adapterId: string
  pluginId: string
  providerId: string
}

/** Renders the admin sign-in SPA and starts OIDC for the chosen provider. */
export function AuthApp() {
  const { t } = useTranslation()
  const providers = useQuery({
    queryKey: ['identity-providers'],
    queryFn: () => apiGet<{ providers: LoginProvider[] }>('/.internal-apis/identity-providers')
  })
  const mutation = useMutation({
    mutationFn: (providerId: string) => {
      const returnTo = new URLSearchParams(window.location.search).get('return_to') ?? '/console'
      // The server validates and stores the OIDC state. The SPA only passes the
      // desired return path so the callback can land back in the correct screen.
      return apiPost<{ authorizationUrl: string }>(
        `/.internal-apis/identity-providers/${encodeURIComponent(providerId)}/oidc/authorizations?return_to=${encodeURIComponent(returnTo)}`
      )
    },
    onSuccess: result => window.location.assign(result.authorizationUrl)
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
              <span>{apiErrorMessage(providers.error ?? mutation.error)}</span>
            </div>
          ) : null}
          <div className="ak-login-list">
            {(providers.data?.providers ?? []).map(provider => (
              <button
                className="ak-login-provider"
                disabled={mutation.isPending}
                key={provider.providerId}
                type="button"
                onClick={() => mutation.mutate(provider.providerId)}>
                <span>
                  <strong>{provider.providerId}</strong>
                  <small>
                    {provider.adapterId} · {provider.pluginId}
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
